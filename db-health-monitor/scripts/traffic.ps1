param([int]$IntervalMs = 800)
$endpoints = @(
    @{ url = "http://localhost:8000/orders/summary"; peso = 5 },
    @{ url = "http://localhost:8000/events/summary"; peso = 4 },
    @{ url = "http://localhost:8000/slow";           peso = 1 },
    @{ url = "http://localhost:8000/error";          peso = 1 }
)
# Lista ponderada: os endpoints "normais" dominam, o lento e o com erros sao minoria
$pool = foreach ($e in $endpoints) { 1..$e.peso | ForEach-Object { $e.url } }

$i = 0
Write-Host "A gerar trafego (Ctrl+C para parar)..." -ForegroundColor Cyan
while ($true) {
    $i++
    $url = Get-Random -InputObject $pool
    try {
        $null = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing
        $status = "OK"
    } catch {
        $status = "ERRO"   # esperado no /error - faz parte
    }
    if ($i % 20 -eq 0) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $i pedidos enviados" }
    Start-Sleep -Milliseconds $IntervalMs
}
