# catalog-api - image de production
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# DEMO TRIVY : dependance volontairement vulnerable (Django 2.2, CVE critiques)
RUN pip install --no-cache-dir "django==2.2"
COPY app/ app/

# Utilisateur non-root (bonne pratique sécurité, vérifiée par Trivy/Sonar)
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 8000

# Un seul worker par pod : les compteurs Prometheus restent cohérents.
# Pour monter en charge, on augmente le nombre de replicas Kubernetes.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
