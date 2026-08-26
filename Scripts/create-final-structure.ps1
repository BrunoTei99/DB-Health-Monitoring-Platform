# Script PowerShell para criar a estrutura final do projeto db-health-monitor
# (apenas pastas e ficheiros vazios, sem conteudo)
# Uso: .\create-final-structure.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== Criando estrutura final do projeto db-health-monitor ===" -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Name "db-health-monitor" -Force | Out-Null
Set-Location "db-health-monitor"

$directories = @(
    "prometheus",
    "filebeat",
    "sql",
    "scripts",
    "api",
    "grafana\dashboards",
    "docs"
)

foreach ($dir in $directories) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$files = @(
    "docker-compose.yml",
    "README.md",
    "prometheus\prometheus.yml",
    "filebeat\filebeat.yml",
    "sql\schema.sql",
    "scripts\load-postgres.sh",
    "scripts\load-mongo.sh",
    "scripts\collect-metrics.ps1",
    "scripts\traffic.ps1",
    "scripts\chaos.ps1",
    "scripts\chaos.sh",
    "api\app.py",
    "api\requirements.txt",
    "grafana\dashboards\db-health-overview.json"
)

foreach ($file in $files) {
    New-Item -ItemType File -Path $file -Force | Out-Null
}

Write-Host "OK - Estrutura criada com sucesso!" -ForegroundColor Green
Write-Host ""
Write-Host "Estrutura de pastas:" -ForegroundColor Cyan
Write-Host ""

Get-ChildItem -Recurse | ForEach-Object {
    $level = ($_.FullName -split '\\').Count - (Get-Location).Path.Split('\').Count
    $indent = "  " * $level
    Write-Host "$indent├─ $($_.Name)"
}
