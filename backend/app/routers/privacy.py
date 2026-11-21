"""Audited account-erasure requests; review never performs a silent data wipe."""
from datetime import datetime, timezone
from typing import Literal
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, update, and_
from app import care_store, users_store
from app.auth import authorize_patient_access, require_role
from app.database import care_records, users, connection, transaction, upsert, dump_json, load_json
from app.schemas import validate_utc_timestamp

router = APIRouter(tags=['privacy-requests'])
patient_role = require_role('patient')
admin_role = require_role('admin')


class DeletionRequest(BaseModel):
    id: UUID
    requested_at: str
    reason: str = Field(default='', max_length=2000)


class ReviewRequest(BaseModel):
    status: Literal['under_review', 'rejected']
    note: str = Field(default='', max_length=2000)
    expected_version: str | None = Field(default=None, max_length=64)


def combined_view(request, review):
    return {**request, 'recordedAt': request['updatedAt'],
            'status': review['status'] if review else 'received',
            'reviewNote': review['note'] if review else '',
            'reviewVersion': review['updatedAt'] if review else None,
            'reviewedAt': review['updatedAt'] if review else None}


def view(request):
    return combined_view(request, care_store.get_record(request['patientId'], 'deletion-review', request['id']))


def request_list(patient_id, limit):
    requests = care_records.alias('privacy_requests')
    reviews = care_records.alias('privacy_reviews')
    query = select(requests, users.c.name.label('patient_name'),
        reviews.c.payload_json.label('review_payload'), reviews.c.updated_at.label('review_at'))
    query = query.outerjoin(reviews, and_(reviews.c.patient_id == requests.c.patient_id,
        reviews.c.kind == 'deletion-review', reviews.c.record_id == requests.c.record_id, reviews.c.deleted.is_(False)))
    query = query.join(users, users.c.id == requests.c.patient_id).where(
        requests.c.kind == 'deletion-request', requests.c.deleted.is_(False))
    if patient_id is not None:
        query = query.where(requests.c.patient_id == patient_id)
    with connection() as conn:
        rows = conn.execute(query.order_by(requests.c.updated_at.desc(), requests.c.record_id, requests.c.patient_id).limit(limit + 1)).all()
    result = []
    for row in rows[:limit]:
        data = row._mapping
        review = {**load_json(data['review_payload'], {}), 'updatedAt': data['review_at']} if data['review_at'] else None
        result.append({**combined_view(care_store.public_record(row), review), 'patientName': data['patient_name']})
    return {'requests': result, 'hasMore': len(rows) > limit}


@router.post('/patients/{patient_id}/deletion-request', status_code=201)
def request_deletion(patient_id: str, body: DeletionRequest, actor: dict = Depends(patient_role)):
    authorize_patient_access(patient_id, actor, enforce=True)
    try:
        validate_utc_timestamp(body.requested_at, 'requested_at')
    except ValueError as error:
        raise HTTPException(422, str(error)) from error
    try:
        with transaction():
            row = care_store.save(patient_id, 'deletion-request', str(body.id), body.model_dump(mode='json'), actor['sub'])
            users_store.log(actor['sub'], actor['role'], 'request_account_erasure', str(body.id), {'patientId': patient_id})
    except ValueError as error:
        raise HTTPException(409, 'request identifier conflict') from error
    return {'request': view(row)}


@router.get('/patients/{patient_id}/deletion-requests')
def own_requests(patient_id: str, limit: int = Query(100, ge=1, le=500), actor: dict = Depends(patient_role)):
    authorize_patient_access(patient_id, actor, enforce=True)
    return request_list(patient_id, limit)


@router.get('/admin/deletion-requests')
def admin_requests(limit: int = Query(100, ge=1, le=500), actor: dict = Depends(admin_role)):
    return request_list(None, limit)


@router.post('/admin/deletion-requests/{patient_id}/{request_id}/review')
def review_request(patient_id: str, request_id: UUID, body: ReviewRequest, actor: dict = Depends(admin_role)):
    if body.status == 'rejected' and not body.note.strip():
        raise HTTPException(422, 'a rejection reason is required')
    with transaction() as conn:
        request = care_store.get_record(patient_id, 'deletion-request', str(request_id))
        if not request:
            raise HTTPException(404, 'request not found')
        previous = care_store.get_record(patient_id, 'deletion-review', str(request_id))
        payload = {'status': body.status, 'note': body.note.strip()}
        if previous and previous['status'] == body.status and previous['note'] == body.note.strip() and previous['recordedBy'] == actor['sub']:
            return {'request': view(request)}
        if (previous['updatedAt'] if previous else None) != body.expected_version:
            raise HTTPException(409, 'review changed; reload before editing')
        values = dict(patient_id=patient_id, kind='deletion-review', record_id=str(request_id),
            payload_json=dump_json(payload), actor_id=actor['sub'],
            updated_at=datetime.now(timezone.utc).isoformat(), deleted=False)
        if previous:
            statement = update(care_records).where(care_records.c.patient_id == patient_id,
                care_records.c.kind == 'deletion-review', care_records.c.record_id == str(request_id),
                care_records.c.updated_at == body.expected_version).values(**values)
        else:
            statement = upsert(care_records, values).on_conflict_do_nothing(index_elements=['patient_id', 'kind', 'record_id'])
        if not conn.execute(statement).rowcount:
            raise HTTPException(409, 'review changed; reload before editing')
        users_store.log(actor['sub'], actor['role'], 'review_account_erasure', str(request_id),
            {'patientId': patient_id, **payload, 'previousStatus': previous['status'] if previous else 'received'})
        return {'request': view(request)}
