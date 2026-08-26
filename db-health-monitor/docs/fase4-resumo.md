# Fase 4 — Log aggregation com Elasticsearch + Filebeat — resumo detalhado

**Objetivo da fase:** ter os logs do PostgreSQL (incluindo as queries lentas >1s) e dos containers a fluir automaticamente para o Elasticsearch, pesquisáveis no Kibana, e um painel de logs no dashboard do Grafana — métricas e logs lado a lado.

**Pré-requisito:** Fases 1–3 concluídas — ver [fase3-resumo.md](fase3-resumo.md).

Este documento regista o que foi feito, os comandos exatos, os problemas reais encontrados durante a execução (e como foram resolvidos) e os resultados obtidos.

---

## Passo 0 — Preparação do ambiente

- RAM confirmada: `docker system info` → **15 GB** disponíveis (bem acima do mínimo de 4 GB recomendado).
- `vm.max_map_count` ajustado preventivamente:
  ```powershell
  wsl -d docker-desktop sh -c "sysctl -w vm.max_map_count=262144"
  ```
  → `vm.max_map_count = 262144` confirmado.
- Pasta `filebeat/` criada **antes** do `docker compose up`, replicando a lição da Fase 1 (evitar que o Docker crie uma pasta-fantasma em vez do ficheiro de config).

## Passo 1 — `filebeat/filebeat.yml`

Ficheiro criado com a estrutura do guia — dois inputs (`filestream` para os logs do PostgreSQL, `container` para stdout/stderr de todos os containers), output para Elasticsearch com índice diário, `setup.ilm.enabled: false`.

**Desvio consciente do guia, já aplicado na primeira escrita:** os campos `fields: service: postgresql` / `fields: service: docker` do guia original foram escritos como `fields: service.name: postgresql` / `fields: service.name: docker` — ver Passo 3 para a razão (o guia original causaria um erro de mapeamento).

## Passo 2 — Serviços no `docker-compose.yml`

Adicionados os 3 serviços (`elasticsearch`, `kibana`, `filebeat`) e o volume `esdata`, seguindo a configuração do guia, com uma alteração no `command:` do Filebeat — ver Passo 3.3.

## Passo 3 — Arrancar e validar a cadeia

### 3.1–3.2 — Containers e Elasticsearch

`docker compose up -d` → 9 containers Up. `curl.exe -s http://localhost:9200` devolveu 200. `_cluster/health` mostrou `active_primary_shards: 31`, `unassigned_shards: 3` — consistente com status `yellow` esperado em nó único (réplicas sem segundo nó para onde ir).

### 3.3 — Filebeat: dois problemas reais encontrados

**Problema 1 — `docker compose logs filebeat` não mostrava nada.**

Investigação:
```bash
docker logs lab-filebeat --tail 50   # saída vazia
docker inspect lab-filebeat --format='...'   # container a correr normalmente, 0 restarts
docker exec lab-filebeat ps aux   # processo "filebeat --strict.perms=false" ativo
```

**Causa:** o `command: ["--strict.perms=false"]` no `docker-compose.yml` **substitui por completo** o comando por defeito da imagem oficial do Filebeat, que inclui a flag `-e` (log para stderr). Sem essa flag, o Filebeat escreve os seus próprios logs internos para ficheiro dentro do container (`/usr/share/filebeat/logs/*.ndjson`), não para o stdout que o `docker logs`/`docker compose logs` captura.

**Solução:**
```yaml
command: ["-e", "--strict.perms=false"]
```

**Problema 2 — todos os eventos rejeitados; `docs.count: 0` persistente.**

Ao inspecionar os logs internos do Filebeat (`/usr/share/filebeat/logs/*.ndjson`, acedidos com `MSYS_NO_PATHCONV=1 docker exec lab-filebeat ...` para evitar a conversão de paths do Git Bash), encontrou-se um volume anormal de warnings repetidos:
```
"message":"Cannot index event (status=400): dropping event! Enable debug logs to view the event and cause."
```

Ativado temporariamente `logging.level: debug` + `logging.selectors: ["elasticsearch"]` no `filebeat.yml`, recriado o container (`docker compose up -d --force-recreate filebeat`), e localizada a causa exata:
```json
{"type":"document_parsing_exception","reason":"[1:896] object mapping for [service] tried to parse field [service] as object, but found a concrete value"}
```

**Causa raiz:** `service` é um campo reservado do **ECS** (Elastic Common Schema), definido como **objeto** (com subcampos como `service.name`, `service.type`). O `filebeat.yml` tentava escrever `service` como uma string simples (`postgresql` / `docker`), entrando em conflito direto com o mapeamento já registado no Elasticsearch pelo próprio template do Filebeat.

**Solução:** renomear o campo de `service` para `service.name` em ambos os inputs do `filebeat.yml` — alinhado com o ECS, sem conflito.

**Passos de recuperação:**
```powershell
# Apagar os data streams vazios/com mapeamento problemático
curl.exe -s -X DELETE "http://localhost:9200/_data_stream/db-logs-*"

# Recriar o filebeat com a config corrigida
docker compose up -d --force-recreate filebeat
```

