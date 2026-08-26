# Fase 6 — Conceitos técnicos e teóricos

Este documento explica os conceitos por trás dos cenários de chaos e da narrativa de demo desta fase, complementando o "como fazer" em [fase6-resumo.md](fase6-resumo.md) e o guião pronto em [fase6-guiao-demo.md](fase6-guiao-demo.md).

---

## 1. Chaos engineering em miniatura: falhas injetadas de propósito, não simuladas

Os três cenários desta fase não são "mocks" nem dados falsos — são **efeitos colaterais reais** de comandos SQL genuínos (`pg_sleep`, `LOCK TABLE`, um `CROSS JOIN` combinatoriamente caro) correndo contra o PostgreSQL real do lab. Isto é a essência do *chaos engineering*: em vez de esperar que um incidente aconteça sozinho (o que pode nunca acontecer num ambiente de demo/lab), injeta-se deliberadamente uma condição adversa controlada, com um início e um fim conhecidos, para observar e validar que os sistemas de deteção (alertas, logs, traces) reagem como esperado. A diferença entre isto e "estragar o sistema a sério" é o controlo: cada cenário tem um mecanismo de resolução explícito (`resolve`, ou um timeout automático de 90s no caso do `lock`), nunca deixando o lab num estado permanentemente danificado.

## 2. "Muitas ligações ≠ muita carga": a distinção que o cenário `connections` ensina

O cenário `connections` abre 50 sessões que fazem literalmente nada (`pg_sleep`) — CPU e I/O do PostgreSQL continuam perto de zero. No entanto, o **número de ligações ativas** dispara, e é só *esse* recurso que fica esgotado. Isto ilustra uma distinção fundamental em capacidade de bases de dados: **ligações** e **capacidade de processamento** são recursos independentes. Um pool de ligações mal configurado, ou uma aplicação que não devolve ligações ao pool (um "connection leak"), pode esgotar o limite de `max_connections` do PostgreSQL sem que a base de dados esteja sequer ocupada — e nesse estado, *qualquer* nova ligação (incluindo a de um health-check ou de um utilizador legítimo) é rejeitada, apesar de o servidor estar, na prática, ocioso. Saber ler um dashboard e reconhecer "isto é esgotamento de ligações, não sobrecarga de trabalho" é o tipo de leitura que distingue diagnóstico causal de reação a cores.

## 3. `idle in transaction`: o estado que aparece quando uma transação fica pendurada

Uma sessão a correr `SELECT pg_sleep(300)` **dentro de uma transação aberta** (mesmo implícita, no caso de uma única statement) aparece no `pg_stat_activity` com um estado específico — tipicamente `idle in transaction` ou `active`, dependendo do momento exato do sleep. Este estado é distinto de uma ligação genuinamente `idle` (sem transação aberta): uma transação pendurada mantém locks e recursos internos (como snapshots do MVCC do PostgreSQL) que uma ligação simplesmente ociosa não mantém. É por isso que sessões `idle in transaction` de longa duração são consideradas um problema operacional sério em PostgreSQL real — não é só "uma ligação a mais", é uma transação que pode estar a impedir o `VACUUM` de limpar linhas antigas, entre outros efeitos.

## 4. `ACCESS EXCLUSIVE`: o lock mais restritivo do PostgreSQL

O PostgreSQL tem uma hierarquia de modos de lock a nível de tabela, do menos ao mais restritivo. `ACCESS EXCLUSIVE` é o topo dessa hierarquia: é incompatível com **qualquer outro lock**, incluindo os locks implícitos e leves que uma simples leitura (`SELECT`) adquire. Isto significa que, enquanto uma transação detém este lock sobre `orders`, não só os `INSERT`/`UPDATE` ficam bloqueados (esperado), como até `SELECT`s simples da mesma tabela ficam à espera. É o equivalente, em bases de dados, a colocar um cadeado físico na porta de um armazém — ninguém entra, nem para olhar, até a operação que motivou o lock terminar (`COMMIT` ou `ROLLBACK`). Operações que precisam desta garantia mais forte no mundo real incluem `ALTER TABLE`, certas migrações de schema, ou `TRUNCATE` — daí ser um cenário realista de "incidente causado por uma operação de manutenção mal cronometrada".

