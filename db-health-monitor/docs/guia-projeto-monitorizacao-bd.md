# Mini projeto: Plataforma de monitorização de saúde de bases de dados

Guia passo a passo do lab de observabilidade construído sobre PostgreSQL e MongoDB, usando Prometheus, Grafana, Elasticsearch, Filebeat, scripts Bash/PowerShell e uma componente de APM com Application Insights.

Para o "porquê" teórico de cada decisão, ver os `docs/faseN-conceitos.md`; para o histórico passo a passo com os problemas reais encontrados e resolvidos, ver os `docs/faseN-resumo.md`. Para o guião de apresentação da demo final, ver [fase6-guiao-demo.md](fase6-guiao-demo.md).

## Visão geral da arquitetura

```mermaid
flowchart TB
    subgraph carga["Carga sintética"]
        LP["load-postgres.sh"]
        LM["load-mongo.sh"]
        TR["traffic.ps1"]
    end

    subgraph dados["Camada de dados"]
        PG[("PostgreSQL 16\nlabdb")]
        MG[("MongoDB 7\nlabdb")]
    end

    API["API Flask :8000\n/orders /events /slow /error"]

    subgraph metrics["Métricas"]
        PGE["postgres_exporter :9187"]
        MGE["mongodb_exporter :9216"]
        PROM["Prometheus :9090"]
        GRAF["Grafana :3000"]
    end

    subgraph logslayer["Logs"]
        FB["Filebeat"]
        ES[("Elasticsearch :9200")]
        KIB["Kibana :5601"]
    end

    AI["Application Insights\n(Azure, cloud)"]
    CHAOS["chaos.ps1 / chaos.sh"]

    LP --> PG
    LM --> MG
    TR --> API
    API --> PG
    API --> MG
    API -- OpenTelemetry --> AI

    PG --> PGE --> PROM --> GRAF
    MG --> MGE --> PROM
    PG -- "logs .log" --> FB
    FB --> ES --> KIB
    ES -- "data source" --> GRAF

    CHAOS -. "injeta falhas" .-> PG
```

O PostgreSQL e o MongoDB são monitorizados por métricas (via exporters + Prometheus); só o PostgreSQL tem logs de ficheiro capturados (via `logging_collector`) — o Filebeat também recolhe o stdout/stderr de todos os containers da stack, dando volume adicional ao índice de logs. A API Flask fecha o terceiro pilar (traces), falando diretamente com o Application Insights.

## Estrutura de pastas

```
db-health-monitor/
├── docker-compose.yml
├── prometheus/prometheus.yml
├── filebeat/filebeat.yml
├── sql/schema.sql
├── scripts/
│   ├── load-postgres.sh
│   ├── load-mongo.sh
│   ├── collect-metrics.ps1
│   ├── traffic.ps1
│   ├── chaos.ps1
│   └── chaos.sh
├── api/
│   ├── app.py
│   └── requirements.txt
├── grafana/dashboards/
│   └── db-health-overview.json
├── docs/
└── README.md
```

---

## Fase 1 — Infraestrutura base com Docker Compose

**Objetivo:** subir PostgreSQL, MongoDB, os exporters, Prometheus e Grafana.

### `docker-compose.yml`

```yaml
services:

  postgres:
    image: postgres:16
    container_name: lab-postgres
    environment:
      POSTGRES_USER: admin
      POSTGRES_PASSWORD: admin123
      POSTGRES_DB: labdb
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
      - pglogs:/var/log/postgresql
    command: >
      postgres -c logging_collector=on
               -c log_directory=/var/log/postgresql
               -c log_min_duration_statement=1000
               -c log_statement=none
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U admin -d labdb"]
      interval: 10s
      timeout: 5s
      retries: 5

  mongodb:
    image: mongo:7
    container_name: lab-mongodb
    ports:
      - "27017:27017"
    volumes:
      - mongodata:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: lab-pg-exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://admin:admin123@postgres:5432/labdb?sslmode=disable"
    ports:
      - "9187:9187"
    depends_on:
      postgres:
        condition: service_healthy

  mongodb-exporter:
    image: percona/mongodb_exporter:0.40
    container_name: lab-mongo-exporter
    command:
      - "--mongodb.uri=mongodb://mongodb:27017"
      - "--collect-all"
    ports:
      - "9216:9216"
    depends_on:
      mongodb:
        condition: service_healthy

  prometheus:
    image: prom/prometheus:latest
    container_name: lab-prometheus
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: lab-grafana
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin
    depends_on:
      - prometheus

volumes:
  pgdata:
  pglogs:
  mongodata:
```

