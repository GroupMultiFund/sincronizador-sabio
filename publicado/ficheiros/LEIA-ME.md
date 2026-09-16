# Sincronizador Sábio

Serviço do Windows que corre em cada POS e copia as tabelas do ZoneSoft para
o arquivo do Dashboard Sábio (Cloudflare D1), cifradas.

```
  POS: SQL Server do ZoneSoft (só leitura)
        │
        │  serviço "Sincronizador Sabio" (WinSW + PowerShell)
        │  · lê o esquema real e as tabelas da lista
        │  · parte por dia / por blocos, calcula SHA-256 de cada partição
        │  · só envia o que mudou, e só dias fechados (até ontem)
        ▼
  HTTPS + envelope AES-256-CBC/HMAC-SHA256 com a chave da loja
        ▼
  Worker de entrada (Cloudflare) → valida chave, regras e integridade das partes
        ▼
  D1 arquivo-zsrest (UE) — cada partição comprimida, substituída atomicamente
```

---

## Instalar num POS (por AnyDesk)

1. Copiar a pasta `instalacao-<versão>` para o POS (por exemplo para o ambiente de trabalho).
2. Duplo clique em **`INSTALAR.bat`** → aparece o aviso do Windows → **Sim**.
3. Abre o configurador:
   - **Loja**: `moscatel`, `cais56` ou `adega`
   - **Servidor SQL** e **Base de dados**: vêm detectados da configuração do ZoneSoft.
     Carregar em **Procurar bases** mostra todas, com a data do último documento e
     a indicação *(em uso pelo ZoneSoft)*. No Moscatel há duas: escolher a que está em uso.
   - **Utilizador**: `dashboard_ro` — **Password**: escrever à mão
   - **Testar ligação**: tem de ficar verde. Se avisar que o utilizador lê `clientes`, ver *Segurança do SQL* abaixo.
   - **Endereço do Worker** e **Chave da loja**: a chave cola-se a partir do PC de administração (ver *Chaves*).
   - **Testar arquivo**: tem de ficar verde.
   - **Guardar**.
4. O instalador regista e arranca o serviço. Fica a correr sozinho, arranca com o Windows.

Para mudar a configuração mais tarde: `C:\Program Files\SincronizadorSabio\configurador.ps1`
(botão direito → Executar com o PowerShell, como administrador). O serviço lê a
configuração nova sozinho, sem reiniciar.

Para remover: **`DESINSTALAR.bat`**. O arquivo no Cloudflare não é tocado.

---

## Onde fica cada coisa no POS

