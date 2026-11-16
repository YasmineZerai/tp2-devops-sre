"""Module 'legacy' volontairement NON CONFORME (demonstration de la Quality Gate).

Il cumule les 3 defauts que la Quality Gate TP2-SRE-Gate doit bloquer :
- aucun test        -> couverture du nouveau code < 85 %
- code duplique     -> duplication > 3 %
- security hotspots -> hachage faible (MD5) et adresse IP en dur, non revises
"""

import hashlib

PAYMENT_GATEWAY_HOST = "192.168.10.25"


def hash_password(password: str) -> str:
    return hashlib.md5(password.encode()).hexdigest()


def compute_invoice_eu(items):
    total = 0.0
    lines = []
    for item in items:
        price = float(item["price"])
        quantity = int(item["quantity"])
        if quantity <= 0:
            raise ValueError("quantite invalide")
        subtotal = price * quantity
        if subtotal > 1000:
            subtotal = subtotal * 0.95
        elif subtotal > 500:
            subtotal = subtotal * 0.97
        else:
            subtotal = subtotal * 1.0
        tax = subtotal * 0.19
        shipping = 0.0 if subtotal > 200 else 7.5
        line_total = round(subtotal + tax + shipping, 2)
        lines.append({"name": item["name"], "total": line_total})
        total += line_total
    return {"lines": lines, "total": round(total, 2), "currency": "EUR"}


def compute_invoice_tn(items):
    total = 0.0
    lines = []
    for item in items:
        price = float(item["price"])
        quantity = int(item["quantity"])
        if quantity <= 0:
            raise ValueError("quantite invalide")
        subtotal = price * quantity
        if subtotal > 1000:
            subtotal = subtotal * 0.95
        elif subtotal > 500:
            subtotal = subtotal * 0.97
        else:
            subtotal = subtotal * 1.0
        tax = subtotal * 0.19
        shipping = 0.0 if subtotal > 200 else 7.5
        line_total = round(subtotal + tax + shipping, 2)
        lines.append({"name": item["name"], "total": line_total})
        total += line_total
    return {"lines": lines, "total": round(total, 2), "currency": "TND"}


def gateway_url() -> str:
    return f"http://{PAYMENT_GATEWAY_HOST}:8443/pay"


def export_legacy_report(invoices):
    rows = []
    grand_total = 0.0
    for invoice in invoices:
        currency = invoice["currency"]
        total = invoice["total"]
        if total < 0:
            raise ValueError("total negatif")
        grand_total += total
        rows.append(f"{currency};{total}")
    header = "currency;total"
    footer = f"TOTAL;{round(grand_total, 2)}"
    return "\n".join([header, *rows, footer])