**Resultado após a correção** (revertido `logging.level` para `info`):
```
index                                     docs.count
.ds-db-logs-2026.08.25-2026.08.26-000001     611142  (e a crescer)
.ds-db-logs-2026.08.26-2026.08.26-000001      10619
.ds-db-logs-2026.08.24-2026.08.26-000001     312910
```

**Nota:** os nomes dos índices são `.ds-db-logs-YYYY.MM.DD-...-000001` (prefixo `.ds-`, formato de **data stream**), não `db-logs-YYYY.MM.DD` como o guia original assumia — o `setup.ilm.enabled: false` não impediu esta versão do Filebeat/Elasticsearch de usar data streams. Isto não afeta a pesquisa (o index pattern `db-logs-*` continua a corresponder), só a forma como o `_cat/indices` os apresenta.

### 3.4 — Kibana

Abriu sem incidentes em http://localhost:5601.

## Passo 4 — Queries lentas

```powershell
docker exec lab-postgres psql -U admin -d labdb -c "SELECT pg_sleep(1.5);"
docker exec lab-postgres psql -U admin -d labdb -c "SELECT pg_sleep(2.2);"
docker exec lab-postgres psql -U admin -d labdb -c "SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2;"
```

Confirmado no log do PostgreSQL:
```
duration: 1500.371 ms  statement: SELECT pg_sleep(1.5);
duration: 2203.386 ms  statement: SELECT pg_sleep(2.2);
duration: 8148.928 ms  statement: SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2;
```
(e, como bónus histórico, ainda visíveis os `pg_sleep(300)` da tempestade de ligações testada na Fase 3.)

## Passo 5 — Kibana: data view e pesquisas

Data view `db-logs` criado sobre o padrão `db-logs-*`, timestamp `@timestamp`. Pesquisas no Discover adaptadas ao nome de campo corrigido:

| Pesquisa (KQL) | Nota |
|---|---|
| `service.name : "postgresql"` | adaptado de `service : ...` do guia original |
| `service.name : "postgresql" and message : *duration*` | as queries lentas |
| `message : *duration* and message : *CROSS*` | a query lenta do CROSS JOIN |

## Passo 6 — Painel de logs no Grafana

### Problema 1 — URL do data source mal escrito

Primeira tentativa de "Save & test" no data source Elasticsearch falhou com um `Health check failed` que devolvia uma página HTML em vez de JSON — sintoma de o Grafana estar a bater contra o serviço/endereço errado. Causa: erro de escrita no campo URL. Corrigido para `http://elasticsearch:9200`.

### Problema 2 — Painel "Logs" a mostrar `_id` em vez de `message`

Depois de configurado o painel (Metric → Logs, visualização tipo Logs), as linhas mostravam apenas códigos como `9RA1PaABipfffo8vQ9Ff` — o `_id` interno do documento Elasticsearch — em vez do conteúdo do log.

**Causa:** o data source Elasticsearch do Grafana não sabia qual campo usar como "linha de log" (ao contrário do Loki, o Elasticsearch não tem um campo fixo `line`/`message`).

**Solução:** em **Connections → Data sources → Elasticsearch → secção "Logs"**, definido explicitamente **"Message field name" = `message`**. Depois de gravar e voltar ao painel, as linhas passaram a mostrar o conteúdo real do log.

## ✅ Checkpoint final da Fase 4

- [x] 9 containers Up; `lab-elasticsearch` healthy (status yellow, esperado em nó único)
- [x] Data streams `db-logs-*` a crescer (`docs.count` na ordem das centenas de milhares)
- [x] Queries lentas visíveis no log do PostgreSQL (`grep duration`)
- [x] Data view criado no Kibana; pesquisas KQL (adaptadas para `service.name`) devolvem as queries lentas
- [x] Data source Elasticsearch no Grafana a validar (depois de corrigido o URL)
- [x] Painel "PG — Queries lentas" no dashboard, a mostrar o conteúdo real dos logs (depois de configurado o "Message field name")

---

## Pendente / a retomar mais tarde

- **Exportar de novo o JSON do dashboard** — o "DB Health Overview" ganhou um 7º painel (logs) nesta fase; o `grafana/dashboards/db-health-overview.json` versionado na Fase 3 ainda não reflete esta alteração. Repetir o Passo 5 da Fase 3 (Export as JSON) antes de fechar esta fase.
- **Volume dos data streams `db-logs-*`** — o input `container` está a processar o backlog completo dos ficheiros `*-json.log` de todos os containers desde o início do projeto (documentos já na ordem das centenas de milhares, dezenas de MB por dia). Considerar, se o disco começar a apertar, restringir os `paths` do input `container` a menos containers, ou definir uma política de índice para apagar dias antigos (ver secção de troubleshooting do guia: `DELETE /db-logs-*` já usada uma vez durante esta fase para limpar o estado com erro).
- **Nome de índice `db-logs-YYYY.MM.DD` vs. data stream `.ds-db-logs-...`** — confirmar se esta diferença de nomenclatura tem impacto nalgum passo futuro (ex. dashboards Kibana pré-construídos, ILM) antes da Fase 5.

**Próximo passo:** Fase 5 — a mini API instrumentada com Application Insights, que fecha o terceiro pilar da observabilidade (traces).
