from datetime import datetime, timedelta, timezone
from uuid import uuid4

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


def credentials(client):
    admin = client.post('/auth/login', json={'username': TEST_ADMIN_USERNAME, 'password': TEST_ADMIN_PASSWORD}).json()['access_token']
    headers = {'Authorization': f'Bearer {admin}'}
    ids, tokens = [], []
    for i in range(2):
        row = client.post('/admin/patients', headers=headers, json={
            'username': f'event-patient-{i}', 'name': f'Patient {i}', 'password': 'report-password-123',
        })
        assert row.status_code == 201, row.text
        ids.append(row.json()['user']['id'])
        token = client.post('/auth/login', json={'username': f'event-patient-{i}', 'password': 'report-password-123'}).json()['access_token']
        tokens.append({'Authorization': f'Bearer {token}'})
    return ids, tokens


def payload():
    return {'id': str(uuid4()), 'occurred_at': (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat(),
            'duration_seconds': 45, 'seizure_type': 'other', 'notes': 'Observed event, unknown diagnosis',
            'reported_by': 'forged-doctor', 'alert_id': None}


def test_report_replay_is_idempotent_and_does_not_claim_clinical_confirmation():
    with TestClient(app) as client:
        ids, headers = credentials(client)
        path = f'/patients/{ids[0]}/seizure-logs'
        body = payload()
        for _ in range(2):
            result = client.post(path, headers=headers[0], json=body)
            assert result.status_code == 201, result.text
            event = result.json()['event']
            assert event['id'] == body['id']
            assert event['reportedBy'] == ids[0]
            assert event['clinicallyConfirmed'] is False
        rows = client.get(path, headers=headers[0]).json()
        assert len(rows) == 1
        assert rows[0]['durationSeconds'] == 45
        assert client.get(path, headers=headers[1]).status_code == 403
        assert client.post(path, headers=headers[1], json=payload()).status_code == 403
        assert client.get(path).status_code == 401
        altered = {**body, 'notes': 'Different record with reused identity'}
        assert client.post(path, headers=headers[0], json=altered).status_code == 422
        assert client.get(path, headers=headers[0]).json()[0]['notes'] == body['notes']


def test_event_requires_valid_timezone_duration_and_same_patient_identity():
    with TestClient(app) as client:
        ids, headers = credentials(client)
        path = f'/patients/{ids[0]}/seizure-logs'
        body = payload()
        for patch in ({'duration_seconds': -1}, {'duration_seconds': 0}, {'duration_seconds': 86401},
                      {'occurred_at': '2026-01-01T01:00:00'},
                      {'occurred_at': (datetime.now(timezone.utc) + timedelta(days=10)).isoformat()},
                      {'seizure_type': 'unsupported'}, {'id': 'not-a-uuid'}):
            assert client.post(path, headers=headers[0], json={**body, **patch}).status_code == 422
        assert client.post(path, headers=headers[0], json=body).status_code == 201
        other_path = f'/patients/{ids[1]}/seizure-logs'
        assert client.post(other_path, headers=headers[1], json=body).status_code == 422
        assert client.get(other_path, headers=headers[1]).json() == []
