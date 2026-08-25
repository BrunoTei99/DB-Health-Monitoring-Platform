# Fase 3 — Dashboards e alertas no Grafana — resumo detalhado

**Objetivo da fase:** ter dashboards da comunidade importados, um dashboard próprio ("DB Health Overview") construído painel a painel com PromQL, e um alerta configurado e testado — ciclo completo Normal → Pending → Firing → Normal.

**Pré-requisito:** Fase 1 e Fase 2 concluídas — ver [fase2-resumo.md](fase2-resumo.md). Scripts `load-postgres.sh` e `load-mongo.sh` a correr durante toda a fase.

Este documento regista o que foi feito, os comandos exatos, os problemas reais encontrados durante a execução (e como foram resolvidos) e os resultados obtidos.

---

## Passo 0 — Verificações rápidas

Data source Prometheus validado (**Save & test** → sucesso) e confirmação de dados a chegar via **Explore** com `rate(pg_stat_database_xact_commit{datname="labdb"}[1m])`.

## Passo 1 — Dashboards da comunidade

Importados os dashboards `9628` (PostgreSQL) e `2583` (MongoDB) via **Dashboards → New → Import**. Como esperado pelo guia, alguns painéis do dashboard de MongoDB ficaram sem dados — resultado normal de um dashboard genérico desenhado para outra versão do exporter.

## Passo 2 — Dashboard "DB Health Overview"

Construídos os 6 painéis planeados. Dois deles exigiram investigação e adaptação por causa de diferenças de nomenclatura no `percona/mongodb_exporter:0.40` face ao que o guia original assumia.

### Painéis 1–3 (PostgreSQL) — sem incidentes

- **Painel 1** — Stat, `pg_stat_database_numbackends{datname="labdb"}`, thresholds 20/40
- **Painel 2** — Time series, `rate(pg_stat_database_xact_commit{datname="labdb"}[1m])`
- **Painel 3** — Gauge, `pg_stat_database_blks_hit / (blks_hit + blks_read)`, thresholds 0.90/0.97

### Painel 4 — MongoDB operações/s: métrica inexistente

Query do guia original devolveu **"No data"**:
```promql
sum by (type) (rate(mongodb_op_counters_total[1m]))
```

**Investigação:**
1. No Explore, `mongodb_op` no autocomplete — nada encontrado.
2. `mongodb_` no autocomplete — só apareciam métricas `mongodb_dbstats_*`.
3. Testado o prefixo `mongodb_ss_` (serverStatus, já identificado como padrão desta versão do exporter na Fase 2) — `mongodb_ss_opcounters` **existe**, com um label `type` (`insert`, `query`, `update`, `delete`, `getmore`, `command`).

**Query final (Painel 4):**
```promql
sum by (type) (rate(mongodb_ss_opcounters[1m]))
```
Legend: `{{type}}`

### Painel 5 — MongoDB ligações: métrica com nome diferente e valor persistentemente zero

`mongodb_connections{state="current"}` (nome do guia) não existe. Investigação equivalente ao Painel 4 revelou `mongodb_ss_connections` com label `conn_type`.

Primeira tentativa, `conn_type="active"`, devolveu `0` — **valor tecnicamente correto mas não o que o painel quer mostrar**: `active` é uma fotografia instantânea de ligações a executar uma operação *neste exato milissegundo* (quase sempre 0 fora de picos de carga), diferente de `current` (total de ligações abertas, sempre > 0 com o exporter/scripts ligados).

Corrigido para `conn_type="current"` — **continuou a mostrar `0`**, o que já não era esperado. Diagnóstico em 4 camadas, de trás para a frente:

1. **MongoDB diretamente** (`mongosh --eval "db.serverStatus().connections"`) → `current: 5` — a base de dados via ligações reais.
2. **Exporter diretamente** (`curl http://localhost:9216/metrics | grep mongodb_ss_connections`) → `conn_type="current"` a `0` — **discrepância confirmada aqui**: o exporter estava a expor um valor errado/desatualizado, o problema não era Prometheus nem Grafana.
3. **Logs do exporter** (`docker logs lab-mongo-exporter`):
   ```
   level=error msg="Cannot connect to MongoDB: ... dial tcp: lookup mongodb on 127.0.0.11:53: no such host"
   ```
   Falhas de resolução de DNS intermitentes ao nome de serviço `mongodb` dentro da rede Docker, em vários momentos ao longo de dois dias — o exporter tinha ficado com um estado de ligação "preso" desde uma falha anterior.
4. **Resolução:** `docker restart lab-mongo-exporter` → reconexão limpa. Confirmado de imediato via `curl` direto ao exporter: `conn_type="current"` passou a `3`.

Mesmo depois disto, o painel no Grafana continuou a mostrar `0` — **quarta camada**, já não relacionada com dados mas com a UI: o time range do painel estava fixo num intervalo antigo (`08:37 to 14:37`, herdado de uma sessão de Explore anterior). Mudar o time range para "Last 5 minutes" e correr a query de novo resolveu.

**Lição:** um "No data" ou valor errado num dashboard pode ter origem em qualquer uma de quatro camadas independentes — base de dados, exporter, Prometheus, ou apenas a janela de tempo da UI do Grafana — e cada uma se testa isoladamente com a ferramenta certa (`mongosh`/`psql` direto, `curl /metrics` direto ao exporter, query direta em `:9090/graph`, e por fim o próprio painel).

**Query final (Painel 5):**
```promql
mongodb_ss_connections{conn_type="current"}
```

