# Fase 1 — Infraestrutura base com Docker Compose (resumo detalhado)

**Objetivo da fase:** ter 6 containers a correr — PostgreSQL, MongoDB, os dois exporters, Prometheus e Grafana — com o Prometheus a recolher métricas das duas bases de dados e o Grafana acessível no browser.

Este documento regista, passo a passo, o que foi feito, os comandos exatos executados (PowerShell, no Windows), o resultado esperado/obtido e as explicações de cada configuração.

---

## Passo 0 — Pré-requisitos e verificação do ambiente

### 0.1 Verificar o Docker

```powershell
docker --version
docker compose version
```

Resultado esperado (versões podem variar):
```
Docker version 26.x.x
Docker Compose version v2.x.x
```

> Se `docker compose` (sem hífen) não funcionar mas `docker-compose` sim, é a versão v1 — funciona da mesma forma, mas substitui `docker compose` por `docker-compose` em todos os comandos.

### 0.2 Verificar que o daemon está a correr

```powershell
docker ps
```

- Devolveu uma tabela (mesmo vazia) → OK, o Docker Desktop está a correr.
- `Cannot connect to the Docker daemon` → é preciso abrir o Docker Desktop primeiro.

### 0.3 Verificar portas livres

O projeto usa as portas **5432** (PostgreSQL), **27017** (MongoDB), **9187** (postgres-exporter), **9216** (mongodb-exporter), **9090** (Prometheus) e **3000** (Grafana).

```powershell
Get-NetTCPConnection -LocalPort 5432,27017,9090,3000,9187,9216 -ErrorAction SilentlyContinue
```

- Sem resultado → todas as portas estavam livres. Confirmado.
- Caso alguma porta estivesse ocupada, a alternativa seria parar o serviço em conflito ou mudar o lado esquerdo do mapeamento de porta no `docker-compose.yml` (ex.: `"5433:5432"`).

### 0.4 Verificar recursos do Docker

Confirmar pelo menos 4 GB de RAM alocados ao Docker (Docker Desktop → Settings → Resources, ou via `.wslconfig` se o backend for WSL2).

> **Estado:** adiado — não foi necessário configurar para esta fase (consumo é baixo, ~1 GB). **Fica pendente para retomar antes da Fase 4**, quando o Elasticsearch entrar em cena e o consumo de RAM aumentar.

---

## Passo 1 — Estrutura do projeto

```powershell
mkdir -p db-health-monitor/prometheus
cd db-health-monitor
git init
```

Estrutura final do repositório após o scaffold:

```
db-health-monitor/
├── docker-compose.yml
├── prometheus/
│   └── prometheus.yml
├── filebeat/
│   └── filebeat.yml
├── sql/
│   └── schema.sql            (a criar na Fase 2)
├── scripts/
│   ├── load-postgres.sh
│   ├── load-mongo.sh
│   ├── chaos.sh
│   └── collect-metrics.ps1
├── api/
│   └── app.py
└── README.md
```

Verificação feita com:
```powershell
Get-ChildItem -Recurse db-health-monitor -Name
```

---

## Passo 2 — `docker-compose.yml`

Ficheiro criado em `db-health-monitor/docker-compose.yml` com 6 serviços. Conteúdo completo:

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

### Explicação linha a linha

**`postgres`**
- `image: postgres:16` — versão fixa, evita surpresas de `latest`.
- `container_name: lab-postgres` — nome fixo para os comandos `docker exec` serem previsíveis.
- `environment` — cria o utilizador `admin`, password `admin123`, base `labdb` **apenas no primeiro arranque** (mudar depois não tem efeito sem apagar o volume `pgdata`).
- `ports: "5432:5432"` — mapeamento porta da máquina : porta do container.
- `volumes` — `pgdata` persiste os dados entre reinícios; `pglogs` guarda os logs (usados pelo Filebeat na Fase 4).
- `command` — flags extra no arranque:
  - `logging_collector=on` — escreve logs em ficheiro em vez de só stdout.
  - `log_directory=/var/log/postgresql` — onde escreve.
  - `log_min_duration_statement=1000` — regista toda a query com duração > 1000 ms (a base da deteção de queries lentas na Fase 4).
  - `log_statement=none` — não regista todas as queries, só as lentas, para não inundar os logs.
- `healthcheck` — considera o container saudável quando `pg_isready` responde; os exporters só arrancam depois (`depends_on: condition: service_healthy`), evitando erros de "connection refused" no arranque.

