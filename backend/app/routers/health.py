from fastapi import APIRouter, Depends, Request, Response
from sqlalchemy import text

from app import alert_outbox
from app.auth import require_role
from app.metrics import metrics

router = APIRouter(tags=["health"])
API_VERSION = "2.3.0"


def _database_ready() -> tuple[bool, str | None]:
    """Actually touch the database.

    Readiness must fail when storage is unusable (locked file, failed
    migration); otherwise a load balancer keeps routing traffic that is
    guaranteed to return 500.
    """
    try:
        from app.database import connection

        with connection() as conn:
            conn.execute(text("SELECT 1"))
        return True, None
    except Exception as exc:  # noqa: BLE001 - readiness reports, never raises
        return False, f"{type(exc).__name__}: {exc}"


@router.get("/health/live")
def liveness():
    """Process is up. Must not touch dependencies, or a database blip would
    trigger pointless restarts."""
    return {"status": "alive", "service": "epilepsy-monitoring-api"}


@router.get("/health/ready")
def readiness(request: Request, response: Response):
    checks = {"classifier": False, "device_hub": False, "database": False}
    errors: dict[str, str] = {}
    try:
        checks["classifier"] = bool(request.app.state.classifier.engine_info())
    except Exception as exc:  # noqa: BLE001 - readiness reports degraded state
        errors["classifier"] = f"{type(exc).__name__}: {exc}"
    checks["device_hub"] = hasattr(request.app.state, "device_hub")
    checks["database"], db_error = _database_ready()
    if db_error:
        errors["database"] = db_error
    ready = all(checks.values())
    if not ready:
        response.status_code = 503
    body = {
        "status": "ready" if ready else "degraded",
        "service": "epilepsy-monitoring-api",
        "version": API_VERSION,
        "checks": checks,
    }
    if errors:
        body["errors"] = errors
    return body


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


@router.get("/metrics")
def operational_metrics(principal: dict = Depends(require_role("admin"))):
    """Counters, inference latency, and notification-delivery health.

    Admin-only: latency and alert volumes reveal patient activity patterns.
    """
    snapshot = metrics.snapshot()
    try:
        snapshot["alert_outbox"] = alert_outbox.stats()
    except Exception as exc:  # noqa: BLE001 - metrics must never fail
        snapshot["alert_outbox"] = {"error": f"{type(exc).__name__}: {exc}"}
    return snapshot
