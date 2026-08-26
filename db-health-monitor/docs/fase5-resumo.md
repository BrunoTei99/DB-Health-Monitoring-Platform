# Fase 5 — APM com Application Insights — resumo detalhado

**Objetivo da fase:** uma mini API em Python a falar com PostgreSQL e MongoDB, instrumentada com OpenTelemetry a enviar telemetria para o Azure Application Insights — o terceiro pilar da observabilidade (traces) a fechar o projeto.

**Pré-requisito:** Fases 1–4 concluídas, stack Docker a correr.

Este documento regista o que foi feito, os comandos exatos, os problemas reais encontrados durante a execução (e como foram resolvidos) e os resultados obtidos.

---

## Passo 0 — Preparação do Python

- Python instalado via `winget install Python.Python.3.12` (não estava instalado previamente).

### Problema encontrado — pasta `api/` errada

O guia instrui `cd` para a **raiz do repositório** antes de `mkdir api`. Isto colidiu com a estrutura real do projeto, onde já existia `db-health-monitor/api/app.py` (placeholder da Fase 0, referenciado no `README.md`). O `.venv` foi criado inicialmente em `DB-Health-Monitoring-Platform/api/.venv` (raiz), o local errado.

**Resolução:** o `.venv` foi movido para `db-health-monitor/api/.venv` com `mv`. Isto **partiu os executáveis do venv** (`pip.exe`, etc.) — no Windows, esses launchers têm o caminho absoluto do `python.exe` codificado internamente no próprio `.exe`; mover a pasta não atualiza esse caminho. Sintoma: `Fatal error in launcher: Unable to create process using '...\api\.venv\Scripts\python.exe'`. **Solução real:** apagar o `.venv` movido e recriá-lo do zero já no local correto (`python -m venv .venv` dentro de `db-health-monitor/api`) — mover não é uma opção válida para venvs no Windows, só recriar.

### `requirements.txt`

```
flask==3.0.3
psycopg2-binary==2.9.9
pymongo==4.8.0
azure-monitor-opentelemetry==1.6.1
```

### Problema encontrado — `pkg_resources` / `setuptools`

Ao arrancar a API por instrumentar (`python app.py`):
```
ModuleNotFoundError: No module named 'pkg_resources'
```
Python 3.12+ deixou de incluir `setuptools` (que contém `pkg_resources`) por defeito num venv novo. `pip install setuptools` resolveu — mas instalado numa sessão sem o venv ativo, foi para o Python global, não para o venv correto (o erro persistiu até se confirmar `(.venv)` no prompt e repetir o comando).

**Segundo problema, mais subtil:** a versão mais recente do `setuptools` instalada (**84.0.0**) **removeu completamente** o módulo `pkg_resources` (funcionalidade descontinuada e removida em versões recentes). Resolvido fixando uma versão anterior:
```powershell
pip install "setuptools<81"
```
→ instalou `80.10.2`, que ainda inclui `pkg_resources` (com aviso de depreciação, não erro).

## Passo 1 — Conta Azure e Application Insights

- Conta Azure nova criada em https://azure.microsoft.com/free.

### Problema encontrado — região indisponível

A criação do recurso na região sugerida pelo guia (**West Europe**) falhou:
```
Resource 'appi-db-health-lab' was disallowed by Azure: The selected region is currently not accepting new customers.
```
Restrição comum em contas Azure novas, sem relação com a configuração em si. Resolvido escolhendo outra região disponível para a subscrição (o Log Analytics workspace ficou em `North Europe`, refletido no `IngestionEndpoint` da connection string: `northeurope-2.in.applicationinsights.azure.com`).

- Connection string copiada do Overview do recurso e tratada como segredo (nunca escrita em código nem no Git).

## Passo 2 — Criar a API

`db-health-monitor/api/app.py` criado com os 5 endpoints do guia (`/health`, `/orders/summary`, `/events/summary`, `/slow`, `/error`).

## Passo 3 — Arrancar a API

### Problema encontrado — variável de ambiente perdida entre janelas

