<#
.SYNOPSIS
  Relatorio rapido de saude das BDs via API do Prometheus.
.EXAMPLE
  .\collect-metrics.ps1
  .\collect-metrics.ps1 -Watch          # atualiza a cada 10s
  .\collect-metrics.ps1 -PromUrl http://localhost:9090
#>
[CmdletBinding()]
param(
    [string]$PromUrl = "http://localhost:9090",
    [switch]$Watch,
    [int]$IntervalSeconds = 10
)

function Get-PromValue {
    param([string]$Query)
    try {
        $r = Invoke-RestMethod -Uri "$PromUrl/api/v1/query" -Method Get `
             -Body @{ query = $Query } -TimeoutSec 5
        if ($r.status -eq "success" -and $r.data.result.Count -gt 0) {
            return [math]::Round([double]$r.data.result[0].value[1], 2)
        }
        return $null
    } catch {
        Write-Warning "Falha ao consultar o Prometheus: $($_.Exception.Message)"
        return $null
    }
}

function Show-Report {
    $metrics = [ordered]@{
        "PG  - ligacoes ativas"    = 'pg_stat_database_numbackends{datname="labdb"}'
        "PG  - commits/s (1m)"     = 'rate(pg_stat_database_xact_commit{datname="labdb"}[1m])'
        "PG  - cache hit ratio"    = 'pg_stat_database_blks_hit{datname="labdb"} / (pg_stat_database_blks_hit{datname="labdb"} + pg_stat_database_blks_read{datname="labdb"})'
        "PG  - tamanho da BD (MB)" = 'pg_database_size_bytes{datname="labdb"} / 1024 / 1024'
        # MongoDB: ajustar apos confirmar os collectors ativos no exporter (ver Passo 3)
        "MDB - ligacoes atuais"    = 'mongodb_ss_connections{state="current"}'
        "MDB - operacoes/s (1m)"   = 'sum(rate(mongodb_ss_opcounters[1m]))'
    }

    Clear-Host
    Write-Host "=== Relatorio de saude das BDs - $(Get-Date -Format 'HH:mm:ss') ===" -ForegroundColor Cyan
    Write-Host ("Prometheus: {0}" -f $PromUrl) -ForegroundColor DarkGray
    Write-Host ""

    foreach ($item in $metrics.GetEnumerator()) {
        $v = Get-PromValue -Query $item.Value
        if ($null -eq $v) {
            Write-Host ("{0,-26}: sem dados" -f $item.Key) -ForegroundColor DarkYellow
        } else {
            Write-Host ("{0,-26}: {1}" -f $item.Key, $v)
        }
    }

    Write-Host ""
    $conns = Get-PromValue 'pg_stat_database_numbackends{datname="labdb"}'
    $cache = Get-PromValue 'pg_stat_database_blks_hit{datname="labdb"} / (pg_stat_database_blks_hit{datname="labdb"} + pg_stat_database_blks_read{datname="labdb"})'

    if ($conns -and $conns -gt 40) {
        Write-Host "[ALERTA] Ligacoes PG elevadas: $conns (> 40)" -ForegroundColor Red
    } elseif ($cache -and $cache -lt 0.90) {
        Write-Host "[AVISO] Cache hit ratio baixo: $cache (< 0.90)" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] Tudo dentro dos limites." -ForegroundColor Green
    }
}

if ($Watch) {
    while ($true) { Show-Report; Start-Sleep -Seconds $IntervalSeconds }
} else {
    Show-Report
}