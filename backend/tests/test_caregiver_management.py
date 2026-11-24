from tests.account_payloads import patient_payload
import pytest
from fastapi.testclient import TestClient
from app.main import app
from app import users_store
from tests.conftest import TEST_ADMIN_PASSWORD, TEST_ADMIN_USERNAME


def patient_session(client):
    admin = client.post('/auth/login', json={'username': TEST_ADMIN_USERNAME, 'password': TEST_ADMIN_PASSWORD, "device_id": "test-installation"}).json()['access_token']
    headers = {'Authorization': f'Bearer {admin}'}
    patient = client.post('/admin/patients', headers=headers, json=patient_payload({'name': 'Patient', 'username': 'family-patient', 'password': 'patient-password-123'}))
    assert patient.status_code == 201
    token = client.post('/auth/login', json={'username': 'family-patient', 'password': 'patient-password-123', "device_id": "test-installation"}).json()['access_token']
    return patient.json()['user']['id'], {'Authorization': f'Bearer {token}'}


def caregiver_body():
    return {'name': 'Family Member', 'username': 'family-member', 'password': 'caregiver-password-123', 'phone': '123456789', 'relation': 'Sibling'}


def test_contact_metadata_roundtrip_and_explicit_clear_without_patient_record():
    with TestClient(app) as client:
        _, headers = patient_session(client)
        created = client.post('/patient/caregivers', headers=headers, json=caregiver_body())
        assert created.status_code == 201
        caregiver_id = created.json()['caregiver']['id']
        first = client.get('/patient/caregivers', headers=headers).json()['caregivers'][0]
        assert first['phone'] == '123456789'
        assert first['relation'] == 'Sibling'
        changed = client.patch(f'/patient/caregivers/{caregiver_id}', headers=headers, json={'phone': '', 'relation': None})
        assert changed.status_code == 200
        row = client.get('/patient/caregivers', headers=headers).json()['caregivers'][0]
        assert row['phone'] == ''
        assert row['relation'] is None
        assert row['name'] == 'Family Member'
        assert client.patch(f'/patient/caregivers/{caregiver_id}', headers=headers, json={'name': '  '}).status_code == 422


def test_link_failure_rolls_back_created_account(monkeypatch):
    with TestClient(app) as client:
        _, headers = patient_session(client)
        def fail(*args, **kwargs):
            raise RuntimeError('simulated link failure')
        monkeypatch.setattr(users_store, 'link_caregiver', fail)
        with pytest.raises(RuntimeError, match='simulated link failure'):
            client.post('/patient/caregivers', headers=headers, json=caregiver_body())
        assert users_store.get_by_username('family-member') is None


def test_disabled_access_is_patient_scoped_and_does_not_disable_login():
    with TestClient(app) as client:
        patient_id, headers = patient_session(client)
        row = client.post('/patient/caregivers', headers=headers, json=caregiver_body()).json()['caregiver']
        other = users_store.create_user(username='other-patient', name='Other', role='patient', password_hash='not-for-login')
        users_store.link_caregiver(other['id'], row['id'])
        assert client.post(f"/patient/caregivers/{row['id']}/disable", headers=headers).status_code == 200
        assert users_store.caregivers_for_patient(patient_id) == []
        assert users_store.caregivers_for_patient(other['id']) == [row['id']]
        assert users_store.get_user(row['id'])['disabled'] is False
        assert client.post('/auth/login', json={'username': 'family-member', 'password': 'caregiver-password-123', "device_id": "test-installation"}).status_code == 200
        assert client.post(f"/patient/caregivers/{row['id']}/enable", headers=headers).status_code == 200


def test_unlinked_patient_cannot_edit_caregiver():
    with TestClient(app) as client:
        _, headers = patient_session(client)
        other = users_store.create_user(username='not-linked-family', name='Unlinked', role='caregiver', password_hash='not-for-login')
        assert client.patch(f"/patient/caregivers/{other['id']}", headers=headers, json={'name': 'Forged'}).status_code == 403
        assert users_store.get_user(other['id'])['name'] == 'Unlinked'