### Painel 6 — sem incidentes

`pg_database_size_bytes{datname="labdb"}`, unit `bytes(IEC)`. Nota: este painel só sobe com `load-postgres.sh` a correr — não reage ao `load-mongo.sh` (confusão inicial esclarecida: os dois load scripts alimentam bases de dados diferentes, cada um só afeta os painéis da sua própria base).

## Passo 2.8/2.9 — Layout e teste de "respiração"

Layout arrumado (Stats/Gauge em cima, Time series em baixo), auto-refresh 10s, time range "Last 30 minutes". Dashboard gravado.

## Passo 3 — Alerta de ligações elevadas

### Diferença de UI face ao guia original

A versão do Grafana usada aqui **não expõe os blocos clássicos A (query) / B (Reduce) / C (Threshold)** por defeito — usa uma UI simplificada com uma única caixa **"Alert condition"** (`WHEN QUERY IS ABOVE <valor>`), porque a query já corre em modo `Type: Instant` (devolve diretamente um valor único por série, tornando o passo "Reduce" explícito redundante). Os blocos A/B/C clássicos só aparecem ao ativar **"Advanced options"**.

**Configuração aplicada:**
- Nome: `PG - Ligacoes elevadas`
- Query: `pg_stat_database_numbackends{datname="labdb"}` (modo Instant)
- Alert condition: `IS ABOVE 40`
- Preview inicial (antes da tempestade): `Normal` ✅
- Folder: `db-lab`; Evaluation group: `db-alerts`, intervalo `1m`
- Pending period: `2m`
- Label: `severity=warning`

Contact point (Discord/SMTP) **não configurado** — decisão consciente para este lab: o alerta dispara e o estado é visível na UI (`Alerting → Alert rules`), mas sem notificação externa. Confirmado que isto é esperado e não um erro: sem contact point real, o Grafana não tem para onde enviar a notificação.

## Passo 4 — Teste do alerta

Tempestade de 50 ligações penduradas:
```powershell
1..50 | ForEach-Object {
  docker exec -d lab-postgres psql -U admin -d labdb -c "SELECT pg_sleep(300);"
}
```

**Resultado observado:**
- Painel 1 saltou imediatamente para ~50 (vermelho)
- Estado **Pending** não foi capturado a tempo (janela de ~1 min, fácil de perder sem estar a olhar exatamente nessa altura)
- Estado **Firing** confirmado em `Alerting → Alert rules`

Resolução:
```powershell
docker exec -it lab-postgres psql -U admin -d labdb -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_sleep%' AND pid <> pg_backend_pid();"
```
→ Painel voltou a verde, alerta voltou a **Normal** em 1–2 minutos. Ciclo de deteção → investigação → resolução → confirmação validado, ainda que sem screenshot do estado intermédio "Pending" (pendente repetir o teste com o separador de alertas já aberto, se se quiser esse screenshot para portfólio).

## Passo 5 — Exportar o dashboard

### Diferença de UI face ao guia original

O botão **Share** desta versão do Grafana abre por defeito o ecrã de **"Share externally"** (link público, partilhável com qualquer pessoa — **não usado**, por ser um mecanismo de partilha pública desnecessário para este caso). A opção correta está no dropdown ao lado do botão Share: **"Export as JSON"**.

Ficheiro descarregado e guardado em:
```
db-health-monitor/grafana/dashboards/db-health-overview.json
```

**Problema encontrado:** o ficheiro descarregado ficou com extensão duplicada (`db-health-overview.json.json`) — corrigido com `mv`.

README do projeto atualizado com secção "Dashboards do Grafana", explicando como reimportar o ficheiro (`Dashboards → New → Import → Upload`).

---

## ✅ Checkpoint final da Fase 3

- [x] Dashboards `9628` e `2583` importados
- [x] Dashboard "DB Health Overview" com os 6 painéis, unidades e thresholds coerentes com o alerta
- [x] Auto-refresh 10s ativo; layout arrumado
- [x] Regra de alerta criada; ciclo Normal → Firing → Normal testado e confirmado (Pending não capturado em screenshot)
- [x] Sessões penduradas terminadas com `pg_terminate_backend`
- [x] JSON do dashboard exportado, extensão corrigida, e versionado; README atualizado com instruções de reimportação

---

## Pendente / a retomar mais tarde

- **Screenshot do estado "Pending"** — o ciclo completo (Normal → Pending → Firing → Normal) foi validado funcionalmente, mas o estado intermédio não foi capturado a tempo. Repetir o teste da tempestade de ligações com o separador `Alerting → Alert rules` já aberto e refresh manual a cada ~15s.
- **Contact point (Discord/SMTP)** — passo 3.3 do guia, opcional, deixado de fora conscientemente. Pode ser adicionado mais tarde sem alterar a regra de alerta em si.
- **Confirmar se o restart do `lab-mongo-exporter` foi um sintoma pontual ou recorrente** — os logs mostraram falhas de DNS em pelo menos três momentos distintos ao longo de dois dias; se voltar a acontecer, vale a pena investigar a estabilidade do DNS interno do Docker Desktop no Windows, ou adicionar um `restart: unless-stopped` / healthcheck ao serviço `mongodb-exporter` no `docker-compose.yml`.

**Próximo passo:** Fase 4 — Elasticsearch + Filebeat, onde os logs (incluindo as queries lentas que o PostgreSQL já regista desde a Fase 1) ficam pesquisáveis e entram no dashboard.
