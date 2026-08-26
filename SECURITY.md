# Segurança — estado conhecido e plano de correção

Este é um laboratório local de observabilidade, construído para fins de aprendizagem/portfólio — **não é um sistema em produção**. Ainda assim, fez-se uma auto-revisão de segurança ao código, e os pontos abaixo são conhecidos e têm correção planeada. Nenhum deles expõe dados reais (todas as bases de dados só contêm dados sintéticos gerados pelos próprios scripts do lab).

## Falhas conhecidas

- [ ] **MongoDB sem autenticação** — o serviço `mongodb` corre sem `--auth` nem utilizador/password definidos (`db-health-monitor/docker-compose.yml`). Qualquer cliente com acesso de rede à porta 27017 tem acesso total de leitura/escrita.
  **Correção planeada:** definir `MONGO_INITDB_ROOT_USERNAME`/`MONGO_INITDB_ROOT_PASSWORD` via variável de ambiente (não commitada).

- [ ] **Elasticsearch e Kibana sem autenticação** — `xpack.security.enabled=false` desliga toda a autenticação do Elasticsearch; o Kibana herda esse estado. Qualquer cliente com acesso à porta 9200/5601 tem acesso total aos logs indexados.
  **Correção planeada:** ativar `xpack.security.enabled=true` com credenciais via variável de ambiente.

- [ ] **Password do PostgreSQL fraca e hardcoded** — `POSTGRES_PASSWORD: admin123` está escrita diretamente no `docker-compose.yml` e repetida no `DATA_SOURCE_NAME` do exporter e em `api/app.py`.
  **Correção planeada:** mover para uma variável de ambiente lida de um ficheiro `.env` não commitado (já previsto no `.gitignore`).

- [ ] **Password de admin do Grafana fraca e hardcoded** — `GF_SECURITY_ADMIN_PASSWORD: admin` está escrita diretamente no `docker-compose.yml`.
  **Correção planeada:** mesma abordagem — variável de ambiente não commitada.

- [ ] **Todos os serviços publicados em `0.0.0.0` em vez de `127.0.0.1`** — as portas no `docker-compose.yml` (5432, 27017, 9090, 3000, 9200, 5601, 9187, 9216) usam a sintaxe curta `"PORTA:PORTA"`, que o Docker publica em todas as interfaces de rede do host, não só em `localhost`. Combinado com os pontos acima, isto significa que os serviços ficam acessíveis a partir de qualquer máquina na mesma rede (LAN/VPN), não só da própria máquina.
  **Correção planeada:** mudar para `"127.0.0.1:PORTA:PORTA"` em todos os serviços que não precisem de ser acedidos de fora da máquina.

- [ ] **Filebeat com acesso ao socket do Docker** — `/var/run/docker.sock` está montado (mesmo que `:ro`) no container do Filebeat, para enriquecimento de metadados de containers. O `:ro` só impede escrever no ficheiro do socket, não restringe a API do Docker Engine acessível através dele — se o container do Filebeat for comprometido por qualquer outra via, esse acesso pode ser usado para escalar para root no host.
  **Correção planeada:** avaliar um proxy de socket com API restrita (ex. `tecnativa/docker-socket-proxy`), ou aceitar o risco conscientemente dado tratar-se de um ambiente local de curta duração.

## Contexto

Estas configurações foram escolhidas deliberadamente para simplificar o arranque de um lab local (sem passos extra de configuração de credenciais antes do primeiro `docker compose up`). Antes de expor esta stack a qualquer rede partilhada, ou de a usar como base para algo real, os pontos acima devem ser corrigidos primeiro.

## Nota

Não há dados sensíveis reais neste repositório — apenas dados sintéticos gerados pelos scripts de carga (`scripts/load-postgres.sh`, `scripts/load-mongo.sh`) para fins de demonstração.
