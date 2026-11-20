"""Tests de l'instrumentation OpenTelemetry (logs JSON correles aux traces)."""

import json
import logging

from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider

from app import telemetry


def _record(msg="bonjour"):
    return logging.LogRecord("catalog-api", logging.INFO, __file__, 1, msg, None, None)


def test_json_log_without_span():
    line = json.loads(telemetry.JsonFormatter().format(_record()))
    assert line["msg"] == "bonjour"
    assert line["service"] == "catalog-api"
    assert "trace_id" not in line


def test_json_log_inside_span_has_trace_id():
    tracer = TracerProvider().get_tracer("test")
    with tracer.start_as_current_span("requete") as span:
        line = json.loads(telemetry.JsonFormatter().format(_record()))
    assert line["trace_id"] == format(span.get_span_context().trace_id, "032x")
    assert len(line["span_id"]) == 16


def test_tracer_provider_without_endpoint_exports_nothing():
    provider = telemetry.build_tracer_provider(Resource.create({}), None)
    assert provider._active_span_processor._span_processors == ()


def test_tracer_provider_with_endpoint_adds_exporter():
    provider = telemetry.build_tracer_provider(Resource.create({}), "http://tempo:4317")
    assert len(provider._active_span_processor._span_processors) == 1
    provider.shutdown()
