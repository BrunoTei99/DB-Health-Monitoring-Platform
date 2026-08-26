#!/usr/bin/env bash
# Injeta falhas controladas. Uso: ./chaos.sh {connections|slowquery|lock|resolve|status}
set -euo pipefail
C="lab-postgres"

case "${1:-}" in
  connections)
    echo ">>> A abrir 50 ligacoes penduradas..."
    for i in $(seq 1 50); do
      docker exec -d "$C" psql -U admin -d labdb -c "SELECT pg_sleep(300);"
    done
    echo ">>> Observa o alerta no Grafana. Resolve: ./chaos.sh resolve"
    ;;
  slowquery)
    echo ">>> CROSS JOIN pesado..."
    docker exec "$C" psql -U admin -d labdb -c \
      "SELECT COUNT(*) FROM orders o1 CROSS JOIN orders o2;"
    echo ">>> Pesquisa message:*duration* no Kibana."
    ;;
  lock)
    echo ">>> Lock ACCESS EXCLUSIVE na tabela orders (90s)..."
    docker exec -d "$C" psql -U admin -d labdb -c \
      "BEGIN; LOCK TABLE orders IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(90); COMMIT;"
    echo ">>> Ve os commits/s a cair no Grafana."
    ;;
  resolve)
    echo ">>> A terminar sessoes de chaos..."
    docker exec "$C" psql -U admin -d labdb -c \
      "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
       WHERE (query LIKE '%pg_sleep%' OR query LIKE '%LOCK TABLE%')
         AND pid <> pg_backend_pid();"
    ;;
  status)
    docker exec "$C" psql -U admin -d labdb -c \
      "SELECT pid, state, wait_event_type, LEFT(query,60) AS query,
              now() - query_start AS running_for
       FROM pg_stat_activity WHERE datname='labdb' ORDER BY query_start;"
    ;;
  *)
    echo "Uso: $0 {connections|slowquery|lock|resolve|status}"; exit 1 ;;
esac
