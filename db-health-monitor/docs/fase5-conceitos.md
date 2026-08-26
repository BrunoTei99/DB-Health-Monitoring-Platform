# Fase 5 — Conceitos técnicos e teóricos

Este documento explica os conceitos por trás das ferramentas e decisões da Fase 5, complementando o "como fazer" em [fase5-resumo.md](fase5-resumo.md). Ver também [fase4-conceitos.md](fase4-conceitos.md) — a arquitetura de logs (Filebeat/Elasticsearch/Kibana) segue o mesmo espírito de "camadas independentes" que se aplica aqui a traces.

---

## 1. O terceiro pilar: traces, e como fecha o ciclo com métricas e logs

As Fases 1–3 deram **métricas** (Prometheus + Grafana): números agregados ao longo do tempo — "quantas ligações agora?", "qual a taxa de commits?". A Fase 4 deu **logs** (Filebeat + Elasticsearch + Kibana): texto livre, pesquisável, associado a um instante — "o que aconteceu exatamente às 11:32:57?". Esta fase dá **traces**: a árvore de chamadas de **uma única transação**, do pedido HTTP que entra até cada chamada de base de dados que esse pedido despoletou, com duração exata de cada etapa.

A diferença qualitativa é esta: uma métrica diz-te *que* algo está lento (commits/s a cair); um log diz-te *o quê* aconteceu (uma query específica demorou 8s); um trace diz-te *a estrutura causal exata* — este pedido HTTP específico, chamado por este cliente, a esta hora, gastou 2,6 dos seus 2,6 segundos numa única chamada SQL. É o nível de detalhe que permite passar de "suspeito que é a base de dados" para "confirmado, é esta query, neste pedido, com esta duração exata" — sem inferência, com prova.

**Como se encaixa no resto da solução:** ao contrário das Fases 3–4 (que alimentam o mesmo Grafana), esta fase usa uma ferramenta cloud separada (Application Insights) porque traces distribuídos exigem infraestrutura de correlação (IDs de operação propagados entre chamadas) que o stack local (Prometheus/Elasticsearch) não foi montado para fazer. Continua a ser o mesmo objetivo de observabilidade, só que com uma ferramenta especializada nesse pilar específico — tal como o Kibana é especializado em logs e o Grafana em métricas.

## 2. "Distros" de OpenTelemetry e o modelo de auto-instrumentação

O `azure-monitor-opentelemetry` é uma **distro**: um pacote que embrulha o SDK genérico do OpenTelemetry (que, por si só, não faz nada útil sem configuração manual extensa) com defaults sensatos e um exportador pré-configurado para um destino específico (Application Insights). A promessa da distro é "duas linhas e o resto é automático" — mas essa automação depende de um mecanismo de **descoberta de instrumentadores**: para cada biblioteca instalada no ambiente (Flask, psycopg2, pymongo, requests, ...), existe um pacote satélite (`opentelemetry-instrumentation-<lib>`) que sabe como "interceptar" essa biblioteca e transformar as suas chamadas em spans OpenTelemetry.

Esta fase revelou os dois modos como isso pode falhar:

1. **O pacote satélite nem está instalado** — `opentelemetry-instrumentation-pymongo` estava simplesmente ausente do conjunto de dependências que a distro (`azure-monitor-opentelemetry==1.6.1`) trazia consigo. A distro não instala automaticamente instrumentadores para *toda* a biblioteca imaginável — só para as que os seus autores decidiram incluir como dependência direta nessa versão.
2. **O pacote está instalado, mas a descoberta automática não o ativa** — mesmo depois de instalado e com versões compatíveis, Flask e PyMongo continuaram sem gerar spans. A distro usa (nesta versão) `pkg_resources.iter_entry_points` para enumerar instrumentadores disponíveis via *entry points* — um mecanismo de plugins do ecossistema Python que pode falhar silenciosamente a encontrar tudo o que devia, especialmente numa altura de transição do próprio ecossistema de empacotamento (ver secção 4).

