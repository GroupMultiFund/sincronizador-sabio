#Requires -Version 5.1
<#
    SINCRONIZADOR SÁBIO — módulo principal

    Lê tabelas do ZoneSoft (SQL Server, só leitura) e envia-as, cifradas,
    para o Worker de entrada, que as grava no arquivo D1.

    Regras que este módulo aplica e que o Worker volta a aplicar do lado
    de lá (o teste Regras.Tests.ps1 confirma que são iguais nos dois):
      · só tabelas da lista (tabelas.json + TabelasPermitidas);
      · nunca colunas com credenciais nem dados pessoais;
      · nunca tipos binários.
#>

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ caminhos
function Get-SabioDirInstalacao {
    if ($env:SABIO_INSTALACAO) { return $env:SABIO_INSTALACAO }
    return $PSScriptRoot
}

function Get-SabioDirDados {
    if ($env:SABIO_DADOS) { return $env:SABIO_DADOS }
    return (Join-Path $env:ProgramData 'SincronizadorSabio')
}

function Get-SabioVersaoInstalada {
    $f = Join-Path (Get-SabioDirInstalacao) 'versao.json'
    if (-not (Test-Path -LiteralPath $f)) { return '0.0.0' }
    return [string](Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json).versao
}

function Get-SabioPropriedade {
    param($Objecto, [string]$Nome, $PorOmissao = $null)
    if ($null -eq $Objecto) { return $PorOmissao }
    if ($Objecto -is [System.Collections.IDictionary]) {
        if ($Objecto.Contains($Nome)) { return $Objecto[$Nome] }
        return $PorOmissao
    }
    $p = $Objecto.PSObject.Properties[$Nome]
    if ($null -eq $p) { return $PorOmissao }
    return $p.Value
}

# ------------------------------------------------------------------ regras (espelho do worker.js)
# REGRAS:INICIO — não mudar o formato destas linhas: o teste lê-as.
$script:TabelasPermitidas = @('anulacoes', 'caixa', 'caixadia', 'compensacoes', 'docpag', 'documentos', 'documentos_pessoas', 'empregados', 'emppostos', 'empzonas', 'familias', 'fichaingredientes', 'fichatecnica', 'historico_mesas', 'historico_precos', 'mapamesas', 'marcacoes', 'mesasmov', 'postos', 'produtos', 'quebras', 'subfamilias', 'tblstockmov', 'tipospagamento', 'venda_dif_valores', 'vendas', 'zonas')
$script:PadraoCredencial = 'pass|senha|pwd|token|secret|apikey|api_key|certific|^pin$|^login$'
$script:PadraoPessoal = 'contribuinte|morada|telefone|telemovel|e_?mail|nascimento|codpostal|codigo_postal|localidade|^carga$|^descarga$|iban|matricula|foto|nomecontacto|nome_contacto|identificacao|rfid'
$script:ColunasProibidasTabela = @{ documentos = @('nome'); empregados = @('obs'); marcacoes = @('obs') }
$script:ColunasDerivadas = @{ documentos = @('_tem_nif') }
# REGRAS:FIM

# Só o POS sabe calcular as derivadas: o SQL corre no SQL Server de origem.
# 999999990 é o NIF genérico de "consumidor final" — não conta como ter NIF.
$script:ExpressoesDerivadas = @{
    documentos = @{
        _tem_nif = @{
            requer = 'contribuinte'
            sql    = "CASE WHEN LTRIM(RTRIM(ISNULL(CAST([contribuinte] AS varchar(50)), ''))) IN ('', '0', '999999990') THEN 0 ELSE 1 END"
        }
    }
}

$script:TiposD1 = @{
    'int' = 'INTEGER'; 'bigint' = 'INTEGER'; 'smallint' = 'INTEGER'; 'tinyint' = 'INTEGER'; 'bit' = 'INTEGER'
    'float' = 'REAL'; 'real' = 'REAL'
    'money' = 'TEXT'; 'smallmoney' = 'TEXT'; 'decimal' = 'TEXT'; 'numeric' = 'TEXT'
    'datetime' = 'TEXT'; 'smalldatetime' = 'TEXT'; 'datetime2' = 'TEXT'; 'date' = 'TEXT'; 'time' = 'TEXT'; 'datetimeoffset' = 'TEXT'
    'char' = 'TEXT'; 'varchar' = 'TEXT'; 'nchar' = 'TEXT'; 'nvarchar' = 'TEXT'; 'text' = 'TEXT'; 'ntext' = 'TEXT'
    'uniqueidentifier' = 'TEXT'
}

function Get-SabioTipoD1 {
    param([string]$TipoSql)
    $t = $TipoSql.ToLowerInvariant()
    if ($script:TiposD1.ContainsKey($t)) { return $script:TiposD1[$t] }
    return $null
}

function Test-SabioTabelaPermitida {
    param([string]$Tabela)
    return ($script:TabelasPermitidas -contains $Tabela.ToLowerInvariant())
}

function Test-SabioColunaPermitida {
    param([string]$Tabela, [string]$Coluna)
    $t = $Tabela.ToLowerInvariant()
    $c = $Coluna.ToLowerInvariant()
    if ([regex]::IsMatch($c, $script:PadraoCredencial, 'IgnoreCase')) { return $false }
    if ([regex]::IsMatch($c, $script:PadraoPessoal, 'IgnoreCase')) { return $false }
    if ($script:ColunasProibidasTabela.ContainsKey($t) -and ($script:ColunasProibidasTabela[$t] -contains $c)) { return $false }
    return $true
}