**`mongodb`** — mesma lógica: versão fixa (`mongo:7`), volume de dados (`mongodata`), healthcheck via `mongosh ... ping`.

**`postgres-exporter`**
- Traduz as estatísticas internas (`pg_stat_*`) do PostgreSQL para o formato Prometheus.
- `DATA_SOURCE_NAME` usa o hostname `postgres` (nome do serviço no compose, resolvido pela rede interna) — **nunca `localhost`** aqui, porque dentro do container `localhost` é o próprio container.
- `sslmode=disable` porque é um lab local sem TLS.

**`mongodb-exporter`**
- Imagem fixa `percona/mongodb_exporter:0.40` porque a flag `--collect-all` mudou entre versões.
- `--collect-all` ativa todos os grupos de métricas (opcounters, connections, etc.).

**`prometheus`** — monta `prometheus.yml` local; alterações ao ficheiro exigem `docker compose restart prometheus`.

**`grafana`** — `GF_SECURITY_ADMIN_PASSWORD: admin` define a password de admin já no arranque (sem isto, a password inicial também seria `admin`, mas obrigaria a trocar no primeiro login).

**`volumes:`** — volumes nomeados, guardados pelo Docker fora dos containers; `docker compose down` **não** os apaga (só `down -v` apaga).

> Nota: não foi incluída a linha `version: "3.8"` do formato antigo do compose — o Compose v2 ignora-a (e avisa), por isso o ficheiro começa direto em `services:`.

---

## Passo 3 — `prometheus/prometheus.yml`

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

### Explicação

- `scrape_interval: 15s` — o Prometheus recolhe métricas a cada 15 segundos (bom equilíbrio entre detalhe e volume de dados para um lab).
- Cada `job_name` é uma "fonte" de métricas; o nome fica disponível como label `job` em todas as métricas (útil em queries, ex.: `up{job="postgres"}`).
- Os `targets` usam os **nomes dos serviços do compose** e a porta interna do container (não a porta mapeada na máquina host).
- `localhost:9090` está correto no job `prometheus`, porque é o próprio Prometheus a fazer scrape de si mesmo, dentro do seu container.

Validação de sintaxe feita com:
```powershell
docker run --rm -v ${PWD}/prometheus/prometheus.yml:/p.yml --entrypoint promtool prom/prometheus:latest check config /p.yml
```
Resultado: `SUCCESS`.

---

## Passo 4 — Arrancar a stack

```powershell
cd db-health-monitor
docker compose up -d
```

O Docker descarregou as 6 imagens (~1,5 GB na primeira vez), criou a rede interna, os volumes nomeados (`pgdata`, `pglogs`, `mongodata`), e arrancou os containers pela ordem das dependências (`depends_on` + `service_healthy`).

Verificação do estado:
```powershell
docker compose ps
```

Resultado obtido:
```
NAME                STATUS
lab-postgres        Up (healthy)
lab-mongodb         Up (healthy)
lab-pg-exporter     Up
lab-mongo-exporter  Up
lab-prometheus      Up
lab-grafana         Up
```

Os healthchecks do Postgres/Mongo demoraram ~30s a passar de `health: starting` para `healthy` (esperado).

Comandos de apoio usados/disponíveis para inspecionar logs de arranque:
```powershell
docker compose logs -f postgres
docker compose logs --tail=50 prometheus
```

---

## Passo 5 — Validação componente a componente

### 5.1 PostgreSQL responde?

```powershell
docker exec -it lab-postgres psql -U admin -d labdb -c "SELECT version();"
```
Resultado: `PostgreSQL 16.x ...` ✅

Confirmação do logging ativo:
```powershell
docker exec -it lab-postgres psql -U admin -d labdb -c "SHOW log_min_duration_statement;"
```
Resultado: `1s` ✅

### 5.2 MongoDB responde?

```powershell
docker exec -it lab-mongodb mongosh --quiet --eval "db.adminCommand('ping')"
```
Resultado: `{ ok: 1 }` ✅

### 5.3 postgres-exporter expõe métricas?

```powershell
(Invoke-WebRequest -Uri http://localhost:9187/metrics -UseBasicParsing).Content | Select-String pg_up
```
Resultado: `pg_up 1` ✅ (1 = exporter conseguiu falar com o PostgreSQL; `pg_up 0` indicaria falha de ligação/credenciais no `DATA_SOURCE_NAME`)