## 5. `wait_event_type = Lock`: a diferença entre "ocupado" e "à espera"

Uma sessão PostgreSQL pode estar `active` (a fazer trabalho real: CPU, I/O) ou `active` mas **bloqueada à espera de um lock** que outra sessão detém — o `pg_stat_activity.wait_event_type` distingue estes dois casos. Uma sessão com `wait_event_type = Lock` não está lenta por estar a processar muito; está parada, à espera que outra sessão (a que detém o `ACCESS EXCLUSIVE`) liberte o recurso. Esta é exatamente a informação que faltava ao painel de métricas (que só mostra "commits/s a zero", o sintoma) e que só a introspecção direta à base de dados fornece (a causa). É o mesmo padrão de "camadas de diagnóstico" já visto nas Fases 3-5: uma métrica dispara a atenção, mas confirmar a causa exige descer um nível.

## 6. O padrão "flatline → recuperação em V" como assinatura visual de um incidente resolvido

Um gráfico de taxa (`rate(...)`) que cai a pique e depois recupera abruptamente desenha uma forma reconhecível — a "recuperação em V". Esta assinatura visual conta uma história específica: o sistema não degradou gradualmente (o que produziria uma curva suave), foi **bloqueado por completo** durante um intervalo definido e depois **desbloqueado instantaneamente**. Reconhecer este padrão é útil operacionalmente: distingue um incidente de contenção/lock (recuperação em V, uma vez removido o obstáculo) de um incidente de degradação de recursos (recuperação gradual, à medida que a pressão sobre CPU/memória/disco diminui). Foi exatamente esta forma que gerou a pergunta real durante o ensaio desta fase — "porque é que os commits estão a subir?" — cuja resposta foi "porque estás a ver a perna ascendente do V, não um problema novo".

## 7. Por que o CROSS JOIN é um bom "vilão" para a demo de logs/traces

`SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2` produz um produto cartesiano: com N linhas em `orders`, o resultado intermédio tem N² combinações antes do `COUNT`. Com a tabela a crescer ao longo das fases anteriores (populada pelos load scripts), isto passa de instantâneo (tabela pequena) a vários segundos (tabela com milhares de linhas) sem precisar de nenhum artifício como `pg_sleep` — é uma lentidão "real", causada por uma escolha de query genuinamente cara, o tipo de erro que acontece em produção quando alguém escreve um JOIN sem pensar na cardinalidade resultante. É por isso que serve melhor como demonstração do pipeline de logs/traces do que um `pg_sleep` explícito: mostra o sistema a capturar uma lentidão *organicamente* gerada, não artificialmente cronometrada.

## 8. A narrativa "métricas → o quê; logs → qual; traces → onde" como resumo do projeto inteiro

Os três incidentes desta fase foram escolhidos deliberadamente para mapear, um a um, aos três pilares:

- **Incidente 1 (ligações)** é detetado por uma **métrica** e um **alerta** — sabes *que* há um problema de recursos, sem precisares de olhar para nenhum log ou trace.
- **Incidente 2 (query lenta)** é detetado por um **log** — sabes *qual* SQL específico foi lento e *quanto* tempo demorou, informação que a métrica agregada (commits/s) nunca teria dado sozinha.
- Esse mesmo incidente, visto do lado da aplicação, é confirmado por um **trace** — sabes *onde* exatamente (dentro de qual dependência, com que peso relativo) o tempo foi gasto num pedido específico.
- **Incidente 3 (lock)** combina os dois primeiros pilares: a métrica mostra o sintoma (flatline), e uma introspecção direta (`pg_stat_activity`) — o equivalente, aqui, ao "log" de diagnóstico — mostra a causa.

Esta frase-resumo (*"métricas dizem-me que, logs dizem-me qual, traces dizem-me onde"*) não é só retórica de apresentação — é a justificação de engenharia para ter as três camadas simultaneamente: cada uma responde a uma pergunta que as outras não respondem, e é a combinação das três, não qualquer uma isolada, que permite fechar um incidente real do sintoma à causa raiz sem adivinhar.

---

**Ver também:** [fase6-resumo.md](fase6-resumo.md) — o que foi feito nesta fase, e [fase6-guiao-demo.md](fase6-guiao-demo.md) — o guião pronto para apresentar.
