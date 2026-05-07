"""Health endpoints — used by APIM probe + Grafana scenario verification."""
from fastapi import APIRouter
from app.config import settings

router = APIRouter()


@router.get("/health")
def health():
    return {
        "status": "ok",
        "service": "api-service",
        "deployment_version": settings.deployment_version,
        "pod": settings.pod_name,
    }


@router.get("/ready")
def ready():
    return {"status": "ready"}
