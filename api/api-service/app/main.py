from fastapi import FastAPI

from app.telemetry.otel import configure_telemetry
from app.telemetry.middleware import CorrelationMiddleware
from app.routers import orders, admin, health


app = FastAPI(title="ai-observability-sre-demo / api-service")
app.add_middleware(CorrelationMiddleware)
configure_telemetry(app)

app.include_router(health.router, prefix="/api", tags=["health"])
app.include_router(orders.router, prefix="/api", tags=["orders"])
app.include_router(admin.router, prefix="/api/admin", tags=["admin"])


@app.get("/")
def root():
    return {"service": "api-service", "see": ["/api/health", "/api/orders", "/api/admin/faults"]}