`$env:APPLICATIONINSIGHTS_CONNECTION_STRING` só vive na sessão do PowerShell onde é definida. Ao longo da fase, a API acabou a correr, em diferentes momentos, em janelas onde a variável nunca tinha sido definida — sem gerar erro imediato (a app arranca normalmente sem a connection string, só não envia telemetria, silenciosamente). Isto só foi detetado mais tarde, na investigação do Passo 5.

### Problema encontrado — processo morto sem aviso

A determinado ponto, a API deixou de responder sem nenhum sinal óbvio na janela onde tinha sido arrancada. Diagnóstico:
```powershell
netstat -ano | grep "8000"          # nenhuma linha LISTENING, só um SYN_SENT pendurado
tasklist | findstr /I python        # nenhum processo Python a correr
```
Confirmado que o processo simplesmente tinha morrido (a janela original tinha sido interrompida com `Ctrl+C` e não reaberta corretamente).

**Solução final adotada:** arrancar a API de forma controlada, em background, com a connection string explicitamente definida na mesma invocação:
```powershell
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = "<connection-string>"
Start-Process -FilePath ".\.venv\Scripts\python.exe" -ArgumentList "app.py" `
  -WorkingDirectory "...\db-health-monitor\api" -WindowStyle Hidden `
  -RedirectStandardOutput "app_stdout.log" -RedirectStandardError "app_stderr.log"
```
Isto elimina a ambiguidade de "em que janela é que isto está a correr, com que variáveis" — os logs ficam num ficheiro inspecionável independentemente da sessão de terminal.

Smoke test (`/health`, `/orders/summary`, `/events/summary`, `/slow`) confirmado OK.

## Passo 4 — Tráfego contínuo

`db-health-monitor/scripts/traffic.ps1` criado com a lista ponderada de endpoints (5:4:1:1 — orders/summary, events/summary, slow, error). **Porquê a ponderação:** num sistema real, os endpoints lentos/com falhas são a minoria; esta proporção faz o Application Map e os percentis parecerem-se com produção a sério — material mais realista para o portfólio do que uma distribuição uniforme. O script sobreviveu sem problemas a dois reinícios da API (o `try/catch` em volta de `Invoke-WebRequest` trata os `ERRO` como esperado, não faz o script parar).

## Passo 5 — Explorar no Application Insights

### Problema encontrado — Application Map vazio; Requests e Dependencies a zero

Depois de ~280 pedidos, o **Application Map** mostrava "Não existem dados disponíveis". Investigação em **Investigate → Pesquisar** (Search) revelou que **havia** telemetria a chegar (979 Trace, 72 Exception), mas **0 Request e 0 Dependency** — ou seja, os logs de acesso do Werkzeug estavam a ser capturados como texto simples, mas nenhuma instrumentação estruturada (spans de Flask/psycopg2/pymongo) estava ativa.

**Causa 1 — versão desatualizada e mecanismo de descoberta de instrumentadores.** O `azure-monitor-opentelemetry==1.6.1` pinado pelo guia usa `pkg_resources.iter_entry_points` para descobrir automaticamente que instrumentadores (Flask, psycopg2, pymongo) ativar — o mesmo mecanismo afetado pela saga do `pkg_resources`/`setuptools` do Passo 0. Atualizado para a versão mais recente disponível:
```powershell
pip install --upgrade azure-monitor-opentelemetry   # 1.6.1 -> 1.8.9
```

**Causa 2 — `opentelemetry-instrumentation-pymongo` nem estava instalado.** Confirmado via `pip list` que este pacote específico estava ausente do conjunto de dependências trazidas pela distro Azure — instalado manualmente. Isto introduziu um conflito de versões entre sub-pacotes (`opentelemetry-semantic-conventions` 0.65b0 vs. 0.64b0 exigido pelo SDK), resolvido reinstalando `azure-monitor-opentelemetry` e `opentelemetry-instrumentation-pymongo` **na mesma invocação do pip**, para o resolver de dependências escolher versões mutuamente compatíveis de uma só vez.