Os healthchecks em `postgres`/`mongodb`, combinados com `depends_on: condition: service_healthy` nos exporters, garantem que cada exporter só tenta ligar-se depois de a base de dados estar mesmo pronta a aceitar ligações — não só depois do container ter arrancado.

### `prometheus/prometheus.yml`

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "postgres"
    static_configs:
      - targets: ["postgres-exporter:9187"]

  - job_name: "mongodb"
    static_configs:
      - targets: ["mongodb-exporter:9216"]

  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
```

### Arrancar e validar

```powershell
docker compose up -d
docker compose ps
```

Validações: `http://localhost:9090/targets` (3 targets UP), `http://localhost:9187/metrics`, `http://localhost:9216/metrics`, `http://localhost:3000` (Grafana, admin/admin).

✅ **Checkpoint:** Prometheus a fazer scrape das duas bases de dados.

---

## Fase 2 — Scripts de carga (Bash + PowerShell)

**Objetivo:** gerar atividade realista nas bases de dados para ter dados para monitorizar.

### Schema (SQL)

```powershell
docker cp sql/schema.sql lab-postgres:/tmp/schema.sql
docker exec -it lab-postgres psql -U admin -d labdb -f /tmp/schema.sql
```

`sql/schema.sql`:
```sql
CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    amount      NUMERIC(10,2),
    status      VARCHAR(20) DEFAULT 'pending',
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);

INSERT INTO orders (customer_id, amount, status)
VALUES (1, 10.50, 'paid'), (2, 99.99, 'pending'), (3, 5.00, 'cancelled');
```

### Scripts de carga

`scripts/load-postgres.sh` gera INSERTs contínuos na tabela `orders`, com uma agregação (`GROUP BY status`) a cada 10 iterações e um `UPDATE` em lote a cada 50. `scripts/load-mongo.sh` insere documentos `events` aleatórios, com um pipeline de agregação ocasional (`$match` → `$group` → `$sort`) e um `find` com filtro/sort. Ambos correm em Git Bash:

```bash
cd db-health-monitor
chmod +x scripts/load-postgres.sh scripts/load-mongo.sh
./scripts/load-postgres.sh
./scripts/load-mongo.sh
```

### `scripts/collect-metrics.ps1`

Consulta a API do Prometheus e produz um mini relatório de saúde:

```powershell
$prom = "http://localhost:9090/api/v1/query"

function Get-PromValue($query) {
    $r = Invoke-RestMethod -Uri $prom -Method Get -Body @{ query = $query }
    if ($r.data.result.Count -gt 0) {
        return [math]::Round([double]$r.data.result[0].value[1], 2)
    }
    return "n/a"
}

Write-Host "=== Relatorio de saude das BDs $(Get-Date -Format 'HH:mm:ss') ===" -ForegroundColor Cyan

$pgConns    = Get-PromValue "pg_stat_database_numbackends{datname='labdb'}"
$pgCommit   = Get-PromValue "rate(pg_stat_database_xact_commit{datname='labdb'}[1m])"
$mongoOps   = Get-PromValue "sum(rate(mongodb_ss_opcounters[1m]))"
$mongoConns = Get-PromValue "mongodb_ss_connections{conn_type='current'}"

Write-Host "PostgreSQL - ligacoes ativas : $pgConns"
Write-Host "PostgreSQL - commits/s       : $pgCommit"
Write-Host "MongoDB    - operacoes/s     : $mongoOps"
Write-Host "MongoDB    - ligacoes atuais : $mongoConns"

if ($pgConns -ne "n/a" -and [double]$pgConns -gt 40) {
    Write-Warning "Numero de ligacoes elevado!"
}
```

✅ **Checkpoint:** `rate(pg_stat_database_xact_commit{datname="labdb"}[1m])` a subir no Prometheus, com os dois load scripts a correr.

---

## Fase 3 — Dashboards e alertas no Grafana

**Objetivo:** visualizar tudo e criar um alerta testado.

### Data source e dashboards da comunidade

