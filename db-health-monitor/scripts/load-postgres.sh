#!/usr/bin/env bash
# =============================================================
# load-postgres.sh — gera carga continua no PostgreSQL
# Uso: ./load-postgres.sh [intervalo_segundos]  (default: 0.5)
# Parar: Ctrl+C
# =============================================================
set -euo pipefail

INTERVAL="${1:-0.5}"
CONTAINER="lab-postgres"
ITER=0

echo "[$(date '+%H:%M:%S')] A iniciar carga no PostgreSQL (intervalo: ${INTERVAL}s). Ctrl+C para parar."

# Ctrl+C termina com uma mensagem em vez de um erro feio
trap 'echo; echo "[$(date "+%H:%M:%S")] Carga parada. Total de iteracoes: $ITER"; exit 0' INT

while true; do
  ITER=$((ITER + 1))
  customer=$((RANDOM % 1000))
  amount="$((RANDOM % 500)).$((RANDOM % 90 + 10))"

  # INSERT normal — o "grosso" da carga
  docker exec "$CONTAINER" psql -U admin -d labdb -q -c \
    "INSERT INTO orders (customer_id, amount, status)
     VALUES ($customer, $amount,
             (ARRAY['pending','paid','cancelled'])[floor(random()*3)+1]);"

  # A cada ~10 iteracoes: agregacao (query mais pesada)
  if (( ITER % 10 == 0 )); then
    docker exec "$CONTAINER" psql -U admin -d labdb -q -c \
      "SELECT status, COUNT(*) AS n, ROUND(AVG(amount),2) AS avg_amount
       FROM orders GROUP BY status;" > /dev/null
    echo "[$(date '+%H:%M:%S')] iter=$ITER — agregacao executada"
  fi

  # A cada ~50 iteracoes: UPDATE em lote (gera mais WAL/commits)
  if (( ITER % 50 == 0 )); then
    docker exec "$CONTAINER" psql -U admin -d labdb -q -c \
      "UPDATE orders SET status='paid'
       WHERE status='pending' AND id IN
         (SELECT id FROM orders WHERE status='pending' LIMIT 20);"
    echo "[$(date '+%H:%M:%S')] iter=$ITER — update em lote"
  fi

  sleep "$INTERVAL"
done
