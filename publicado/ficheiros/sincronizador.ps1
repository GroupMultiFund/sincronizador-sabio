#Requires -Version 5.1
<#
    SINCRONIZADOR — o ciclo do serviço.

    A cada intervalo_min (60 min): tabelas de movimento, dias fechados recentes.
    (Dias fechados = até ontem. O de hoje só entra amanhã, de uma vez.)
    A cada intervalo_referencia_min (6 h): também as tabelas de referência.
    A cada revisao_completa_dias (30 dias): tudo, de ponta a ponta.
    A cada intervalo_horas de actualizações (6 h): procura versão nova.

    Uma versão acabada de instalar só fica confirmada depois do primeiro
    ciclo que corre bem. Se falhar três ciclos seguidos por um erro que não
    é de rede, sai com erro — o arranque.ps1 conta isso e, à segunda, reverte.
#>
param([switch]$UmCiclo)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SincronizadorSabio.psm1') -Force

$cfg = Read-SabioConfig
$versao = Get-SabioVersaoInstalada
Write-SabioRegisto INFO "arranque: versao $versao, loja $($cfg.loja), base $($cfg.sqlBase)"
Remove-SabioRegistosAntigos

$pendente = Test-Path -LiteralPath (Join-Path (Get-SabioDirDados) 'pendente.json')
$estado = Read-SabioEstadoLocal
$agora = Get-Date

function Get-Data([string]$texto) {
    if (-not $texto) { return [datetime]::MinValue }
    try { return [datetime]::Parse($texto, [Globalization.CultureInfo]::InvariantCulture) } catch { return [datetime]::MinValue }
}

$proxCiclo = $agora
$proxReferencia = (Get-Data $estado.ultima_referencia).AddMinutes($cfg.intervaloRefMin)
# Na primeira vez não se faz a revisão completa logo: a carga inicial já é completa.
$proxCompleta = if ($estado.ultima_completa) { (Get-Data $estado.ultima_completa).AddDays($cfg.completaDias) } else { $agora.AddDays($cfg.completaDias) }
$proxActualizacao = if ($UmCiclo) { $agora } else { $agora.AddMinutes(2) }
$falhasSeguidas = 0

while ($true) {
    $agora = Get-Date

    # Configuração mudada pelo configurador: recarregar sem reiniciar.
    $f = Get-SabioCaminhoConfig
    if ((Get-Item -LiteralPath $f).LastWriteTimeUtc -ne $cfg.alterado) {
        try { $cfg = Read-SabioConfig; Write-SabioRegisto INFO 'configuracao recarregada.' }
        catch { Write-SabioRegisto ERRO "configuracao nova ilegivel, mantem-se a anterior: $($_.Exception.Message)" }
    }

    if ($agora -ge $proxCiclo) {
        $referencia = $agora -ge $proxReferencia
        $completa = $agora -ge $proxCompleta
        try {
            $r = Invoke-SabioCiclo -Config $cfg -Referencia:$referencia -Completa:$completa
            $e = Read-SabioEstadoLocal
            if ($referencia -or $completa) { $e.ultima_referencia = $agora.ToString('s'); $proxReferencia = $agora.AddMinutes($cfg.intervaloRefMin) }
            if ($completa) { $e.ultima_completa = $agora.ToString('s'); $proxCompleta = $agora.AddDays($cfg.completaDias) }
            Save-SabioEstadoLocal $e
            $falhasSeguidas = 0
            if ($pendente -and $r.erros -eq 0) { Confirm-SabioActualizacao; $pendente = $false }
        } catch {
            $m = $_.Exception.Message
            if (Test-SabioErroRede $m) {
                Write-SabioRegisto AVISO "sem ligacao ao arquivo, tenta no proximo ciclo: $m"
            } else {
                $falhasSeguidas++
                Write-SabioRegisto ERRO "ciclo falhou ($falhasSeguidas seguido(s)): $m"
                if ($pendente -and $falhasSeguidas -ge 3) {
                    Write-SabioRegisto ERRO 'versao nova falhou 3 ciclos seguidos: a sair para o arranque decidir.'
                    exit 1
                }
            }
        }
        # Com o limite diário atingido não vale a pena tentar de 15 em 15 minutos.
        $proxCiclo = (Get-Date).AddMinutes($cfg.intervaloMin)
    }

    if ($agora -ge $proxActualizacao) {
        try {
            $pacote = Invoke-SabioVerificarActualizacao -Config $cfg
            if ($pacote) {
                Install-SabioActualizacao -Pacote $pacote
                exit 3
            }
        } catch {
            Write-SabioRegisto AVISO "verificacao de actualizacoes falhou: $($_.Exception.Message)"
        }
        $proxActualizacao = (Get-Date).AddHours($cfg.intervaloActH)
    }

    if ($UmCiclo) { exit 0 }
    Start-Sleep -Seconds 20
}