# ------------------------------------------------------------------ núcleo em C#
# Serialização de valores, hashes e criptografia. Em C# porque é o caminho
# quente (centenas de milhares de valores) e porque os tipos têm de ser
# tratados com exactidão: money não pode passar por double.
# C# 5 — é o compilador que vem com o .NET Framework dos POS.
$script:CodigoNucleo = @'
using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace SabioV1
{
    public sealed class Particao
    {
        public string Nome;
        public List<string> Linhas = new List<string>();
        public long Bytes;
        public string Hash;
    }

    public sealed class CorpoParticoes
    {
        private readonly StringBuilder sb = new StringBuilder(262144);
        private int quantas;
        public readonly string Tabela;

        public CorpoParticoes(string baseNome, string tabela, string[] colunas)
        {
            Tabela = tabela;
            sb.Append("{\"base\":"); Nucleo.Texto(sb, baseNome);
            sb.Append(",\"tabela\":"); Nucleo.Texto(sb, tabela);
            sb.Append(",\"colunas\":[");
            for (int i = 0; i < colunas.Length; i++) { if (i > 0) sb.Append(','); Nucleo.Texto(sb, colunas[i]); }
            sb.Append("],\"itens\":[");
        }

        public int Quantas { get { return quantas; } }
        public long Tamanho { get { return sb.Length; } }

        // Uma parte de uma partição comprimida. "dados" é um pedaço do base64
        // (no máximo 90 000 caracteres); "bytesTotal" é o tamanho do base64 inteiro.
        public void Acrescentar(Particao p, int parte, int partes, string lote, long bytesTotal, string dados)
        {
            if (quantas > 0) sb.Append(',');
            sb.Append("{\"p\":"); Nucleo.Texto(sb, p.Nome);
            sb.Append(",\"hash\":\"").Append(p.Hash).Append('"');
            sb.Append(",\"n_total\":").Append(p.Linhas.Count.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"parte\":").Append(parte.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"partes\":").Append(partes.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"bytes\":").Append(bytesTotal.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"lote\":");
            if (lote == null) sb.Append("null"); else Nucleo.Texto(sb, lote);
            sb.Append(",\"dados\":\"").Append(dados).Append("\"}");
            quantas++;
        }

        public string Fechar() { return sb.ToString() + "]}"; }
    }

    public static class Nucleo
    {
        private static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        private static readonly Encoding Utf8 = new UTF8Encoding(false);
        private static readonly byte[] Entropia = Encoding.ASCII.GetBytes("SincronizadorSabio|v1");

        // ---------------------------------------------------------- JSON
        public static void Texto(StringBuilder sb, string s)
        {
            sb.Append('"');
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c == '\u2028' || c == '\u2029')
                            sb.Append("\\u").Append(((int)c).ToString("x4", Inv));
                        else
                            sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        public static string TextoJson(string s)
        {
            StringBuilder sb = new StringBuilder(s.Length + 2);
            Texto(sb, s);
            return sb.ToString();
        }

        public static void Valor(StringBuilder sb, IDataRecord r, int i, string tipo)
        {
            if (r.IsDBNull(i)) { sb.Append("null"); return; }
            switch (tipo)
            {
                case "int": sb.Append(r.GetInt32(i).ToString(Inv)); return;
                case "smallint": sb.Append(r.GetInt16(i).ToString(Inv)); return;
                case "tinyint": sb.Append(r.GetByte(i).ToString(Inv)); return;
                case "bit": sb.Append(r.GetBoolean(i) ? "1" : "0"); return;
                case "bigint": sb.Append('"').Append(r.GetInt64(i).ToString(Inv)).Append('"'); return;
                case "money":
                case "smallmoney": sb.Append('"').Append(r.GetDecimal(i).ToString("0.0000", Inv)).Append('"'); return;
                case "decimal":
                case "numeric": sb.Append('"').Append(r.GetDecimal(i).ToString(Inv)).Append('"'); return;
                case "float": sb.Append('"').Append(r.GetDouble(i).ToString("R", Inv)).Append('"'); return;
                case "real": sb.Append('"').Append(r.GetFloat(i).ToString("R", Inv)).Append('"'); return;
                case "datetime":
                case "smalldatetime": sb.Append('"').Append(r.GetDateTime(i).ToString("yyyy-MM-dd'T'HH:mm:ss.fff", Inv)).Append('"'); return;
                case "datetime2": sb.Append('"').Append(r.GetDateTime(i).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff", Inv)).Append('"'); return;
                case "date": sb.Append('"').Append(r.GetDateTime(i).ToString("yyyy-MM-dd", Inv)).Append('"'); return;
                case "time": sb.Append('"').Append(((TimeSpan)r.GetValue(i)).ToString("hh\\:mm\\:ss\\.fffffff", Inv)).Append('"'); return;
                case "datetimeoffset": sb.Append('"').Append(((DateTimeOffset)r.GetValue(i)).ToString("o", Inv)).Append('"'); return;
                case "uniqueidentifier": sb.Append('"').Append(r.GetGuid(i).ToString("D")).Append('"'); return;
                case "char":
                case "varchar":
                case "nchar":
                case "nvarchar":
                case "text":
                case "ntext": Texto(sb, r.GetString(i)); return;
                default: throw new InvalidOperationException("tipo nao suportado: " + tipo);
            }
        }

        // ---------------------------------------------------------- leitura
        // modo: "dia" (particao = data da coluna indice), "chave" (blocos do
        // inteiro da coluna indice), "tabela" (tudo numa particao "t").
        public static Dictionary<string, Particao> Ler(SqlCommand cmd, string[] tipos, int indice, string modo, long balde)
        {
            Dictionary<string, Particao> saida = new Dictionary<string, Particao>(StringComparer.Ordinal);
            using (SqlDataReader r = cmd.ExecuteReader())
            {
                if (r.FieldCount != tipos.Length) throw new InvalidOperationException("colunas nao batem com os tipos");
                StringBuilder sb = new StringBuilder(1024);
                while (r.Read())
                {
                    sb.Length = 0;
                    sb.Append('[');
                    for (int i = 0; i < tipos.Length; i++)
                    {
                        if (i > 0) sb.Append(',');
                        Valor(sb, r, i, tipos[i]);
                    }
                    sb.Append(']');

                    string nome;
                    if (modo == "dia")
                    {
                        nome = r.IsDBNull(indice) ? "sem-data" : r.GetDateTime(indice).ToString("yyyy-MM-dd", Inv);
                    }
                    else if (modo == "chave")
                    {
                        if (r.IsDBNull(indice)) nome = "sem-chave";
                        else
                        {
                            long k = Convert.ToInt64(r.GetValue(indice), Inv);
                            long b = k >= 0 ? k / balde : -((-k + balde - 1) / balde);
                            nome = "k:" + b.ToString(Inv);
                        }
                    }
                    else nome = "t";

                    Particao p;
                    if (!saida.TryGetValue(nome, out p))
                    {
                        p = new Particao();
                        p.Nome = nome;
                        saida[nome] = p;
                    }
                    string linha = sb.ToString();
                    p.Linhas.Add(linha);
                    p.Bytes += Utf8.GetByteCount(linha) + 1;
                }
            }
            return saida;
        }

        // Ordena as linhas (a ordem de leitura do SQL Server não é garantida)
        // e calcula o hash sobre colunas + linhas. Duas leituras dos mesmos
        // dados dão sempre o mesmo hash; mudar um valor muda o hash.
        public static void Finalizar(Particao p, string[] colunas)
        {
            p.Linhas.Sort(StringComparer.Ordinal);
            using (SHA256 sha = SHA256.Create())
            {
                byte[] cab = Utf8.GetBytes("cols:" + string.Join(",", colunas) + "\n");
                sha.TransformBlock(cab, 0, cab.Length, null, 0);
                foreach (string l in p.Linhas)
                {
                    byte[] b = Utf8.GetBytes(l + "\n");
                    sha.TransformBlock(b, 0, b.Length, null, 0);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                p.Hash = Hex(sha.Hash);
            }
        }

        // Comprime EXACTAMENTE os bytes sobre os quais o hash foi calculado
        // (Finalizar tem de ter corrido antes). Assim, quem descomprimir pode
        // confirmar a integridade: SHA-256(conteúdo) == hash.
        public static string Comprimir(Particao p, string[] colunas)
        {
            using (System.IO.MemoryStream ms = new System.IO.MemoryStream())
            {
                using (System.IO.Compression.GZipStream gz = new System.IO.Compression.GZipStream(ms, System.IO.Compression.CompressionLevel.Optimal, true))
                {
                    byte[] cab = Utf8.GetBytes("cols:" + string.Join(",", colunas) + "\n");
                    gz.Write(cab, 0, cab.Length);
                    foreach (string l in p.Linhas)
                    {
                        byte[] b = Utf8.GetBytes(l + "\n");
                        gz.Write(b, 0, b.Length);
                    }
                }
                return Convert.ToBase64String(ms.ToArray());
            }
        }

        public static string Descomprimir(string b64)
        {
            byte[] dados = Convert.FromBase64String(b64);
            using (System.IO.MemoryStream entrada = new System.IO.MemoryStream(dados))
            using (System.IO.Compression.GZipStream gz = new System.IO.Compression.GZipStream(entrada, System.IO.Compression.CompressionMode.Decompress))
            using (System.IO.MemoryStream saida = new System.IO.MemoryStream())
            {
                gz.CopyTo(saida);
                return Utf8.GetString(saida.ToArray());
            }
        }

        // ---------------------------------------------------------- utilitários
        public static string Hex(byte[] b)
        {
            StringBuilder sb = new StringBuilder(b.Length * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2", Inv));
            return sb.ToString();
        }

        public static string Sha256Hex(byte[] dados)
        {
            using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(dados));
        }

        public static byte[] Aleatorio(int n)
        {
            byte[] b = new byte[n];
            using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) rng.GetBytes(b);
            return b;
        }

        public static bool IgualConstante(byte[] a, byte[] b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int x = 0;
            for (int i = 0; i < a.Length; i++) x |= a[i] ^ b[i];
            return x == 0;
        }

        public static byte[] Hmac(byte[] chave, string msg)
        {
            using (HMACSHA256 h = new HMACSHA256(chave)) return h.ComputeHash(Utf8.GetBytes(msg));
        }

        // ---------------------------------------------------------- chaves
        public static byte[] ChaveLoja(byte[] mestra, string loja, int versao)
        {
            if (mestra == null || mestra.Length != 32) throw new CryptographicException("a chave mestra tem de ter 32 bytes");
            return Hmac(mestra, "sabio|loja|" + loja + "|v" + versao.ToString(Inv));
        }

        public static string Impressao(byte[] chave)
        {
            return Sha256Hex(chave).Substring(0, 16);
        }

        // ---------------------------------------------------------- envelope
        private static byte[] Cifrar(byte[] chave, byte[] iv, byte[] dados)
        {
            using (Aes aes = Aes.Create())
            {
                aes.KeySize = 256; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                aes.Key = chave; aes.IV = iv;
                using (ICryptoTransform t = aes.CreateEncryptor()) return t.TransformFinalBlock(dados, 0, dados.Length);
            }
        }

        private static byte[] Decifrar(byte[] chave, byte[] iv, byte[] dados)
        {
            using (Aes aes = Aes.Create())
            {
                aes.KeySize = 256; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                aes.Key = chave; aes.IV = iv;
                using (ICryptoTransform t = aes.CreateDecryptor()) return t.TransformFinalBlock(dados, 0, dados.Length);
            }
        }

        private static string Envelope(byte[] kLoja, string rotulo, string loja, string caminho, string json, long ts, string nonce, bool comLojaENonce)
        {
            byte[] kEnc = Hmac(kLoja, "sabio|enc|v1");
            byte[] kMac = Hmac(kLoja, "sabio|mac|v1");
            try
            {
                byte[] iv = Aleatorio(16);
                string ivB = Convert.ToBase64String(iv);
                string ctB = Convert.ToBase64String(Cifrar(kEnc, iv, Utf8.GetBytes(json)));
                string mac = Convert.ToBase64String(Hmac(kMac, "v1|" + rotulo + "|" + loja + "|" + ts.ToString(Inv) + "|" + nonce + "|" + caminho + "|" + ivB + "|" + ctB));
                StringBuilder sb = new StringBuilder(ctB.Length + 256);
                sb.Append("{\"v\":1");
                if (comLojaENonce) { sb.Append(",\"loja\":"); Texto(sb, loja); }
                sb.Append(",\"ts\":").Append(ts.ToString(Inv));
                if (comLojaENonce) sb.Append(",\"nonce\":\"").Append(nonce).Append('"');
                sb.Append(",\"iv\":\"").Append(ivB).Append("\",\"ct\":\"").Append(ctB).Append("\",\"mac\":\"").Append(mac).Append("\"}");
                return sb.ToString();
            }
            finally
            {
                Array.Clear(kEnc, 0, kEnc.Length);
                Array.Clear(kMac, 0, kMac.Length);
            }
        }

        public static string Selar(byte[] kLoja, string loja, string caminho, string json, long ts, out string nonce)
        {
            nonce = Convert.ToBase64String(Aleatorio(16));
            return Envelope(kLoja, "pedido", loja, caminho, json, ts, nonce, true);
        }

        // Só para testes: simula o que o Worker devolve.
        public static string SelarResposta(byte[] kLoja, string loja, string caminho, string nonce, string json, long ts)
        {
            return Envelope(kLoja, "resposta", loja, caminho, json, ts, nonce, false);
        }

        public static string AbrirResposta(byte[] kLoja, string loja, string caminho, string nonce, string corpo, long agora, int janela)
        {
            string ivB, ctB, macB;
            long ts;
            try
            {
                JavaScriptSerializer js = new JavaScriptSerializer();
                js.MaxJsonLength = int.MaxValue;
                Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(corpo);
                if (Convert.ToInt32(d["v"], Inv) != 1) throw new CryptographicException("envelope");
                ts = Convert.ToInt64(d["ts"], Inv);
                ivB = (string)d["iv"]; ctB = (string)d["ct"]; macB = (string)d["mac"];
            }
            catch (CryptographicException) { throw; }
            catch (Exception) { throw new CryptographicException("envelope"); }

            if (Math.Abs(agora - ts) > janela) throw new CryptographicException("relogio");

            byte[] kEnc = Hmac(kLoja, "sabio|enc|v1");
            byte[] kMac = Hmac(kLoja, "sabio|mac|v1");
            try
            {
                byte[] esperado = Hmac(kMac, "v1|resposta|" + loja + "|" + ts.ToString(Inv) + "|" + nonce + "|" + caminho + "|" + ivB + "|" + ctB);
                byte[] recebido;
                try { recebido = Convert.FromBase64String(macB); } catch (FormatException) { throw new CryptographicException("autenticacao"); }
                if (!IgualConstante(esperado, recebido)) throw new CryptographicException("autenticacao");
                return Utf8.GetString(Decifrar(kEnc, Convert.FromBase64String(ivB), Convert.FromBase64String(ctB)));
            }
            finally
            {
                Array.Clear(kEnc, 0, kEnc.Length);
                Array.Clear(kMac, 0, kMac.Length);
            }
        }

        // ---------------------------------------------------------- DPAPI
        public static string Proteger(byte[] dados, bool maquina)
        {
            return Convert.ToBase64String(ProtectedData.Protect(dados, Entropia, maquina ? DataProtectionScope.LocalMachine : DataProtectionScope.CurrentUser));
        }

        public static byte[] Desproteger(string b64, bool maquina)
        {
            return ProtectedData.Unprotect(Convert.FromBase64String(b64), Entropia, maquina ? DataProtectionScope.LocalMachine : DataProtectionScope.CurrentUser);
        }

        // ---------------------------------------------------------- assinaturas (actualizações)
        public static bool VerificarAssinatura(string chavePublicaXml, byte[] dados, string assinaturaB64)
        {
            byte[] s;
            try { s = Convert.FromBase64String(assinaturaB64.Trim()); } catch (FormatException) { return false; }
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider())
            {
                rsa.PersistKeyInCsp = false;
                rsa.FromXmlString(chavePublicaXml);
                if (rsa.KeySize < 3072) return false;
                return rsa.VerifyData(dados, CryptoConfig.MapNameToOID("SHA256"), s);
            }
        }

        public static string Assinar(string chavePrivadaXml, byte[] dados)
        {
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider())
            {
                rsa.PersistKeyInCsp = false;
                rsa.FromXmlString(chavePrivadaXml);
                return Convert.ToBase64String(rsa.SignData(dados, CryptoConfig.MapNameToOID("SHA256")));
            }
        }

        public static string[] NovoParRsa()
        {
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(3072))
            {
                rsa.PersistKeyInCsp = false;
                return new string[] { rsa.ToXmlString(true), rsa.ToXmlString(false) };
            }
        }
    }
}
'@

