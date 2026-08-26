# Relatório de testes ponta a ponta — 2026-08-26

> **Nota:** este teste foi executado por um assistente de IA (Claude, via linha de comandos), não manualmente. Os testes manuais às 6 fases já tinham sido feitos antes, ao longo do desenvolvimento do projeto — este relatório serve como **documentação adicional e double-check independente** desse trabalho manual, não como a primeira verificação de que a solução funciona.

## Objetivo e metodologia

Teste completo e ao vivo das 6 fases do projeto, contra a stack real em execução — sem simulação, sem dados inventados, sem reutilizar resultados de sessões anteriores. Cada checkpoint foi reproduzido com o comando/query exato que o comprova, e os cenários de chaos da Fase 6 foram disparados de propósito, com o tempo de reação medido ao vivo (não estimado a partir da documentação).

**Como foi testado**, sem depender do browser (não há acesso a UI neste teste):
- **Docker**: `docker compose ps` / `docker logs` para estado dos containers
- **Prometheus**: queries HTTP diretas à API (`/api/v1/query`)
- **Grafana**: API HTTP (`/api/search`, `/api/dashboards/uid/...`, `/api/v1/provisioning/alert-rules`, `/api/alertmanager/.../alerts`) — os mesmos dados que a UI mostra, só sem o layout visual
- **Elasticsearch**: API REST (`/_cluster/health`, `/_cat/indices`, `/_search`)
- **PostgreSQL/MongoDB**: `psql`/`mongosh` via `docker exec`
- **API Flask**: `curl` direto aos endpoints

**Resultado global: ✅ os 6 pilares funcionam de ponta a ponta.** Detalhe completo abaixo, passo a passo.

---

## Passo 0 — Pré-voo: estado da stack antes de testar

```bash
docker compose ps
```

Resultado: **9/9 containers `Up`**, com `lab-postgres`, `lab-mongodb` e `lab-elasticsearch` em `(healthy)` (os 3 com healthcheck definido).

