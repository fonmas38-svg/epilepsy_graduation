"""Router for clinical and family messaging channels and patient location sharing."""
from __future__ import annotations

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from app import cloud_store, messages_store, users_store
from app.auth import authorize_patient_access, get_current_principal

router = APIRouter(prefix="/patients", tags=["messages"])


class SendMessageRequest(BaseModel):
    channel_type: Literal["doctor_patient", "family_patient"]
    content: str = Field(..., min_length=1, max_length=5000)


class LocationShareRequest(BaseModel):
    latitude: float
    longitude: float
    accuracy: float | None = None
    note: str | None = Field(default=None, max_length=500)


@router.get("/{patient_id}/messages")
def list_messages(
    patient_id: str,
    channel_type: Literal["doctor_patient", "family_patient"] | None = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    principal: dict = Depends(get_current_principal),
):
    """Retrieve messages for a patient scoped by channel and role permissions."""
    authorize_patient_access(patient_id, principal)
    role = principal.get("role")

    # Strict privacy safeguard: Caregivers can NEVER inspect private doctor-patient consultations.
    if role == "caregiver":
        if channel_type == "doctor_patient":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Caregivers are not permitted to access private doctor-patient consultations",
            )
        channel_type = "family_patient"

    msgs = messages_store.list_messages(
        patient_id=patient_id,
        channel_type=channel_type,
        limit=limit,
        offset=offset,
    )
    return {"messages": msgs}


@router.post("/{patient_id}/messages", status_code=201)
def send_message(
    patient_id: str,
    body: SendMessageRequest,
    principal: dict = Depends(get_current_principal),
):
    """Send a message to either doctor-patient or family-patient channel."""
    authorize_patient_access(patient_id, principal)
    role = principal.get("role", "patient")
    sub = str(principal.get("sub", ""))

    # Privacy constraint: Caregivers cannot post to doctor-patient channel
    if role == "caregiver" and body.channel_type == "doctor_patient":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Caregivers cannot send messages to doctor-patient private channel",
        )

    user = users_store.get_user(sub)
    sender_name = user.get("name") if user else (principal.get("name") or "مستخدم")

    try:
        msg = messages_store.create_message(
            patient_id=patient_id,
            sender_id=sub,
            sender_name=sender_name,
            sender_role=role,
            channel_type=body.channel_type,
            content=body.content,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    users_store.log(
        sub,
        role,
        "send_message",
        target=patient_id,
        detail={"channel": body.channel_type, "messageId": msg["id"]},
    )
    return {"message": msg}


@router.post("/{patient_id}/location", status_code=200)
def share_location(
    patient_id: str,
    body: LocationShareRequest,
    principal: dict = Depends(get_current_principal),
):
    """Update and broadcast patient's live location to family and care circle."""
    authorize_patient_access(patient_id, principal)
    sub = str(principal.get("sub", ""))
    role = principal.get("role", "patient")

    loc_data = {
        "latitude": body.latitude,
        "longitude": body.longitude,
        "accuracy": body.accuracy,
        "updatedAt": messages_store._now(),
        "mapsUrl": f"https://maps.google.com/?q={body.latitude:.6f},{body.longitude:.6f}",
        "note": body.note,
    }

    patient = cloud_store.get_patient(patient_id) or {}
    profile = dict(patient)
    profile["lastKnownLocation"] = loc_data
    cloud_store.upsert_patient(patient_id, profile)

    # Automatically post a system notification into the family channel
    user = users_store.get_user(sub)
    sender_name = user.get("name") if user else "المريض"
    location_msg = f"📍 قام {sender_name} بمشاركة موقعه الحالي مع الأسرة: {loc_data['mapsUrl']}"
    if body.note:
        location_msg += f"\nملاحظة: {body.note}"

    messages_store.create_message(
        patient_id=patient_id,
        sender_id=sub,
        sender_name=sender_name,
        sender_role=role,
        channel_type="family_patient",
        content=location_msg,
    )

    users_store.log(sub, role, "share_location", target=patient_id, detail=loc_data)
    return {"location": loc_data, "ok": True}


@router.get("/{patient_id}/location")
def get_location(
    patient_id: str,
    principal: dict = Depends(get_current_principal),
):
    """Get the patient's last reported location coordinates."""
    authorize_patient_access(patient_id, principal)
    patient = cloud_store.get_patient(patient_id) or {}
    loc = patient.get("lastKnownLocation")
    if not loc:
        return {"location": None}
    return {"location": loc}