if (-not ('SabioV1.Nucleo' -as [type])) {
    Add-Type -TypeDefinition $script:CodigoNucleo -Language CSharp -ReferencedAssemblies @('System.Data', 'System.Security', 'System.Web.Extensions', 'System.Xml')
}

# TLS 1.2 no mínimo. O PowerShell 5.1 ainda aceita TLS 1.0 por omissão.
$protocolos = [Net.SecurityProtocolType]::Tls12
try { $protocolos = $protocolos -bor [Net.SecurityProtocolType]'Tls13' } catch { }
[Net.ServicePointManager]::SecurityProtocol = $protocolos

# ------------------------------------------------------------------ registo
function Protect-SabioTextoRegisto {
    param([string]$Texto)
    if ($null -eq $Texto) { return '' }
    $t = $Texto
    $t = [regex]::Replace($t, '(?i)(password|pwd|senha|chave|token|secret)\s*[=:]\s*[^;\s,"]+', '$1=***')
    $t = [regex]::Replace($t, '[A-Za-z0-9+/]{40,}={0,2}', '***')
    if ($t.Length -gt 1000) { $t = $t.Substring(0, 1000) + '…' }
    return $t
}

function Write-SabioRegisto {
    param(
        [ValidateSet('INFO', 'AVISO', 'ERRO')][string]$Nivel,
        [string]$Mensagem
    )
    $dir = Join-Path (Get-SabioDirDados) 'registos'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $linha = '{0} {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Nivel, (Protect-SabioTextoRegisto $Mensagem)
    $ficheiro = Join-Path $dir ('sincronizador-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    [System.IO.File]::AppendAllText($ficheiro, $linha + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Verbose $linha
}

function Remove-SabioRegistosAntigos {
    param([int]$Dias = 30)
    $dir = Join-Path (Get-SabioDirDados) 'registos'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    Get-ChildItem -LiteralPath $dir -Filter '*.log' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Dias) } | Remove-Item -Force
}

# ------------------------------------------------------------------ ficheiros e permissões
function Write-SabioFicheiroAtomico {
    param([string]$Caminho, [string]$Conteudo)
    $tmp = $Caminho + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $Conteudo, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Caminho) {
        # [NullString]: o PowerShell passa $null como "" a métodos .NET, e o Replace recusa "".
        [System.IO.File]::Replace($tmp, $Caminho, [NullString]::Value)
    } else {
        [System.IO.File]::Move($tmp, $Caminho)
    }
}

# Pasta de dados: só SYSTEM e Administradores. Usa SIDs e não nomes, porque
# num Windows em português o grupo chama-se "Administradores".
#
# Lê e grava SÓ a secção de permissões. O Get-Acl/Set-Acl mexe também na
# auditoria (SACL), que exige SeSecurityPrivilege — que nem um administrador
# tem activo por omissão. Foi apanhado nos testes a 16-09-2026.
function Set-SabioAcl {
    param([string]$Caminho, [object[]]$Regras)   # Regras: @(@('S-1-5-18', 'FullControl'), ...)
    $item = Get-Item -LiteralPath $Caminho
    $acl = $item.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($r) }
    foreach ($par in $Regras) {
        $id = New-Object Security.Principal.SecurityIdentifier([string]$par[0])
        if ($item.PSIsContainer) {
            $regra = New-Object Security.AccessControl.FileSystemAccessRule($id, [string]$par[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        } else {
            $regra = New-Object Security.AccessControl.FileSystemAccessRule($id, [string]$par[1], 'Allow')
        }
        $acl.AddAccessRule($regra)
    }
    $item.SetAccessControl($acl)
}

function Set-SabioAclRestrito {
    param([string]$Caminho, [switch]$IncluirUtilizadorActual)
    $regras = @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'))
    if ($IncluirUtilizadorActual) { $regras += , @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'FullControl') }
    Set-SabioAcl -Caminho $Caminho -Regras $regras
}

# ------------------------------------------------------------------ configuração
function Get-SabioCaminhoConfig { Join-Path (Get-SabioDirDados) 'config.json' }

