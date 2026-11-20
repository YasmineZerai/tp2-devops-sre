"""catalog-api : microservice REST de catalogue produit (TP2 DevOps Avancé).

Endpoints :
- GET  /health              : sonde de vie
- GET  /products            : liste des produits
- GET  /products/{id}       : un produit (404 si inconnu)
- POST /checkout            : traitement volontairement lent (latence simulée)
- GET  /flaky               : erreurs 503 intermittentes (taux configurable)
- GET  /metrics             : métriques au format Prometheus
"""

import asyncio
import logging
import os
import random
import time

from fastapi import FastAPI, HTTPException, Request, Response
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, Field

from app.telemetry import setup_telemetry

logger = logging.getLogger("catalog-api")
tracer = trace.get_tracer("catalog-api")

app = FastAPI(title="catalog-api", version="1.1.0")
setup_telemetry(app)  # traces OTLP -> Tempo, metriques OTel, logs JSON avec trace_id

# --- Métriques Prometheus (méthode RED) -------------------------------------
# Le bucket 0.2 s correspond exactement au seuil du SLO de latence (p95 <= 200 ms).
REQUESTS = Counter(
    "http_requests_total",
    "Nombre total de requêtes HTTP",
    ["method", "route", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "Durée des requêtes HTTP en secondes",
    ["method", "route"],
    buckets=(0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0),
)

# --- Paramètres de simulation (surchargeables par variables d'environnement) -
FLAKY_ERROR_RATE = float(os.getenv("FLAKY_ERROR_RATE", "0.1"))  # 10 % de 503 sur /flaky
SLOW_RATE = float(os.getenv("SLOW_RATE", "0.1"))  # 10 % de checkouts lents

PRODUCTS = {
    1: {"id": 1, "name": "Clavier mécanique", "price": 49.90},
    2: {"id": 2, "name": "Souris sans fil", "price": 19.90},
    3: {"id": 3, "name": "Écran 27 pouces", "price": 229.00},
}


class Item(BaseModel):
    product_id: int
    quantity: int = Field(gt=0)


class Order(BaseModel):
    items: list[Item]


@app.middleware("http")
async def prometheus_middleware(request: Request, call_next):
    """Mesure le débit, les erreurs et la durée de chaque requête."""
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        # On utilise le gabarit de route (/products/{product_id}) et non l'URL brute
        # pour éviter l'explosion de cardinalité des labels.
        path = route.path if route else "unmatched"
        if path != "/metrics":
            LATENCY.labels(request.method, path).observe(time.perf_counter() - start)
            REQUESTS.labels(request.method, path, str(status)).inc()


async def simulate_processing(delay: float) -> None:
    """Simule un traitement métier (appel paiement, stock...)."""
    await asyncio.sleep(delay)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/products")
def list_products():
    return list(PRODUCTS.values())


@app.get("/products/{product_id}")
def get_product(product_id: int):
    if product_id not in PRODUCTS:
        logger.warning("produit introuvable: %s", product_id)
        raise HTTPException(status_code=404, detail="Produit introuvable")
    return PRODUCTS[product_id]


@app.post("/checkout")
async def checkout(order: Order):
    if not order.items:
        raise HTTPException(status_code=400, detail="Panier vide")
    if random.random() < SLOW_RATE:
        delay = random.uniform(0.5, 1.5)  # cas lent : casse le SLO de latence
    else:
        delay = random.uniform(0.02, 0.12)  # cas nominal
    with tracer.start_as_current_span("process_payment") as span:
        span.set_attribute("checkout.items", len(order.items))
        span.set_attribute("checkout.slow_path", delay >= 0.5)
        await simulate_processing(delay)
    total = sum(
        PRODUCTS[item.product_id]["price"] * item.quantity
        for item in order.items
        if item.product_id in PRODUCTS
    )
    logger.info("checkout confirme, total=%.2f, latence simulee=%.3fs", total, delay)
    return {"status": "confirmed", "total": round(total, 2)}


@app.get("/flaky")
def flaky():
    if random.random() < FLAKY_ERROR_RATE:
        logger.warning("flaky: erreur 503 simulée")
        raise HTTPException(status_code=503, detail="Erreur intermittente simulée")
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
