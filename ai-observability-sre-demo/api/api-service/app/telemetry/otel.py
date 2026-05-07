"""OpenTelemetry + structured logging bootstrap for api-service."""
import logging
import os
from contextvars import ContextVar
from typing import Optional

from pythonjsonlogger import jsonlogger
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry._logs import set_logger_provider
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor

from app.config import settings


# Request-scoped context for correlation/request IDs and business fields.
_correlation_id: ContextVar[Optional[str]] = ContextVar("correlation_id", default=None)
_request_id: ContextVar[Optional[str]] = ContextVar("request_id", default=None)
_user_id: ContextVar[Optional[str]] = ContextVar("user_id", default=None)
_order_id: ContextVar[Optional[str]] = ContextVar("order_id", default=None)


def set_request_context(correlation_id: str, request_id: str, user_id: str = "", order_id: str = ""):
    _correlation_id.set(correlation_id)
    _request_id.set(request_id)
    _user_id.set(user_id)
    _order_id.set(order_id)


def get_correlation_id() -> Optional[str]:
    return _correlation_id.get()


def get_request_id() -> Optional[str]:
    return _request_id.get()


def get_user_id() -> Optional[str]:
    return _user_id.get()


def get_order_id() -> Optional[str]:
    return _order_id.get()


class CorrelationFilter(logging.Filter):
    """Inject correlation/request/trace fields into every log record."""

    def filter(self, record: logging.LogRecord) -> bool:
        record.correlation_id = _correlation_id.get() or ""
        record.request_id = _request_id.get() or ""
        record.user_id = _user_id.get() or ""
        record.order_id = _order_id.get() or ""
        record.deployment_version = settings.deployment_version
        record.pod = settings.pod_name
        record.namespace = settings.namespace
        record.node = settings.node_name
        record.service_name = settings.service_name

        span = trace.get_current_span()
        ctx = span.get_span_context() if span is not None else None
        if ctx and ctx.is_valid:
            record.trace_id = format(ctx.trace_id, "032x")
            record.span_id = format(ctx.span_id, "016x")
        else:
            record.trace_id = ""
            record.span_id = ""
        return True


def configure_telemetry(app):
    resource = Resource.create({
        "service.name": settings.service_name,
        "service.version": settings.deployment_version,
        "deployment.environment": os.getenv("ENV", "demo"),
        "k8s.pod.name": settings.pod_name,
        "k8s.namespace.name": settings.namespace,
        "k8s.node.name": settings.node_name,
    })

    # Tracing
    tp = TracerProvider(resource=resource)
    tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=settings.otel_exporter_otlp_endpoint, insecure=True)))
    trace.set_tracer_provider(tp)

    # Logs (OTel logs API)
    lp = LoggerProvider(resource=resource)
    lp.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=settings.otel_exporter_otlp_endpoint, insecure=True)))
    set_logger_provider(lp)

    # JSON structured logs to stdout (also picked up by collector via filelog)
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    for h in list(root.handlers):
        root.removeHandler(h)

    handler = logging.StreamHandler()
    fmt = jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s %(correlation_id)s %(request_id)s %(trace_id)s %(span_id)s %(user_id)s %(order_id)s %(deployment_version)s %(pod)s %(namespace)s %(node)s %(service_name)s"
    )
    handler.setFormatter(fmt)
    handler.addFilter(CorrelationFilter())
    root.addHandler(handler)

    # Mirror logs to OTel as well
    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=lp)
    otel_handler.addFilter(CorrelationFilter())
    root.addHandler(otel_handler)

    # Auto-instrument
    FastAPIInstrumentor.instrument_app(app)
    HTTPXClientInstrumentor().instrument()
    RedisInstrumentor().instrument()
    LoggingInstrumentor().instrument(set_logging_format=False)


def get_tracer(name: str = "api-service"):
    return trace.get_tracer(name)


def stamp_span_with_correlation(span):
    """Set business attributes on the active span."""
    cid = _correlation_id.get()
    rid = _request_id.get()
    uid = _user_id.get()
    oid = _order_id.get()
    if cid:
        span.set_attribute("correlation_id", cid)
    if rid:
        span.set_attribute("request_id", rid)
    if uid:
        span.set_attribute("user_id", uid)
    if oid:
        span.set_attribute("order_id", oid)
    span.set_attribute("deployment_version", settings.deployment_version)
    span.set_attribute("k8s.pod.name", settings.pod_name)
