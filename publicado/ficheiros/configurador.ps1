#Requires -Version 5.1
<#
    CONFIGURADOR do Sincronizador Sábio.

    Com janela (normal):   configurador.ps1
    Sem janela (testes):   configurador.ps1 -SemJanela -Loja moscatel -Servidor ... -Base ...
                             -Utilizador dashboard_ro -Password (SecureString)
                             -WorkerUrl https://... -ChaveLoja (SecureString) [-Fonte ...]

    Os dois modos usam as mesmas funções do módulo. Guarda em
    %ProgramData%\SincronizadorSabio\config.json, com a password do SQL e a
    chave da loja cifradas por DPAPI (âmbito da máquina) e a pasta fechada a
    SYSTEM e Administradores.

    Códigos de saída: 0 guardado · 1 erro · 2 cancelado
#>
param(
    [switch]$SemJanela,
    [string]$Loja,
    [string]$Servidor,
    [string]$Base,
    [string]$Utilizador = 'dashboard_ro',
    [Security.SecureString]$Password,
    [switch]$Integrada,
    [string]$WorkerUrl,
    [Security.SecureString]$ChaveLoja,
    [string]$Fonte = '',
    [hashtable]$Sincronizacao = @{},
    [switch]$AclComUtilizadorActual,
    [switch]$SoConstruir          # testes: monta a janela inteira e sai sem a mostrar
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SincronizadorSabio.psm1') -Force

if ($SemJanela) {
    try {
        Save-SabioConfig -Loja $Loja -Servidor $Servidor -Base $Base -Utilizador $Utilizador -Password $Password -Integrada:$Integrada `
            -WorkerUrl $WorkerUrl -ChaveLoja $ChaveLoja -Fonte $Fonte -Sincronizacao $Sincronizacao -AclComUtilizadorActual:$AclComUtilizadorActual
        Write-Output 'Configuracao guardada.'
        exit 0
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$FONTE_PADRAO = 'https://raw.githubusercontent.com/GroupMultiFund/sincronizador-sabio/main/publicado'
$WORKER_PADRAO = 'https://arquivo-zsrest.logistica-64e.workers.dev'
$verde = [System.Drawing.Color]::FromArgb(0, 110, 50)
$vermelho = [System.Drawing.Color]::FromArgb(170, 20, 20)
$laranja = [System.Drawing.Color]::FromArgb(170, 90, 0)

# ---------------------------------------------------------------- estado inicial
$existente = $null
$caminhoConfig = Get-SabioCaminhoConfig
if (Test-Path -LiteralPath $caminhoConfig) {
    try { $existente = Get-Content -LiteralPath $caminhoConfig -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$detectado = Find-SabioZoneSoft

# ---------------------------------------------------------------- janela
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Sincronizador Sábio — configuração'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.ClientSize = New-Object System.Drawing.Size(620, 640)

function Novo-Rotulo($texto, $x, $y, $largura = 150) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $texto; $l.Location = New-Object System.Drawing.Point($x, $y); $l.Size = New-Object System.Drawing.Size($largura, 22)
    $l.TextAlign = 'MiddleLeft'
    return $l
}
function Nova-Caixa($x, $y, $largura, [switch]$Segredo) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($largura, 23)
    if ($Segredo) { $t.UseSystemPasswordChar = $true }
    return $t
}
function Novo-Botao($texto, $x, $y, $largura = 130) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texto; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($largura, 26)
    return $b
}
function Novo-Grupo($texto, $y, $altura) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $texto; $g.Location = New-Object System.Drawing.Point(12, $y); $g.Size = New-Object System.Drawing.Size(596, $altura)
    $form.Controls.Add($g)
    return $g
}
function Mostrar($rotulo, $texto, $cor) { $rotulo.Text = $texto; $rotulo.ForeColor = $cor; [System.Windows.Forms.Application]::DoEvents() }

# Loja
$gLoja = Novo-Grupo 'Loja' 10 60
$gLoja.Controls.Add((Novo-Rotulo 'Identificador da loja' 12 24))
$cLoja = New-Object System.Windows.Forms.ComboBox
$cLoja.Location = New-Object System.Drawing.Point(170, 24); $cLoja.Size = New-Object System.Drawing.Size(200, 23)
[void]$cLoja.Items.AddRange(@('moscatel', 'cais56', 'adega'))
$gLoja.Controls.Add($cLoja)

# SQL
$gSql = Novo-Grupo 'Base de dados do ZoneSoft' 80 250
$gSql.Controls.Add((Novo-Rotulo 'Servidor SQL' 12 24))
$tServidor = Nova-Caixa 170 24 260; $gSql.Controls.Add($tServidor)
$bDetectar = Novo-Botao 'Detectar' 440 23 140; $gSql.Controls.Add($bDetectar)
$gSql.Controls.Add((Novo-Rotulo 'Utilizador' 12 56))
$tUtilizador = Nova-Caixa 170 56 260; $gSql.Controls.Add($tUtilizador)
$gSql.Controls.Add((Novo-Rotulo 'Password' 12 88))
$tPassword = Nova-Caixa 170 88 260 -Segredo; $gSql.Controls.Add($tPassword)
$gSql.Controls.Add((Novo-Rotulo 'Base de dados' 12 120))
$cBase = New-Object System.Windows.Forms.ComboBox
$cBase.Location = New-Object System.Drawing.Point(170, 120); $cBase.Size = New-Object System.Drawing.Size(410, 23)
$cBase.DropDownStyle = 'DropDownList'
$gSql.Controls.Add($cBase)
$bBases = Novo-Botao 'Procurar bases' 170 152 140; $gSql.Controls.Add($bBases)
$bTestarSql = Novo-Botao 'Testar ligação' 320 152 140; $gSql.Controls.Add($bTestarSql)
$lSql = Novo-Rotulo '' 12 186 570; $lSql.Size = New-Object System.Drawing.Size(570, 56); $lSql.TextAlign = 'TopLeft'
$gSql.Controls.Add($lSql)

# Arquivo
$gArq = Novo-Grupo 'Arquivo (Worker)' 340 150
$gArq.Controls.Add((Novo-Rotulo 'Endereço do Worker' 12 24))
$tWorker = Nova-Caixa 170 24 410; $gArq.Controls.Add($tWorker)
$gArq.Controls.Add((Novo-Rotulo 'Chave da loja' 12 56))
$tChave = Nova-Caixa 170 56 410 -Segredo; $gArq.Controls.Add($tChave)
$bTestarArq = Novo-Botao 'Testar arquivo' 170 88 140; $gArq.Controls.Add($bTestarArq)
$lArq = Novo-Rotulo '' 12 118 570; $lArq.Size = New-Object System.Drawing.Size(570, 26); $lArq.TextAlign = 'TopLeft'
$gArq.Controls.Add($lArq)

# Actualizações
$gAct = Novo-Grupo 'Actualizações automáticas' 500 60
$gAct.Controls.Add((Novo-Rotulo 'Fonte' 12 24))
$tFonte = Nova-Caixa 170 24 410; $gAct.Controls.Add($tFonte)

$bGuardar = Novo-Botao 'Guardar' 380 600 110; $form.Controls.Add($bGuardar)
$bCancelar = Novo-Botao 'Cancelar' 498 600 110; $form.Controls.Add($bCancelar)
$lEstado = Novo-Rotulo '' 12 600 360; $form.Controls.Add($lEstado)
$form.AcceptButton = $bGuardar
$form.CancelButton = $bCancelar

# ---------------------------------------------------------------- preencher
$basesNomes = New-Object System.Collections.ArrayList
function Definir-Base([string]$nome) {
    for ($i = 0; $i -lt $basesNomes.Count; $i++) { if ($basesNomes[$i] -eq $nome) { $cBase.SelectedIndex = $i; return } }
    if ($nome) { [void]$basesNomes.Add($nome); [void]$cBase.Items.Add($nome); $cBase.SelectedIndex = $cBase.Items.Count - 1 }
}

if ($existente) {
    $cLoja.Text = [string]$existente.loja
    $tServidor.Text = [string]$existente.sql.servidor
    $tUtilizador.Text = [string](Get-SabioPropriedade $existente.sql 'utilizador' 'dashboard_ro')
    Definir-Base ([string]$existente.sql.base)
    $tWorker.Text = [string]$existente.worker.url
    $tFonte.Text = [string](Get-SabioPropriedade $existente.actualizacoes 'fonte' '')
    Mostrar $lEstado 'Configuração existente carregada. Segredos em branco = manter os guardados.' ([System.Drawing.Color]::DimGray)
} else {
    $tUtilizador.Text = 'dashboard_ro'
    $tFonte.Text = $FONTE_PADRAO
    $tWorker.Text = $WORKER_PADRAO
    if ($detectado) {
        $tServidor.Text = $detectado.servidor
        Definir-Base $detectado.base
        Mostrar $lSql "Detectado na configuração do ZoneSoft: $($detectado.servidor) / $($detectado.base)" $verde
    } else {
        $tServidor.Text = 'localhost\ZONESOFTSQL'
    }
}

function Password-Actual {
    if ($tPassword.Text) { return $tPassword.Text }
    if ($existente -and (Get-SabioPropriedade $existente.sql 'password_dpapi')) {
        return [Text.Encoding]::UTF8.GetString([SabioV1.Nucleo]::Desproteger([string]$existente.sql.password_dpapi, $true))
    }
    return ''
}

function Chave-Actual {
    if ($tChave.Text) {
        try { $b = [Convert]::FromBase64String($tChave.Text.Trim()) } catch { throw 'A chave da loja não é base64 válido.' }
        if ($b.Length -ne 32) { throw 'A chave da loja tem de ter 32 bytes.' }
        return , $b
    }
    if ($existente -and (Get-SabioPropriedade $existente.worker 'chave_dpapi')) {
        return , ([SabioV1.Nucleo]::Desproteger([string]$existente.worker.chave_dpapi, $true))
    }
    throw 'Falta a chave da loja.'
}

function Base-Seleccionada {
    if ($cBase.SelectedIndex -ge 0) { return [string]$basesNomes[$cBase.SelectedIndex] }
    return ''
}

# ---------------------------------------------------------------- acções
$bDetectar.Add_Click({
    $d = Find-SabioZoneSoft
    if ($d) {
        $tServidor.Text = $d.servidor
        Definir-Base $d.base
        Mostrar $lSql "Detectado: $($d.servidor) / $($d.base)  (de $($d.origem))" $verde
    } else {
        Mostrar $lSql 'Não encontrei a configuração do ZoneSoft nesta máquina. Preencha à mão.' $laranja
    }
})

$bBases.Add_Click({
    Mostrar $lSql 'A procurar bases…' ([System.Drawing.Color]::DimGray)
    try {
        $lista = Get-SabioBasesDados -Servidor $tServidor.Text -Utilizador $tUtilizador.Text -Password (Password-Actual)
        $escolhida = Base-Seleccionada
        $emUso = if ($detectado) { $detectado.base } else { '' }
        $cBase.Items.Clear(); $basesNomes.Clear()
        foreach ($b in $lista) {
            $texto = $b.nome
            if ($b.ultimo_documento) { $texto += '   — último documento ' + ([datetime]$b.ultimo_documento).ToString('dd-MM-yyyy HH:mm') }
            if ($b.nome -eq $emUso) { $texto += '   (em uso pelo ZoneSoft)' }
            [void]$basesNomes.Add($b.nome); [void]$cBase.Items.Add($texto)
        }
        if ($escolhida) { Definir-Base $escolhida } elseif ($emUso) { Definir-Base $emUso }
        Mostrar $lSql "$($lista.Count) base(s) encontrada(s). A que está em uso tem o documento mais recente." $verde
    } catch {
        Mostrar $lSql "Não consegui listar as bases: $($_.Exception.Message)" $vermelho
    }
})

$bTestarSql.Add_Click({
    Mostrar $lSql 'A testar…' ([System.Drawing.Color]::DimGray)
    try {
        $r = Test-SabioLigacaoSql -Servidor $tServidor.Text -Base (Base-Seleccionada) -Utilizador $tUtilizador.Text -Password (Password-Actual)
        if (-not $r.ok) { Mostrar $lSql $r.mensagem $vermelho; return }
        $texto = $r.mensagem
        $cor = $verde
        if ($r.escrever) { $texto += "`nATENÇÃO: este utilizador consegue ESCREVER. Devia ser só de leitura."; $cor = $vermelho }
        if ($r.ler_clientes) {
            $texto += "`nAviso: este utilizador consegue ler a tabela clientes. O sincronizador não a envia, mas recomenda-se DENY SELECT (ver LEIA-ME)."
            if ($cor -eq $verde) { $cor = $laranja }
        }
        Mostrar $lSql $texto $cor
    } catch {
        Mostrar $lSql $_.Exception.Message $vermelho
    }
})

