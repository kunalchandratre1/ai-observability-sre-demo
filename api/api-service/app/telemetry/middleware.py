"""FastAPI middleware that bootstraps correlation_id/request_id/trace context."""
import uuid
import logging
from typing import Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from opentelemetry import trace

from app.telemetry.otel import set_request_context

log = logging.getLogger(__name__)


def _stamp_active_span(correlation_id: str, request_id: str, user_id: str) -> str:
    span = trace.get_current_span()
    ctx = span.get_span_context() if span is not None else None
    if not ctx or not ctx.is_valid:
        return ""
    span.set_attribute("correlation_id", correlation_id)
    span.set_attribute("request_id", request_id)
    span.set_attribute("user_id", user_id)
    return format(ctx.trace_id, "032x")


class CorrelationMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        cid = request.headers.get("x-correlation-id") or str(uuid.uuid4())
        rid = request.headers.get("x-request-id") or str(uuid.uuid4())
        uid = request.headers.get("x-user-id") or "anon"
        set_request_context(correlation_id=cid, request_id=rid, user_id=uid, order_id="")
        trace_id = _stamp_active_span(cid, rid, uid)

        log.info("request.start", extra={"path": request.url.path, "method": request.method})
        try:
            response = await call_next(request)
        except Exception:  # noqa: BLE001
            log.exception("request.unhandled_exception")
            raise

        trace_id = _stamp_active_span(cid, rid, uid) or trace_id

        # Echo back IDs (always)
        response.headers["x-correlation-id"] = cid
        response.headers["x-request-id"] = rid
        if trace_id:
            response.headers["x-trace-id"] = trace_id
        log.info("request.end", extra={"status_code": response.status_code})
        return response
