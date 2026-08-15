from fastapi import APIRouter, Request, Response

router = APIRouter(tags=["health"])
API_VERSION = "2.2.0"


@router.get("/health/live")
def liveness():
    return {"status": "alive", "service": "epilepsy-monitoring-api"}


@router.get("/health/ready")
def readiness(request: Request, response: Response):
    checks = {"classifier": False, "device_hub": False}
    try:
        checks["classifier"] = bool(request.app.state.classifier.engine_info())
    except Exception:  # noqa: BLE001 - readiness reports degraded state
        pass
    checks["device_hub"] = hasattr(request.app.state, "device_hub")
    ready = all(checks.values())
    if not ready:
        response.status_code = 503
    return {
        "status": "ready" if ready else "degraded",
        "service": "epilepsy-monitoring-api",
        "version": API_VERSION,
        "checks": checks,
    }


@router.get("/health")
def health_check(request: Request):
    engine = None
    try:
        engine = request.app.state.classifier.engine_info()["active_engine"]
    except Exception:  # noqa: BLE001 - health must never fail
        pass
    return {
        "status": "ok",
        "service": "epilepsy-monitoring-api",
        "version": API_VERSION,
        "engine": engine,
    }
