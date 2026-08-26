# Fase 6 — Cenário de demonstração: injetar uma falha — resumo detalhado

**Objetivo da fase:** transformar as 5 fases numa história única e demonstrável: injetar incidentes controlados e mostrar cada camada a detetá-los — alerta no Grafana, log no Kibana, trace no Application Insights — até à resolução e regresso ao verde.

**Pré-requisito:** Fases 1–5 concluídas — ver [fase5-resumo.md](fase5-resumo.md).

Este documento regista o que foi feito e os resultados obtidos. O guião pronto a seguir numa apresentação está em [fase6-guiao-demo.md](fase6-guiao-demo.md).

---

## Passo 1 — Scripts de chaos

Criados `db-health-monitor/scripts/chaos.ps1` e `scripts/chaos.sh`, com os 5 cenários do guia (`connections`, `slowquery`, `lock`, `resolve`, `status`).

**Nota:** já existia um `chaos.sh` no repositório desde a Fase 0 — era só um placeholder vazio (`# Adicionar testes aqui`, sem lógica real). Substituído pelo conteúdo funcional desta fase. Confirmado explicitamente que o ficheiro ficou com terminadores de linha **LF** (`grep -c $'\r' chaos.sh` → `0`), requisito do guia para o script correr corretamente num ambiente Bash/Linux.

Os 5 cenários testados isoladamente antes da demo (`status` → `slowquery` → `connections` → `status` → `resolve`), todos conforme esperado.

## Passo 1.5 — Verificação lateral: 8 ligações "current" no MongoDB

Antes de preparar o palco da demo, surgiu a dúvida de por que o MongoDB mostrava 8 ligações atuais em repouso. Investigado com:
```bash
docker exec lab-mongodb mongosh --quiet --eval "db.currentOp().inprog.map(o => ({appName: o.appName, connectionId: o.connectionId, client: o.client, active: o.active}))"
```
Resultado: confirmadas as ligações do `mongodb_exporter`, do `load-mongo.sh` (via gateway Docker `172.18.0.1`), da própria sessão de diagnóstico (`mongosh`), e duas operações internas do servidor sem cliente associado. A soma com os sockets de monitorização/pool do `pymongo` da API Flask explica o total de 8 — nenhuma é um "leak", são exatamente os clientes esperados ligados em simultâneo.

## Passo 2 — Palco da demo

Confirmados os 4 componentes de carga de fundo antes de iniciar:
- `load-postgres.sh` — confirmado via `xact_commit` a subir entre duas leituras
- `load-mongo.sh` — confirmado via `events.countDocuments()` a subir
- API Flask — confirmado via `/health`
- `traffic.ps1` — **não estava a correr** neste ponto da sessão; foi arrancado antes de continuar (`.\scripts\traffic.ps1`)

## Passo 3 — Guião da demo (ensaio)

Percorridos os 5 atos:

- **Ato 1** — estado saudável confirmado (dashboard verde).
- **Ato 2** — `chaos.ps1 connections` disparou o Stat de ligações e o ciclo do alerta; resolvido com `chaos.ps1 resolve`.
- **Ato 3** — `chaos.ps1 slowquery` executado; comportamento validado nas fases anteriores (Kibana + trace no App Insights).
- **Ato 4** — `chaos.ps1 lock`. Ponto de confusão real durante o ensaio: depois do `resolve`, observou-se **commits/s a subir**, o que pareceu inesperado à primeira vista. Esclarecido: essa subida é precisamente a **recuperação em V** que o guia descreve — durante o lock os commits caem a pique (flatline), e depois do `resolve` o `load-postgres.sh` desbloqueia e os commits recuperam a subir. Não foi um problema, foi a confirmação de que o cenário funcionou como esperado — só a ordem de observação (a pergunta surgiu já depois do resolve, não durante o lock) tornou o sintoma ambíguo à primeira leitura.
- **Ato 5** — fecho narrativo.

## ✅ Checkpoint final da Fase 6

- [x] `chaos.ps1` e `chaos.sh` no repositório, os 5 cenários testados isoladamente
- [x] Demo ensaiada de ponta a ponta pelo menos uma vez
- [ ] Os 8 screenshots em `docs/screenshots/` — **pendente**, ver lista em [fase6-guiao-demo.md](fase6-guiao-demo.md)
- [ ] README atualizado com a secção de incident demo + imagens — **pendente**
- [ ] (Opcional) Vídeo/GIF gravado — **pendente**

---

## Pendente / a retomar mais tarde

- **Screenshots reais** — o ensaio confirmou o comportamento de cada cenário, mas as capturas de ecrã (Passo 4.1 do guia) ainda não foram tiradas/guardadas.
- **Secção "Incident demo" no README** — falta adicionar com as imagens depois de capturadas.
- **Vídeo/GIF da demo** — opcional, alto impacto para portfólio.

**Marco:** com a Fase 6 concluída (faltando só os artefactos visuais), o projeto está tecnicamente completo — as 13 skills da lista inicial estão todas cobertas e demonstráveis.
