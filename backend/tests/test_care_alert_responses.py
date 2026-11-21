from uuid import uuid4

from fastapi.testclient import TestClient

from app import care_store, cloud_store, users_store
from app.auth import create_token
from app.main import app


def account(role, username, *, name=None):
    user = users_store.create_user(
        username=username, name=name or username, role=role, password_hash='unused',
    )
    return user['id'], {'Authorization': f"Bearer {create_token(user['id'], role)}"}


def linked_alert():
    patient_id, patient = account('patient', 'response-patient')
    caregiver_id, caregiver = account('caregiver', 'response-family', name='Trusted family')
    users_store.link_caregiver(patient_id, caregiver_id)
    alert_id = str(uuid4())
    cloud_store.add_alert(patient_id, {'id': alert_id, 'severity': 'critical'})
    return patient_id, patient, caregiver_id, caregiver, alert_id


def body(alert_id, **patch):
    return {
        'id': str(uuid4()), 'alert_id': alert_id,
        'responder_id': 'forged-id', 'responder_name': 'Forged name',
        'status': 'seen', 'at': '2026-11-13T10:00:00Z', **patch,
    }


def test_response_roundtrip_retry_trusted_identity_and_chronology():
    with TestClient(app) as client:
        pid, patient, cid, caregiver, alert_id = linked_alert()
        path = f'/patients/{pid}/alerts/{alert_id}/responses'
        event = body(alert_id, at='2026-11-13T12:00:00+02:00')
        first = client.post(path, headers=caregiver, json=event)
        assert first.status_code == 201
        assert first.json()['responder_id'] == cid
        assert first.json()['responder_name'] == 'Trusted family'
        assert first.json()['at'] == '2026-11-13T10:00:00+00:00'
        assert first.json()['patientId'] == pid
        assert first.json()['recordedBy'] == cid
        users_store.update_user(cid, {'name': 'Updated name'})
        retry = client.post(path, headers=caregiver, json={**event, 'responder_name': 'Other forgery'})
        assert retry.status_code == 201
        assert retry.json() == first.json()
        earlier = body(alert_id, status='acknowledged', at='2026-11-13T09:30:00Z')
        assert client.post(path, headers=caregiver, json=earlier).status_code == 201
        records = client.get(path, headers=patient).json()
        assert [record['id'] for record in records] == [earlier['id'], event['id']]
        assert records[0]['responder_name'] == 'Updated name'


def test_conflicting_retry_or_other_caregiver_cannot_replace_event():
    with TestClient(app) as client:
        pid, patient, _, caregiver, alert_id = linked_alert()
        path = f'/patients/{pid}/alerts/{alert_id}/responses'
        event = body(alert_id)
        assert client.post(path, headers=caregiver, json=event).status_code == 201
        for patch in [{'status': 'arrived'}, {'at': '2026-11-13T11:00:00Z'}]:
            assert client.post(path, headers=caregiver, json={**event, **patch}).status_code == 409
        other_id, other = account('caregiver', 'response-other-family')
        users_store.link_caregiver(pid, other_id)
        assert client.post(path, headers=other, json=event).status_code == 409
        assert client.get(path, headers=patient).json()[0]['status'] == 'seen'
        assert len(care_store.list_records(pid, 'alert-response')) == 1


def test_role_patient_relationship_and_revocation_boundaries():
    with TestClient(app) as client:
        pid, patient, cid, caregiver, alert_id = linked_alert()
        path = f'/patients/{pid}/alerts/{alert_id}/responses'
        did, doctor = account('doctor', 'response-doctor')
        _, other_patient = account('patient', 'response-other-patient')
        _, unlinked = account('caregiver', 'response-unlinked')
        assert client.get(path).status_code == 401
        for forbidden in [other_patient, doctor, unlinked]:
            assert client.get(path, headers=forbidden).status_code == 403
        users_store.assign_patient(pid, did)
        assert client.get(path, headers=doctor).status_code == 200
        for forbidden in [patient, doctor, unlinked]:
            assert client.post(path, headers=forbidden, json=body(alert_id)).status_code == 403
        users_store.set_caregiver_link_disabled(pid, cid, True)
        assert client.get(path, headers=caregiver).status_code == 403
        assert client.post(path, headers=caregiver, json=body(alert_id)).status_code == 403
        users_store.set_caregiver_link_disabled(pid, cid, False)
        users_store.set_disabled(cid, True)
        assert client.get(path, headers=caregiver).status_code == 401
        assert client.post(path, headers=caregiver, json=body(alert_id)).status_code == 401
        assert care_store.list_records(pid, 'alert-response') == []


def test_missing_alert_patient_mismatch_and_body_mismatch():
    with TestClient(app) as client:
        pid, patient, _, caregiver, alert_id = linked_alert()
        other_pid, _ = account('patient', 'response-foreign-patient')
        foreign_alert = str(uuid4())
        cloud_store.add_alert(other_pid, {'id': foreign_alert, 'severity': 'warning'})
        for missing in [str(uuid4()), foreign_alert]:
            path = f'/patients/{pid}/alerts/{missing}/responses'
            assert client.get(path, headers=patient).status_code == 404
            assert client.post(path, headers=caregiver, json=body(missing)).status_code == 404
        path = f'/patients/{pid}/alerts/{alert_id}/responses'
        assert client.post(path, headers=caregiver, json=body(foreign_alert)).status_code == 422
        assert care_store.list_records(pid, 'alert-response') == []


def test_response_validation_rejects_unknown_status_naive_and_future_clock():
    with TestClient(app) as client:
        pid, _, _, caregiver, alert_id = linked_alert()
        path = f'/patients/{pid}/alerts/{alert_id}/responses'
        for patch in [
            {'id': 'invalid'}, {'status': 'delivered'}, {'at': 'invalid'},
            {'at': '2026-11-13T10:00:00'}, {'at': '2999-01-01T00:00:00Z'},
        ]:
            assert client.post(path, headers=caregiver, json=body(alert_id, **patch)).status_code == 422
        for status in ['seen', 'acknowledged', 'on_way', 'arrived']:
            assert client.post(path, headers=caregiver, json=body(alert_id, status=status)).status_code == 201
        assert len(care_store.list_records(pid, 'alert-response')) == 4


def test_responses_are_filtered_per_alert_before_any_record_limit():
    with TestClient(app) as client:
        pid, _, cid, caregiver, alert_id = linked_alert()
        path = f'/patients/{pid}/alerts/{alert_id}/responses'
        event = body(alert_id)
        assert client.post(path, headers=caregiver, json=event).status_code == 201
        # More recent events for other alerts must not hide this alert's event.
        for index in range(505):
            payload = body(f'other-{index}', responder_id=cid, responder_name='Trusted family')
            care_store.save(pid, 'alert-response', payload['id'], payload, cid)
        result = client.get(path, headers=caregiver)
        assert result.status_code == 200
        assert [record['id'] for record in result.json()] == [event['id']]


def test_audit_failure_rolls_back_alert_response(monkeypatch):
    with TestClient(app, raise_server_exceptions=False) as client:
        pid, patient, _, caregiver, alert_id = linked_alert()
        path = f'/patients/{pid}/alerts/{alert_id}/responses'

        def audit_failure(*args, **kwargs):
            raise RuntimeError('isolated audit failure')

        with monkeypatch.context() as patch:
            patch.setattr(users_store, 'log', audit_failure)
            assert client.post(path, headers=caregiver, json=body(alert_id)).status_code == 500
        assert client.get(path, headers=patient).json() == []
