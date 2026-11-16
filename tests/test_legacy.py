"""Tests du module legacy (export_legacy_report volontairement non teste)."""

import pytest

from app import legacy

ITEMS = [
    {"name": "petit", "price": 10, "quantity": 2},
    {"name": "moyen", "price": 300, "quantity": 2},
    {"name": "gros", "price": 600, "quantity": 2},
]


@pytest.mark.parametrize("compute", [legacy.compute_invoice_eu, legacy.compute_invoice_tn])
def test_invoices(compute):
    result = compute(ITEMS)
    assert len(result["lines"]) == 3


@pytest.mark.parametrize("compute", [legacy.compute_invoice_eu, legacy.compute_invoice_tn])
def test_invoice_invalid_quantity(compute):
    with pytest.raises(ValueError):
        compute([{"name": "x", "price": 1, "quantity": 0}])


def test_hash_and_gateway():
    assert len(legacy.hash_password("x")) == 32
    assert legacy.gateway_url().startswith("http://")
