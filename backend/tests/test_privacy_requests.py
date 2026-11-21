from uuid import uuid4
import pytest
from sqlalchemy import event
from fastapi.testclient import TestClient
from app.main import app
from app import care_store, users_store
from app.database import get_engine
from tests.test_care_resources import account


def body():
    return {'id': str(uuid4()), 'requested_at': '2026-11-14T10:00:00Z', 'reason': 'Please review account erasure'}


def test_request_is_replay_safe_and_private_to_patient_and_admin():
    with TestClient(app) as client:
        pid, patient = account('patient', 'privacy-patient')
        _, other = account('patient', 'privacy-other')
        _, doctor = account('doctor', 'privacy-doctor')
        _, admin = account('admin', 'privacy-admin')
        item = body()
        path = f'/patients/{pid}/deletion-request'
        assert client.post(path, headers=patient, json=item).status_code == 201
        assert client.post(path, headers=patient, json=item).status_code == 201
        assert client.post(path, headers=patient, json={**item, 'reason': 'changed'}).status_code == 409
        assert client.post(path, headers=other, json=body()).status_code == 403
        assert client.get(f'/patients/{pid}/deletion-requests', headers=doctor).status_code == 403
        rows = client.get(f'/patients/{pid}/deletion-requests', headers=patient).json()['requests']
        assert len(rows) == 1 and rows[0]['status'] == 'received'
        assert client.get('/admin/deletion-requests', headers=patient).status_code == 403
        assert len(client.get('/admin/deletion-requests', headers=admin).json()['requests']) == 1


def test_review_uses_version_and_does_not_claim_erasure_completed():
    with TestClient(app) as client:
        pid, patient = account('patient', 'review-patient')
        _, admin = account('admin', 'review-admin')
        item = body()
        client.post(f'/patients/{pid}/deletion-request', headers=patient, json=item)
        path = f"/admin/deletion-requests/{pid}/{item['id']}/review"
        started = client.post(path, headers=admin, json={'status': 'under_review'})
        assert started.status_code == 200
        version = started.json()['request']['reviewVersion']
        assert version
        assert client.post(path, headers=admin, json={'status': 'rejected', 'note': 'Missing verification'}).status_code == 409
        assert client.post(path, headers=admin, json={'status': 'rejected', 'expected_version': version}).status_code == 422
        draft = {'status': 'rejected', 'note': 'Verify identity through support', 'expected_version': version}
        assert client.post(path, headers=admin, json=draft).status_code == 200
        assert client.post(path, headers=admin, json=draft).status_code == 200
        assert client.post(path, headers=admin, json={'status': 'completed'}).status_code == 422
        row = client.get(f'/patients/{pid}/deletion-requests', headers=patient).json()['requests'][0]
        assert row['status'] == 'rejected' and row['reviewNote'] == draft['note']
        assert users_store.get_user(pid)['disabled'] is False


def test_erasure_request_and_audit_rollback_together(monkeypatch):
    with TestClient(app) as client:
        pid, patient = account('patient', 'atomic-privacy')
        def fail(*args, **kwargs): raise RuntimeError('audit failure')
        monkeypatch.setattr(users_store, 'log', fail)
        with pytest.raises(RuntimeError, match='audit failure'):
            client.post(f'/patients/{pid}/deletion-request', headers=patient, json=body())
        assert care_store.list_records(pid, 'deletion-request') == []


def test_inbox_loads_requests_and_reviews_with_one_joined_read():
    with TestClient(app) as client:
        pid, _ = account('patient', 'inbox-patient')
        _, admin = account('admin', 'inbox-admin')
        for index in range(20):
            item = body()
            care_store.save(pid, 'deletion-request', item['id'], item, pid)
            if index == 0:
                care_store.save(pid, 'deletion-review', item['id'], {'status': 'under_review', 'note': 'Review started'}, 'admin')
        statements = []
        def capture(conn, cursor, statement, parameters, context, executemany):
            if 'privacy_requests' in statement and 'privacy_reviews' in statement:
                statements.append(statement)
        engine = get_engine()
        event.listen(engine, 'before_cursor_execute', capture)
        try:
            result = client.get('/admin/deletion-requests', headers=admin)
        finally:
            event.remove(engine, 'before_cursor_execute', capture)
        assert result.status_code == 200
        assert len(result.json()['requests']) == 20
        assert sum(row['status'] == 'under_review' for row in result.json()['requests']) == 1
        assert len(statements) == 1
