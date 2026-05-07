"""Admin endpoints to flip fault toggles for the demo."""
from fastapi import APIRouter
from pydantic import BaseModel

from app.config import settings

router = APIRouter()


class FaultState(BaseModel):
    fault_force_openai_down: bool | None = None
    fault_force_speech_down: bool | None = None
    fault_force_thirdparty_down: bool | None = None
    fault_force_cosmos_dns_break: bool | None = None
    fault_extra_cpu_burn_ms: int | None = None
    fault_force_exception: bool | None = None


@router.get("/faults")
def get_faults():
    return {
        "fault_force_openai_down": settings.fault_force_openai_down,
        "fault_force_speech_down": settings.fault_force_speech_down,
        "fault_force_thirdparty_down": settings.fault_force_thirdparty_down,
        "fault_force_cosmos_dns_break": settings.fault_force_cosmos_dns_break,
        "fault_extra_cpu_burn_ms": settings.fault_extra_cpu_burn_ms,
        "fault_force_exception": settings.fault_force_exception,
        "deployment_version": settings.deployment_version,
        "pod": settings.pod_name,
    }


@router.post("/faults")
def set_faults(state: FaultState):
    for k, v in state.model_dump(exclude_unset=True).items():
        setattr(settings, k, v)
    return get_faults()
