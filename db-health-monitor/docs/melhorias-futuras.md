# Melhorias futuras

Lista de melhorias identificadas depois de concluídas as 6 fases, por ordem de prioridade (impacto no portfólio vs. esforço). Não são bloqueantes — o projeto está funcionalmente completo sem elas.

## Alta prioridade (baixo esforço, alto impacto)

- [ ] **CI smoke test** (GitHub Actions) — workflow que corre `docker compose up -d`, espera pelos healthchecks, testa alguns endpoints (`/targets` do Prometheus, `/health` da API), e desliga tudo. Prova que o projeto funciona a partir de um clone limpo, não só na máquina do autor — provavelmente o maior salto de credibilidade para quem só lê o repositório sem o correr.

- [ ] **Fechar o loop visual da Fase 6** — os 7 screenshots já existem em `docs/screenshots/`; falta embebê-los no `fase6-guiao-demo.md` e/ou numa secção "Incident demo" no README, como o guia original sugeria. Ver checkpoint pendente em [fase6-resumo.md](fase6-resumo.md).

## Média prioridade (mais esforço técnico, reforça a história)

- [ ] **Corrigir pelo menos os itens mais fáceis do `SECURITY.md`** — começar pela autenticação no MongoDB (mais rápido de implementar que Elasticsearch). Documentar que se conhecem as falhas é bom; corrigi-las mostra follow-through.

- [ ] **Fixar as versões `latest` no `docker-compose.yml`** (`postgres-exporter`, `prometheus`, `grafana`) — já documentado como caveat em [versoes-tecnologias.md](versoes-tecnologias.md). Fixar versões explícitas torna o projeto 100% reprodutível no futuro, independentemente de quando for clonado.

- [ ] **Grafana provisioning** (dashboards e data sources como código, via ficheiros YAML montados no arranque) — resolve o problema real de o dashboard só existir no volume do container (perdido com `docker compose down -v`), documentado em [fase3-conceitos.md](fase3-conceitos.md#9-dashboards-como-estado-efémero-vs-dashboards-as-code). Boa linha extra de "infrastructure as code" no CV.

## Baixa prioridade / opcional

- [ ] Notificações de alerta via Discord/Slack (contact point) — Fase 3 deixou isto de fora conscientemente
- [ ] Node exporter para métricas ao nível do host
- [ ] Vídeo/GIF da demo de incidentes (Fase 6)
- [ ] Dynatrace OneAgent como alternativa de APM (trial de 15 dias) — comparação *agent-based vs SDK-based instrumentation*
- [ ] Consolidar a duplicação de nomes entre `Scripts/` (raiz, scaffold do projeto) e `db-health-monitor/scripts/` (scripts reais do lab) — puramente cosmético, mas confunde à primeira leitura

---

**Nota:** esta lista foi gerada a pedido, depois de concluídas as 6 fases — não confundir com o "Roadmap" original do README, que já continha algumas destas ideias antes de serem priorizadas aqui.
