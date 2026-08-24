# Script PowerShell para criar a estrutura do projeto db-health-monitor
# Uso: .\create-project-structure.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== Criando estrutura do projeto db-health-monitor ===" -ForegroundColor Cyan
Write-Host ""

# Criar diretório raiz
New-Item -ItemType Directory -Name "db-health-monitor" -Force | Out-Null
Set-Location "db-health-monitor"

# Criar subdirectórios
@("prometheus", "filebeat", "scripts", "api") | ForEach-Object {
    New-Item -ItemType Directory -Name $_ -Force | Out-Null
}

# Criar ficheiros vazios
@(
    "docker-compose.yml",
    "README.md",
    "prometheus/prometheus.yml",
    "filebeat/filebeat.yml",
    "scripts/load-postgres.sh",
    "scripts/load-mongo.sh",
    "scripts/chaos.sh",
    "scripts/collect-metrics.ps1",
    "api/app.py"
) | ForEach-Object {
    New-Item -ItemType File -Path $_ -Force | Out-Null
}

# README.md
@"
# DB Health Monitor

Sistema de monitorização de saude para bases de dados (PostgreSQL, MongoDB).

## Estrutura do Projeto

- docker-compose.yml - Configuracao dos servicos Docker
- prometheus/ - Configuracao do Prometheus
- filebeat/ - Configuracao do Filebeat
- scripts/ - Scripts de carga e teste
- api/ - API principal

## Setup

docker-compose up -d

## Ficheiros

- prometheus/prometheus.yml - Configuracao de scraping do Prometheus
- filebeat/filebeat.yml - Configuracao de coleta de logs
- scripts/load-postgres.sh - Script de carga para PostgreSQL
- scripts/load-mongo.sh - Script de carga para MongoDB
- scripts/chaos.sh - Script para testes caóticos
- scripts/collect-metrics.ps1 - Script de coleta de metricas
- api/app.py - API principal
"@ | Set-Content -Path "README.md"

# docker-compose.yml
@"
version: '3.8'

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: healthdb
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: password
    ports:
      - "5432:5432"

  mongodb:
    image: mongo:6
    ports:
      - "27017:27017"

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  filebeat:
    image: docker.elastic.co/beats/filebeat:8.0.0
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml
"@ | Set-Content -Path "docker-compose.yml"

# prometheus/prometheus.yml
@"
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
"@ | Set-Content -Path "prometheus/prometheus.yml"

# filebeat/filebeat.yml
@"
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/*.log

output.stdout:
  pretty: true
"@ | Set-Content -Path "filebeat/filebeat.yml"

# scripts/load-postgres.sh
@"
#!/bin/bash
# Script de carga de dados para PostgreSQL

echo "Iniciando carga de dados PostgreSQL..."

# Adicionar comandos aqui

echo "Carga concluida!"
"@ | Set-Content -Path "scripts/load-postgres.sh"

# scripts/load-mongo.sh
@"
#!/bin/bash
# Script de carga de dados para MongoDB

echo "Iniciando carga de dados MongoDB..."

# Adicionar comandos aqui

echo "Carga concluida!"
"@ | Set-Content -Path "scripts/load-mongo.sh"

# scripts/chaos.sh
@"
#!/bin/bash
# Script para testes de caos

echo "Iniciando testes de caos..."

# Adicionar testes aqui

echo "Testes concluidos!"
"@ | Set-Content -Path "scripts/chaos.sh"

# scripts/collect-metrics.ps1
@"
# Script PowerShell para coleta de metricas

Write-Host "Iniciando coleta de metricas..." -ForegroundColor Green

# Adicionar comandos aqui

Write-Host "Coleta concluida!" -ForegroundColor Green
"@ | Set-Content -Path "scripts/collect-metrics.ps1"

# api/app.py
@"
"""
API de Health Monitor
"""

from flask import Flask

app = Flask(__name__)

@app.route('/health', methods=['GET'])
def health():
    return {'status': 'healthy'}, 200

if __name__ == '__main__':
    app.run(debug=True, port=5000)
"@ | Set-Content -Path "api/app.py"

# Mostrar resultado
Write-Host "OK - Estrutura criada com sucesso!" -ForegroundColor Green
Write-Host ""
Write-Host "Estrutura de pastas:" -ForegroundColor Cyan
Write-Host ""

# Mostrar tree
Get-ChildItem -Recurse | ForEach-Object {
    $level = ($_.FullName -split '\\').Count - (Get-Location).Path.Split('\').Count
    $indent = "  " * $level
    if ($level -eq 0) {
        Write-Host "├─ $($_.Name)"
    } else {
        Write-Host "$indent├─ $($_.Name)"
    }
}

Write-Host ""
Write-Host "Para comear:" -ForegroundColor Cyan
Write-Host "1. cd db-health-monitor"
Write-Host "2. docker-compose up -d"
Write-Host ""
