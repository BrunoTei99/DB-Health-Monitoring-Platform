# Versões das tecnologias utilizadas

Referência das versões exatas de cada componente da stack, confirmadas diretamente nos serviços em execução (não só nas tags do `docker-compose.yml`) em 2026-08-26. Útil para reproduzir o ambiente ou diagnosticar diferenças de comportamento face a este projeto.

## Sistema base

| Ferramenta | Versão |
|---|---|
| Docker Engine | 29.6.1 |
| Docker Compose | v5.2.0 |
| PowerShell | 5.1 (Windows PowerShell) |
| Python | 3.12.10 |
| pip | 25.0.1 |

## Bases de dados

| Componente | Imagem (docker-compose.yml) | Versão real do serviço |
|---|---|---|
| PostgreSQL | `postgres:16` | 16.15 (Debian 16.15-1.pgdg13+2) |
| MongoDB | `mongo:7` | 7.0.40 |

## Métricas (Prometheus + Grafana)

| Componente | Imagem (docker-compose.yml) | Versão real do serviço |
|---|---|---|
| postgres_exporter | `prometheuscommunity/postgres-exporter:latest` | 0.20.1 |
| mongodb_exporter (Percona) | `percona/mongodb_exporter:0.40` | 0.40 |
| Prometheus | `prom/prometheus:latest` | 3.14.0 |
| Grafana | `grafana/grafana:latest` | 13.2.0 |

⚠️ `postgres-exporter`, `prometheus` e `grafana` usam a tag `latest` no `docker-compose.yml` — a versão real depende do momento em que a imagem foi puxada (`docker pull`). As versões acima são as que ficaram fixadas neste ambiente; um `docker compose pull` mais tarde pode trazer versões mais recentes. Para reprodutibilidade total, considera fixar tags explícitas (ex. `prom/prometheus:v3.14.0`).

## Logs (stack Elastic)

| Componente | Versão (fixada no docker-compose.yml) |
|---|---|
| Elasticsearch | 8.13.4 |
| Kibana | 8.13.4 |
| Filebeat | 8.13.4 |

Elasticsearch, Kibana e Filebeat têm de estar todos na **mesma versão major.minor** — misturar versões causa erros de compatibilidade.

## Dashboards da comunidade (Grafana.com)

| Dashboard | ID |
|---|---|
| PostgreSQL Database | 9628 |
| MongoDB | 2583 |

## API / APM (`api/requirements.txt`)

| Pacote | Versão |
|---|---|
| flask | 3.0.3 |
| psycopg2-binary | 2.9.9 |
| pymongo | 4.8.0 |
| azure-monitor-opentelemetry | 1.8.9 |
| opentelemetry-instrumentation-pymongo | 0.64b0 |
| setuptools | <81 (resolvido para 80.10.2) |

### Dependências transitivas relevantes (resolvidas pelo pip)

| Pacote | Versão |
|---|---|
| opentelemetry-api | 1.43.0 |
| opentelemetry-sdk | 1.43.0 |
| opentelemetry-semantic-conventions | 0.64b0 |
| opentelemetry-instrumentation | 0.64b0 |
| opentelemetry-instrumentation-flask | 0.64b0 |
| opentelemetry-instrumentation-psycopg2 | 0.64b0 |
| opentelemetry-instrumentation-dbapi | 0.64b0 |
| opentelemetry-instrumentation-logging | 0.64b0 |
| azure-monitor-opentelemetry-exporter | 1.0.0b56 |
| azure-identity | 1.25.3 |
| azure-core | 1.41.0 |

⚠️ Todo o conjunto `opentelemetry-*` tem de ficar em versões mutuamente compatíveis — instalar um pacote `opentelemetry-instrumentation-*` isoladamente (ex. `pip install opentelemetry-instrumentation-pymongo` sozinho) pode puxar uma versão mais recente e desalinhar `opentelemetry-semantic-conventions`/`opentelemetry-api` em relação ao que o `opentelemetry-sdk` espera. Instalar sempre em conjunto (`pip install -r requirements.txt`) para o resolver de dependências escolher versões coerentes — ver [fase5-resumo.md](fase5-resumo.md) para o incidente real que motivou esta nota.

## Cloud (Azure)

| Serviço | Nota |
|---|---|
| Application Insights | Recurso `appi-db-health-lab`, região North Europe (região sugerida originalmente, West Europe, não aceitava novas subscrições no momento da criação) |

---

**Como estas versões foram obtidas:** cada serviço foi consultado diretamente (não só a tag da imagem):

```bash
curl -s http://localhost:9090/api/v1/status/buildinfo          # Prometheus
curl -s http://localhost:3000/api/health                       # Grafana
curl -s http://localhost:9187/metrics | grep postgres_exporter_build_info
docker exec lab-postgres psql -U admin -d labdb -t -c "SHOW server_version;"
docker exec lab-mongodb mongosh --quiet --eval "db.version()"
docker version
docker compose version
```