function Read-SabioConfig {
    $f = Get-SabioCaminhoConfig
    if (-not (Test-Path -LiteralPath $f)) { throw "Falta a configuracao ($f). Correr o configurador." }
    $c = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($obrigatorio in @('loja', 'sql', 'worker')) {
        if ($null -eq (Get-SabioPropriedade $c $obrigatorio)) { throw "Configuracao incompleta: falta '$obrigatorio'." }
    }
    $sinc = Get-SabioPropriedade $c 'sincronizacao'
    $act = Get-SabioPropriedade $c 'actualizacoes'
    $integrada = [bool](Get-SabioPropriedade $c.sql 'integrada' $false)

    $cfg = [pscustomobject]@{
        loja            = [string]$c.loja
        sqlServidor     = [string]$c.sql.servidor
        sqlBase         = [string]$c.sql.base
        sqlUtilizador   = [string](Get-SabioPropriedade $c.sql 'utilizador' '')
        sqlIntegrada    = $integrada
        sqlPassword     = $null
        workerUrl       = ([string]$c.worker.url).TrimEnd('/')
        chaveLoja       = $null
        fonte           = [string](Get-SabioPropriedade $act 'fonte' '')
        intervaloActH   = [double](Get-SabioPropriedade $act 'intervalo_horas' 6)
        intervaloMin    = [double](Get-SabioPropriedade $sinc 'intervalo_min' 60)
        intervaloRefMin = [double](Get-SabioPropriedade $sinc 'intervalo_referencia_min' 360)
        completaDias    = [double](Get-SabioPropriedade $sinc 'revisao_completa_dias' 30)
        loteKb          = [int](Get-SabioPropriedade $sinc 'lote_kb' 200)
        limiteEscritas  = [long](Get-SabioPropriedade $sinc 'limite_escritas_dia' 90000)
        inicio          = [string](Get-SabioPropriedade $sinc 'inicio' '')
        alterado        = (Get-Item -LiteralPath $f).LastWriteTimeUtc
    }
    if (-not $integrada) {
        $cfg.sqlPassword = [Text.Encoding]::UTF8.GetString([SabioV1.Nucleo]::Desproteger([string]$c.sql.password_dpapi, $true))
    }
    $cfg.chaveLoja = [SabioV1.Nucleo]::Desproteger([string]$c.worker.chave_dpapi, $true)
    if ($cfg.chaveLoja.Length -ne 32) { throw 'A chave da loja guardada nao tem 32 bytes.' }
    return $cfg
}

function Save-SabioConfig {
    param(
        [Parameter(Mandatory)][string]$Loja,
        [Parameter(Mandatory)][string]$Servidor,
        [Parameter(Mandatory)][string]$Base,
        [string]$Utilizador,
        [Security.SecureString]$Password,
        [switch]$Integrada,
        [Parameter(Mandatory)][string]$WorkerUrl,
        [Security.SecureString]$ChaveLoja,
        [string]$Fonte = '',
        [hashtable]$Sincronizacao = @{},
        [switch]$AclComUtilizadorActual
    )
    if ($Loja -notmatch '^[a-z0-9]{2,20}$') { throw 'Loja invalida: so minusculas e algarismos, 2 a 20.' }
    if ($Base -notmatch '^[A-Za-z0-9_]{1,64}$') { throw 'Nome de base de dados invalido.' }
    if ($WorkerUrl -notmatch '^https://[^\s/]+(/.*)?$') { throw 'O endereco do Worker tem de comecar por https://' }
    if ($Fonte -and $Fonte -notmatch '^https://' -and -not (Test-Path -LiteralPath $Fonte -PathType Container)) {
        throw 'A fonte de actualizacoes tem de ser https:// ou uma pasta existente.'
    }

    $anterior = $null
    $f = Get-SabioCaminhoConfig
    if (Test-Path -LiteralPath $f) { $anterior = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json }

    $dir = Get-SabioDirDados
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Segredos: se vierem vazios, mantém-se os que já estavam guardados.
    $pwdBlob = $null
    if (-not $Integrada) {
        $texto = ConvertFrom-SabioSecureString $Password
        if ($texto) {
            $pwdBlob = [SabioV1.Nucleo]::Proteger([Text.Encoding]::UTF8.GetBytes($texto), $true)
        } elseif ($anterior -and (Get-SabioPropriedade $anterior.sql 'password_dpapi')) {
            $pwdBlob = $anterior.sql.password_dpapi
        } else {
            throw 'Falta a password do SQL.'
        }
    }

    $chaveTexto = ConvertFrom-SabioSecureString $ChaveLoja
    if ($chaveTexto) {
        try { $bytes = [Convert]::FromBase64String($chaveTexto.Trim()) } catch { throw 'A chave da loja nao e base64 valido.' }
        if ($bytes.Length -ne 32) { throw 'A chave da loja tem de ter 32 bytes.' }
        $chaveBlob = [SabioV1.Nucleo]::Proteger($bytes, $true)
        [Array]::Clear($bytes, 0, $bytes.Length)
    } elseif ($anterior -and (Get-SabioPropriedade $anterior.worker 'chave_dpapi')) {
        $chaveBlob = $anterior.worker.chave_dpapi
    } else {
        throw 'Falta a chave da loja.'
    }

    $sinc = [ordered]@{
        intervalo_min            = 60
        intervalo_referencia_min = 360
        revisao_completa_dias    = 30
        lote_kb                  = 200
        limite_escritas_dia      = 90000
        inicio                   = ''
    }
    if ($anterior -and (Get-SabioPropriedade $anterior 'sincronizacao')) {
        foreach ($p in $anterior.sincronizacao.PSObject.Properties) { $sinc[$p.Name] = $p.Value }
    }
    foreach ($k in $Sincronizacao.Keys) { $sinc[$k] = $Sincronizacao[$k] }

    $sql = [ordered]@{ servidor = $Servidor; base = $Base; integrada = [bool]$Integrada }
    if (-not $Integrada) { $sql.utilizador = $Utilizador; $sql.password_dpapi = $pwdBlob }

    $conteudo = [ordered]@{
        versao_config = 1
        loja          = $Loja
        sql           = $sql
        worker        = [ordered]@{ url = $WorkerUrl.TrimEnd('/'); chave_dpapi = $chaveBlob }
        actualizacoes = [ordered]@{ fonte = $Fonte; intervalo_horas = 6 }
        sincronizacao = $sinc
    }
    Write-SabioFicheiroAtomico -Caminho $f -Conteudo ($conteudo | ConvertTo-Json -Depth 5)
    Set-SabioAclRestrito -Caminho $dir -IncluirUtilizadorActual:$AclComUtilizadorActual
    Set-SabioAclRestrito -Caminho $f -IncluirUtilizadorActual:$AclComUtilizadorActual
}

function ConvertFrom-SabioSecureString {
    param([Security.SecureString]$Seguro)
    if ($null -eq $Seguro -or $Seguro.Length -eq 0) { return '' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Seguro)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# ------------------------------------------------------------------ estado local
function Read-SabioEstadoLocal {
    $f = Join-Path (Get-SabioDirDados) 'estado-local.json'
    $e = @{ esquema_hash = ''; escritas_dia = 0; dia_escritas = ''; ultima_referencia = ''; ultima_completa = ''; versao_rejeitada = '' }
    if (Test-Path -LiteralPath $f) {
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $e[$p.Name] = $p.Value }
        } catch {
            Write-SabioRegisto AVISO 'estado-local.json ilegivel; recomeca do zero (o arquivo nao e afectado).'
        }
    }
    $hoje = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
    if ($e.dia_escritas -ne $hoje) { $e.dia_escritas = $hoje; $e.escritas_dia = 0 }
    return $e
}

function Save-SabioEstadoLocal {
    param([hashtable]$Estado)
    $f = Join-Path (Get-SabioDirDados) 'estado-local.json'
    Write-SabioFicheiroAtomico -Caminho $f -Conteudo ($Estado | ConvertTo-Json -Depth 3)
}

# ------------------------------------------------------------------ SQL Server
function New-SabioLigacaoSql {
    param([string]$Servidor, [string]$Base, [string]$Utilizador, [string]$Password, [switch]$Integrada)
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Servidor
    $b['Initial Catalog'] = $Base
    if ($Integrada) { $b['Integrated Security'] = $true }
    else { $b['User ID'] = $Utilizador; $b['Password'] = $Password }
    $b['Application Name'] = 'SincronizadorSabio'
    $b['Connect Timeout'] = 15
    $b['Pooling'] = $false
    $cn = New-Object System.Data.SqlClient.SqlConnection($b.ConnectionString)
    $cn.Open()
    # O POS tem prioridade: se houver bloqueio, desistimos nós, não o ZoneSoft.
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = 'SET LOCK_TIMEOUT 10000; SET DEADLOCK_PRIORITY LOW;'
    [void]$cmd.ExecuteNonQuery()
    return $cn
}

function Open-SabioSql {
    param($Config)
    return New-SabioLigacaoSql -Servidor $Config.sqlServidor -Base $Config.sqlBase -Utilizador $Config.sqlUtilizador -Password $Config.sqlPassword -Integrada:$Config.sqlIntegrada
}

function Invoke-SabioSqlEscalar {
    param($Ligacao, [string]$Sql, [hashtable]$Parametros = @{})
    $cmd = $Ligacao.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 300
    foreach ($k in $Parametros.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parametros[$k]) }
    $v = $cmd.ExecuteScalar()
    if ($v -is [DBNull]) { return $null }
    return $v
}

function Get-SabioTabelasConfig {
    $f = if ($env:SABIO_TABELAS) { $env:SABIO_TABELAS } else { Join-Path (Get-SabioDirInstalacao) 'tabelas.json' }
    $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $lista = New-Object System.Collections.ArrayList
    foreach ($t in $j.tabelas) {
        if (-not (Test-SabioTabelaPermitida $t.nome)) {
            Write-SabioRegisto AVISO "tabelas.json pede '$($t.nome)', que nao esta na lista permitida: ignorada."
            continue
        }
        [void]$lista.Add($t)
    }
    return , $lista
}

