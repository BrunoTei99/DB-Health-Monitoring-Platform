import os
import random

from flask import Flask, jsonify
import psycopg2
from pymongo import MongoClient

# ---- Instrumentacao: configure_azure_monitor cobre psycopg2/dbapi automaticamente;
# Flask e pymongo precisaram de instrumentacao explicita nesta versao da distro ----
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.pymongo import PymongoInstrumentor

configure_azure_monitor()  # le APPLICATIONINSIGHTS_CONNECTION_STRING do ambiente
PymongoInstrumentor().instrument()

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

PG_DSN = os.environ.get(
    "PG_DSN", "postgresql://admin:admin123@localhost:5432/labdb"
)
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://localhost:27017")

mongo = MongoClient(MONGO_URI)


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/orders/summary")
def orders_summary():
    """Agregacao SQL - aparece como dependencia PostgreSQL no App Insights."""
    conn = psycopg2.connect(PG_DSN)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT status, COUNT(*), ROUND(AVG(amount), 2) "
                "FROM orders GROUP BY status;"
            )
            rows = cur.fetchall()
    finally:
        conn.close()
    return jsonify(
        {status: {"count": count, "avg": float(avg)} for status, count, avg in rows}
    )


@app.route("/events/summary")
def events_summary():
    """Pipeline NoSQL - aparece como dependencia MongoDB no App Insights."""
    pipeline = [
        {"$group": {"_id": "$type", "total": {"$sum": 1}}},
        {"$sort": {"total": -1}},
    ]
    result = list(mongo.labdb.events.aggregate(pipeline))
    return jsonify(result)


@app.route("/slow")
def slow():
    """Endpoint propositadamente lento - a estrela dos traces."""
    delay = round(random.uniform(1.5, 3.0), 2)
    conn = psycopg2.connect(PG_DSN)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT pg_sleep(%s);", (delay,))
    finally:
        conn.close()
    return jsonify({"ok": True, "delayed_seconds": delay})


@app.route("/error")
def error():
    """Endpoint que falha ~50% das vezes - para ver excecoes no App Insights."""
    if random.random() < 0.5:
        raise ValueError("Falha simulada para demonstrar tracking de excecoes")
    return jsonify({"ok": True})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000)