1. Grafana → **Connections → Data sources → Add data source → Prometheus**, URL `http://prometheus:9090` → **Save & test**
2. **Dashboards → New → Import**, IDs **9628** (PostgreSQL) e **2583** (MongoDB)

### Dashboard próprio "DB Health Overview"

7 painéis, construídos manualmente com PromQL:

| Painel | Tipo | Query |
|---|---|---|
| Ligações ativas (PG) | Stat | `pg_stat_database_numbackends{datname="labdb"}` |
| Commits/s (PG) | Time series | `rate(pg_stat_database_xact_commit{datname="labdb"}[1m])` |
| Cache hit ratio (PG) | Gauge | `pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read)` |
| Operações/s (Mongo) | Time series | `sum by (type) (rate(mongodb_ss_opcounters[1m]))` |
| Ligações (Mongo) | Stat | `mongodb_ss_connections{conn_type="current"}` |
| Tamanho da BD (PG) | Time series | `pg_database_size_bytes{datname="labdb"}` |
| Queries lentas (Fase 4) | Logs | data source Elasticsearch, `service.name:postgresql AND message:*duration*` |

Thresholds do painel de ligações (20/40) alinhados com o limiar do alerta, para coerência visual.

### Alerta

- Nome: `PG - Ligacoes elevadas`
- Query (modo Instant): `pg_stat_database_numbackends{datname="labdb"}`, condição `IS ABOVE 40`
- Folder `db-lab`, evaluation group `db-alerts` (1 min), pending period 2 min
- Label `severity=warning`

Ciclo Normal → Pending → Firing → Normal testado com uma tempestade de 50 ligações penduradas.

### Exportar o dashboard

Dashboard → Share → Export as JSON → guardado em `grafana/dashboards/db-health-overview.json`, versionado no repositório.

✅ **Checkpoint:** dashboard a mexer em tempo real com os load scripts ativos; alerta testado de ponta a ponta.

---

## Fase 4 — Log aggregation com Elasticsearch + Filebeat

**Objetivo:** centralizar os logs do PostgreSQL e de todos os containers, pesquisáveis e correlacionáveis com as métricas.

### Serviços adicionados ao `docker-compose.yml`

```yaml
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.13.4
    container_name: lab-elasticsearch
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    ports:
      - "9200:9200"
    volumes:
      - esdata:/usr/share/elasticsearch/data
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_cluster/health | grep -q '\"status\":\"\\(green\\|yellow\\)\"'"]
      interval: 15s
      timeout: 10s
      retries: 10

  kibana:
    image: docker.elastic.co/kibana/kibana:8.13.4
    container_name: lab-kibana
    environment:
      - ELASTICSEARCH_HOSTS=http://elasticsearch:9200
    ports:
      - "5601:5601"
    depends_on:
      elasticsearch:
        condition: service_healthy

  filebeat:
    image: docker.elastic.co/beats/filebeat:8.13.4
    container_name: lab-filebeat
    user: root
    command: ["-e", "--strict.perms=false"]
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - pglogs:/var/log/postgresql:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      elasticsearch:
        condition: service_healthy
```

(mais `esdata:` na secção `volumes:`)

`user: root` e `--strict.perms=false` são necessários para o Filebeat conseguir ler o `filebeat.yml` montado a partir do Windows (bind mounts não preservam ownership Unix); `-e` garante que os logs do próprio Filebeat vão para stdout (visíveis com `docker compose logs filebeat`).

### `filebeat/filebeat.yml`

```yaml
filebeat.inputs:

  - type: filestream
    id: postgres-logs
    paths:
      - /var/log/postgresql/*.log
    fields:
      service.name: postgresql
    fields_under_root: true
    parsers:
      - multiline:
          type: pattern
          pattern: '^\d{4}-\d{2}-\d{2}'
          negate: true
          match: after

  - type: container
    paths:
      - /var/lib/docker/containers/*/*.log
    fields:
      service.name: docker
    fields_under_root: true

output.elasticsearch:
  hosts: ["http://elasticsearch:9200"]
  index: "db-logs-%{+yyyy.MM.dd}"

setup.template.name: "db-logs"
setup.template.pattern: "db-logs-*"
setup.ilm.enabled: false

logging.level: info
```