**A lição prática, generalizável:** "instalei o pacote de instrumentação" e "a instrumentação está ativa" são afirmações diferentes, e só a segunda importa. Quando a descoberta automática é opaca (não dá erro, só fica em silêncio), a solução robusta é **instrumentar explicitamente**:
```python
FlaskInstrumentor().instrument_app(app)
PymongoInstrumentor().instrument()
```
Isto não depende de nenhum mecanismo de descoberta — chama-se diretamente a classe do instrumentador e o próprio código garante que está ativo. Menos "mágico", mais previsível.

## 3. Trace, Log e Exception: três canais de telemetria com fiabilidade diferente

Um sintoma central desta fase foi ver **Trace (979)** e **Exception (72)** a fluir normalmente para o Application Insights, enquanto **Request (0)** e **Dependency (0)** ficavam vazios — apesar de vir tudo da mesma aplicação, ao mesmo tempo. A explicação está em **como** cada tipo de telemetria chega lá:

- **Trace** (nesta distro, também usado para capturar registos do módulo `logging` do Python) é alimentado por um *handler* de logging que a distro regista globalmente — funciona independentemente de qualquer instrumentador de biblioteca específica, porque intercepta ao nível do `logging` do Python, não da biblioteca Flask/Werkzeug em si. Foi por isto que as linhas de acesso do Werkzeug (`"GET /events/summary HTTP/1.1" 200`) apareceram sempre, mesmo sem o `FlaskInstrumentor` ativo.
- **Exception** é capturado de forma semelhante — um hook global de exceções não depende de instrumentação por biblioteca.
- **Request** e **Dependency**, pelo contrário, só existem se o instrumentador *específico* dessa biblioteca (Flask para Request; psycopg2/pymongo para Dependency) estiver mesmo a interceptar as chamadas e a criar spans estruturados. Sem isso, não há dados nenhuns — nem incompletos, simplesmente zero.

Isto explica por que a ausência de dados estruturados não gerou nenhum erro visível: os canais "genéricos" (logging, exceções) continuaram a funcionar perfeitamente, mascarando a falha dos canais "específicos" (spans de request/dependency), que exigem uma peça de instrumentação adicional a funcionar corretamente.

## 4. `pkg_resources`, `setuptools` e a transição do empacotamento Python

O ecossistema Python está a afastar-se de `pkg_resources` (parte do `setuptools`, usado historicamente para descobrir plugins/metadados de pacotes instalados) a favor de `importlib.metadata` (parte da biblioteca padrão desde o Python 3.8+, sem dependências externas). `pkg_resources` está formalmente marcado para remoção; versões recentes do `setuptools` (≥ 81, culminando na 84 usada nesta fase) já o removeram por completo.

Isto cria uma **janela de incompatibilidade transitória**: bibliotecas mais antigas que ainda fazem `from pkg_resources import iter_entry_points` (como o `azure-monitor-opentelemetry==1.6.1` desta fase) partem-se com um `setuptools` demasiado recente, mas funcionam com um mais antigo (com aviso de depreciação, não erro). A solução de curto prazo (fixar `setuptools<81`) é um paliativo explícito, documentado como tal — a solução de longo prazo é a própria biblioteca (`azure-monitor-opentelemetry`) deixar de depender de `pkg_resources`, o que a versão mais recente (1.8.9) já faz (confirmado: nenhum aviso de depreciação depois da atualização).

## 5. Venvs no Windows não são portáteis por simples cópia/movimento

Um ambiente virtual Python (`venv`) no Windows contém, dentro de `Scripts/`, pequenos executáveis (`pip.exe`, `python.exe` como link/cópia) cujo mecanismo de arranque tem, codificado dentro do próprio ficheiro binário, o caminho absoluto para o interpretador Python que o criou. Mover a pasta do venv (`mv .venv /novo/sitio`) não atualiza esse caminho — os executáveis continuam a apontar para o sítio antigo, resultando em `Fatal error in launcher: Unable to create process using '<caminho-antigo>'`.

