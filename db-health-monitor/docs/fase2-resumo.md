# Fase 2 — Scripts de carga (Bash + PowerShell) — resumo detalhado

**Objetivo da fase:** ter as duas bases de dados a receber carga contínua (INSERTs, SELECTs, agregações), gerada por scripts em Bash e PowerShell, e conseguir ver essa atividade a mexer nas métricas do Prometheus/Grafana.

**Pré-requisito:** Fase 1 concluída — ver [fase1-resumo.md](fase1-resumo.md).

Este documento regista o que foi feito, os comandos exatos, os problemas reais encontrados durante a execução (e como foram resolvidos) e os resultados obtidos.

---

## Passo 0 — Preparar o ambiente para scripts

- PowerShell confirmado (≥ 5.1).
- Execution policy: adiado o ajuste inicial de `.wslconfig`/RAM (já resolvido na Fase 1); execution policy tratada à medida que apareceu (ver Passo 4).
- Git Bash confirmado disponível e usado para os scripts `.sh`.
- `.gitattributes` (para CRLF/LF automático) **não foi criado** — decisão consciente de avançar sem essa rede de segurança e resolver os problemas de line endings caso a caso.
- Pasta `sql/` criada dentro de `db-health-monitor/`.

## Passo 1 — Schema no PostgreSQL

**`db-health-monitor/sql/schema.sql`:**
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

### Problema encontrado e resolução

A primeira tentativa de aplicar o schema via pipe do PowerShell **falhou silenciosamente**:
```powershell
Get-Content .\sql\schema.sql | docker exec -i lab-postgres psql -U admin -d labdb
```
Não produziu nenhuma saída (nem `CREATE TABLE`, nem erro) — o conteúdo não chegou ao `psql` dentro do container. É um problema conhecido de buffering do `docker exec -i` quando alimentado por pipeline do PowerShell no Windows.

**Solução aplicada** — copiar o ficheiro para dentro do container e executá-lo lá com `-f`:
```powershell
docker cp .\sql\schema.sql lab-postgres:/tmp/schema.sql
docker exec -it lab-postgres psql -U admin -d labdb -f /tmp/schema.sql
```
Resultado: `CREATE TABLE`, `CREATE INDEX`, `INSERT 0 3` ✅

Confirmação:
```powershell
docker exec -it lab-postgres psql -U admin -d labdb -c "SELECT COUNT(*) FROM orders;"
```
→ `3`

**Lição para o resto do projeto:** sempre que for preciso passar conteúdo de um ficheiro para dentro de um container via stdin no PowerShell, preferir `docker cp` + execução do ficheiro dentro do container, em vez de pipe direto.

## Passo 2 — Script de carga do PostgreSQL (Bash)

`db-health-monitor/scripts/load-postgres.sh` — gera carga contínua: um `INSERT` por iteração, uma agregação (`GROUP BY status`) a cada 10 iterações, um `UPDATE` em lote a cada 50 iterações.

### Problema encontrado e resolução

Tentativa inicial de correr `chmod +x scripts/load-postgres.sh` **dentro do PowerShell** — `chmod` não existe nesse shell (é um comando Unix). Confusão entre terminais (PowerShell vs. Git Bash) foi o problema recorrente desta fase.

**Solução:** usar consistentemente o **Git Bash** para tudo o que é `.sh`:
```bash
cd /c/Users/runot/Documents/GitHub/DB-Health-Monitoring-Platform/db-health-monitor
chmod +x scripts/load-postgres.sh
./scripts/load-postgres.sh
```
Deixado a correr numa janela dedicada.

## Passo 3 — Script de carga do MongoDB (Bash)

`db-health-monitor/scripts/load-mongo.sh` — insere um documento `events` aleatório por iteração; ~10% das vezes corre um pipeline de agregação (`$match` → `$group` → `$sort`); ~5% das vezes faz um `find` com filtro + sort.

Executado da mesma forma no Git Bash, em janela própria, em paralelo com o `load-postgres.sh`.

Confirmação de crescimento de dados:
```powershell
docker exec -it lab-mongodb mongosh --quiet --eval "db.getSiblingDB('labdb').events.countDocuments()"
```

### Problema encontrado — nomes de métricas do `mongodb-exporter` diferentes do esperado

Ao tentar visualizar a carga do Mongo no Grafana com a query do guia original (`sum(rate(mongodb_op_counters_total[1m]))`), o painel devolveu **"No data"**.