### 5.4 mongodb-exporter expõe métricas?

```powershell
(Invoke-WebRequest -Uri http://localhost:9216/metrics -UseBasicParsing).Content | Select-String mongodb_up | Select-Object -First 1
```
Resultado: `mongodb_up 1` ✅

### 5.5 Prometheus vê os targets?

Verificado em: **http://localhost:9090/targets**

3 targets, todos **UP**:
- `postgres (1/1 up)`
- `mongodb (1/1 up)`
- `prometheus (1/1 up)`

### 5.6 As métricas chegam mesmo?

Queries corridas em **http://localhost:9090/graph**:

| Query | Resultado obtido |
|---|---|
| `up` | 3 séries, todas com valor `1` |
| `pg_stat_database_numbackends{datname="labdb"}` | Nº de ligações ao PostgreSQL (≥ 1) |
| `mongodb_connections{state="current"}` | Ligações atuais ao MongoDB |

Cadeia BD → exporter → Prometheus confirmada como completa.

### 5.7 O Grafana abre?

- URL: **http://localhost:3000**
- Login: `admin` / `admin`
- Pedido de troca de password: "Skip" (aceitável num lab local)

### 5.8 Ligar o Grafana ao Prometheus

1. Menu lateral → **Connections → Data sources → Add data source**
2. Escolhida a opção **Prometheus**
3. Campo **Prometheus server URL**: `http://prometheus:9090`
   > ⚠️ Não usar `localhost:9090` aqui — o Grafana corre dentro do seu próprio container, e o `localhost` desse container não é a máquina host. Tem de ser o nome do serviço na rede do compose.
4. **Save & test** → mensagem verde: "Successfully queried the Prometheus API" ✅

### 5.9 Primeiro painel de teste (opcional, feito)

1. Dashboards → New → New dashboard → Add visualization
2. Data source: Prometheus
3. Query: `pg_stat_database_numbackends{datname="labdb"}`
4. Painel guardado como dashboard **"DB Health Overview"** — base para expandir na Fase 3.

---

## ✅ Checkpoint final da Fase 1

- [x] `docker compose ps` mostra os 6 containers `Up` (postgres e mongodb `healthy`)
- [x] `pg_up 1` no endpoint `:9187` e `mongodb_up 1` no `:9216`
- [x] Os 3 targets **UP** em http://localhost:9090/targets
- [x] A query `up` no Prometheus devolve 3 séries com valor 1
- [x] Grafana acessível com o data source Prometheus a validar com sucesso

---

## Comandos úteis para o dia a dia (referência)

```powershell
docker compose ps                      # estado de tudo
docker compose logs -f <serviço>       # logs em tempo real
docker compose restart <serviço>       # reiniciar um serviço
docker compose down                    # parar tudo (mantém dados)
docker compose down -v                 # parar tudo e apagar dados (⚠️ destrutivo)
docker stats                           # CPU/RAM por container
```

## Troubleshooting (não foi necessário nesta execução, mantido como referência)

- **"port is already allocated"** — outra aplicação usa a porta; parar o serviço em conflito ou mudar o mapeamento no compose.
- **`lab-postgres` fica em Restarting** — normalmente um volume `pgdata` antigo com credenciais diferentes; `docker compose down -v && docker compose up -d` (apaga os dados do lab).
- **`pg_up 0` no exporter** — exporter arrancou antes da BD estar pronta, ou credenciais erradas; confirmar `DATA_SOURCE_NAME` e `docker compose restart postgres-exporter`.
- **Target DOWN com "no such host"** — nome no `prometheus.yml` não corresponde ao nome do serviço no compose.
- **Prometheus não arranca (erro de parsing YAML)** — indentação errada; validar com `promtool` e `docker compose restart prometheus`.
- **mongodb-exporter sem métricas úteis** — confirmar imagem `percona/mongodb_exporter:0.40` e flag `--collect-all` presente.
- **Alteração ao `prometheus.yml` sem efeito** — o Prometheus só lê a config no arranque: `docker compose restart prometheus`.

---

## Pendente / a retomar mais tarde

- Configurar `.wslconfig` (`memory=4GB`, `processors=2`) com RAM alocada ao WSL2 — necessário antes da Fase 4 (Elasticsearch aumenta bastante o consumo de memória).

**Próximo passo:** Fase 2 — scripts de carga em Bash e PowerShell, para dar vida aos dashboards.
