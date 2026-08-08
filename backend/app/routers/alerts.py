from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from app.preprocessing import extract_features
from app.schemas import AnalyzeResponse, RiskLabel, VitalWindow

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
def evaluate_alert(body: AlertTriggerRequest, request: Request):
    """Analyze a window and build an alert payload when high_risk is detected."""
    features = extract_features(body.window)
    classifier = request.app.state.classifier
    label, confidence = classifier.predict(features)
    should_notify = label == "high_risk"
    severity = {"stable": "info", "watch": "warning", "high_risk": "critical"}[label]
    message = {
        "stable": "Patient vitals look stable.",
        "watch": "Patient needs closer monitoring.",
        "high_risk": "High seizure risk detected. Check on the patient immediately.",
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
def fcm_stub(alert: AlertPayload):
    """
    Stub for FCM dispatch. In production, call Firebase Admin SDK here.
    Mobile app still receives Firestore-written alerts + local FCM tokens.
    """
    if not alert.should_notify:
        raise HTTPException(status_code=400, detail="Alert is not marked for notification")
    return {
        "status": "queued",
        "channel": "fcm_stub",
        "patient_id": alert.patient_id,
        "recipients": alert.recipients,
        "message": alert.message,
    }
