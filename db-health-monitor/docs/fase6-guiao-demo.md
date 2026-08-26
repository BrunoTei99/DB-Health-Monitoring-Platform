# Guião da demo de incidentes — DB Health Monitor

Este é o guião ensaiado para apresentar o projeto ao vivo (entrevista, portfólio, gravação em vídeo). Junta as 5 fases numa história única: injetas 3 incidentes controlados e mostras cada camada da stack a detetá-los — alerta no Grafana, log no Kibana, trace no Application Insights — até à resolução e regresso ao verde.

**Duração:** ~12 minutos. Ensaia pelo menos uma vez de ponta a ponta antes de apresentar a sério.

---

## Pré-requisitos — o "estado de palco"

Confirma **antes** de começar (todos vivos, gráficos a "respirar"):

- [ ] Stack Docker completa a correr (9 containers `Up`)
- [ ] `load-postgres.sh` a correr numa janela dedicada
- [ ] `load-mongo.sh` a correr numa janela dedicada
- [ ] API Flask a correr com `APPLICATIONINSIGHTS_CONNECTION_STRING` definida
- [ ] `traffic.ps1` a correr numa janela dedicada
- [ ] Alerta da Fase 3 configurado ("PG - Ligacoes elevadas", threshold 40, pending 2m) em estado **Normal**

## Organização dos ecrãs

| Janela / Tab | Conteúdo |
|---|---|
| Browser, tab 1 | Grafana → "DB Health Overview", time range **Last 15 minutes**, refresh **10s** |
| Browser, tab 2 | Grafana → Alerting → Alert rules |
| Browser, tab 3 | Kibana → Discover, pesquisa guardada `Queries lentas PostgreSQL`, Last 15 minutes |
| Browser, tab 4 | Azure → Application Insights → Performance (+ Live Metrics numa tab extra, opcional) |
| PowerShell | Na pasta `db-health-monitor`, pronta para os `chaos.ps1` |

📸 **Screenshot 0 — "antes":** dashboard todo verde, alerta em Normal. Guardar como `docs/screenshots/00-healthy-state.png`.

---

## Ato 1 — Estado saudável (min 0-1)

> *"Isto é uma plataforma de monitorização de duas bases de dados — uma relacional, uma NoSQL — com os três pilares da observabilidade: métricas no Prometheus/Grafana, logs no Elasticsearch/Kibana, e traces no Application Insights. Neste momento está tudo saudável: carga sintética constante, alerta em Normal."*

Mostra o dashboard verde e o Application Map com as duas dependências (PostgreSQL, MongoDB).

## Ato 2 — Incidente 1: tempestade de ligações (min 1-6)

```powershell
.\scripts\chaos.ps1 connections
```

1. **Imediato:** Stat "PG — Ligações ativas" salta de ~2 para ~52, fica vermelho. 📸 `01-connection-storm-stat.png`
2. Investiga como investigarias a sério:
   ```powershell
   .\scripts\chaos.ps1 status
   ```
   > *"52 sessões, todas no mesmo query — pg_sleep — todas idle-in-transaction há segundos. Isto não é carga real: é algo a fugir com ligações. Num caso real, seria um connection pool mal configurado ou uma app a não fechar ligações."*
3. Tab do Alerting: **Pending** (~1 min) → **Firing** (~3 min). 📸 `02-alert-firing.png`
4. Em voz alta: commits/s e cache hit **inalterados** — a app de fundo continua a funcionar; o problema é de recursos, não de performance.
5. Resolve:
   ```powershell
   .\scripts\chaos.ps1 resolve
   ```
6. Em 1-2 min: Stat verde, alerta de volta a **Normal**. 📸 `03-alert-normal-again.png`

## Ato 3 — Incidente 2: query lenta (min 6-9)

```powershell
.\scripts\chaos.ps1 slowquery
```

1. O comando demora vários segundos a devolver — a lentidão sente-se.
2. Kibana (ou painel de logs do dashboard), refresca ~30s depois — entrada com `duration: XXXX ms` e o SQL completo do CROSS JOIN. 📸 `04-slow-query-kibana.png`
   > *"O log diz-me exatamente QUAL query foi lenta e QUANTO demorou — o que as métricas sozinhas nunca dizem. Métricas dizem-me QUE algo está lento; logs dizem-me O QUÊ."*
3. Application Insights → Performance → `GET /slow` → drill into samples → um trace: 📸 `05-trace-slow-app-insights.png`
   > *"E quando a lentidão vem de uma aplicação, o trace mostra-me ONDE: este request passou a maior parte do tempo dentro da dependência PostgreSQL. Métricas → o quê; logs → qual; traces → onde."*

## Ato 4 — Incidente 3: lock de tabela (min 9-11)

```powershell
.\scripts\chaos.ps1 lock
```

1. Janela do `load-postgres.sh`: **congela** (INSERTs à espera do lock).
2. Dashboard: **commits/s caem a pique** — o flatline. 📸 `06-commit-flatline.png`
3. ```powershell
   .\scripts\chaos.ps1 status
   ```
   Sessões com `wait_event_type = Lock`:
   > *"Aqui as métricas mostram o sintoma (throughput a zero) e o `pg_stat_activity` mostra a causa (sessões bloqueadas por um lock exclusivo)."*
4. Deixa auto-resolver (90s) ou força com `resolve` — commits/s recuperam **em V**. 📸 `07-commit-recovery-v.png`

## Ato 5 — Fecho (min 11-12)

> *"Três incidentes diferentes, três padrões de deteção: um alerta proativo, uma pesquisa de logs, uma correlação métrica-diagnóstico. Tudo local, tudo reproduzível, tudo open source exceto o APM — que fica no free tier."*

---

## Os 8 screenshots que contam a história

| # | Ecrã | Momento | Ficheiro |
|---|---|---|---|
| 0 | Dashboard verde + alerta Normal | Antes | `00-healthy-state.png` |
| 1 | Stat de ligações vermelho (52) | Incidente 1 | `01-connection-storm-stat.png` |
| 2 | Alerta em Firing | Incidente 1 | `02-alert-firing.png` |
| 3 | Regresso a Normal | Resolução 1 | `03-alert-normal-again.png` |
| 4 | Query lenta no Kibana com duration | Incidente 2 | `04-slow-query-kibana.png` |
| 5 | Trace do /slow no App Insights | Incidente 2 | `05-trace-slow-app-insights.png` |
| 6 | Flatline de commits/s | Incidente 3 | `06-commit-flatline.png` |
| 7 | Recuperação em V | Resolução 3 | `07-commit-recovery-v.png` |

Guardar em `db-health-monitor/docs/screenshots/`.

## Reset entre ensaios

```powershell
.\scripts\chaos.ps1 resolve
# opcional: encolher a tabela se o CROSS JOIN ficou lento DEMAIS (>30s)
docker exec lab-postgres psql -U admin -d labdb -c "DELETE FROM orders WHERE id NOT IN (SELECT id FROM orders ORDER BY id DESC LIMIT 20000);"
```
