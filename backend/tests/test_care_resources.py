from uuid import uuid4

from fastapi.testclient import TestClient

from app import users_store
from app.auth import create_token
from app.main import app


def account(role, username):
    user = users_store.create_user(username=username, name=username, role=role, password_hash='unused')
    return user['id'], {'Authorization': f"Bearer {create_token(user['id'], role)}"}


def test_contacts_retry_conflict_update_and_tombstones():
    with TestClient(app) as client:
        pid, headers = account('patient', 'care-patient')
        path = f'/patients/{pid}/emergency-contacts'
        body = dict(id=str(uuid4()), name='Family', phone='+123456789', priority=0)
        assert client.post(path, headers=headers, json=body).status_code == 201
        assert client.post(path, headers=headers, json=body).status_code == 201
        assert len(client.get(path, headers=headers).json()) == 1
        assert client.post(path, headers=headers, json={**body, 'phone': 'changed'}).status_code == 409
        assert client.put(f"{path}/{body['id']}", headers=headers, json={**body, 'phone': 'changed'}).status_code == 200
        assert client.delete(f"{path}/{body['id']}", headers=headers).status_code == 200
        assert client.post(path, headers=headers, json=body).status_code == 409
        assert client.get(path, headers=headers).json() == []
        body['id'] = str(uuid4())
        assert client.delete(f"{path}/{body['id']}", headers=headers).status_code == 200
        assert client.post(path, headers=headers, json=body).status_code == 409


def test_medical_card_roundtrip_and_clear():
    with TestClient(app) as client:
        pid, headers = account('patient', 'card-patient')
        path = f'/patients/{pid}/medical-card'
        assert client.get(path, headers=headers).json() == {}
        assert client.put(path, headers=headers, json={'diagnosis': 'Recorded by patient', 'blood_type': 'O+'}).status_code == 200
        assert client.get(path, headers=headers).json()['blood_type'] == 'O+'
        assert client.put(path, headers=headers, json={}).status_code == 200
        assert client.get(path, headers=headers).json()['diagnosis'] == ''


def test_trigger_validation_and_retry():
    with TestClient(app) as client:
        pid, headers = account('patient', 'trigger-patient')
        path = f'/patients/{pid}/triggers'
        body = dict(id=str(uuid4()), occurred_at='2026-11-13T10:00:00Z', kind='stress', intensity=3)
        assert client.post(path, headers=headers, json=body).status_code == 201
        assert client.post(path, headers=headers, json=body).status_code == 201
        assert len(client.get(path, headers=headers).json()['triggers']) == 1
        for patch in [{'occurred_at': '2026-11-13T10:00:00'}, {'kind': 'unknown'}, {'intensity': 6}]:
            assert client.post(path, headers=headers, json={**body, **patch}).status_code == 422
        assert client.delete(f"{path}/{body['id']}", headers=headers).status_code == 200
        assert client.get(path, headers=headers).json()['triggers'] == []
        assert client.get(path, headers=headers).json()['deleted_ids'] == [body['id']]


def test_role_and_patient_boundaries_and_note_author():
    with TestClient(app) as client:
        pid, patient = account('patient', 'scope-patient')
        _, other = account('patient', 'scope-other')
        did, doctor = account('doctor', 'scope-doctor')
        cid, caregiver = account('caregiver', 'scope-family')
        root = f'/patients/{pid}'
        assert client.get(f'{root}/medical-card', headers=other).status_code == 403
        assert client.get(f'{root}/medical-card', headers=doctor).status_code == 403
        users_store.assign_patient(pid, did)
        users_store.link_caregiver(pid, cid)
        assert client.get(f'{root}/medical-card', headers=caregiver).status_code == 200
        assert client.put(f'{root}/medical-card', headers=caregiver, json={}).status_code == 403
        assert client.get(f'{root}/clinical-notes', headers=caregiver).status_code == 403
        note = dict(id=str(uuid4()), text='Clinical observation', written_at='2026-11-13T10:00:00Z', doctor_id='forged')
        assert client.post(f'{root}/clinical-notes', headers=patient, json=note).status_code == 403
        response = client.post(f'{root}/clinical-notes', headers=doctor, json=note)
        assert response.status_code == 201
        assert response.json()['doctor_id'] == did
        assert client.post(f'{root}/clinical-notes', headers=doctor, json=note).status_code == 201
        assert len(client.get(f'{root}/clinical-notes', headers=patient).json()) == 1
        users_store.set_caregiver_link_disabled(pid, cid, True)
        assert client.get(f'{root}/medical-card', headers=caregiver).status_code == 403


def test_upload_clinical_report_endpoint(monkeypatch):
    import base64
    from app.routers import care

    # Mock upload_clinical_report to avoid external network dependency in unit tests
    monkeypatch.setattr(
        care,
        'upload_clinical_report',
        lambda data, name, content_type='application/pdf': {
            'success': True,
            'bucket': 'clinical-reports',
            'path': name,
            'url': f'https://mock.supabase.co/storage/v1/object/public/clinical-reports/{name}',
        },
    )

    with TestClient(app) as client:
        pid, patient_headers = account('patient', 'upload-patient')
        _, other_headers = account('patient', 'upload-other')

        # Invalid base64
        res = client.post(
            f'/patients/{pid}/reports/upload',
            headers=patient_headers,
            json={'filename': 'report.pdf', 'file_base64': 'invalid!!!', 'content_type': 'application/pdf'},
        )
        assert res.status_code == 422

        # Valid upload
        valid_b64 = base64.b64encode(b'%PDF-1.4 mock content').decode('ascii')
        res = client.post(
            f'/patients/{pid}/reports/upload',
            headers=patient_headers,
            json={'filename': 'report.pdf', 'file_base64': valid_b64, 'content_type': 'application/pdf'},
        )
        assert res.status_code == 201
        data = res.json()
        assert data['success'] is True
        assert 'clinical-reports' in data['url']

        # Unauthorized access by another patient
        res = client.post(
            f'/patients/{pid}/reports/upload',
            headers=other_headers,
            json={'filename': 'report.pdf', 'file_base64': valid_b64, 'content_type': 'application/pdf'},
        )
        assert res.status_code == 403