Antes de testar a carga sintética, confirmei que os processos da sessão anterior ainda estavam vivos (para não reiniciar nada innecessariamente):

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'python|powershell|pwsh' } | Select-Object Id,ProcessName,StartTime,Path
```

Encontrei um processo `python.exe` a correr desde as 11:28 (a API Flask) e vários `powershell`/`bash` de janelas anteriores. Confirmei que a API respondia antes de assumir que estava operacional:

```bash
curl.exe -s -o /dev/null -w "API /health status: %{http_code}\n" http://localhost:8000/health
# API /health status: 200
```

---

## Fase 1 + 2 — Infraestrutura e carga sintética

**O que estou a verificar:** que o Prometheus está mesmo a receber dados frescos dos dois exporters, não só que os containers estão `Up`.

```bash
curl.exe -s "http://localhost:9090/api/v1/query?query=pg_stat_database_xact_commit%7Bdatname%3D%22labdb%22%7D"
# leitura 1: 136127
sleep 15
curl.exe -s "http://localhost:9090/api/v1/query?query=pg_stat_database_xact_commit%7Bdatname%3D%22labdb%22%7D"
# leitura 2 (15s depois): 136200   -> +73 em 15s ≈ 4,9 commits/s
```

```bash
curl.exe -s "http://localhost:9090/api/v1/query?query=sum(mongodb_ss_opcounters)"
# leitura 1: 13776
# leitura 2 (15s depois): 13979   -> +203 em 15s ≈ 13,5 ops/s
```

**Resultado:** ambos os contadores sobem entre as duas leituras — confirma que `load-postgres.sh` e `load-mongo.sh` estão ativamente a gerar carga, não é um valor parado de uma execução antiga. ✅

---

## Fase 3 — Grafana (dashboard e alerta)

**O que estou a verificar:** que o dashboard e a regra de alerta existem com a configuração correta, e não só "existe alguma coisa chamada assim".

```bash
curl.exe -s -u admin:admin "http://localhost:3000/api/search?query=DB%20Health"
```
```json
[{"uid":"adm9wkd","title":"DB Health Overview","url":"/d/adm9wkd/db-health-overview", ...}]
```

Confirmado que existe. Fui buscar os painéis reais dentro desse dashboard:

```bash
curl.exe -s -u admin:admin "http://localhost:3000/api/dashboards/uid/adm9wkd"
```

Resultado — **7 painéis**, todos os esperados:
```
PG — Ligações ativas          | stat
PG — Cache hit ratio          | gauge
MongoDB — Ligações atuais     | stat
PG — Commits por segundo      | timeseries
PG — Tamanho da base de dados | timeseries
PG — Queries lentas (>1s)     | logs
MongoDB — Operações por segundo | timeseries
```

Depois a regra de alerta, via a API de provisioning (mostra a configuração exata, não só o nome):

```bash
curl.exe -s -u admin:admin "http://localhost:3000/api/v1/provisioning/alert-rules"
```
```
Nome: PG - Ligacoes elevadas
Query A: pg_stat_database_numbackends{datname="labdb"}
Condicao C: evaluator={type: gt, params: [40]}, reducer: last
For (pending period): 2m
```

E o estado atual do alerta (deve estar silencioso em repouso):

```bash
curl.exe -s -u admin:admin "http://localhost:3000/api/alertmanager/grafana/api/v2/alerts"
# [] -> sem alertas ativos = Normal
```

**Resultado:** dashboard com os 7 painéis certos, regra com threshold=40 e pending=2m exatamente como configurado na Fase 3, estado em repouso = Normal. ✅

---

## Fase 4 — Logs (Elasticsearch / Kibana / Filebeat)

**O que estou a verificar:** que os índices continuam a crescer (não pararam de receber dados desde a última vez que isto foi testado), que a pesquisa de queries lentas continua a funcionar com o campo `service.name` corrigido na Fase 4, e que o Filebeat não está com erros silenciosos.

```bash
curl.exe -s "http://localhost:9200/_cluster/health?pretty" | grep -E "status|number_of_nodes"
# status: yellow, number_of_nodes: 1   -> esperado, nó único
```

```bash
curl.exe -s "http://localhost:9200/_cat/indices/db-logs-*?v&s=index"
```
```
.ds-db-logs-2026.08.24-...   469365 docs
.ds-db-logs-2026.08.25-...   916713 docs
.ds-db-logs-2026.08.26-...   934479 docs
```

10 segundos depois, o índice do dia tinha subido para **934541** (+62 documentos) — confirma ingestão contínua.

Pesquisa de queries lentas (o mesmo padrão usado desde a Fase 4, com o campo `service.name` corrigido):

```bash
curl.exe -s -X GET "http://localhost:9200/db-logs-*/_search" -d '
{"query":{"query_string":{"query":"service.name:postgresql AND message:*duration*"}},"size":2,"sort":[{"@timestamp":"desc"}]}'
```
→ **9158 resultados totais**, os 2 mais recentes eram entradas de `pg_sleep(1.93)`/`pg_sleep(1.52)` — na verdade geradas pelo próprio endpoint `/slow` da API, que o `traffic.ps1` estava a chamar em paralelo. Isto foi uma pista extra de que a Fase 5 também estava ativa.

Verifiquei o Filebeat por erros — à primeira tentativa usei `grep -i error` nos logs, que deu **falso positivo** (apanhou o campo `"errors":2` das métricas internas de monitorização do próprio Filebeat, não um erro real). Corrigi filtrando só por `log.level`:

```bash
docker logs lab-filebeat --since 5m 2>&1 | grep -o '"log.level":"[a-z]*"' | sort | uniq -c
#      11 "log.level":"info"
```
→ só logs `info`, zero `error`/`warn` reais nos últimos 5 minutos.

**Resultado:** índices a crescer, pesquisa correta, Filebeat sem erros genuínos. ✅

---

## Fase 5 — API / APM

**O que estou a verificar:** que os 5 endpoints respondem corretamente, incluindo a lógica probabilística do `/error`, e que não há erros de transmissão para o Application Insights nos logs locais da API.

```bash
curl.exe -s http://localhost:8000/health          # {"status":"ok"}
curl.exe -s http://localhost:8000/orders/summary  # {"cancelled":{...12490...},"paid":{...24558...},"pending":{...12...}}
curl.exe -s http://localhost:8000/events/summary  # [{"_id":"click","total":6739}, ...]
curl.exe -s http://localhost:8000/slow            # {"delayed_seconds":1.54,"ok":true}
```

Para o `/error`, uma amostra pequena (3 pedidos) deu 200/200/200 — estatisticamente possível (12,5% de chance com p=0,5), mas queria confirmar com mais amostra:

```bash
for i in $(seq 1 10); do
  code=$(curl.exe -s -o /dev/null -w "%{http_code}" http://localhost:8000/error)
  # contar 200 vs 500
done
# 200: 5 | 500: 5
```
→ exatamente 5/5, confirma a lógica `random.random() < 0.5` a funcionar como esperado.

Verifiquei o `app_stderr.log` da API (o ficheiro onde redirecionei o stderr quando a arranquei nesta sessão) por erros de transmissão para o Azure — **vazio**, sem nada a reportar.

**Resultado:** todos os endpoints corretos, taxa de erro do `/error` confirmada estatisticamente, sem erros de transmissão. A entrega real da telemetria ao portal do Application Insights não foi re-verificada agora (sem acesso a browser neste teste) — já tinha sido confirmada visualmente mais cedo nesta mesma sessão (Application Map com as 2 dependências, Performance a destacar o `/slow`, Failures com a `ValueError`). ✅ (parcial — ver limitações no fim)

---

## Fase 6 — Demo de incidentes, reproduzida ao vivo

Esta foi a parte mais longa do teste — disparei os 3 cenários reais de chaos, um a um, com resolução entre cada, medindo os tempos de reação.

### Baseline

```powershell
.\scripts\chaos.ps1 status
```
→ 2 sessões (1 idle, 1 a própria query de diagnóstico). Estado limpo antes de começar.

### Cenário 1 — Tempestade de ligações

```powershell
.\scripts\chaos.ps1 connections
```

Imediatamente depois:
```bash
curl.exe -s "http://localhost:9090/api/v1/query?query=pg_stat_database_numbackends{datname=\"labdb\"}"
# numbackends: 47
```
→ salto instantâneo de 2 para 47 (acima do threshold 40).

```powershell
.\scripts\chaos.ps1 status
```
→ 53 sessões, as 50 novas todas com `wait_event_type=Timeout` (o estado de espera correto para `pg_sleep`).

Lancei um script de monitorização em segundo plano, a interrogar a API de alertas do Grafana a cada 15s:

```bash
while [ $elapsed -lt 300 ]; do
  state=$(curl.exe -s -u admin:admin "http://localhost:3000/api/alertmanager/grafana/api/v2/alerts" | ...)
  echo "t=+${elapsed}s: estado=$state"
  [ "$state" = "active" ] && break
  sleep 15; elapsed=$((elapsed+15))
done
```

Resultado registado:
```
t=+0s   estado=normal
t=+15s  estado=normal
...
t=+120s estado=normal
t=+135s estado=active   <- FIRING
```
→ **o alerta disparou aos 2m15s**, consistente com o pending period de 2 min configurado + latência de avaliação (o motor de alerting do Grafana avalia a cada 1 min, por isso ~15s de overshoot é esperado).

Resolvi:
```powershell
.\scripts\chaos.ps1 resolve
```
→ `pg_terminate_backend` devolveu `t` (sucesso) em **51 linhas** (as 50 de chaos + 1 sessão órfã adicional).

Novo script de monitorização, agora à espera do regresso a Normal:
```
t=+0s   alerta=active | numbackends=2
t=+15s  alerta=active | numbackends=2
t=+30s  alerta=normal | numbackends=2   <- NORMAL
```
→ o número de ligações caiu para 2 imediatamente (as sessões foram mesmo terminadas), mas o **alerta** só atualiza no próximo ciclo de avaliação do Grafana — daí os 30s de atraso entre a causa desaparecer e o estado voltar a Normal.

**Ciclo completo confirmado: Normal → Firing (2m15s) → resolve → Normal (+30s).** ✅

### Cenário 2 — Query lenta

```powershell
Measure-Command { .\scripts\chaos.ps1 slowquery }
```
```
>>> A executar CROSS JOIN pesado...
   count
------------
 1373443600
real  0m23.009s
```
→ a tabela `orders` já tem crescido o suficiente (√1.373.443.600 ≈ 37 059 linhas) para o CROSS JOIN demorar **23 segundos reais**, sem precisar de nenhum `pg_sleep` artificial.

Confirmei o log exato no PostgreSQL:
```bash
docker exec lab-postgres sh -c "grep -h duration /var/log/postgresql/*.log | tail -3"
# duration: 22771.762 ms  statement: SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2;
```

E a chegada ao Elasticsearch, pesquisando por essa mensagem exata:
```bash
curl.exe -s -X GET "http://localhost:9200/db-logs-*/_search" -d '{"query":{"query_string":{"query":"message:*CROSS*"}}, ...}'
# Hits: 53
# - duration: 22771.762 ms  statement: SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2;
```
→ a entrada já estava indexada quando fui verificar, bem dentro dos ~30s que o guia estima.

**Resultado:** query lenta gerada, registada, e pesquisável — ciclo completo em menos de 30s. ✅

### Cenário 3 — Lock de tabela

Antes de disparar, arranquei uma monitorização em segundo plano da taxa de commits (15 leituras, 15s cada, 150s no total), para não perder o início da queda:

```powershell
.\scripts\chaos.ps1 lock
```
```
>>> A bloquear a tabela orders durante 90s (ACCESS EXCLUSIVE)...
```

Enquanto isso, confirmei o efeito imediato:
```powershell
.\scripts\chaos.ps1 status
```
```
6268 | active | Timeout | BEGIN; LOCK TABLE orders IN ACCESS EXCLUSIVE MODE; SELECT pg... (a sessao do lock)
6269 | active | Lock    | SELECT status, COUNT(*), ROUND(AVG(amount), 2) FROM orders G... (bloqueada!)
```
→ a segunda linha é uma query real da API (`/orders/summary`, disparada pelo `traffic.ps1`) já bloqueada pelo lock, a demonstrar que o lock afeta consumidores reais, não só o load script.

Curva de commits/s capturada pela monitorização em segundo plano:

| t (s) | Commits/s | Nota |
|---|---|---|
| 0 | 2,61 | antes do lock fazer efeito |
| 15 | 2,51 | |
| 30 | 1,84 | a cair |
| 45 | 1,19 | a cair |
| **60** | **(sem dados)** | **flatline — zero commits** |
| **75** | **(sem dados)** | |
| **90** | **(sem dados)** | |
| **105** | **(sem dados)** | |
| 120 | 2,66 | recuperação |
| 135 | 3,01 | de volta ao normal |

A meio da janela de flatline, voltei a correr `status` e encontrei uma **fila de 5 sessões bloqueadas** (não só 1 como esperava):
```
6269 | Lock | SELECT status, COUNT(*), ... FROM orders G...        <- API (traffic.ps1)
6285 | Lock | SELECT status, COUNT(*), ... FROM orders G...        <- API (traffic.ps1)
6294 | Lock | SELECT current_database() datname, schemaname, ...   <- provavelmente postgres_exporter
6304 | Lock | SELECT status, COUNT(*), ... FROM orders G...        <- API (traffic.ps1)
6305 | Lock | SELECT current_database() datname, schemaname, ...   <- provavelmente postgres_exporter
6314 | Lock | SELECT status, COUNT(*), ... FROM orders G...        <- API (traffic.ps1)
```
→ achado que o guião original não previa: o lock bloqueia genuinamente **qualquer** consumidor da tabela `orders`, incluindo a própria introspeção de schema do `postgres_exporter` — um efeito em cascata mais realista do que "só o load script congela".

O lock auto-resolveu aos 90s (sem precisar de forçar `resolve`). Confirmação final:
```powershell
.\scripts\chaos.ps1 status
```
→ de volta a 2 sessões, nenhuma pendurada.

**Resultado:** flatline real confirmado (não só "valores baixos", literalmente sem dados durante ~45s), recuperação em V confirmada, e um efeito de cascata mais amplo do que o documentado. ✅

---

## Estado final da stack (depois dos 3 incidentes)

```bash
curl.exe -s -u admin:admin ".../api/alertmanager/.../alerts"   # normal
docker compose ps --format "{{.Name}}: {{.Status}}"
```
- Alerta: **Normal**
- 9/9 containers `Up`, os 3 com healthcheck em `(healthy)`
- 2 sessões PostgreSQL (baseline), 0 penduradas
- `load-postgres.sh`, `load-mongo.sh` e `traffic.ps1` continuam a correr normalmente — a stack não precisou de ser reiniciada em nenhum momento deste teste

## Checklist resumo

| Fase | Checkpoint | Resultado |
|---|---|---|
| 1 | 9/9 containers Up, healthchecks OK | ✅ |
| 2 | Commits/s e ops/s Mongo a subir entre 2 leituras | ✅ |
| 3 | Dashboard com 7 painéis + alerta configurado corretamente | ✅ |
| 4 | Índices a crescer, pesquisa funcional, 0 erros no Filebeat | ✅ |
| 5 | 5 endpoints corretos, taxa de erro do `/error` confirmada (5/10) | ✅ |
| 6.1 | Alerta Normal→Firing em 2m15s, resolve→Normal em 30s | ✅ |
| 6.2 | Query lenta de 22,77s indexada em <30s | ✅ |
| 6.3 | Flatline real de ~45s, recuperação em V, fila de 5 sessões bloqueadas | ✅ |

## Limitações deste teste

- **Application Insights** — não voltei a confirmar a chegada de telemetria ao portal Azure (sem acesso a browser neste teste). Apoiei-me na ausência de erros de transmissão nos logs locais da API e na confirmação visual já feita mais cedo nesta sessão.
- **UI do Grafana/Kibana** — todas as verificações foram feitas via API HTTP, que devolve os mesmos dados/configuração que a UI mostra, mas não confirma detalhes puramente visuais (cores dos thresholds, layout dos painéis no browser).
- Este teste não incluiu recriar a stack do zero (`docker compose down -v && docker compose up -d`) — validou o sistema já em execução, não o processo de arranque a partir de um clone limpo (essa é precisamente a lacuna que o item "CI smoke test" em [melhorias-futuras.md](melhorias-futuras.md) propõe fechar).
