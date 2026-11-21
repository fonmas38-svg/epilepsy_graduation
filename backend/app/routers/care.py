"""Authenticated care resources used by offline mobile workflows."""
from datetime import datetime, timezone
from typing import Literal
from uuid import UUID
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from app import care_store, cloud_store, users_store
from app.auth import authorize_patient_access, require_role
from app.database import transaction
from app.schemas import validate_utc_timestamp

router = APIRouter(prefix='/patients', tags=['care'])
read_access = require_role('patient', 'doctor', 'caregiver', 'admin')
edit_access = require_role('patient', 'doctor')


class Contact(BaseModel):
    id: UUID
    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(min_length=1, max_length=32)
    relation: str = Field(default='', max_length=64)
    priority: int = Field(default=0, ge=0, le=10000)


class MedicalCard(BaseModel):
    diagnosis: str = Field(default='', max_length=2000)
    allergies: str = Field(default='', max_length=2000)
    blood_type: str = Field(default='', max_length=16)
    doctor_name: str = Field(default='', max_length=120)
    doctor_phone: str = Field(default='', max_length=32)
    notes: str = Field(default='', max_length=5000)


class Trigger(BaseModel):
    id: UUID
    occurred_at: str
    kind: Literal['sleep', 'stress', 'fatigue', 'missed_meal', 'menstrual', 'fever', 'missed_dose', 'other']
    intensity: int = Field(default=3, ge=1, le=5)
    note: str = Field(default='', max_length=2000)


class ClinicalNote(BaseModel):
    id: UUID
    text: str = Field(min_length=1, max_length=5000)
    written_at: str
    doctor_id: str | None = None


class AlertResponse(BaseModel):
    id: UUID
    alert_id: str = Field(min_length=1, max_length=128)
    responder_id: str = Field(default='', max_length=64)
    responder_name: str = Field(default='', max_length=120)
    status: Literal['seen', 'acknowledged', 'on_way', 'arrived']
    at: str


def authorize(patient_id, actor):
    authorize_patient_access(patient_id, actor, enforce=True)
    patient = users_store.get_user(patient_id)
    if not patient or patient['role'] != 'patient':
        raise HTTPException(404, 'patient not found')


def save(patient_id, kind, record_id, payload, actor, *, replace=False):
    authorize(patient_id, actor)
    try:
        with transaction():
            result = care_store.save(patient_id, kind, record_id, payload, str(actor['sub']), replace=replace)
            users_store.log(actor['sub'], actor['role'], f'save_{kind}', record_id, {'patientId': patient_id})
            return result
    except ValueError as error:
        raise HTTPException(409, str(error)) from error


def remove(patient_id, kind, record_id, actor):
    authorize(patient_id, actor)
    with transaction():
        care_store.remove(patient_id, kind, str(record_id), str(actor['sub']))
        users_store.log(actor['sub'], actor['role'], f'remove_{kind}', str(record_id), {'patientId': patient_id})
    return {'ok': True}


def timestamp(value, field):
    try:
        validate_utc_timestamp(value, field)
    except ValueError as error:
        raise HTTPException(422, str(error)) from error


@router.get('/{patient_id}/emergency-contacts')
def contacts(patient_id: str, actor: dict = Depends(read_access)):
    authorize(patient_id, actor)
    return sorted(care_store.list_records(patient_id, 'contact', None), key=lambda row: row['priority'])


@router.post('/{patient_id}/emergency-contacts', status_code=201)
def add_contact(patient_id: str, body: Contact, actor: dict = Depends(edit_access)):
    if not body.name.strip() or not body.phone.strip():
        raise HTTPException(422, 'name and phone must not be blank')
    return save(patient_id, 'contact', str(body.id), body.model_dump(mode='json'), actor)


@router.put('/{patient_id}/emergency-contacts/{record_id}')
def update_contact(patient_id: str, record_id: UUID, body: Contact, actor: dict = Depends(edit_access)):
    if body.id != record_id or not body.name.strip() or not body.phone.strip():
        raise HTTPException(422, 'invalid contact')
    return save(patient_id, 'contact', str(record_id), body.model_dump(mode='json'), actor, replace=True)


