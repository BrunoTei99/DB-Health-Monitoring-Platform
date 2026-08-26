<#
.SYNOPSIS
  Injeta falhas controladas no lab para demonstrar a detecao em cada camada.
.EXAMPLE
  .\chaos.ps1 connections    # tempestade de ligacoes -> alerta Grafana
  .\chaos.ps1 slowquery      # query pesada -> logs Elasticsearch + APM
  .\chaos.ps1 lock           # bloqueio de tabela -> sessoes bloqueadas
  .\chaos.ps1 resolve        # termina as sessoes problematicas
  .\chaos.ps1 status         # mostra o estado atual das sessoes
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("connections", "slowquery", "lock", "resolve", "status")]
    [string]$Scenario
)

$C = "lab-postgres"

function Invoke-PG([string]$Sql) {
    docker exec $C psql -U admin -d labdb -c $Sql
}

switch ($Scenario) {

    "connections" {
        Write-Host ">>> A abrir 50 ligacoes penduradas (pg_sleep 300s)..." -ForegroundColor Yellow
        1..50 | ForEach-Object {
            docker exec -d $C psql -U admin -d labdb -c "SELECT pg_sleep(300);"
        }
        Write-Host ">>> Feito. Observa:" -ForegroundColor Yellow
        Write-Host "    1. Grafana: painel 'PG - Ligacoes ativas' fica vermelho (imediato)"
        Write-Host "    2. Grafana Alerting: Normal -> Pending (~1 min) -> Firing (~3 min)"
        Write-Host "    Resolve com: .\chaos.ps1 resolve"
    }

    "slowquery" {
        Write-Host ">>> A executar CROSS JOIN pesado (demora varios segundos)..." -ForegroundColor Yellow
        Invoke-PG "SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2;"
        Write-Host ">>> Feito. Observa:" -ForegroundColor Yellow
        Write-Host "    1. Kibana/Grafana logs: pesquisa message:*duration* (~30s a aparecer)"
        Write-Host "    2. O painel 'PG - Queries lentas' do dashboard mostra a entrada"
    }

    "lock" {
        Write-Host ">>> A bloquear a tabela orders durante 90s (ACCESS EXCLUSIVE)..." -ForegroundColor Yellow
        docker exec -d $C psql -U admin -d labdb -c "BEGIN; LOCK TABLE orders IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(90); COMMIT;"
        Write-Host ">>> Feito. Observa:" -ForegroundColor Yellow
        Write-Host "    1. O load-postgres.sh 'congela' (INSERTs bloqueados a espera do lock)"
        Write-Host "    2. Commits/s no Grafana caem a pique"
        Write-Host "    3. .\chaos.ps1 status mostra sessoes em 'waiting'"
        Write-Host "    Auto-resolve em 90s, ou forca com: .\chaos.ps1 resolve"
    }

    "resolve" {
        Write-Host ">>> A terminar sessoes de chaos (pg_sleep e locks)..." -ForegroundColor Green
        Invoke-PG @"
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE (query LIKE '%pg_sleep%' OR query LIKE '%LOCK TABLE%')
  AND pid <> pg_backend_pid();
"@
        Write-Host ">>> Feito. Em 1-2 min tudo volta ao verde (alerta -> Normal)." -ForegroundColor Green
    }

    "status" {
        Write-Host ">>> Sessoes ativas no PostgreSQL:" -ForegroundColor Cyan
        Invoke-PG @"
SELECT pid, state, wait_event_type,
       LEFT(query, 60) AS query,
       now() - query_start AS running_for
FROM pg_stat_activity
WHERE datname = 'labdb'
ORDER BY query_start;
"@
    }
}