**Investigação:**
1. Confirmado que `lab-mongo-exporter` estava `Up` e `mongodb_up 1` (o exporter falava com a BD).
2. Ao listar as métricas expostas em `http://localhost:9216/metrics`, `mongodb_op_counters_total` **não existe** nesta versão (`percona/mongodb_exporter:0.40`) — só apareciam inicialmente métricas `mongodb_top_*` (do collector "topmetrics").
3. Testado `mongodb_ss_opcounters` (prefixo `_ss_` = serverStatus, nomenclatura das versões mais recentes do exporter) — **este sim devolveu dados** (confirmado no `collect-metrics.ps1`: `MDB - operacoes/s (1m) : 14,2`).
4. `mongodb_ss_connections{state="current"}` continuou "sem dados" — o label correto para esta métrica ainda não foi confirmado (**pendente**, ver secção abaixo).

**Conclusão:** o guia original assumia nomes de métrica de uma versão diferente do `mongodb_exporter`. A versão `0.40` usa o prefixo `mongodb_ss_*` para métricas do `serverStatus` (opcounters confirmado), mas o label exato de `connections` fica pendente de confirmação.

## Passo 4 — Relatório de saúde em PowerShell

`db-health-monitor/scripts/collect-metrics.ps1` — consulta a API do Prometheus (`Invoke-RestMethod` contra `/api/v1/query`) e produz um relatório com thresholds simples (alerta se ligações PG > 40, aviso se cache hit ratio < 0.90).

Queries do MongoDB **já atualizadas** no script para refletir os nomes reais descobertos no Passo 3 (`mongodb_ss_connections`, `mongodb_ss_opcounters`) em vez dos nomes originais do guia.

### Problema encontrado e resolução

Tentativa de correr `.\scripts\collect-metrics.ps1` **dentro do Git Bash** → `bash: .collect-metrics.ps1: command not found` (scripts `.ps1` não correm em Bash).

**Solução:** abrir uma janela de **PowerShell** separada (mantendo o Git Bash a correr os scripts de carga) e executar aí.

Resultado obtido (com os dois scripts de carga a correr):
```
PG  - ligacoes ativas     : 2
PG  - commits/s (1m)      : 4,41
PG  - cache hit ratio     : 1
PG  - tamanho da BD (MB)  : 7,86
MDB - ligacoes atuais     : sem dados       (pendente — ver Passo 3)
MDB - operacoes/s (1m)    : 14,2
```

## Passo 5 — Validar a carga no Prometheus

Confirmado em http://localhost:9090/graph, com os dois scripts de carga a correr:

| Query | Resultado |
|---|---|
| `rate(pg_stat_database_xact_commit{datname="labdb"}[1m])` | > 0, estável |
| `rate(pg_stat_database_tup_inserted{datname="labdb"}[1m])` | ≈ 1/intervalo |
| `sum(rate(mongodb_ss_opcounters[1m]))` | > 0 (query corrigida — ver Passo 3) |
| `pg_stat_database_numbackends{datname="labdb"}` | pequenas oscilações |

Confirmado também que é possível observar esta carga diretamente no **Grafana → Explore** (data source Prometheus já configurado na Fase 1), sem precisar de esperar pelos dashboards permanentes da Fase 3.

---

## ✅ Checkpoint final da Fase 2

- [x] `sql/schema.sql` aplicado; `orders` populada e a crescer
- [x] `load-postgres.sh` a correr sem erros, com mensagens periódicas de agregação
- [x] `load-mongo.sh` a correr; `events.countDocuments()` a crescer
- [x] `collect-metrics.ps1` mostra valores reais (PostgreSQL completo; MongoDB opcounters OK)
- [x] As 4 queries de validação mostram linhas > 0 no Prometheus

---

## Pendente / a retomar mais tarde

- **Label correto de `mongodb_ss_connections`** — a query `mongodb_ss_connections{state="current"}` devolve "sem dados"; falta confirmar o nome do label correto para esta versão do exporter (grep a `/metrics` por `mongodb_ss_connections` e ajustar `collect-metrics.ps1` e os futuros dashboards da Fase 3).
- **Flag `--collect-all` do `mongodb-exporter`** — a suspeita é que esta flag pode estar desatualizada/inválida na versão `0.40` do `percona/mongodb_exporter`, e que os collectors ativos podem não corresponder ao que o `docker-compose.yml` da Fase 1 pretendia. Ainda por confirmar via `docker compose logs lab-mongo-exporter` e `--help` do binário; possível ajuste futuro do `command:` do serviço `mongodb-exporter` para flags explícitas (`--collector.diagnosticdata`, `--collector.topmetrics`, etc.).
- `.wslconfig` / RAM do WSL2 — continua adiado desde a Fase 1, relevante antes da Fase 4 (Elasticsearch).

**Próximo passo:** Fase 3 — dashboards e alertas no Grafana.
