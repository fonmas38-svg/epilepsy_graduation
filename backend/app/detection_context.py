"""Research detection attribution; absence of history is not a clinical miss."""
from datetime import datetime, timezone
import math

from sqlalchemy import select
from app.database import assessments, load_json


def detection_context(conn, patient_id: str, assessment: dict, device_id: str, window) -> dict:
    at = datetime.fromisoformat(assessment['timestamp'].replace('Z', '+00:00')).astimezone(timezone.utc)
    horizon = assessment.get('horizon_min') or 30
    if not isinstance(horizon, (float, int)) or not math.isfinite(horizon) or not 0 < horizon <= 120:
        horizon = 30
    prior = None
    # Existing retention is bounded: do not claim complete prospective coverage.
    rows = conn.execute(select(assessments.c.payload_json).where(
        assessments.c.patient_id == patient_id,
    ).order_by(assessments.c.sequence.desc()).limit(500))
    for row in rows:
        candidate = load_json(row[0], {})
        fields = {**(candidate.get('features') or {}), **candidate}
        try:
            occurred = datetime.fromisoformat(fields['timestamp'].replace('Z', '+00:00'))
            delta = (at - occurred).total_seconds()
        except (AttributeError, KeyError, TypeError, ValueError):
            continue
        if not 0 < delta <= horizon * 60:
            continue
        components = fields.get('components') or {}
        if (fields.get('predicted') is True and fields.get('label') != 'high_risk'
                and fields.get('prediction_source') in ('cloud_preictal_net', 'cnn_lstm_preictal')
                and components.get('assessment_valid', True)):
            prior = {'assessment_id': fields.get('id'), 'at': fields['timestamp'],
                     'source': fields['prediction_source'], 'lead_seconds': delta}
            break
    return {
        'event_kind': 'experimental_high_risk_detection',
        'confirmed_seizure': False, 'clinically_validated': False,
        'forecast_status': 'prior_model_forecast' if prior else 'no_prior_alert_in_available_history',
        'prior_forecast': prior, 'history_complete': False,
        'warning_delivery_status': 'not_verified',
        'clinical_false_negative_established': False,
        'lookback_minutes': horizon, 'detected_at': assessment['timestamp'],
        'device_id': device_id, 'assessment_id': assessment['id'],
        'reading_id': assessment.get('reading_id'),
        'engine': assessment.get('engine'), 'classification_score': assessment.get('confidence'),
        'sample_count': len(window.eeg), 'sample_rate_hz': 256,
        'heart_rate_bpm': window.hr, 'location_status': 'not_captured_by_device',
    }
