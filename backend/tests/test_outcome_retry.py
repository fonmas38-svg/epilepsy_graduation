from uuid import uuid4
from fastapi.testclient import TestClient
from app import users_store, cloud_store
from app.auth import create_token
from app.main import app


def test_observed_outcome_retry_preserves_one_record_and_rejects_changed_data():
    with TestClient(app) as client:
        patient = users_store.create_user(username='outcome-retry', name='Patient', role='patient', password_hash='unused')
        cloud_store.upsert_patient(patient['id'], {'name': 'Patient'})
        headers = {'Authorization': f"Bearer {create_token(patient['id'], 'patient')}"}
        path = f"/patients/{patient['id']}/outcomes"
        body = {'id': str(uuid4()), 'outcome': 'unknown', 'occurred_at': '2026-11-14T10:00:00Z', 'notes': 'Needs review', 'metadata': {'source': 'manual'}}
        first = client.post(path, headers=headers, json=body)
        assert first.status_code == 201, first.text
        repeated = client.post(path, headers=headers, json=body)
        assert repeated.status_code == 201
        assert first.json()['outcome']['id'] == repeated.json()['outcome']['id'] == body['id']
        assert len(client.get(path, headers=headers).json()['outcomes']) == 1
        for changes in [{'outcome': 'seizure'}, {'metadata': {}}, {'notes': 'changed'}]:
            conflict = client.post(path, headers=headers, json={**body, **changes})
            assert conflict.status_code == 409
        assert len(client.get(path, headers=headers).json()['outcomes']) == 1
