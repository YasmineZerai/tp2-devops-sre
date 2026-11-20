"""Instrumentation OpenTelemetry de catalog-api.

- Traces  : SDK OpenTelemetry -> export OTLP (gRPC) vers Tempo
- Metriques : SDK OpenTelemetry -> lecteur Prometheus (exposees sur /metrics)
- Logs    : JSON structure sur stdout, avec trace_id / span_id (correlation logs <-> traces)
"""

import json
import logging
import os
import sys

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.prometheus import PrometheusMetricReader
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

SERVICE_NAME = "catalog-api"


class JsonFormatter(logging.Formatter):
    """Formate chaque log en une ligne JSON, enrichie du contexte de trace courant."""

    def format(self, record: logging.LogRecord) -> str:
        log = {
            "ts": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "service": SERVICE_NAME,
            "msg": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            log["trace_id"] = format(ctx.trace_id, "032x")
            log["span_id"] = format(ctx.span_id, "016x")
        return json.dumps(log, ensure_ascii=False)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)


def build_tracer_provider(resource: Resource, endpoint: str | None) -> TracerProvider:
    provider = TracerProvider(resource=resource)
    if endpoint:  # absent pendant les tests unitaires : aucune exportation reseau
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True)))
    return provider


def setup_telemetry(app) -> None:
    """Active traces, metriques et logs JSON pour l'application FastAPI."""
    resource = Resource.create({"service.name": SERVICE_NAME})
    trace.set_tracer_provider(build_tracer_provider(resource, os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")))
    metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[PrometheusMetricReader()]))
    FastAPIInstrumentor.instrument_app(app, excluded_urls="metrics,health")
    configure_logging()