O campo personalizado chama-se `service.name` (não `service`) para se alinhar com o esquema ECS do Elasticsearch, onde `service` é reservado como objeto. Os índices resultantes são geridos como data streams (`.ds-db-logs-YYYY.MM.DD-...`), mas o padrão de pesquisa `db-logs-*` continua a apanhá-los normalmente.

### Validar

```powershell
curl.exe -s "http://localhost:9200/_cat/indices/db-logs-*?v"
```

No Kibana: **Stack Management → Data Views**, criar `db-logs` sobre o padrão `db-logs-*`. No Discover, pesquisar `service.name : "postgresql" and message : *duration*` para encontrar as queries lentas.

### Painel de logs no Grafana

1. **Connections → Data sources → Add data source → Elasticsearch**, URL `http://elasticsearch:9200`, index `db-logs-*`, time field `@timestamp`
2. Na secção **Logs** do data source, definir **Message field name = `message`** (necessário para o painel mostrar o texto do log em vez do `_id` do documento)
3. No dashboard, painel tipo **Logs**, query Lucene `service.name:postgresql AND message:*duration*`

✅ **Checkpoint:** queries lentas pesquisáveis no Kibana e visíveis no painel de logs do dashboard, correlacionadas no tempo com os gráficos de métricas.

---

## Fase 5 — APM com Application Insights

**Objetivo:** ter tracing de uma aplicação real que fala com as duas bases de dados, fechando o terceiro pilar da observabilidade.

### Conta Azure e recurso Application Insights

1. https://azure.microsoft.com/free → criar conta (free tier de ingestão, 5 GB/mês, permanente)
2. Portal Azure → **Application Insights → + Create**, Resource Group novo, região disponível para a subscrição (algumas regiões podem recusar novas contas — escolher outra se acontecer)
3. Copiar a **Connection String** do Overview do recurso — tratar como segredo, nunca commitar

### `api/requirements.txt`

```
flask==3.0.3
psycopg2-binary==2.9.9
pymongo==4.8.0
azure-monitor-opentelemetry==1.8.9
opentelemetry-instrumentation-pymongo==0.64b0
setuptools<81
```

`psycopg2-binary` evita precisar de compilador C no Windows; `setuptools<81` mantém disponível o `pkg_resources`, ainda usado internamente pela distro Azure; `opentelemetry-instrumentation-pymongo` é instalado à parte porque não vem incluído por omissão com a distro.

### `api/app.py`

```python
import os
import random

from flask import Flask, jsonify
import psycopg2
from pymongo import MongoClient

from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.pymongo import PymongoInstrumentor

configure_azure_monitor()  # le APPLICATIONINSIGHTS_CONNECTION_STRING do ambiente
PymongoInstrumentor().instrument()

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

PG_DSN = os.environ.get("PG_DSN", "postgresql://admin:admin123@localhost:5432/labdb")
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://localhost:27017")
mongo = MongoClient(MONGO_URI)


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/orders/summary")
def orders_summary():
    conn = psycopg2.connect(PG_DSN)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT status, COUNT(*), ROUND(AVG(amount), 2) FROM orders GROUP BY status;"
            )
            rows = cur.fetchall()
    finally:
        conn.close()
    return jsonify({s: {"count": c, "avg": float(a)} for s, c, a in rows})


@app.route("/events/summary")
def events_summary():
    pipeline = [
        {"$group": {"_id": "$type", "total": {"$sum": 1}}},
        {"$sort": {"total": -1}},
    ]
    return jsonify(list(mongo.labdb.events.aggregate(pipeline)))


@app.route("/slow")
def slow():
    delay = round(random.uniform(1.5, 3.0), 2)
    conn = psycopg2.connect(PG_DSN)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_sleep(%s);", (delay,))
    finally:
        conn.close()
    return jsonify({"ok": True, "delayed_seconds": delay})


@app.route("/error")
def error():
    if random.random() < 0.5:
        raise ValueError("Falha simulada para demonstrar tracking de excecoes")
    return jsonify({"ok": True})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)
```

`configure_azure_monitor()` ativa a auto-instrumentação de base (psycopg2/dbapi, exceções, logging); `FlaskInstrumentor` e `PymongoInstrumentor` são chamados explicitamente para garantir que os spans de **Request** (Flask) e **Dependency** (MongoDB) ficam mesmo ativos, independentemente da descoberta automática da distro.

### Arrancar

```powershell
cd api
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = "<a-tua-connection-string>"
python app.py
```

