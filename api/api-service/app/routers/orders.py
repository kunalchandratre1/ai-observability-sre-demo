"""Voice-Order route.

Flow (CORE BUSINESS):
  1. correlation/request IDs already established by middleware
  2. call OpenAI to extract intent  (MUST)
  3. call third-party API for an enriched response
  4. call Speech (TTS) for an audio confirmation               (MUST)
  5. enqueue Service Bus message with all propagation properties
  6. return JSON containing correlation_id, request_id, trace_id, per-dep outcomes
"""
from __future__ import annotations

import time
import uuid
import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel
from opentelemetry import trace

from app.config import settings
from app.telemetry.otel import (
    get_correlation_id,
    get_request_id,
    set_request_context,
    get_tracer,
)
from app.services import dependencies as deps

router = APIRouter()
log = logging.getLogger(__name__)
tracer = get_tracer()


class VoiceOrderRequest(BaseModel):
    text: str
    user_id: str = "demo-user"


@router.post("/orders")
async def submit_order(payload: VoiceOrderRequest, request: Request):
    order_id = f"order-{uuid.uuid4().hex[:10]}"
    set_request_context(
        correlation_id=get_correlation_id() or str(uuid.uuid4()),
        request_id=get_request_id() or str(uuid.uuid4()),
        user_id=payload.user_id,
        order_id=order_id,
    )
    cid = get_correlation_id()
    rid = get_request_id()

    deps_outcome: dict[str, dict[str, Any]] = {}

    if settings.fault_extra_cpu_burn_ms > 0:
        end = time.perf_counter() + (settings.fault_extra_cpu_burn_ms / 1000.0)
        while time.perf_counter() < end:
            pass

    if settings.fault_force_exception:
        log.error("synthetic.unhandled_exception", extra={"order_id": order_id})
        raise RuntimeError("synthetic unhandled exception (fault_force_exception=true)")

    # Fault: Cosmos DNS break — attempt a direct Cosmos write so AppExceptions appear in ADX/Grafana.
    # This simulates the scenario where Cosmos Private Endpoint DNS is misconfigured;
    # api-service catches the DNS error, marks cosmos=error in the response, and logs to ADX.
    if settings.fault_force_cosmos_dns_break:
        try:
            await deps.cosmos_write_order({
                "id": f"dns-probe-{order_id}",
                "order_id": f"dns-probe-{order_id}",
                "user_id": payload.user_id,
                "_ttl": 60,
            })
            deps_outcome["cosmos"] = {"status": "ok"}
        except Exception as ex:
            deps_outcome["cosmos"] = {"status": "error", "error": str(ex)[:200]}
            log.error("fault.cosmos_dns_break.detected", extra={
                "order_id": order_id,
                "error_type": type(ex).__name__,
                "error_message": str(ex)[:300],
            })
        # Continue — let the order flow proceed so SB + worker also observe the fault

    # Fault: Cosmos RU throttle — fire 20 parallel dummy writes to exhaust the 400 RU/s budget
    # This causes subsequent real writes in the same second to get 429 TooManyRequests from Cosmos.
    if settings.fault_cosmos_throttle:
        import asyncio
        async def _dummy_write(i: int):
            try:
                await deps.cosmos_write_order({
                    "id": f"throttle-{order_id}-{i}",
                    "order_id": f"throttle-{order_id}-{i}",
                    "user_id": payload.user_id,
                    "_ttl": 10,
                })
            except Exception:
                pass
        await asyncio.gather(*[_dummy_write(i) for i in range(20)], return_exceptions=True)
        log.warning("fault.cosmos_throttle.burst_fired", extra={"order_id": order_id, "burst_writes": 20})

    # Extract traceparent for downstream propagation
    span = trace.get_current_span()
    sc = span.get_span_context() if span else None
    traceparent = (
        f"00-{format(sc.trace_id, '032x')}-{format(sc.span_id, '016x')}-01"
        if sc and sc.is_valid
        else None
    )

    # 1. OpenAI
    openai_text: Optional[str] = None
    try:
        prompt = f"Extract the order intent from: '{payload.text}'. Respond with one short sentence."
        t0 = time.perf_counter()
        openai_text = await deps.call_openai_chat(prompt)
        deps_outcome["openai"] = {"status": "ok", "latency_ms": int((time.perf_counter() - t0) * 1000)}
    except deps.DependencyError as ex:
        deps_outcome["openai"] = {"status": "error", "error": str(ex)}
        # Mandatory dependency: 503 if OpenAI is broken
        raise HTTPException(
            status_code=503,
            detail={"dependency": "AzureOpenAI", "message": str(ex), "correlation_id": cid, "request_id": rid},
        ) from ex

    # 2. Third-party API
    try:
        t0 = time.perf_counter()
        fact = await deps.call_third_party()
        deps_outcome["thirdparty"] = {
            "status": "ok",
            "latency_ms": int((time.perf_counter() - t0) * 1000),
            "snippet": (fact.get("text") or fact.get("fact") or "")[:120],
        }
    except deps.DependencyError as ex:
        deps_outcome["thirdparty"] = {"status": "error", "error": str(ex)}
        # Non-fatal: continue but mark unhealthy.

    # 3. Speech (TTS)
    try:
        t0 = time.perf_counter()
        await deps.call_speech_tts(f"Your order {order_id} has been received.")
        deps_outcome["speech"] = {"status": "ok", "latency_ms": int((time.perf_counter() - t0) * 1000)}
    except deps.DependencyError as ex:
        deps_outcome["speech"] = {"status": "error", "error": str(ex)}
        raise HTTPException(
            status_code=503,
            detail={"dependency": "AzureSpeech", "message": str(ex), "correlation_id": cid, "request_id": rid},
        ) from ex

    # 4. Service Bus enqueue
    order_doc = {
        "order_id": order_id,
        "user_id": payload.user_id,
        "intent_text": openai_text,
        "raw_text": payload.text,
        "correlation_id": cid,
        "request_id": rid,
        "trace_id": format(sc.trace_id, "032x") if sc and sc.is_valid else "",
        "deployment_version": settings.deployment_version,
        "created_at_ms": int(time.time() * 1000),
    }
    try:
        t0 = time.perf_counter()
        await deps.enqueue_voice_order(order_doc, traceparent=traceparent)
        deps_outcome["servicebus"] = {"status": "ok", "latency_ms": int((time.perf_counter() - t0) * 1000)}
    except deps.DependencyError as ex:
        deps_outcome["servicebus"] = {"status": "error", "error": str(ex)}
        raise HTTPException(
            status_code=503,
            detail={"dependency": "AzureServiceBus", "message": str(ex), "correlation_id": cid, "request_id": rid},
        ) from ex

    return {
        "order_id": order_id,
        "correlation_id": cid,
        "request_id": rid,
        "trace_id": format(sc.trace_id, "032x") if sc and sc.is_valid else "",
        "intent": openai_text,
        "dependencies": deps_outcome,
    }


@router.get("/orders/{order_id}")
async def get_order(order_id: str, user_id: str = "demo-user"):
    item = await deps.cosmos_read_order(order_id, user_id)
    if item is None:
        raise HTTPException(status_code=404, detail="not found yet (worker may still be processing)")
    return item