| | |
|---|---|
| `C:\Program Files\SincronizadorSabio\` | Programa. Só administradores escrevem; utilizadores só lêem |
| `C:\ProgramData\SincronizadorSabio\config.json` | Configuração. Password e chave **cifradas** (DPAPI da máquina) |
| `C:\ProgramData\SincronizadorSabio\registos\` | `sincronizador-AAAAMMDD.log` (30 dias), `arranque.log`, registos do WinSW |
| `C:\ProgramData\SincronizadorSabio\estado-local.json` | Contagem de escritas do dia e versão rejeitada |

A pasta `ProgramData\SincronizadorSabio` só é acessível a SYSTEM e Administradores.

---

## O que é enviado, e o que nunca é

**Só entram as tabelas de `tabelas.json`**, e só se também estiverem na lista
do módulo e do Worker. Uma tabela nova do ZoneSoft não entra sozinha.

**Nunca saem do POS, e o Worker recusa-as mesmo que cheguem:**

| | |
|---|---|
| Tabelas | `clientes`, `ATConfig`, `mailconfig`, `utilizadores`, `fornecedores`, permissões, temporárias |
| Credenciais | qualquer coluna com `pass`, `senha`, `pwd`, `token`, `secret`, `apikey`, `certific`, `pin`, `login` |
| Dados pessoais | `contribuinte`, `morada`, `telefone`, `telemovel`, `email`, `nascimento`, `codpostal`, `localidade`, `iban`, `matricula`, `foto`, `identificacao`, `rfid`, e `documentos.nome` |
| Binários | `image`, `varbinary`, `timestamp`, `xml`… |

Em vez do contribuinte, `documentos` leva `_tem_nif` (1/0). `999999990`
(consumidor final) conta como sem NIF.

Dos empregados entram nome e código; password, foto, telefone, email,
identificação e observações (`obs`, texto livre) não. Das reservas
(`marcacoes`) também não entram as observações: costumam ter nomes e telefones.

---

## Como sincroniza

- **De hora a hora**: tabelas de movimento (vendas, documentos…), dias fechados
  dentro da janela de revisão de cada tabela (`revisao_dias` em `tabelas.json`:
  35 para vendas e documentos, 7 para as restantes, 3 para anulações).
- **De 6 em 6 horas**: também as tabelas de referência (produtos, zonas, empregados…).
- **De 30 em 30 dias**: revisão completa de todo o histórico.
- **Primeira vez**: carga completa, respeitando o limite diário de escritas.

Cada partição tem um SHA-256. Se é igual ao do arquivo, não se envia nada.
Se mudou, a partição inteira é substituída numa transacção. O Worker confirma
a contagem de linhas no mesmo pedido.

**Dias fechados só.** O dia de hoje entra amanhã, de uma vez. Reenviar um dia
em crescimento a cada ciclo custaria dezenas de milhares de escritas por dia.
Excepção: `marcacoes` (tem datas futuras).

**Tabelas que o POS apaga sozinho** (`anulacoes`, `purga: true`): se uma
partição tiver menos linhas no POS do que no arquivo, o arquivo **não** é
substituído. O arquivo passa a ser a única cópia.

---

## Como os dados ficam guardados

Cada partição (um dia de vendas, um bloco de produtos…) é **uma linha em
`_dados`**, comprimida em gzip e guardada em base64. Partições que comprimidas
passem de 90 000 caracteres ficam em várias partes, e só substituem a anterior
quando chegam todas.

Descomprimido, o conteúdo é:

```
cols:id,datahora,liquido,...
[1,"2026-08-01T12:31:04.000","12.3400",...]
[2,"2026-08-01T12:35:10.000","7.4900",...]
```

**O SHA-256 destes bytes é o `hash` em `_particoes`.** Quem ler o arquivo pode
confirmar sozinho que nada foi alterado — a ferramenta de extracção fá-lo sempre.

Porquê comprimido: medido com dados do ZoneSoft, ~34 bytes por registo, contra
~850 como linhas SQL. As três lojas cabem no plano gratuito do D1 (500 MB).
Em troca, os dados **não se consultam directamente com SQL na consola do D1**:
extraem-se.

**Dinheiro** vai como texto exacto (`"12.3400"`), sem arredondamentos.
**Datas** em ISO (`2026-08-01T12:31:04.000`). `bigint` vai em texto.

### Extrair uma tabela para Excel

No PC de administração:

```powershell
.\ferramentas\extrair-arquivo.ps1 -Ambiente producao -Worker https://<worker> `
    -Loja cais56 -Base zsrest_2024_0 -Tabela vendas -Desde 2026-08-01 -Ate 2026-08-31