### Gerar tráfego

`scripts/traffic.ps1` bate nos endpoints com uma distribuição ponderada (5 `/orders/summary` : 4 `/events/summary` : 1 `/slow` : 1 `/error`), para que o Application Map e os percentis se pareçam com produção a sério:

```powershell
.\scripts\traffic.ps1
```

### Explorar no Application Insights

- **Application map** — a app no centro, com PostgreSQL e MongoDB como dependências
- **Performance** — `GET /slow` destacado (~2-3s); drill into samples mostra a query SQL a ocupar quase todo o tempo do request
- **Failures** — a `ValueError` do `/error` com stack trace completo
- **Live metrics** — telemetria em tempo real (pode demorar um pouco a ligar-se, canal separado do resto da ingestão)

✅ **Checkpoint:** Application Map completo; `/slow` identificado como lento pela dependência PostgreSQL; exceções capturadas.

---

## Fase 6 — Cenário de demonstração: injetar uma falha

**Objetivo:** juntar as 5 fases numa história única — alerta no Grafana, log no Kibana, trace no Application Insights, até à resolução.

### `scripts/chaos.ps1` / `scripts/chaos.sh`

Cinco cenários:

```powershell
.\scripts\chaos.ps1 connections   # 50 ligacoes penduradas (pg_sleep 300s) -> alerta no Grafana
.\scripts\chaos.ps1 slowquery     # CROSS JOIN pesado -> log no Kibana + trace no App Insights
.\scripts\chaos.ps1 lock          # lock ACCESS EXCLUSIVE 90s na tabela orders -> commits/s em flatline
.\scripts\chaos.ps1 status        # diagnostico via pg_stat_activity
.\scripts\chaos.ps1 resolve       # pg_terminate_backend nas sessoes de chaos
```

`connections` ocupa ligações sem gerar carga real de CPU (mostra "muitas ligações ≠ muita carga"); `slowquery` explora o produto cartesiano de `orders` consigo própria; `lock` bloqueia toda a tabela com `ACCESS EXCLUSIVE`, travando os INSERTs do load script; `resolve` termina só as sessões de chaos (`pid <> pg_backend_pid()`); `status` é a query de diagnóstico que um DBA correria num incidente real.

### Guião da demo

O guião completo, minuto a minuto, com as falas sugeridas e os 8 screenshots recomendados, está em [fase6-guiao-demo.md](fase6-guiao-demo.md). Resumo dos 5 atos:

1. **Estado saudável** — dashboard verde, Application Map com as duas dependências
2. **Tempestade de ligações** — Stat vermelho imediato, alerta Normal → Pending → Firing → Normal
3. **Query lenta** — entrada no Kibana com `duration`, trace no App Insights a mostrar a dependência SQL
4. **Lock de tabela** — commits/s em flatline, recuperação em V após o `resolve`
5. **Fecho** — três incidentes, três padrões de deteção: alerta proativo, pesquisa de logs, correlação métrica-diagnóstico

✅ **Checkpoint:** ciclo completo detetado nas três camadas e revertido com `resolve`; screenshots capturados para o portfólio.

---

## Ordem de execução

| Fase | Skills demonstradas |
|---|---|
| 1. Infraestrutura | Docker Compose, Prometheus, healthchecks |
| 2. Scripts de carga | Bash, PowerShell, SQL, NoSQL |
| 3. Grafana | PromQL, dashboards, alerting |
| 4. Logs | Elasticsearch, Filebeat, Kibana, ECS |
| 5. APM | OpenTelemetry, Application Insights, Python |
| 6. Demo de falha | Troubleshooting ponta a ponta, chaos engineering |

## Notas finais

- Cada fase tem `docs/faseN-conceitos.md` e `docs/faseN-resumo.md` no repositório, com commit próprio.
- Screenshots da demo de incidentes em `docs/screenshots/`.
- O Elasticsearch é o serviço mais pesado (~700 MB-1 GB); no Windows requer `vm.max_map_count=262144` via WSL2 (`wsl -d docker-desktop sh -c "sysctl -w vm.max_map_count=262144"`), que se perde a cada reinício do Docker Desktop.
- Os nomes dos containers são fixos via `container_name` (`lab-postgres`, `lab-mongodb`, etc.), independentes do nome da pasta do projeto.
