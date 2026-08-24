#!/usr/bin/env bash
# =============================================================
# load-mongo.sh — gera carga continua no MongoDB
# Uso: ./load-mongo.sh [intervalo_segundos]  (default: 0.5)
# =============================================================
set -euo pipefail

INTERVAL="${1:-0.5}"
CONTAINER="lab-mongodb"
ITER=0

echo "[$(date '+%H:%M:%S')] A iniciar carga no MongoDB (intervalo: ${INTERVAL}s). Ctrl+C para parar."
trap 'echo; echo "[$(date "+%H:%M:%S")] Carga parada. Total: $ITER iteracoes"; exit 0' INT

while true; do
  ITER=$((ITER + 1))

  docker exec "$CONTAINER" mongosh --quiet --eval '
    const db2 = db.getSiblingDB("labdb");

    db2.events.insertOne({
      type:   ["login","click","purchase","logout"][Math.floor(Math.random()*4)],
      userId: Math.floor(Math.random()*1000),
      value:  Math.round(Math.random()*100 * 100) / 100,
      ts:     new Date()
    });

    if (Math.random() < 0.10) {
      db2.events.aggregate([
        { $match: { ts: { $gte: new Date(Date.now() - 5*60*1000) } } },
        { $group: { _id: "$type", total: { $sum: 1 }, avgValue: { $avg: "$value" } } },
        { $sort:  { total: -1 } }
      ]).toArray();
    }

    if (Math.random() < 0.05) {
      db2.events.find({ userId: { $lt: 100 } }).sort({ ts: -1 }).limit(20).toArray();
    }
  ' > /dev/null

  if (( ITER % 20 == 0 )); then
    echo "[$(date '+%H:%M:%S')] iter=$ITER"
  fi

  sleep "$INTERVAL"
done