function Get-SabioEsquemaTabela {
    param($Ligacao, $Definicao)
    $nome = [string]$Definicao.nome
    $tab = $nome.ToLowerInvariant()
    $cmd = $Ligacao.CreateCommand()
    $cmd.CommandText = @'
SELECT c.name, ty.name AS tipo, c.column_id, c.is_identity,
       CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 1
                         WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id) THEN 1 ELSE 0 END AS pk,
       (SELECT COUNT(*) FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 1
         WHERE ic.object_id = c.object_id) AS pk_colunas
FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(@t)
ORDER BY c.column_id
'@
    [void]$cmd.Parameters.AddWithValue('@t', 'dbo.' + $nome)
    $dt = New-Object System.Data.DataTable
    $dt.Load($cmd.ExecuteReader())
    if ($dt.Rows.Count -eq 0) { return $null }

    $nomes = New-Object System.Collections.ArrayList
    $tipos = New-Object System.Collections.ArrayList
    $select = New-Object System.Collections.ArrayList
    $excluidas = New-Object System.Collections.ArrayList
    $existentes = @{}
    foreach ($r in $dt.Rows) { $existentes[([string]$r.name).ToLowerInvariant()] = $r }

    foreach ($r in $dt.Rows) {
        $col = [string]$r.name
        $tipo = ([string]$r.tipo).ToLowerInvariant()
        if (-not (Get-SabioTipoD1 $tipo)) { [void]$excluidas.Add("$col (tipo $tipo)"); continue }
        if (-not (Test-SabioColunaPermitida $tab $col)) { [void]$excluidas.Add($col); continue }
        [void]$nomes.Add($col.ToLowerInvariant())
        [void]$tipos.Add($tipo)
        [void]$select.Add('[' + $col.Replace(']', ']]') + ']')
    }
    if ($script:ExpressoesDerivadas.ContainsKey($tab)) {
        foreach ($d in $script:ExpressoesDerivadas[$tab].GetEnumerator()) {
            if ($existentes.ContainsKey($d.Value.requer)) {
                [void]$nomes.Add($d.Key)
                [void]$tipos.Add('int')
                [void]$select.Add($d.Value.sql + ' AS [' + $d.Key + ']')
            }
        }
    }
    if ($nomes.Count -eq 0) { return $null }

    # Estratégia de partição
    $modo = [string](Get-SabioPropriedade $Definicao 'modo' 'referencia')
    $indice = -1
    $colunaParticao = $null
    if ($modo -eq 'dia') {
        foreach ($cand in @(Get-SabioPropriedade $Definicao 'colunas_data' @())) {
            $i = $nomes.IndexOf(([string]$cand).ToLowerInvariant())
            if ($i -ge 0 -and @('datetime', 'smalldatetime', 'datetime2', 'date') -contains $tipos[$i]) {
                $indice = $i; $colunaParticao = $select[$i]; break
            }
        }
        if ($indice -lt 0) {
            Write-SabioRegisto AVISO "$nome sem coluna de data utilizavel: passa a tabela de referencia."
            $modo = 'referencia'
        }
    }
    $leitura = 'dia'
    if ($modo -eq 'referencia') {
        $leitura = 'tabela'
        foreach ($r in $dt.Rows) {
            $ehChave = ([int]$r.pk -eq 1 -and [int]$r.pk_colunas -eq 1) -or [bool]$r.is_identity
            $i = $nomes.IndexOf(([string]$r.name).ToLowerInvariant())
            if ($ehChave -and $i -ge 0 -and @('int', 'bigint', 'smallint', 'tinyint') -contains $tipos[$i]) {
                $leitura = 'chave'; $indice = $i; $colunaParticao = $select[$i]; break
            }
        }
        if ($leitura -eq 'tabela') { $indice = 0 }
    }

    return [pscustomobject]@{
        nome          = $tab
        nomeOrigem    = $nome
        nomes         = [string[]]$nomes.ToArray([string])
        tipos         = [string[]]$tipos.ToArray([string])
        select        = ($select -join ', ')
        excluidas     = [string[]]$excluidas.ToArray([string])
        modo          = $modo
        leitura       = $leitura
        indice        = $indice
        colunaParticao = $colunaParticao
        revisaoDias   = [int](Get-SabioPropriedade $Definicao 'revisao_dias' 7)
        purga         = [bool](Get-SabioPropriedade $Definicao 'purga' $false)
        incluirHoje   = [bool](Get-SabioPropriedade $Definicao 'incluir_hoje' $false)
    }
}

function Read-SabioParticoes {
    param($Ligacao, $Esquema, [string]$Onde = '', [hashtable]$Parametros = @{})
    $cmd = $Ligacao.CreateCommand()
    $cmd.CommandTimeout = 600
    $cmd.CommandText = "SELECT $($Esquema.select) FROM [dbo].[$($Esquema.nomeOrigem.Replace(']', ']]'))] $Onde"
    foreach ($k in $Parametros.Keys) { [void]$cmd.Parameters.AddWithValue($k, $Parametros[$k]) }
    $d = [SabioV1.Nucleo]::Ler($cmd, $Esquema.tipos, $Esquema.indice, $Esquema.leitura, 2000)
    foreach ($p in $d.Values) { [SabioV1.Nucleo]::Finalizar($p, $Esquema.nomes) }
    return , $d
}

# ------------------------------------------------------------------ Worker
function Invoke-SabioWorker {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Caminho,
        [Parameter(Mandatory)][string]$Corpo,
        [int]$Tentativas = 3
    )
    $ultimo = $null
    for ($t = 1; $t -le $Tentativas; $t++) {
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $nonce = $null
        $envelope = [SabioV1.Nucleo]::Selar($Config.chaveLoja, $Config.loja, $Caminho, $Corpo, $ts, [ref]$nonce)
        $bytes = [Text.Encoding]::UTF8.GetBytes($envelope)
        $estado = 0
        $texto = ''
        try {
            $req = [System.Net.HttpWebRequest]::Create($Config.workerUrl + $Caminho)
            $req.Method = 'POST'
            $req.ContentType = 'application/json; charset=utf-8'
            $req.UserAgent = 'SincronizadorSabio/' + (Get-SabioVersaoInstalada)
            $req.Timeout = 180000
            $req.ReadWriteTimeout = 180000
            $req.ContentLength = $bytes.Length
            $s = $req.GetRequestStream()
            try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
            try {
                $resp = $req.GetResponse()
            } catch [System.Net.WebException] {
                $resp = $_.Exception.Response
                if ($null -eq $resp) { throw }
            }
            try {
                $estado = [int]$resp.StatusCode
                $leitor = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                $texto = $leitor.ReadToEnd()
            } finally { $resp.Close() }
        } catch {
            $ultimo = "rede: $($_.Exception.Message)"
            if ($t -lt $Tentativas) { Start-Sleep -Seconds (5 * $t); continue }
            throw $ultimo
        }

        if ($estado -eq 200) {
            $claro = [SabioV1.Nucleo]::AbrirResposta($Config.chaveLoja, $Config.loja, $Caminho, $nonce, $texto, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), 300)
            return ($claro | ConvertFrom-Json)
        }

        $codigo = 'desconhecido'
        try { $codigo = [string]($texto | ConvertFrom-Json).erro } catch { }
        $ultimo = "worker: $estado $codigo"
        # 429 e 5xx podem passar; 4xx não — repetir só gasta pedidos.
        if (($estado -eq 429 -or $estado -ge 500) -and $t -lt $Tentativas) { Start-Sleep -Seconds (10 * $t); continue }
        throw $ultimo
    }
    throw $ultimo
}

function Test-SabioErroRede {
    param([string]$Mensagem)
    return ($Mensagem -like 'rede:*' -or $Mensagem -match '^worker: (429|5\d\d) ')
}

function ConvertTo-SabioJson {
    param($Objecto)
    return ($Objecto | ConvertTo-Json -Depth 10 -Compress)
}

# ------------------------------------------------------------------ sincronização
function Send-SabioCorpo {
    param($Config, $Corpo, [hashtable]$Resumo, [hashtable]$Estado)
    if ($Corpo.Quantas -eq 0) { return }
    $r = Invoke-SabioWorker -Config $Config -Caminho '/v1/particoes' -Corpo $Corpo.Fechar()
    $escritas = [long](Get-SabioPropriedade $r 'escritas' 0)
    $Resumo.escritas += $escritas
    $Estado.escritas_dia = [long]$Estado.escritas_dia + $escritas
    $enviadas = New-Object System.Collections.ArrayList
    foreach ($x in @($r.resultados)) {
        if ($x.verificado) {
            $Resumo.particoes_enviadas++
            $Resumo.linhas += [long]$x.linhas
            [void]$enviadas.Add("$($x.p) ($($x.linhas))")
        } else {
            $Resumo.erros++
            Write-SabioRegisto ERRO "particao $($x.p): o arquivo tem $($x.linhas) linhas e nao bate certo. Volta a ser enviada no proximo ciclo."
        }
    }
    if ($enviadas.Count) {
        $texto = ($enviadas | Select-Object -First 12) -join ', '
        if ($enviadas.Count -gt 12) { $texto += " e mais $($enviadas.Count - 12)" }
        Write-SabioRegisto INFO "enviadas $($Corpo.Tabela): $texto"
    }
}

# Tem de ser igual ao MAX_PARTE do worker.js (caracteres base64 por linha de _dados).
$script:MaxParte = 90000

