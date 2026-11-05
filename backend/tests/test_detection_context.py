from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app import cloud_store, notification_delivery
from app.device_hub import DeviceHub, DeviceSample
from app.preprocessing import extract_features


class Detector:
    def predict_window(self, window):
        return SimpleNamespace(label='high_risk', confidence=0.9,
            features=extract_features(window), engine='test_detector',
            components={'assessment_valid': True})


def detect(batch='one'):
    samples = [DeviceSample(eeg=i % 7 + 0.1, ecg=0.2, motion=0.1, hr=120) for i in range(262)]
    return DeviceHub().ingest('p1', 'd1', samples, Detector(), batch_id=batch)


def prior(patient='p1', source='cloud_preictal_net', after=False):
    cloud_store.add_assessment(patient, {
        'id': 'forecast', 'timestamp': (datetime.now(timezone.utc) + timedelta(seconds=10 if after else -10)).isoformat(),
        'label': 'watch', 'predicted': True, 'prediction_source': source,
        'components': {'assessment_valid': True},
    })


def test_detection_without_forecast_is_saved_but_not_called_a_clinical_miss():
    result = detect()
    detail = result['assessment']['features']['detection_event']
    assert detail['forecast_status'] == 'no_prior_alert_in_available_history'
    assert detail['confirmed_seizure'] is False
    assert detail['clinical_false_negative_established'] is False
    alert = cloud_store.list_alerts('p1')[0]
    assert alert['details']['assessment_id'] == result['assessment']['id']
    assert set(alert['recipients']) == {'patient', 'caregiver', 'doctor'}


def test_prior_research_forecast_linked_to_detection():
    prior()
    detail = detect()['assessment']['features']['detection_event']
    assert detail['forecast_status'] == 'prior_model_forecast'
    assert detail['prior_forecast']['assessment_id'] == 'forecast'
    assert detail['prior_forecast']['lead_seconds'] > 0
    assert detail['history_complete'] is False


@pytest.mark.parametrize('kwargs', [{'patient': 'other'}, {'source': 'simulated_heuristic'}, {'after': True}])
def test_foreign_simulated_and_future_forecasts_do_not_establish_advance_warning(kwargs):
    prior(**kwargs)
    assert detect()['assessment']['features']['detection_event']['prior_forecast'] is None


def test_cooldown_suppresses_push_but_not_detection_evidence():
    detect('first')
    second = detect('second')
    assert second['assessment']['features']['detection_event']
    assert len(cloud_store.list_assessments('p1')) == 2
    assert len(cloud_store.list_alerts('p1')) == 1


def test_undated_legacy_assessment_does_not_crash_live_detection():
    cloud_store.add_assessment('p1', {'id': 'legacy', 'timestamp': None, 'label': 'watch', 'predicted': True})
    assert detect()['assessment']['features']['detection_event']['prior_forecast'] is None


def test_dataset_replay_never_raises_a_physical_device_alert():
    samples = [DeviceSample(eeg=i % 7 + 0.1, ecg=0.2, motion=0.1, hr=120) for i in range(262)]
    DeviceHub().ingest('p1', 'replay', samples, Detector(), source='dataset')
    assert cloud_store.list_assessments('p1')
    assert cloud_store.list_alerts('p1') == []


def test_unavailable_offline_assessment_does_not_replace_real_patient_state():
    now = datetime.now(timezone.utc)
    cloud_store.add_assessment('p1', {'id': 'valid', 'label': 'high_risk', 'timestamp': (now - timedelta(seconds=10)).isoformat()})
    cloud_store.add_assessment('p1', {'id': 'offline', 'label': 'watch', 'timestamp': now.isoformat(),
        'confidence': 0, 'features': {'assessment_valid': False, 'offline': True}})
    assert len(cloud_store.list_assessments('p1')) == 2
    assert cloud_store.get_patient('p1')['currentStatus'] == 'high_risk'


def test_notification_batches_and_private_details_not_in_lockscreen(monkeypatch):
    sent = []
    class Messaging:
        class Notification:
            def __init__(self, **kw): self.values = kw
        class MulticastMessage:
            def __init__(self, **kw): self.values = kw
        @staticmethod
        def send_each_for_multicast(message):
            sent.append(message.values)
            n = len(message.values['tokens'])
            return SimpleNamespace(success_count=n, failure_count=0,
                responses=[SimpleNamespace(success=True, exception=None) for _ in range(n)])
    monkeypatch.setenv('NOTIFICATION_CHANNEL', 'fcm')
    monkeypatch.setattr(notification_delivery, '_firebase_messaging', lambda: Messaging)
    monkeypatch.setattr(notification_delivery.push_tokens_store, 'tokens_for_alert', lambda *args: [f'token{i}' for i in range(1001)])
    result = notification_delivery.deliver({'id': 'a1', 'patient_id': 'p1', 'message': 'private diagnosis and coordinates'})
    assert result['success'] == 1001
    assert [len(m['tokens']) for m in sent] == [500, 500, 1]
    assert all('private diagnosis' not in str(m['notification'].values) for m in sent)
    assert all(m['data']['alert_id'] == 'a1' for m in sent)


def test_alert_detail_access_is_patient_scoped_even_in_demo_mode():
    from fastapi import HTTPException
    from app.routers.clinical import alert_details
    cloud_store.add_alert('p1', {'id': 'detail-a', 'severity': 'warning', 'details': {'assessment_id': 'e1'}})
    assert alert_details('p1', 'detail-a', {'role': 'admin', 'sub': 'admin'})['alert']['details']['assessment_id'] == 'e1'
    with pytest.raises(HTTPException) as exc:
        alert_details('p2', 'detail-a', {'role': 'admin', 'sub': 'admin'})
    assert exc.value.status_code == 404
    with pytest.raises(HTTPException) as exc:
        alert_details('p1', 'detail-a', {})
    assert exc.value.status_code in (401, 403)