@router.delete('/{patient_id}/emergency-contacts/{record_id}')
def delete_contact(patient_id: str, record_id: UUID, actor: dict = Depends(edit_access)):
    return remove(patient_id, 'contact', record_id, actor)


@router.get('/{patient_id}/medical-card')
def medical_card(patient_id: str, actor: dict = Depends(read_access)):
    authorize(patient_id, actor)
    records = care_store.list_records(patient_id, 'medical-card', 1)
    return records[0] if records else {}


@router.put('/{patient_id}/medical-card')
def put_medical_card(patient_id: str, body: MedicalCard, actor: dict = Depends(edit_access)):
    return save(patient_id, 'medical-card', 'card', body.model_dump(), actor, replace=True)


@router.get('/{patient_id}/triggers')
def triggers(patient_id: str, limit: int = Query(200, ge=1, le=500), actor: dict = Depends(read_access)):
    authorize(patient_id, actor)
    return {'triggers': care_store.list_records(patient_id, 'trigger', limit),
            'deleted_ids': care_store.deleted_ids(patient_id, 'trigger')}


@router.post('/{patient_id}/triggers', status_code=201)
def add_trigger(patient_id: str, body: Trigger, actor: dict = Depends(require_role('patient'))):
    timestamp(body.occurred_at, 'occurred_at')
    return save(patient_id, 'trigger', str(body.id), body.model_dump(mode='json'), actor)


@router.delete('/{patient_id}/triggers/{record_id}')
def delete_trigger(patient_id: str, record_id: UUID, actor: dict = Depends(require_role('patient'))):
    return remove(patient_id, 'trigger', record_id, actor)


@router.get('/{patient_id}/clinical-notes')
def notes(patient_id: str, actor: dict = Depends(require_role('patient', 'doctor'))):
    authorize(patient_id, actor)
    return care_store.list_records(patient_id, 'clinical-note')


@router.post('/{patient_id}/clinical-notes', status_code=201)
def add_note(patient_id: str, body: ClinicalNote, actor: dict = Depends(require_role('doctor'))):
    timestamp(body.written_at, 'written_at')
    if not body.text.strip():
        raise HTTPException(422, 'note must not be blank')
    payload = body.model_dump(mode='json')
    payload['doctor_id'] = str(actor['sub'])
    return save(patient_id, 'clinical-note', str(body.id), payload, actor)


def _authorize_alert(patient_id, alert_id, actor):
    authorize(patient_id, actor)
    if cloud_store.get_alert(patient_id, alert_id) is None:
        raise HTTPException(404, 'alert not found or no longer retained')


@router.get('/{patient_id}/alerts/{alert_id}/responses')
def alert_responses(patient_id: str, alert_id: str, actor: dict = Depends(read_access)):
    _authorize_alert(patient_id, alert_id, actor)
    # The record limit must be applied per alert, never before filtering by it.
    records = care_store.list_records(patient_id, 'alert-response', None)
    return sorted((row for row in records if row.get('alert_id') == alert_id),
                  key=lambda row: (row['at'], row['id']))


@router.post('/{patient_id}/alerts/{alert_id}/responses', status_code=201)
def add_alert_response(patient_id: str, alert_id: str, body: AlertResponse,
                       actor: dict = Depends(require_role('caregiver'))):
    with transaction():
        _authorize_alert(patient_id, alert_id, actor)
        if body.alert_id != alert_id:
            raise HTTPException(422, 'alert_id does not match the requested alert')
        timestamp(body.at, 'at')
        responder = users_store.get_user(str(actor['sub']))
        payload = body.model_dump(mode='json')
        payload['at'] = datetime.fromisoformat(body.at.replace('Z', '+00:00')).astimezone(timezone.utc).isoformat()
        payload['responder_id'] = str(actor['sub'])
        # Ignore client names. Preserve the trusted historical name on replay
        # after a caregiver edits their profile, without changing the event.
        existing = care_store.get_record(patient_id, 'alert-response', str(body.id))
        payload['responder_name'] = (
            existing['responder_name'] if existing and existing.get('responder_id') == str(actor['sub'])
            else responder['name']
        )
        return save(patient_id, 'alert-response', str(body.id), payload, actor)