# Lê partições do arquivo e confirma, uma a uma, que o SHA-256 do conteúdo
# descomprimido é o hash registado. Devolve objectos com colunas e linhas (JSON).
function Read-SabioArquivo {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Tabela,
        [Parameter(Mandatory)][string[]]$Particoes
    )
    $saida = New-Object System.Collections.ArrayList
    $pendentes = New-Object System.Collections.Generic.Queue[string]
    foreach ($x in $Particoes) { $pendentes.Enqueue($x) }
    while ($pendentes.Count -gt 0) {
        $grupo = New-Object System.Collections.ArrayList
        while ($pendentes.Count -gt 0 -and $grupo.Count -lt 80) { [void]$grupo.Add($pendentes.Dequeue()) }
        $r = Invoke-SabioWorker -Config $Config -Caminho '/v1/ler' -Corpo (ConvertTo-SabioJson ([ordered]@{ base = $Base.ToLowerInvariant(); tabela = $Tabela.ToLowerInvariant(); particoes = $grupo }))
        foreach ($x in @($r.restantes)) { if ($x) { $pendentes.Enqueue([string]$x) } }
        foreach ($it in @($r.itens)) {
            if (-not $it) { continue }
            if (-not $it.completa) { throw "particao $($it.p) incompleta no arquivo" }
            $texto = [SabioV1.Nucleo]::Descomprimir([string]$it.dados)
            $hash = [SabioV1.Nucleo]::Sha256Hex([Text.Encoding]::UTF8.GetBytes($texto))
            if ($hash -ne [string]$it.hash) { throw "particao $($it.p): o conteudo nao corresponde ao hash (arquivo corrompido)" }
            $linhas = $texto.Split([char]10)
            if (-not $linhas[0].StartsWith('cols:')) { throw "particao $($it.p): formato desconhecido" }
            $dados = New-Object System.Collections.Generic.List[string]
            for ($i = 1; $i -lt $linhas.Length; $i++) { if ($linhas[$i].Length) { $dados.Add($linhas[$i]) } }
            if ($dados.Count -ne [int]$it.linhas) { throw "particao $($it.p): $($dados.Count) linhas, esperadas $($it.linhas)" }
            [void]$saida.Add([pscustomobject]@{ p = [string]$it.p; hash = $hash; colunas = [string[]]$linhas[0].Substring(5).Split(','); linhas = $dados })
        }
    }
    return , $saida
}

function Send-SabioParticoes {
    param($Config, $Esquema, $Particoes, [hashtable]$Arquivadas, [hashtable]$Resumo, [hashtable]$Estado)
    $loteBytes = [long]$Config.loteKb * 1024
    $corpo = New-Object SabioV1.CorpoParticoes($Config.sqlBase.ToLowerInvariant(), $Esquema.nome, $Esquema.nomes)
    $nomes = [string[]]@($Particoes.Keys)
    [Array]::Sort($nomes, [StringComparer]::Ordinal)

    foreach ($n in $nomes) {
        $p = $Particoes[$n]
        $a = $null
        if ($Arquivadas.ContainsKey($n)) { $a = $Arquivadas[$n] }
        if ($a -and [string]$a[0] -eq $p.Hash) { $Resumo.particoes_iguais++; continue }
        if ($a -and $Esquema.purga -and $p.Linhas.Count -lt [int]$a[1]) {
            # O POS já apagou parte deste dia; o arquivo é agora a única cópia.
            $Resumo.saltadas_purga++
            continue
        }
        # Só se comprime o que vai mesmo ser enviado: o hash (barato) já disse que mudou.
        $b64 = [SabioV1.Nucleo]::Comprimir($p, $Esquema.nomes)
        $partes = [int][Math]::Ceiling($b64.Length / $script:MaxParte)

        # Escritas no D1: cada parte nova, cada parte antiga apagada, _particoes.
        # Partições em várias partes passam pela área de espera (+2 por parte).
        $estimativa = 2 + $partes * $(if ($partes -gt 1) { 4 } else { 2 })
        if ([long]$Estado.escritas_dia + $estimativa -gt $Config.limiteEscritas) {
            $Resumo.limite_atingido = $true
            break
        }

        if ($partes -gt 1) {
            Send-SabioCorpo -Config $Config -Corpo $corpo -Resumo $Resumo -Estado $Estado
            $corpo = New-Object SabioV1.CorpoParticoes($Config.sqlBase.ToLowerInvariant(), $Esquema.nome, $Esquema.nomes)
            # Partição grande: cada parte num pedido; ficam numa área de espera e
            # só substituem o arquivo quando chega a última.
            $lote = [SabioV1.Nucleo]::Hex([SabioV1.Nucleo]::Aleatorio(16))
            for ($k = 0; $k -lt $partes; $k++) {
                $inicio = $k * $script:MaxParte
                $pedaco = $b64.Substring($inicio, [Math]::Min($script:MaxParte, $b64.Length - $inicio))
                $umaParte = New-Object SabioV1.CorpoParticoes($Config.sqlBase.ToLowerInvariant(), $Esquema.nome, $Esquema.nomes)
                $umaParte.Acrescentar($p, $k, $partes, $lote, $b64.Length, $pedaco)
                Send-SabioCorpo -Config $Config -Corpo $umaParte -Resumo $Resumo -Estado $Estado
            }
            continue
        }

        if ($corpo.Quantas -gt 0 -and ($corpo.Tamanho + $b64.Length -gt $loteBytes -or $corpo.Quantas -ge 10)) {
            Send-SabioCorpo -Config $Config -Corpo $corpo -Resumo $Resumo -Estado $Estado
            $corpo = New-Object SabioV1.CorpoParticoes($Config.sqlBase.ToLowerInvariant(), $Esquema.nome, $Esquema.nomes)
        }
        $corpo.Acrescentar($p, 0, 1, $null, $b64.Length, $b64)
    }
    Send-SabioCorpo -Config $Config -Corpo $corpo -Resumo $Resumo -Estado $Estado
}

