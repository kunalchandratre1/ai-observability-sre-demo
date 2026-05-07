"""Worker-service: consumes Service Bus messages, continues OTel trace, writes Cosmos."""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from contextvars import ContextVar
from typing import Optional

from azure.identity.aio import DefaultAzureCredential
from azure.servicebus.aio import ServiceBusClient
from azure.cosmos.aio import CosmosClient
from opentelemetry import trace, context
from opentelemetry.propagate import extract
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry._logs import set_logger_provider
from pythonjsonlogger import jsonlogger

DEPLOYMENT_VERSION = os.getenv("DEPLOYMENT_VERSION", "dev")
SERVICE_NAME = "worker-service"
POD_NAME = os.getenv("POD_NAME", "unknown")
NAMESPACE = os.getenv("NAMESPACE", "default")
NODE_NAME = os.getenv("NODE_NAME", "unknown")
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observability.svc.cluster.local:4317")
SB_FQDN = os.getenv("SERVICEBUS_FQDN", "")
SB_QUEUE = os.getenv("SERVICEBUS_QUEUE", "voice-orders")
COSMOS_ENDPOINT = os.getenv("COSMOS_ENDPOINT", "")
COSMOS_DB = os.getenv("COSMOS_DATABASE", "orders")
COSMOS_CONTAINER = os.getenv("COSMOS_CONTAINER", "voice-orders")
AZURE_CLIENT_ID = os.getenv("AZURE_CLIENT_ID", "")
FAULT_FORCE_COSMOS_DNS_BREAK = os.getenv("FAULT_FORCE_COSMOS_DNS_BREAK", "false").lower() == "true"

_correlation_id: ContextVar[Optional[str]] = ContextVar("correlation_id", default=None)


class CorrelationFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.correlation_id = _correlation_id.get() or ""
        record.deployment_version = DEPLOYMENT_VERSION
        record.pod = POD_NAME
        record.namespace = NAMESPACE
        record.node = NODE_NAME
        record.service_name = SERVICE_NAME
        span = trace.get_current_span()
        ctx = span.get_span_context() if span else None
        if ctx and ctx.is_valid:
            record.trace_id = format(ctx.trace_id, "032x")
            record.span_id = format(ctx.span_id, "016x")
        else:
            record.trace_id = ""
            record.span_id = ""
        return True


def configure_telemetry():
    resource = Resource.create({
        "service.name": SERVICE_NAME,
        "service.version": DEPLOYMENT_VERSION,
        "k8s.pod.name": POD_NAME,
        "k8s.namespace.name": NAMESPACE,
        "k8s.node.name": NODE_NAME,
    })
    tp = TracerProvider(resource=resource)
    tp.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)))
    trace.set_tracer_provider(tp)

    lp = LoggerProvider(resource=resource)
    lp.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=OTEL_ENDPOINT, insecure=True)))
    set_logger_provider(lp)

    root = logging.getLogger()
    root.setLevel(logging.INFO)
    for h in list(root.handlers):
        root.removeHandler(h)
    handler = logging.StreamHandler()
    handler.setFormatter(jsonlogger.JsonFormatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s %(correlation_id)s %(trace_id)s %(span_id)s %(deployment_version)s %(pod)s %(namespace)s %(node)s %(service_name)s"
    ))
    handler.addFilter(CorrelationFilter())
    root.addHandler(handler)
    otel_handler = LoggingHandler(level=logging.INFO, logger_provider=lp)
    otel_handler.addFilter(CorrelationFilter())
    root.addHandler(otel_handler)


configure_telemetry()
log = logging.getLogger(__name__)
tracer = trace.get_tracer(SERVICE_NAME)


async def write_to_cosmos(item: dict):
    endpoint = COSMOS_ENDPOINT
    if FAULT_FORCE_COSMOS_DNS_BREAK:
        endpoint = endpoint.replace(".documents.azure.com", ".invalid-dns.azure.com")
    with tracer.start_as_current_span("dep.Cosmos.upsert") as span:
        span.set_attribute("dependency_name", "Cosmos")
        span.set_attribute("dependency.endpoint", endpoint)
        span.set_attribute("correlation_id", _correlation_id.get() or "")
        started = time.perf_counter()
        try:
            credential = DefaultAzureCredential(managed_identity_client_id=AZURE_CLIENT_ID or None)
            async with CosmosClient(endpoint, credential) as client:
                db = client.get_database_client(COSMOS_DB)
                cont = db.get_container_client(COSMOS_CONTAINER)
                await cont.upsert_item(item)
            span.set_attribute("dependency.status_code", 200)
            span.set_attribute("dependency.latency_ms", int((time.perf_counter() - started) * 1000))
            log.info("cosmos.upsert.ok", extra={"order_id": item.get("order_id")})
        except Exception as ex:  # noqa: BLE001
            span.set_attribute("error.type", type(ex).__name__)
            span.set_attribute("error.message", str(ex)[:500])
            span.record_exception(ex)
            log.exception("cosmos.upsert.error", extra={"order_id": item.get("order_id")})
            raise


async def process_message(msg) -> None:
    props = msg.application_properties or {}
    norm = {k.decode() if isinstance(k, (bytes, bytearray)) else k:
            v.decode() if isinstance(v, (bytes, bytearray)) else v
            for k, v in props.items()}
    cid = norm.get("correlation_id", "")
    traceparent = norm.get("traceparent", "")
    _correlation_id.set(cid)

    carrier = {"traceparent": traceparent} if traceparent else {}
    parent_ctx = extract(carrier)

    token = context.attach(parent_ctx) if parent_ctx else None
    try:
        with tracer.start_as_current_span("worker.process_voice_order") as span:
            span.set_attribute("correlation_id", cid)
            span.set_attribute("messaging.system", "servicebus")
            span.set_attribute("messaging.destination.name", SB_QUEUE)
            try:
                body = b"".join(msg.body) if hasattr(msg.body, "__iter__") else msg.body
                payload = json.loads(body.decode("utf-8"))
            except Exception:
                payload = {"raw": str(msg.body)}
            payload["correlation_id"] = cid or payload.get("correlation_id", "")
            payload["worker_processed_at_ms"] = int(time.time() * 1000)
            payload["deployment_version"] = DEPLOYMENT_VERSION
            payload["id"] = payload.get("order_id") or payload.get("id")
            log.info("message.received", extra={"order_id": payload.get("order_id")})
            await write_to_cosmos(payload)
    finally:
        if token is not None:
            context.detach(token)


async def main():
    log.info("worker.start", extra={"sb_fqdn": SB_FQDN, "queue": SB_QUEUE, "deployment_version": DEPLOYMENT_VERSION})
    credential = DefaultAzureCredential(managed_identity_client_id=AZURE_CLIENT_ID or None)
    async with ServiceBusClient(SB_FQDN, credential) as sb:
        receiver = sb.get_queue_receiver(queue_name=SB_QUEUE, max_wait_time=5)
        async with receiver:
            while True:
                batch = await receiver.receive_messages(max_message_count=10, max_wait_time=5)
                for m in batch:
                    try:
                        await process_message(m)
                        await receiver.complete_message(m)
                    except Exception:  # noqa: BLE001
                        log.exception("message.failed; abandoning for retry")
                        await receiver.abandon_message(m)


if __name__ == "__main__":
    asyncio.run(main())
