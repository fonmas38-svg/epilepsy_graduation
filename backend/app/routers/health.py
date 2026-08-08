from fastapi import APIRouter, Request

router = APIRouter(tags=["health"])


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
        "version": "2.2.0",
        "engine": engine,
    }
