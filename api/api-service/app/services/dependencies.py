"""Wrappers around outbound dependencies with consistent OTel spans + structured logs.

Each call:
- creates a child span named `dep.<dependency_name>`
- sets attributes: dependency_name, endpoint, status_code, latency_ms, error.type
- logs success/failure with correlation context
- raises a `DependencyError` on failure so callers can decide policy
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any, Optional

import httpx
from azure.identity.aio import DefaultAzureCredential
from azure.servicebus.aio import ServiceBusClient
from azure.servicebus import ServiceBusMessage
from azure.cosmos.aio import CosmosClient
from openai import AsyncAzureOpenAI

from app.config import settings
from app.telemetry.otel import (
    get_tracer,
    get_correlation_id,
    get_request_id,
    get_user_id,
    get_order_id,
    stamp_span_with_correlation,
)

log = logging.getLogger(__name__)
tracer = get_tracer()


class DependencyError(Exception):
    def __init__(self, dependency: str, message: str, status_code: Optional[int] = None):
        super().__init__(message)
        self.dependency = dependency
        self.status_code = status_code


def _record(span, dep: str, endpoint: str, status_code: Optional[int], started: float, error: Optional[Exception] = None):
    latency_ms = int((time.perf_counter() - started) * 1000)
    span.set_attribute("dependency_name", dep)
    span.set_attribute("dependency.endpoint", endpoint)
    span.set_attribute("dependency.latency_ms", latency_ms)
    if status_code is not None:
        span.set_attribute("dependency.status_code", status_code)
    if error is not None:
        span.set_attribute("error.type", type(error).__name__)
        span.set_attribute("error.message", str(error)[:500])
        span.record_exception(error)
        log.error(
            "dependency.error",
            extra={
                "dependency_name": dep,
                "endpoint": endpoint,
                "status_code": status_code,
                "latency_ms": latency_ms,
                "error_type": type(error).__name__,
                "error_message": str(error)[:500],
            },
        )
    else:
        log.info(
            "dependency.ok",
            extra={
                "dependency_name": dep,
                "endpoint": endpoint,
                "status_code": status_code,
                "latency_ms": latency_ms,
            },
        )


# ----------------------- Azure OpenAI (chat) -----------------------

async def call_openai_chat(prompt: str) -> str:
    if settings.fault_force_openai_down:
        raise DependencyError("AzureOpenAI", "fault_force_openai_down=true (synthetic outage)")

    endpoint = settings.openai_endpoint or "unset"
    with tracer.start_as_current_span("dep.AzureOpenAI") as span:
        stamp_span_with_correlation(span)
        started = time.perf_counter()
        try:
            credential = DefaultAzureCredential(managed_identity_client_id=settings.azure_client_id or None)
            token = (await credential.get_token("https://cognitiveservices.azure.com/.default")).token
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{endpoint.rstrip('/')}/openai/deployments/{settings.openai_chat_deployment}/chat/completions?api-version={settings.openai_api_version}"
                r = await client.post(
                    url,
                    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                    json={"messages": [{"role": "user", "content": prompt}], "max_tokens": 200, "temperature": 0.2},
                )
                _record(span, "AzureOpenAI", url, r.status_code, started)
                if r.status_code >= 400:
                    raise DependencyError("AzureOpenAI", f"openai http {r.status_code}: {r.text[:300]}", r.status_code)
                data = r.json()
                return data["choices"][0]["message"]["content"]
        except DependencyError:
            raise
        except Exception as ex:  # noqa: BLE001
            _record(span, "AzureOpenAI", endpoint, None, started, ex)
            raise DependencyError("AzureOpenAI", str(ex)) from ex


# ----------------------- Azure Speech (TTS) -----------------------

async def call_speech_tts(text: str) -> bytes:
    if settings.fault_force_speech_down:
        raise DependencyError("AzureSpeech", "fault_force_speech_down=true (synthetic outage)")

    endpoint = settings.speech_endpoint or f"https://{settings.speech_region}.tts.speech.microsoft.com"
    with tracer.start_as_current_span("dep.AzureSpeech") as span:
        stamp_span_with_correlation(span)
        started = time.perf_counter()
        try:
            credential = DefaultAzureCredential(managed_identity_client_id=settings.azure_client_id or None)
            token = (await credential.get_token("https://cognitiveservices.azure.com/.default")).token
            ssml = f"<speak version='1.0' xml:lang='en-US'><voice xml:lang='en-US' xml:gender='Female' name='en-US-JennyNeural'>{text}</voice></speak>"
            async with httpx.AsyncClient(timeout=15.0) as client:
                url = f"{endpoint.rstrip('/')}/cognitiveservices/v1"
                r = await client.post(
                    url,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/ssml+xml",
                        "X-Microsoft-OutputFormat": "audio-16khz-32kbitrate-mono-mp3",
                        "User-Agent": "ai-observability-sre-demo",
                    },
                    content=ssml.encode("utf-8"),
                )
                _record(span, "AzureSpeech", url, r.status_code, started)
                if r.status_code >= 400:
                    raise DependencyError("AzureSpeech", f"speech http {r.status_code}", r.status_code)
                return r.content
        except DependencyError:
            raise
        except Exception as ex:  # noqa: BLE001
            _record(span, "AzureSpeech", endpoint, None, started, ex)
            raise DependencyError("AzureSpeech", str(ex)) from ex


# ----------------------- Third-party API -----------------------

async def call_third_party() -> dict:
    if settings.fault_force_thirdparty_down:
        raise DependencyError("ThirdPartyAPI", "fault_force_thirdparty_down=true (synthetic outage)")
    url = settings.third_party_api_url
    with tracer.start_as_current_span("dep.ThirdPartyAPI") as span:
        stamp_span_with_correlation(span)
        started = time.perf_counter()
        try:
            async with httpx.AsyncClient(timeout=8.0) as client:
                r = await client.get(url)
                _record(span, "ThirdPartyAPI", url, r.status_code, started)
                if r.status_code >= 400:
                    raise DependencyError("ThirdPartyAPI", f"thirdparty http {r.status_code}", r.status_code)
                return r.json()
        except DependencyError:
            raise
        except Exception as ex:  # noqa: BLE001
            _record(span, "ThirdPartyAPI", url, None, started, ex)
            raise DependencyError("ThirdPartyAPI", str(ex)) from ex


# ----------------------- Service Bus enqueue -----------------------

async def enqueue_voice_order(order_payload: dict, traceparent: Optional[str]) -> str:
    fqdn = settings.servicebus_fqdn
    queue = settings.servicebus_queue
    with tracer.start_as_current_span("dep.ServiceBus.send") as span:
        stamp_span_with_correlation(span)
        started = time.perf_counter()
        try:
            credential = DefaultAzureCredential(managed_identity_client_id=settings.azure_client_id or None)
            async with ServiceBusClient(fqdn, credential) as sb:
                sender = sb.get_queue_sender(queue_name=queue)
                async with sender:
                    msg = ServiceBusMessage(json.dumps(order_payload))
                    msg.application_properties = {
                        "correlation_id": get_correlation_id() or "",
                        "request_id": get_request_id() or "",
                        "user_id": get_user_id() or "",
                        "order_id": order_payload.get("order_id", ""),
                        "traceparent": traceparent or "",
                        "deployment_version": settings.deployment_version,
                    }
                    msg.correlation_id = get_correlation_id() or ""
                    await sender.send_messages(msg)
            _record(span, "AzureServiceBus", f"sb://{fqdn}/{queue}", 200, started)
            return order_payload["order_id"]
        except Exception as ex:  # noqa: BLE001
            _record(span, "AzureServiceBus", f"sb://{fqdn}/{queue}", None, started, ex)
            raise DependencyError("AzureServiceBus", str(ex)) from ex


# ----------------------- Cosmos (used by worker; included here for read-after-write demo) -----------------------

async def cosmos_write_order(doc: dict) -> None:
    """Write a document to the orders container. Used by fault injection to generate RU load."""
    endpoint = settings.cosmos_endpoint
    with tracer.start_as_current_span("dep.Cosmos.write") as span:
        stamp_span_with_correlation(span)
        started = time.perf_counter()
        try:
            credential = DefaultAzureCredential(managed_identity_client_id=settings.azure_client_id or None)
            async with CosmosClient(endpoint, credential) as client:
                db = client.get_database_client(settings.cosmos_database)
                cont = db.get_container_client(settings.cosmos_container)
                await cont.upsert_item(doc)
                _record(span, "Cosmos", endpoint, 200, started)
        except Exception as ex:  # noqa: BLE001
            _record(span, "Cosmos", endpoint, None, started, ex)
            raise


async def cosmos_read_order(order_id: str, user_id: str) -> Optional[dict]:
    endpoint = settings.cosmos_endpoint
    if settings.fault_force_cosmos_dns_break:
        endpoint = endpoint.replace(".documents.azure.com", ".invalid-dns.azure.com")
    with tracer.start_as_current_span("dep.Cosmos.read") as span:
        stamp_span_with_correlation(span)
        started = time.perf_counter()
        try:
            credential = DefaultAzureCredential(managed_identity_client_id=settings.azure_client_id or None)
            async with CosmosClient(endpoint, credential) as client:
                db = client.get_database_client(settings.cosmos_database)
                cont = db.get_container_client(settings.cosmos_container)
                try:
                    item = await cont.read_item(item=order_id, partition_key=user_id)
                    _record(span, "Cosmos", endpoint, 200, started)
                    return item
                except Exception:
                    _record(span, "Cosmos", endpoint, 404, started)
                    return None
        except Exception as ex:  # noqa: BLE001
            _record(span, "Cosmos", endpoint, None, started, ex)
            raise DependencyError("Cosmos", str(ex)) from ex
