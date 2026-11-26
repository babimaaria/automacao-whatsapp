# Watchdog: reinicia o container lab_evolution_api automaticamente quando a
# sessao Baileys trava silenciosamente (sem nenhuma linha nova de log por
# mais de 2 minutos), bug recorrente documentado em SKILL.md.
#
# Uso: roda em loop infinito. Deixar numa janela PowerShell aberta, ou
# registrar como Tarefa Agendada do Windows (Action: powershell.exe -File
# <caminho>, Trigger: At startup / At logon).

$container = "lab_evolution_api"
$staleThresholdSeconds = 120
$checkIntervalSeconds = 30
$logFile = Join-Path $PSScriptRoot "watchdog-evolution.log"

function Write-Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

Write-Log "Watchdog iniciado. Monitorando container '$container'."

while ($true) {
    try {
        $lastLine = docker logs $container --tail 1 2>&1 | Select-Object -Last 1
        $lastLineTime = Get-Date

        Start-Sleep -Seconds $checkIntervalSeconds

        $newLastLine = docker logs $container --tail 1 2>&1 | Select-Object -Last 1

        if ($newLastLine -eq $lastLine) {
            # Log nao mudou neste intervalo; conferir ha quanto tempo esta parado
            # usando o timestamp real via docker logs --since
            $sinceTime = (Get-Date).AddSeconds(-$staleThresholdSeconds).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $recentLines = docker logs $container --since $sinceTime 2>&1

            if ([string]::IsNullOrWhiteSpace($recentLines)) {
                Write-Log "ALERTA: nenhuma linha de log nos ultimos $staleThresholdSeconds s. Reiniciando container..."
                docker restart $container 2>&1 | Out-Null
                Write-Log "Container reiniciado. Aguardando estabilizar..."
                Start-Sleep -Seconds 20
            }
        }
    }
    catch {
        Write-Log "ERRO no watchdog: $_"
        Start-Sleep -Seconds $checkIntervalSeconds
    }
}