```

Cria um CSV (`;`, UTF-8 — abre directamente no Excel em português), depois de
confirmar o SHA-256 de cada partição. Se alguma não bater, pára com erro.

---

## Encriptação e chaves

| Onde | Como |
|---|---|
| Em trânsito | HTTPS (TLS 1.2+) **e** envelope AES-256-CBC + HMAC-SHA256 (encrypt-then-MAC) |
| Anti-repetição | nonce único por pedido, carimbo temporal ±5 min, resposta ligada ao pedido |
| No POS | password SQL e chave da loja cifradas com DPAPI (máquina), pasta fechada a SYSTEM/Administradores |
| No Cloudflare | D1 cifrado em repouso, jurisdição UE; `CHAVE_MESTRA` como segredo do Worker |
| Registos | sem dados nem segredos (as palavras-passe e blobs base64 são apagados antes de escrever) |

**Chaves** — no PC de administração, `ferramentas\gerir-chaves.ps1`:

```powershell
# uma vez por ambiente: cria a chave mestra e copia-a para colar no Worker (CHAVE_MESTRA)
.\gerir-chaves.ps1 -Ambiente producao -NovaChaveMestra
# por loja: copia a chave para colar no configurador do POS e mostra a linha para _lojas
.\gerir-chaves.ps1 -Ambiente producao -ChaveLoja moscatel
# uma vez por ambiente: par RSA para assinar actualizações
.\gerir-chaves.ps1 -Ambiente producao -NovaChaveAssinatura
```

A chave da loja deriva da mestra e da `versao_chave` em `_lojas`.
**Revogar uma loja**: `UPDATE _lojas SET versao_chave = versao_chave + 1 WHERE loja = 'x'`
(ou `activa = 0`). A chave antiga deixa de funcionar de imediato.

As chaves ficam em `%APPDATA%\SincronizadorSabio\chaves\<ambiente>\`, cifradas
com a conta Windows. **Guardar também a chave mestra num gestor de palavras-passe**:
se este PC se perder, sem ela é preciso gerar outra e reconfigurar as três lojas.

### O que a encriptação não resolve

O DPAPI protege contra outros utilizadores da mesma máquina, **não contra quem é
administrador nela**. Uma máquina que usa uma palavra-passe sozinha tem de a
conseguir ler. Por isso: `dashboard_ro` só lê, chaves por loja, BitLocker nos POS.

---

## Actualizações automáticas

O serviço procura versões novas de 6 em 6 horas (e 2 minutos depois de arrancar)
na fonte configurada.

1. Descarrega `actualizacao.json` e `actualizacao.json.sig`.
2. **Verifica a assinatura RSA-3072** com `chave-publica.xml` (instalada, não actualizável).
3. Recusa versões iguais ou anteriores e versões já rejeitadas.
4. Descarrega cada ficheiro e confirma **SHA-256 e tamanho** contra o manifesto assinado.
5. Guarda a versão actual em `ProgramData\...\anterior`, instala, e reinicia.
6. A versão nova só fica confirmada depois de um ciclo sem erros.
   **Se falhar dois arranques**, o `arranque.ps1` repõe a anterior e marca a nova como rejeitada.

Nunca são actualizados automaticamente: `arranque.ps1`, `chave-publica.xml`,
`SincronizadorSabio.xml`, `SincronizadorSabio.exe`, instalador e desinstalador.
Mudá-los obriga a reinstalar com administrador.

**Publicar uma versão** — no PC de administração:

```powershell
.\ferramentas\publicar-actualizacao.ps1 -Ambiente producao -Versao 1.0.1
```

e enviar o conteúdo de `dist\producao\publicado\` para a fonte de actualizações.

---

## Segurança do SQL (recomendado em cada POS)

O `dashboard_ro` é `db_datareader`: consegue ler **todas** as tabelas. O
sincronizador não envia a `clientes` nem as credenciais, mas negar no SQL é
uma garantia em vez de uma promessa. Correr uma vez, como administrador do SQL:

```sql
USE zsrest_2025_1;   -- a base em uso na loja
DENY SELECT ON dbo.clientes     TO dashboard_ro;
DENY SELECT ON dbo.ATConfig     TO dashboard_ro;
DENY SELECT ON dbo.mailconfig   TO dashboard_ro;
DENY SELECT ON dbo.utilizadores TO dashboard_ro;
DENY SELECT ON dbo.empregados (password) TO dashboard_ro;
```

O botão *Testar ligação* do configurador avisa se o utilizador ainda consegue ler `clientes`.

---

## Diagnóstico

| Sintoma | Onde ver / o que fazer |
|---|---|
| Não sincroniza | `registos\sincronizador-<data>.log` |
| `worker: 401 relogio` | Relógio do POS desacertado mais de 5 minutos |
| `worker: 401 autenticacao` | Chave errada, loja inactiva, ou `versao_chave` mudou |
| `worker: 403 coluna_proibida` | O ZoneSoft trouxe uma coluna que as regras recusam: está a funcionar |
| `Limite diario de escritas atingido` | Normal na carga inicial em plano gratuito; continua no dia seguinte |
| Versão revertida | `registos\arranque.log` |
| O serviço não arranca | `registos\SincronizadorSabio.wrapper.log` e `.err.log` |

No D1, `SELECT * FROM _sincronizacoes WHERE loja = 'x' ORDER BY id DESC LIMIT 20`
mostra cada corrida, com estado, linhas e escritas.

---

## Testes

```powershell
.\testes\correr.ps1                                  # sem rede (178 testes)
.\testes\correr.ps1 -Ficheiros @('Worker.Integracao','Ciclo.Integracao')   # ambiente de teste do Cloudflare
```

Os de integração precisam da chave mestra de **teste** neste PC e do Worker
`arquivo-zsrest-teste`. Nunca apontam para o arquivo de produção.
