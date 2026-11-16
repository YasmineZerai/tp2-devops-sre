# TP2 DevOps Avancé — Continuous Delivery, Quality & Security Gates, SRE

Microservice **catalog-api** (Python FastAPI) livré par une chaîne CI/CD sécurisée
(GitHub Actions, SonarQube Cloud, Trivy, OPA Gatekeeper, ArgoCD) et observé par
Prometheus, Loki, Tempo et Grafana, avec SLO, Error Budget et alertes burn rate.

## Endpoints

| Méthode | Route | Rôle |
| --- | --- | --- |
| GET | `/health` | Sonde de vie |
| GET | `/products`, `/products/{id}` | Catalogue |
| POST | `/checkout` | Traitement lent simulé (10 % des appels entre 0,5 et 1,5 s) |
| GET | `/flaky` | Erreurs 503 intermittentes (`FLAKY_ERROR_RATE`, 10 % par défaut) |
| GET | `/metrics` | Métriques Prometheus (`http_requests_total`, `http_request_duration_seconds`) |

## Lancer en local

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt -r requirements-dev.txt
.\.venv\Scripts\python -m pytest --cov=app --cov-fail-under=85
.\.venv\Scripts\python -m uvicorn app.main:app --port 8000
```

## Scripts d'étape

Chaque étape du TP est automatisée par `scripts\etape-XX.ps1`, qui prend les captures
d'écran du compte rendu dans `docs\captures\`.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\etape-01.ps1
```
