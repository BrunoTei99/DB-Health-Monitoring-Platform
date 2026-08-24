# Database Health Monitoring Platform

A self-contained observability lab that monitors a relational (PostgreSQL) and a NoSQL (MongoDB) database end-to-end — covering the three pillars of observability: **metrics**, **logs**, and **traces** — in a reproducible local environment powered by Docker Compose.

## What this project demonstrates

- **Observability & monitoring** — Prometheus metrics collection, Grafana dashboards, threshold-based alerting
- **Log aggregation** — PostgreSQL and container logs shipped via Filebeat to Elasticsearch, searchable in Kibana and Grafana
- **APM / distributed tracing** — a test API instrumented with Azure Application Insights (OpenTelemetry), mapping dependencies to both databases
- **Scripting** — Bash for synthetic load generation and chaos/failure injection; PowerShell for health reporting via the Prometheus API
- **Databases** — SQL (schema design, aggregations, lock/session management) and NoSQL (document inserts, aggregation pipelines)

## Architecture

```
Load scripts (Bash / PowerShell)
            |
            v
+---------------------------+
|        Data layer         |
|  PostgreSQL   |  MongoDB  |
+---------------------------+
      |                 |
  exporters          Filebeat
      |                 |
      v                 v
 Prometheus       Elasticsearch
      \                 /
       \               /
        v             v
     Grafana (dashboards + alerts)

Test API --> queries --> Databases
     |
     +--> telemetry --> Application Insights
```

| Component | Purpose | Port |
|---|---|---|
| PostgreSQL 16 | Relational database under monitoring | 5432 |
| MongoDB 7 | NoSQL database under monitoring | 27017 |
| postgres_exporter | Exposes PostgreSQL metrics to Prometheus | 9187 |
| mongodb_exporter | Exposes MongoDB metrics to Prometheus | 9216 |
| Prometheus | Metrics scraping and storage | 9090 |
| Grafana | Dashboards and alerting | 3000 |
| Elasticsearch | Log storage and search | 9200 |
| Kibana | Log exploration UI | 5601 |
| Filebeat | Log shipping (DB + container logs) | — |
| Test API (Flask) | Instrumented app for APM tracing | 8000 |

## Prerequisites

- Docker and Docker Compose
- PowerShell 7+ (for the reporting script)
- Python 3.10+ (only for the optional APM phase)
- An Azure account with an Application Insights resource (optional, free tier)

## Quick start

```bash
# 1. Start the core stack
docker compose up -d

# 2. Verify all Prometheus targets are UP
open http://localhost:9090/targets

# 3. Create the sample schema
docker exec -it <postgres-container> psql -U admin -d labdb -f /dev/stdin < sql/schema.sql

# 4. Start generating load
./scripts/load-postgres.sh &
./scripts/load-mongo.sh &

# 5. Open Grafana (admin / admin) and watch the dashboards
open http://localhost:3000
```

Default credentials are for local lab use only — change them for anything beyond localhost.

## Repository structure

```
.
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml          # Scrape configs for both exporters
├── filebeat/
│   └── filebeat.yml            # Ships PostgreSQL + container logs to Elasticsearch
├── sql/
│   └── schema.sql              # Sample schema (orders table + index)
├── scripts/
│   ├── load-postgres.sh        # Synthetic SQL workload (inserts + aggregations)
│   ├── load-mongo.sh           # Synthetic NoSQL workload (inserts + pipelines)
│   ├── chaos.sh                # Failure injection: locks, connection storms, slow queries
│   └── collect-metrics.ps1     # PowerShell health report via the Prometheus API
├── api/
│   └── app.py                  # Flask test API instrumented with Application Insights
└── README.md
```

## Dashboards and alerting

- Community dashboards: **9628** (PostgreSQL) and **2583** (MongoDB), imported into Grafana
- Custom "DB Health Overview" dashboard: active connections, commits/s, cache hit ratio, MongoDB ops/s
- Alert rule: fires when PostgreSQL active connections exceed a threshold, demonstrating detection during the connection-storm scenario

## Log aggregation

PostgreSQL is configured with `log_min_duration_statement=1000`, so every query slower than 1 second is logged. Filebeat ships these logs to Elasticsearch (`db-logs-*` indices), where they can be searched in Kibana — for example, finding every slow query from the last hour during an incident.

## Failure scenarios (chaos demo)

The `chaos.sh` script injects realistic incidents to exercise the full troubleshooting workflow:

```bash
./scripts/chaos.sh connections   # Connection storm -> Grafana alert fires
./scripts/chaos.sh slowquery     # Heavy query -> visible in Elasticsearch logs + APM traces
./scripts/chaos.sh lock          # Table lock -> blocked sessions in metrics
```

**Demo walkthrough:** detect the incident through a Grafana alert → investigate the root cause in Elasticsearch logs and APM traces → resolve by terminating the offending sessions → validate recovery on the dashboards.

## APM (optional phase)

The Flask API exposes endpoints that query both databases, plus a deliberately slow `/slow` endpoint. Instrumented with the Azure Monitor OpenTelemetry distro, it produces distributed traces and an application map showing PostgreSQL and MongoDB as dependencies — making the slow endpoint immediately visible.

```bash
pip install -r api/requirements.txt
export APPLICATIONINSIGHTS_CONNECTION_STRING="<your-connection-string>"
python api/app.py
```

## Cost

Everything in this stack is free for local/lab use: PostgreSQL, MongoDB, Prometheus, Grafana OSS, the exporters, and Filebeat are open source; Elasticsearch and Kibana run under the free Basic license; Application Insights stays within the Azure Monitor free ingestion tier for this workload.

## Roadmap / possible extensions

- Alert notifications via Slack or email contact points
- Node exporter for host-level metrics
- Grafana provisioning (dashboards and data sources as code)
- Replace the manual demo with a scheduled chaos job
- Dynatrace OneAgent as an alternative APM (15-day trial)

## License

MIT