Depois desta correção, o Application Map já mostrava **PostgreSQL** como dependência (161+ chamadas), mas **MongoDB continuava ausente** e o nó da própria aplicação continuava com **0 Request**.

**Causa 3 — descoberta automática incompleta para Flask e PyMongo.** Mesmo com os pacotes corretos instalados e compatíveis, a auto-instrumentação da distro não os estava a ativar neste ambiente. Solução: instrumentar **explicitamente** no código, em vez de confiar só no `configure_azure_monitor()`:
```python
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.pymongo import PymongoInstrumentor

configure_azure_monitor()
PymongoInstrumentor().instrument()

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)
```

Depois desta alteração e reinício da API: **Application Map completo** — app com 2 instâncias, 8 chamadas (13% de falha, como esperado do `/error`), seta para PostgreSQL (487 chamadas) e seta para MongoDB (54 chamadas).

`requirements.txt` final:
```
flask==3.0.3
psycopg2-binary==2.9.9
pymongo==4.8.0
azure-monitor-opentelemetry==1.8.9
opentelemetry-instrumentation-pymongo==0.64b0
setuptools<81
```

### 5.2 — Performance

`GET /slow` destacado com **2,25s** de duração média (vs. milissegundos dos outros endpoints). Drill-down num trace individual confirmou visualmente que a dependência PostgreSQL (`SELECT ... pg_sleep`) ocupa praticamente os mesmos 2,6s do request total — a demonstração exata do valor do APM: "o endpoint é lento porque a dependência SQL é lenta", visível numa única transação ponta a ponta.

### 5.3 — Failures

`GET /error` capturado com `ValueError`, stack trace completo, código de resposta 500.

### 5.4 — Live Metrics

Primeira tentativa: **"Não disponível: não foi possível estabelecer ligação à sua aplicação"**. O Live Metrics usa um canal de ligação separado (QuickPulse), distinto do pipeline de ingestão normal, e demorou mais a estabelecer-se. Ao fim de mais um minuto, funcionou normalmente — visível em tempo real, incluindo a dependência `labdb.aggregate` (MongoDB) no feed ao vivo.

## ✅ Checkpoint final da Fase 5

- [x] API a correr localmente com os 5 endpoints a responder
- [x] `traffic.ps1` gerou bem mais de 500 pedidos (ultrapassou os 900 durante a fase)
- [x] Application Map mostra a app + 2 dependências (PostgreSQL e MongoDB)
- [x] Em Performance, `GET /slow` destaca-se (~2,25-2,6s) e o trace mostra a query SQL como causa
- [x] Em Failures, a `ValueError` do `/error` aparece com stack trace
- [x] Live Metrics confirmado em tempo real (depois de um atraso inicial de ligação)

---

## Pendente / a retomar mais tarde

- **Nome do serviço aparece como `unknown_service`** no Application Map, em vez de um nome reconhecível (ex. `db-health-api`). Não é um erro — é só a ausência do atributo de recurso `service.name` do OpenTelemetry. Corrigível definindo `OTEL_SERVICE_NAME=db-health-api` como variável de ambiente antes de arrancar a API.
- **Bónus KQL (Passo 5.5)** — a query de exemplo (`requests | summarize count(), avg(duration) by name`) não foi corrida explicitamente; Performance já mostrou a mesma informação por UI. Fica como exercício opcional.
- **Ficheiros `app_stdout.log` / `app_stderr.log` / `traffic_stdout.log`** — criados na raiz do `db-health-monitor/` e `api/` para depuração desta fase; considerar adicioná-los ao `.gitignore` (não fazem sentido versionados).
- **Alternativa Dynatrace** (secção opcional do guia) — não explorada nesta fase; documentada no guia original para quem quiser acrescentar a comparação *agent-based vs SDK-based instrumentation* ao portfólio.

**Próximo passo:** Fase 6 — o guião da demo de chaos que junta as 5 fases numa história única: alerta no Grafana → logs no Kibana → trace no App Insights → resolução.