$bTestarArq.Add_Click({
    Mostrar $lArq 'A testar…' ([System.Drawing.Color]::DimGray)
    try {
        $r = Test-SabioWorker -Url $tWorker.Text -ChaveLoja (Chave-Actual) -Loja $cLoja.Text -Base (Base-Seleccionada)
        Mostrar $lArq $r.mensagem $(if ($r.ok) { $verde } else { $vermelho })
    } catch {
        Mostrar $lArq $_.Exception.Message $vermelho
    }
})

$bCancelar.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })

$bGuardar.Add_Click({
    try {
        $pwd = New-Object Security.SecureString
        foreach ($ch in $tPassword.Text.ToCharArray()) { $pwd.AppendChar($ch) }
        $chave = New-Object Security.SecureString
        foreach ($ch in $tChave.Text.Trim().ToCharArray()) { $chave.AppendChar($ch) }
        Save-SabioConfig -Loja $cLoja.Text.Trim() -Servidor $tServidor.Text.Trim() -Base (Base-Seleccionada) -Utilizador $tUtilizador.Text.Trim() `
            -Password $pwd -WorkerUrl $tWorker.Text.Trim() -ChaveLoja $chave -Fonte $tFonte.Text.Trim()
        $tPassword.Text = ''; $tChave.Text = ''
        [System.Windows.Forms.MessageBox]::Show('Configuração guardada. O serviço lê-a sozinho, sem ser preciso reiniciar.', 'Sincronizador Sábio', 'OK', 'Information') | Out-Null
        $form.DialogResult = 'OK'
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Não foi possível guardar', 'OK', 'Error') | Out-Null
    }
})

if ($SoConstruir) {
    $controlos = 0
    $pilha = New-Object System.Collections.Stack
    $pilha.Push($form)
    while ($pilha.Count) { $c = $pilha.Pop(); $controlos++; foreach ($f in $c.Controls) { $pilha.Push($f) } }
    Write-Output ("janela ok: {0} controlos; servidor='{1}' worker='{2}' fonte='{3}' utilizador='{4}'" -f $controlos, $tServidor.Text, $tWorker.Text, $tFonte.Text, $tUtilizador.Text)
    $form.Dispose()
    exit 0
}

$resultado = $form.ShowDialog()
$form.Dispose()
if ($resultado -eq 'OK') { exit 0 } else { exit 2 }