Isto contrasta com convenções de outros ecossistemas onde mover uma pasta de dependências é seguro (ex. `node_modules` normalmente não tem caminhos absolutos codificados). A única solução correta para "mover" um venv é **recriá-lo do zero** no destino final (`python -m venv .venv`) e reinstalar as dependências — nunca copiar/mover a pasta existente.

## 6. Regiões cloud podem rejeitar novas subscrições, independentemente da configuração

O erro `The selected region is currently not accepting new customers` não é um erro de configuração — é uma política operacional da cloud (Azure, neste caso), que por vezes restringe a criação de recursos novos em regiões específicas para contas recém-criadas (gestão de capacidade, medidas antifraude, etc.). A "correção" não está em ajustar nenhum parâmetro do recurso, mas simplesmente em escolher outra região disponível para essa subscrição em particular. É um bom exemplo de uma classe de erros que nenhuma quantidade de leitura de documentação técnica resolve — só tentativa de outra opção válida.

## 7. Cloud role name e a rotulagem de telemetria por serviço

O OpenTelemetry usa **atributos de recurso** (resource attributes) para descrever *quem* gerou um determinado span/log/métrica — o mais importante sendo `service.name`. O Application Insights usa esse atributo para rotular os nós no Application Map. Quando não está definido, cai para um valor genérico (`unknown_service`) — que continua a funcionar (os dados não se perdem, as dependências continuam corretas), só fica menos legível num ambiente com múltiplos serviços. Definir `OTEL_SERVICE_NAME=<nome>` como variável de ambiente é a forma padrão de resolver isto sem alterar código.

## 8. QuickPulse (Live Metrics) como canal de telemetria separado

O Live Metrics do Application Insights não reutiliza o mesmo caminho de ingestão da restante telemetria (que passa por batching e tem alguma latência, 1-3 minutos) — usa um protocolo dedicado (QuickPulse) otimizado para latência de segundos, com a sua própria negociação de ligação. Isto explica por que o "Não foi possível estabelecer ligação" inicial não significava que a telemetria normal estivesse a falhar (já estava a chegar perfeitamente, confirmado via Search) — era só este canal específico, mais exigente em termos de handshake, ainda a estabilizar.

## 9. Tráfego sintético ponderado — por que a distribuição importa

O `traffic.ps1` usa uma distribuição ponderada (5 pedidos normais : 4 pedidos normais : 1 lento : 1 com erro) em vez de escolher endpoints com igual probabilidade. Isto não é só estética — reflete um princípio real de engenharia de tráfego para demonstrações de observabilidade: em produção, os casos "interessantes" (lentidão, erros) são tipicamente uma **minoria** do volume total. Uma distribuição uniforme faria os percentis (P95, P99) e o Application Map parecerem artificialmente dominados por problemas, distorcendo a leitura do que é "normal" vs. "excecional" — exatamente o oposto do que se quer mostrar num portfólio, onde o objetivo é demonstrar a capacidade de **encontrar a agulha no palheiro**, não um palheiro feito só de agulhas.

## 10. Uma transação ponta-a-ponta é uma árvore de spans, não uma lista de eventos

O ecrã de "Detalhes da transação ponto a ponto" (visto no drill-down do `GET /slow`) não é uma lista cronológica solta — é uma **árvore**: o span do `Request` (`GET /slow`) é o pai, e o span da `Dependency` (`SELECT ... pg_sleep`) é o filho, correlacionado através do mesmo `operation ID`. É esta relação pai-filho, propagada automaticamente pelos instrumentadores dentro do mesmo processo (e, em sistemas distribuídos reais, entre processos via cabeçalhos HTTP como `traceparent`), que permite ao Application Insights desenhar a barra do request e a barra da dependência uma dentro/ao lado da outra, e concluir visualmente "quase todo o tempo do pedido foi gasto dentro desta chamada específica" — o mecanismo central por trás de qualquer ferramenta de distributed tracing.

---

**Ver também:** [fase5-resumo.md](fase5-resumo.md) — comandos, resultados e troubleshooting real desta fase.
