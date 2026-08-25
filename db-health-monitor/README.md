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
- grafana/dashboards/db-health-overview.json - Dashboard "DB Health Overview" (PostgreSQL + MongoDB)

## Dashboards do Grafana

O dashboard "DB Health Overview" está versionado em `grafana/dashboards/db-health-overview.json`. Para o reimportar:

1. Grafana (http://localhost:3000) → Dashboards → New → Import
2. Upload do ficheiro `grafana/dashboards/db-health-overview.json`
3. Escolhe o data source Prometheus e confirma a importação
