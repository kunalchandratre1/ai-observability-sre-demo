"""FastAPI middleware that bootstraps correlation_id/request_id/trace context."""
import uuid
import logging
from typing import Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from opentelemetry import trace

from app.telemetry.otel import set_request_context

log = logging.getLogger(__name__)


class CorrelationMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        cid = request.headers.get("x-correlation-id") or str(uuid.uuid4())
        rid = request.headers.get("x-request-id") or str(uuid.uuid4())
        uid = request.headers.get("x-user-id") or "anon"
        set_request_context(correlation_id=cid, request_id=rid, user_id=uid, order_id="")

        span = trace.get_current_span()
        if span is not None and span.get_span_context().is_valid:
            span.set_attribute("correlation_id", cid)
            span.set_attribute("request_id", rid)
            span.set_attribute("user_id", uid)

        log.info("request.start", extra={"path": request.url.path, "method": request.method})
        try:
            response = await call_next(request)
        except Exception:  # noqa: BLE001
            log.exception("request.unhandled_exception")
            raise

        # Echo back IDs (always)
        response.headers["x-correlation-id"] = cid
        response.headers["x-request-id"] = rid
        ctx = span.get_span_context() if span else None
        if ctx and ctx.is_valid:
            response.headers["x-trace-id"] = format(ctx.trace_id, "032x")
        log.info("request.end", extra={"status_code": response.status_code})
        return response
