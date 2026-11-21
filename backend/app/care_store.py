"""Care records are separate from device-supplied monitoring profile JSON."""
from datetime import datetime, timezone
from sqlalchemy import select
from app.database import care_records, connection, transaction, upsert, dump_json, load_json


def _where(patient_id, kind, record_id):
    return (care_records.c.patient_id == patient_id,
            care_records.c.kind == kind, care_records.c.record_id == record_id)


def public_record(row):
    value = row._mapping
    return {**load_json(value['payload_json'], {}), 'patientId': value['patient_id'],
            'updatedAt': value['updated_at'], 'recordedBy': value['actor_id']}


def list_records(patient_id, kind, limit=500):
    with connection() as conn:
        return [public_record(row) for row in conn.execute(select(care_records).where(
            care_records.c.patient_id == patient_id, care_records.c.kind == kind,
            care_records.c.deleted.is_(False),
        ).order_by(care_records.c.updated_at.desc(), care_records.c.record_id).limit(limit))]


def get_record(patient_id, kind, record_id):
    with connection() as conn:
        row = conn.execute(select(care_records).where(
            *_where(patient_id, kind, record_id), care_records.c.deleted.is_(False),
        )).first()
        return public_record(row) if row is not None else None


def deleted_ids(patient_id, kind):
    with connection() as conn:
        return list(conn.scalars(select(care_records.c.record_id).where(
            care_records.c.patient_id == patient_id, care_records.c.kind == kind,
            care_records.c.deleted.is_(True),
        ).order_by(care_records.c.record_id)))


def save(patient_id, kind, record_id, payload, actor, *, replace=False):
    now = datetime.now(timezone.utc).isoformat()
    with transaction() as conn:
        values = dict(patient_id=patient_id, kind=kind, record_id=record_id,
                      payload_json=dump_json(payload), actor_id=actor, updated_at=now, deleted=False)
        statement = upsert(care_records, values)
        if replace:
            statement = statement.on_conflict_do_update(
                index_elements=['patient_id', 'kind', 'record_id'],
                set_={key: values[key] for key in ['payload_json', 'actor_id', 'updated_at']},
                where=care_records.c.deleted.is_(False),
            )
        else:
            statement = statement.on_conflict_do_nothing(index_elements=['patient_id', 'kind', 'record_id'])
        conn.execute(statement)
        row = conn.execute(select(care_records).where(*_where(patient_id, kind, record_id))).one()
        if row._mapping['deleted']:
            raise ValueError('record was removed; use a new identifier')
        if not replace and load_json(row._mapping['payload_json'], {}) != payload:
            raise ValueError('record identifier already has different data')
        return public_record(row)


def remove(patient_id, kind, record_id, actor):
    now = datetime.now(timezone.utc).isoformat()
    with transaction() as conn:
        # A tombstone also handles delete-before-create network replay safely.
        conn.execute(upsert(care_records, dict(patient_id=patient_id, kind=kind,
            record_id=record_id, payload_json='{}', actor_id=actor, updated_at=now,
            deleted=True)).on_conflict_do_update(
                index_elements=['patient_id', 'kind', 'record_id'],
                set_={'deleted': True, 'updated_at': now, 'actor_id': actor}))
