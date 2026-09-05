from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from app import alert_outbox
from app.preprocessing import extract_features
from app.schemas import AnalyzeResponse, RiskLabel, VitalWindow
from app.auth import authorize_patient_access, get_optional_principal, require_role

router = APIRouter(prefix="/alerts", tags=["alerts"])


class AlertTriggerRequest(BaseModel):
    patient_id: str
    window: VitalWindow
    notify_roles: list[str] = Field(default_factory=lambda: ["patient", "caregiver", "doctor"])


class AlertPayload(BaseModel):
    patient_id: str
    label: RiskLabel
    confidence: float
    message: str
    severity: str
    recipients: list[str]
    should_notify: bool


@router.post("/evaluate", response_model=AlertPayload)
def evaluate_alert(
    body: AlertTriggerRequest,
    request: Request,
    principal: dict = Depends(get_optional_principal),
):
    """Analyze a window and build an alert payload when high_risk is detected."""
    authorize_patient_access(body.patient_id, principal)
    features = extract_features(body.window)
    classifier = request.app.state.classifier
    label, confidence = classifier.predict(features)
    should_notify = label == "high_risk"
    severity = {"stable": "info", "watch": "warning", "high_risk": "critical"}[label]
    message = {
        "stable": "المؤشرات الحيوية للمريض مستقرة وطبيعية.",
        "watch": "ملاحظة: المؤشرات الحيوية بحاجة لمتابعة هادئة.",
        "high_risk": "رصد احتمال نوبة محتملة: يرجى اتخاذ تدابير الراحة والسلامة فوراً.",
    }[label]
    return AlertPayload(
        patient_id=body.patient_id,
        label=label,
        confidence=confidence,
        message=message,
        severity=severity,
        recipients=body.notify_roles if should_notify else [],
        should_notify=should_notify,
    )


@router.post("/fcm-stub")
def fcm_stub(
    alert: AlertPayload,
    principal: dict = Depends(get_optional_principal),
):
    """Durably queue an alert for delivery.

    The notification is written to the transactional outbox instead of being
    "sent" and forgotten, so a delivery failure is retried and never lost. A
    background worker performs the actual dispatch (Firebase Admin SDK in
    production).
    """
    if not alert.should_notify:
        raise HTTPException(status_code=400, detail="Alert is not marked for notification")
    authorize_patient_access(alert.patient_id, principal)
    entry = alert_outbox.enqueue_standalone(alert.patient_id, alert.model_dump())
    return {
        # Unchanged for backwards compatibility with the Flutter client; the
        # authoritative delivery state is `delivery_status`/`outbox_id`.
        "status": "queued",
        "channel": "fcm_stub",
        "patient_id": alert.patient_id,
        "recipients": alert.recipients,
        "message": alert.message,
        "outbox_id": entry["id"],
        "delivery_status": entry["status"],
    }


@router.get("/outbox")
def outbox_status(
    status: str | None = None,
    limit: int = 50,
    principal: dict = Depends(require_role("admin")),
):
    """Admin view of pending/failed notifications — makes losses visible."""
    return {
        "stats": alert_outbox.stats(),
        "entries": alert_outbox.list_entries(status=status, limit=max(1, min(limit, 200))),
    }