function Invoke-SabioCiclo {
    param(
        [Parameter(Mandatory)]$Config,
        [switch]$Referencia,
        [switch]$Completa
    )
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    $estado = Read-SabioEstadoLocal
    $base = $Config.sqlBase.ToLowerInvariant()
    $resumo = @{ tabelas = 0; linhas = 0; escritas = 0; particoes_enviadas = 0; particoes_iguais = 0; saltadas_purga = 0; erros = 0; limite_atingido = $false }
    $tipo = if ($Completa) { 'completo' } elseif ($Referencia) { 'com referencia' } else { 'normal' }

    $corrida = Invoke-SabioWorker -Config $Config -Caminho '/v1/corrida' -Corpo (ConvertTo-SabioJson @{ acao = 'inicio'; base = $base; versao = (Get-SabioVersaoInstalada) })
    $cn = $null
    $falha = $null
    try {
        $cn = Open-SabioSql $Config

        # 1. Esquema real das tabelas da lista. Tabelas de movimento primeiro,
        #    e as que o POS apaga sozinho à frente de todas.
        $esquemas = New-Object System.Collections.ArrayList
        foreach ($def in (Get-SabioTabelasConfig)) {
            $e = Get-SabioEsquemaTabela -Ligacao $cn -Definicao $def
            if ($null -eq $e) { continue }
            [void]$esquemas.Add($e)
        }
        $ordenados = @($esquemas | Sort-Object @{ Expression = { -not $_.purga } }, @{ Expression = { $_.modo -ne 'dia' } }, nome)

        # 2. Esquema no arquivo — só quando mudou.
        $sbEsquema = New-Object System.Text.StringBuilder
        [void]$sbEsquema.Append($base)
        foreach ($e in $ordenados) {
            [void]$sbEsquema.Append('|').Append($e.nome)
            for ($j = 0; $j -lt $e.nomes.Count; $j++) { [void]$sbEsquema.Append(',').Append($e.nomes[$j]).Append(':').Append($e.tipos[$j]) }
        }
        $assinaturaEsquema = [SabioV1.Nucleo]::Sha256Hex([Text.Encoding]::UTF8.GetBytes($sbEsquema.ToString()))
        if ($estado.esquema_hash -ne $assinaturaEsquema) {
            for ($i = 0; $i -lt $ordenados.Count; $i += 4) {
                $grupo = @($ordenados[$i..([Math]::Min($i + 3, $ordenados.Count - 1))])
                $tabelas = New-Object System.Collections.ArrayList
                foreach ($e in $grupo) {
                    $cols = New-Object System.Collections.ArrayList
                    for ($j = 0; $j -lt $e.nomes.Count; $j++) { [void]$cols.Add([ordered]@{ nome = $e.nomes[$j]; tipo = $e.tipos[$j] }) }
                    [void]$tabelas.Add([ordered]@{ nome = $e.nome; colunas = $cols })
                }
                $r = Invoke-SabioWorker -Config $Config -Caminho '/v1/esquema' -Corpo (ConvertTo-SabioJson ([ordered]@{ base = $base; tabelas = $tabelas }))
                $escritasEsquema = [long](Get-SabioPropriedade $r 'escritas' 0)
                $resumo.escritas += $escritasEsquema
                $estado.escritas_dia = [long]$estado.escritas_dia + $escritasEsquema
            }
            $estado.esquema_hash = $assinaturaEsquema
            foreach ($e in $ordenados) {
                if ($e.excluidas.Count) { Write-SabioRegisto INFO "$($e.nome): colunas que nao saem do POS: $($e.excluidas -join ', ')" }
            }
        }

        # 3. O que o arquivo já tem.
        $alvo = @($ordenados | Where-Object { $_.modo -eq 'dia' -or $Referencia -or $Completa })
        $hoje = (Get-Date).Date
        $maiorRevisao = 1
        foreach ($e in $alvo) { if ($e.modo -eq 'dia' -and $e.revisaoDias -gt $maiorRevisao) { $maiorRevisao = $e.revisaoDias } }
        $desde = if ($Completa) { '0000-00-00' } else { $hoje.AddDays(-$maiorRevisao).ToString('yyyy-MM-dd') }
        $inicioMinimo = $null
        if ($Config.inicio) { $inicioMinimo = [datetime]::ParseExact($Config.inicio, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }

        $estadoRemoto = $null
        if ($alvo.Count) {
            $estadoRemoto = Invoke-SabioWorker -Config $Config -Caminho '/v1/estado' -Corpo (ConvertTo-SabioJson ([ordered]@{ base = $base; tabelas = @($alvo | ForEach-Object { $_.nome }); desde = $desde }))
        }

        # 4. Tabela a tabela.
        foreach ($e in $alvo) {
            if ($resumo.limite_atingido) { break }
            $info = Get-SabioPropriedade $estadoRemoto.tabelas $e.nome
            $arquivadas = @{}
            $maxDia = $null
            if ($info) {
                $maxDia = Get-SabioPropriedade $info 'max_dia'
                foreach ($p in $info.particoes.PSObject.Properties) { $arquivadas[$p.Name] = @($p.Value) }
            }
            $resumo.tabelas++

            if ($e.modo -eq 'dia') {
                $col = $e.colunaParticao
                $tabelaSql = "[dbo].[$($e.nomeOrigem.Replace(']', ']]'))]"
                $minFonte = Invoke-SabioSqlEscalar -Ligacao $cn -Sql "SELECT MIN($col) FROM $tabelaSql"
                if ($null -eq $minFonte) { continue }
                $maxFonte = [datetime](Invoke-SabioSqlEscalar -Ligacao $cn -Sql "SELECT MAX($col) FROM $tabelaSql")
                $comeco = ([datetime]$minFonte).Date
                if (-not $Completa -and $maxDia) {
                    $depoisDoArquivo = [datetime]::ParseExact([string]$maxDia, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture).AddDays(1)
                    $janela = $hoje.AddDays(-$e.revisaoDias)
                    $comeco = if ($depoisDoArquivo -lt $janela) { $depoisDoArquivo } else { $janela }
                }
                if ($inicioMinimo -and $comeco -lt $inicioMinimo) { $comeco = $inicioMinimo }

                # Só dias fechados. O dia de hoje ainda está a crescer: enviá-lo a cada
                # ciclo reescreveria a partição inteira dezenas de vezes por dia
                # (~75 000 escritas/dia só nas vendas do Moscatel). O sistema anterior
                # também ia só até ontem. Excepção: tabelas com datas futuras
                # (marcacoes), marcadas com incluir_hoje no tabelas.json.
                $limite = if ($e.incluirHoje) { $maxFonte.Date.AddDays(1) } else { $hoje }
                $a = $comeco
                while ($a -lt $limite -and $a -le $maxFonte -and -not $resumo.limite_atingido) {
                    $b = (Get-Date -Year $a.Year -Month $a.Month -Day 1).Date.AddMonths(1)
                    if ($b -gt $limite) { $b = $limite }
                    $ps = Read-SabioParticoes -Ligacao $cn -Esquema $e -Onde "WHERE $col >= @a AND $col < @b" -Parametros @{ '@a' = $a; '@b' = $b }
                    Send-SabioParticoes -Config $Config -Esquema $e -Particoes $ps -Arquivadas $arquivadas -Resumo $resumo -Estado $estado
                    $a = $b
                }
                if (($Referencia -or $Completa) -and -not $resumo.limite_atingido) {
                    $ps = Read-SabioParticoes -Ligacao $cn -Esquema $e -Onde "WHERE $col IS NULL"
                    if ($ps.Count) { Send-SabioParticoes -Config $Config -Esquema $e -Particoes $ps -Arquivadas $arquivadas -Resumo $resumo -Estado $estado }
                }
            } else {
                $ps = Read-SabioParticoes -Ligacao $cn -Esquema $e
                Send-SabioParticoes -Config $Config -Esquema $e -Particoes $ps -Arquivadas $arquivadas -Resumo $resumo -Estado $estado
            }
        }
        if ($resumo.limite_atingido) {
            Write-SabioRegisto AVISO "Limite diario de escritas ($($Config.limiteEscritas)) atingido: o resto continua amanha."
        }
        if ($resumo.saltadas_purga) {
            Write-SabioRegisto AVISO "$($resumo.saltadas_purga) particao(oes) com menos linhas no POS do que no arquivo, numa tabela que o POS apaga sozinho: o arquivo foi mantido."
        }
    } catch {
        $falha = $_.Exception.Message
        throw
    } finally {
        if ($cn) { $cn.Dispose() }
        Save-SabioEstadoLocal $estado
        $fim = [ordered]@{
            acao = 'fim'; id = [long]$corrida.id
            estado = $(if ($falha -or $resumo.erros) { 'erro' } else { 'ok' })
            tabelas = $resumo.tabelas; linhas = $resumo.linhas; escritas = $resumo.escritas
            erro = $(if ($falha) { Protect-SabioTextoRegisto $falha } elseif ($resumo.erros) { "$($resumo.erros) particao(oes) nao verificadas" } else { $null })
        }
        try { [void](Invoke-SabioWorker -Config $Config -Caminho '/v1/corrida' -Corpo (ConvertTo-SabioJson $fim)) } catch { }
        $msg = "ciclo $tipo em {0:n1}s: {1} tabelas, {2} particoes enviadas, {3} iguais, {4} linhas, {5} escritas no arquivo ({6} hoje)" -f $relogio.Elapsed.TotalSeconds, $resumo.tabelas, $resumo.particoes_enviadas, $resumo.particoes_iguais, $resumo.linhas, $resumo.escritas, $estado.escritas_dia
        if ($falha) { Write-SabioRegisto ERRO "$msg - interrompido: $falha" } else { Write-SabioRegisto INFO $msg }
    }
    return $resumo
}

# ------------------------------------------------------------------ actualizações
$script:PadraoActualizavel = '^[A-Za-z0-9_\-]+\.(ps1|psm1|json|txt|md)$'
# Nunca por actualização automática: o arranque (é ele que reverte uma versão
# má), a chave pública (é ela que valida as actualizações), a configuração
# do serviço e o próprio executável.
$script:NuncaActualizar = @('arranque.ps1', 'chave-publica.xml', 'sincronizadorsabio.xml', 'sincronizadorsabio.exe', 'config.json', 'instalar.ps1', 'desinstalar.ps1', 'elevar.ps1')

function Test-SabioCaminhoActualizavel {
    param([string]$Caminho)
    if ($Caminho -notmatch $script:PadraoActualizavel) { return $false }
    if ($script:NuncaActualizar -contains $Caminho.ToLowerInvariant()) { return $false }
    return $true
}

function Get-SabioBytesFonte {
    param([string]$Fonte, [string]$Relativo)
    if ($Relativo -notmatch '^[A-Za-z0-9_\-./]+$' -or $Relativo -match '\.\.') { throw "caminho invalido na fonte: $Relativo" }
    if ($Fonte -match '^https://') {
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'SincronizadorSabio/' + (Get-SabioVersaoInstalada)
        try { return $wc.DownloadData($Fonte.TrimEnd('/') + '/' + $Relativo) } finally { $wc.Dispose() }
    }
    if ($Fonte -match '^[a-z]+://') { throw 'So se aceitam fontes https:// ou pastas locais.' }
    return [IO.File]::ReadAllBytes((Join-Path $Fonte ($Relativo -replace '/', '\')))
}

function Invoke-SabioVerificarActualizacao {
    param([Parameter(Mandatory)]$Config)
    if (-not $Config.fonte) { return $null }
    $manifestoBytes = Get-SabioBytesFonte $Config.fonte 'actualizacao.json'
    $assinatura = [Text.Encoding]::ASCII.GetString((Get-SabioBytesFonte $Config.fonte 'actualizacao.json.sig'))
    $chavePublica = [IO.File]::ReadAllText((Join-Path (Get-SabioDirInstalacao) 'chave-publica.xml'))
    if (-not [SabioV1.Nucleo]::VerificarAssinatura($chavePublica, $manifestoBytes, $assinatura)) {
        Write-SabioRegisto ERRO 'Actualizacao recusada: a assinatura do manifesto nao e valida.'
        return $null
    }
    $m = [Text.Encoding]::UTF8.GetString($manifestoBytes) | ConvertFrom-Json
    if ($m.produto -ne 'SincronizadorSabio') { Write-SabioRegisto ERRO 'Actualizacao recusada: manifesto de outro produto.'; return $null }
    $nova = [version]$m.versao
    $actual = [version](Get-SabioVersaoInstalada)
    if ($nova -le $actual) { return $null }
    $estado = Read-SabioEstadoLocal
    if ($estado.versao_rejeitada -and $nova -le [version]$estado.versao_rejeitada) { return $null }

    $destino = Join-Path (Get-SabioDirDados) ('actualizacao\' + $nova.ToString())
    if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Recurse -Force }
    New-Item -ItemType Directory -Path $destino -Force | Out-Null
    $temVersao = $false
    foreach ($f in @($m.ficheiros)) {
        $nome = [string]$f.caminho
        if (-not (Test-SabioCaminhoActualizavel $nome)) { Write-SabioRegisto ERRO "Actualizacao recusada: '$nome' nao pode ser actualizado automaticamente."; return $null }
        if ([long]$f.tamanho -gt 5MB -or ([string]$f.sha256) -notmatch '^[0-9a-f]{64}$') { Write-SabioRegisto ERRO "Actualizacao recusada: entrada invalida para '$nome'."; return $null }
        $bytes = Get-SabioBytesFonte $Config.fonte ('ficheiros/' + $nome)
        if ($bytes.Length -ne [long]$f.tamanho -or [SabioV1.Nucleo]::Sha256Hex($bytes) -ne [string]$f.sha256) {
            Write-SabioRegisto ERRO "Actualizacao recusada: '$nome' nao corresponde ao manifesto assinado."
            return $null
        }
        [IO.File]::WriteAllBytes((Join-Path $destino $nome), $bytes)
        if ($nome -eq 'versao.json') {
            $temVersao = $true
            if ([string]([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json).versao -ne $m.versao) {
                Write-SabioRegisto ERRO 'Actualizacao recusada: versao.json nao bate com o manifesto.'
                return $null
            }
        }
    }
    if (-not $temVersao) { Write-SabioRegisto ERRO 'Actualizacao recusada: falta versao.json.'; return $null }
    Write-SabioRegisto INFO "Actualizacao $($m.versao) descarregada e verificada."
    return [pscustomobject]@{ versao = $m.versao; pasta = $destino; ficheiros = @($m.ficheiros | ForEach-Object { [string]$_.caminho }) }
}

function Install-SabioActualizacao {
    param([Parameter(Mandatory)]$Pacote)
    $inst = Get-SabioDirInstalacao
    $dados = Get-SabioDirDados
    $anterior = Join-Path $dados 'anterior'
    if (Test-Path -LiteralPath $anterior) { Remove-Item -LiteralPath $anterior -Recurse -Force }
    New-Item -ItemType Directory -Path $anterior -Force | Out-Null
    Get-ChildItem -LiteralPath $inst -File | Where-Object { Test-SabioCaminhoActualizavel $_.Name } | Copy-Item -Destination $anterior -Force

    $pendente = [ordered]@{ versao_nova = $Pacote.versao; versao_anterior = (Get-SabioVersaoInstalada); tentativas = 0; aplicada_em = (Get-Date -Format 's') }
    Write-SabioFicheiroAtomico -Caminho (Join-Path $dados 'pendente.json') -Conteudo ($pendente | ConvertTo-Json)
    foreach ($nome in $Pacote.ficheiros) {
        $novo = Join-Path $inst ($nome + '.novo')
        Copy-Item -LiteralPath (Join-Path $Pacote.pasta $nome) -Destination $novo -Force
        Move-Item -LiteralPath $novo -Destination (Join-Path $inst $nome) -Force
    }
    Write-SabioRegisto INFO "Actualizacao $($Pacote.versao) instalada; o servico vai reiniciar."
}

function Confirm-SabioActualizacao {
    $f = Join-Path (Get-SabioDirDados) 'pendente.json'
    if (-not (Test-Path -LiteralPath $f)) { return }
    $p = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item -LiteralPath $f -Force
    Write-SabioRegisto INFO "Versao $($p.versao_nova) confirmada."
}

# ------------------------------------------------------------------ configurador
function Find-SabioZoneSoft {
    foreach ($c in @('C:\Zone Soft\ZSRest\ZSConnector\appsettings.json', 'C:\Zone Soft\ZSMPos\ZSConnector\appsettings.json')) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $texto = [IO.File]::ReadAllText($c)
            $cs = [regex]::Match($texto, '"SqlConnection"\s*:\s*"([^"]+)"').Groups[1].Value
            $srv = [regex]::Match($cs, '(?i)(?:Server|Data Source)=([^;]+)').Groups[1].Value
            $bd = [regex]::Match($cs, '(?i)(?:Database|Initial Catalog)=([^;]+)').Groups[1].Value
            if ($srv) { return [pscustomobject]@{ servidor = $srv.Replace('\\', '\'); base = $bd; origem = $c } }
        } catch { }
    }
    $log = Get-ChildItem 'C:\Zone Soft\*\logs\COZINHA_*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($log) {
        $m = [regex]::Match([IO.File]::ReadAllText($log.FullName), 'Database=(\S+)\s+Server=(\S+)')
        if ($m.Success) { return [pscustomobject]@{ servidor = $m.Groups[2].Value; base = $m.Groups[1].Value; origem = $log.FullName } }
    }
    return $null
}

function Get-SabioBasesDados {
    param([string]$Servidor, [string]$Utilizador, [string]$Password, [switch]$Integrada)
    $cn = New-SabioLigacaoSql -Servidor $Servidor -Base 'master' -Utilizador $Utilizador -Password $Password -Integrada:$Integrada
    try {
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' AND database_id > 4 AND HAS_DBACCESS(name) = 1 ORDER BY name"
        $dt = New-Object System.Data.DataTable
        $dt.Load($cmd.ExecuteReader())
        $saida = New-Object System.Collections.ArrayList
        foreach ($r in $dt.Rows) {
            $nome = [string]$r.name
            $ultima = $null
            try {
                $ultima = Invoke-SabioSqlEscalar -Ligacao $cn -Sql ("SELECT MAX(datahora) FROM [" + $nome.Replace(']', ']]') + "].dbo.documentos")
            } catch { }
            [void]$saida.Add([pscustomobject]@{ nome = $nome; ultimo_documento = $ultima })
        }
        return , $saida
    } finally { $cn.Dispose() }
}

function Test-SabioLigacaoSql {
    param([string]$Servidor, [string]$Base, [string]$Utilizador, [string]$Password, [switch]$Integrada)
    try {
        $cn = New-SabioLigacaoSql -Servidor $Servidor -Base $Base -Utilizador $Utilizador -Password $Password -Integrada:$Integrada
    } catch {
        return [pscustomobject]@{ ok = $false; mensagem = "Nao liga: $($_.Exception.Message)"; ler_clientes = $false; escrever = $false }
    }
    try {
        $lerDocs = Invoke-SabioSqlEscalar -Ligacao $cn -Sql "SELECT HAS_PERMS_BY_NAME('dbo.documentos', 'OBJECT', 'SELECT')"
        $lerClientes = Invoke-SabioSqlEscalar -Ligacao $cn -Sql "SELECT HAS_PERMS_BY_NAME('dbo.clientes', 'OBJECT', 'SELECT')"
        $escrever = Invoke-SabioSqlEscalar -Ligacao $cn -Sql "SELECT HAS_PERMS_BY_NAME('dbo.documentos', 'OBJECT', 'INSERT')"
        $ok = ([int]$lerDocs -eq 1)
        $msg = if ($ok) { 'Ligacao OK e consegue ler documentos.' } else { 'Liga, mas nao tem permissao para ler documentos.' }
        return [pscustomobject]@{ ok = $ok; mensagem = $msg; ler_clientes = ([int]$lerClientes -eq 1); escrever = ([int]$escrever -eq 1) }
    } finally { $cn.Dispose() }
}

function Test-SabioWorker {
    param([string]$Url, [byte[]]$ChaveLoja, [string]$Loja, [string]$Base)
    try {
        $wc = New-Object System.Net.WebClient
        $saude = [Text.Encoding]::UTF8.GetString($wc.DownloadData($Url.TrimEnd('/') + '/v1/saude')) | ConvertFrom-Json
        $wc.Dispose()
    } catch {
        return [pscustomobject]@{ ok = $false; mensagem = "O Worker nao responde: $($_.Exception.Message)" }
    }
    $cfg = [pscustomobject]@{ loja = $Loja; workerUrl = $Url.TrimEnd('/'); chaveLoja = $ChaveLoja }
    try {
        [void](Invoke-SabioWorker -Config $cfg -Caminho '/v1/estado' -Corpo (ConvertTo-SabioJson @{ base = $Base.ToLowerInvariant(); tabelas = @() }) -Tentativas 1)
        return [pscustomobject]@{ ok = $true; mensagem = "Arquivo OK (Worker $($saude.versao)); a chave da loja foi aceite." }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'relogio') { $m = 'O relogio deste computador esta desacertado mais de 5 minutos.' }
        elseif ($m -match '401') { $m = 'O Worker recusou a chave desta loja.' }
        return [pscustomobject]@{ ok = $false; mensagem = $m }
    }
}

Export-ModuleMember -Function *-Sabio*
