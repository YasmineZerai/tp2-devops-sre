"""Tests unitaires et d'intégration de catalog-api (cas nominaux + cas limites)."""

import pytest
from fastapi.testclient import TestClient

from app import main


@pytest.fixture
def client():
    return TestClient(main.app)


@pytest.fixture(autouse=True)
def no_real_sleep(monkeypatch):
    """Supprime l'attente simulée pour garder des tests rapides."""

    async def instant(_delay):
        return None

    monkeypatch.setattr(main, "simulate_processing", instant)


# --- Cas nominaux ----------------------------------------------------------


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_list_products(client):
    response = client.get("/products")
    assert response.status_code == 200
    assert len(response.json()) == 3


def test_get_product(client):
    response = client.get("/products/1")
    assert response.status_code == 200
    assert response.json()["name"] == "Clavier mécanique"


def test_checkout_nominal(client, monkeypatch):
    monkeypatch.setattr(main.random, "random", lambda: 0.99)  # chemin rapide
    payload = {"items": [{"product_id": 1, "quantity": 2}, {"product_id": 2, "quantity": 1}]}
    response = client.post("/checkout", json=payload)
    assert response.status_code == 200
    assert response.json() == {"status": "confirmed", "total": 119.70}


def test_checkout_slow_path(client, monkeypatch):
    monkeypatch.setattr(main.random, "random", lambda: 0.0)  # chemin lent
    response = client.post("/checkout", json={"items": [{"product_id": 3, "quantity": 1}]})
    assert response.status_code == 200
    assert response.json()["total"] == 229.0


def test_flaky_success(client, monkeypatch):
    monkeypatch.setattr(main.random, "random", lambda: 0.99)
    response = client.get("/flaky")
    assert response.status_code == 200


def test_metrics_endpoint(client):
    client.get("/health")
    response = client.get("/metrics")
    assert response.status_code == 200
    body = response.text
    assert "http_requests_total" in body
    assert 'le="0.2"' in body  # bucket du SLO de latence


# --- Cas limites (edge cases) ---------------------------------------------


def test_product_not_found(client):
    response = client.get("/products/999")
    assert response.status_code == 404


def test_product_invalid_id(client):
    response = client.get("/products/abc")
    assert response.status_code == 422


def test_checkout_empty_cart(client):
    response = client.post("/checkout", json={"items": []})
    assert response.status_code == 400


@pytest.mark.parametrize("quantity", [0, -1])
def test_checkout_invalid_quantity(client, quantity):
    response = client.post("/checkout", json={"items": [{"product_id": 1, "quantity": quantity}]})
    assert response.status_code == 422


def test_checkout_unknown_product_is_ignored(client, monkeypatch):
    monkeypatch.setattr(main.random, "random", lambda: 0.99)
    response = client.post("/checkout", json={"items": [{"product_id": 42, "quantity": 1}]})
    assert response.status_code == 200
    assert response.json()["total"] == 0


def test_flaky_error(client, monkeypatch):
    monkeypatch.setattr(main.random, "random", lambda: 0.0)
    response = client.get("/flaky")
    assert response.status_code == 503


def test_errors_are_counted_in_metrics(client, monkeypatch):
    monkeypatch.setattr(main.random, "random", lambda: 0.0)
    client.get("/flaky")
    body = client.get("/metrics").text
    assert 'route="/flaky",status="503"' in body


def test_unknown_route_label_is_bounded(client):
    client.get("/route/inexistante/123")
    body = client.get("/metrics").text
    assert 'route="unmatched"' in body
    assert "inexistante" not in body


def test_unhandled_exception_counted_as_500(monkeypatch):
    monkeypatch.setattr(main, "PRODUCTS", None)  # provoque une erreur interne
    client = TestClient(main.app, raise_server_exceptions=False)
    response = client.get("/products")
    assert response.status_code == 500
    body = client.get("/metrics").text
    assert 'route="/products",status="500"' in body
