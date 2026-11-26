"""Router for clinical and family messaging channels and patient location sharing."""
from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from app import cloud_store, messages_store, users_store
from app.auth import authorize_patient_access, require_role

router = APIRouter(prefix="/patients", tags=["messages"])
require_messenger = require_role("patient", "doctor", "caregiver", "admin")


ChannelTypeLiteral = Literal[
    "doctor_patient",
    "patient_caregiver",
    "doctor_caregiver",
    "care_team_triage",
    "family_patient",
]


class SendMessageRequest(BaseModel):
    channel_type: ChannelTypeLiteral
    content: str = Field(..., min_length=1, max_length=5000)
    client_message_id: UUID | None = None
    peer_user_id: str | None = Field(default=None, max_length=64)


class MarkReadRequest(BaseModel):
    channel_type: ChannelTypeLiteral | None = None
    peer_user_id: str | None = Field(default=None, max_length=64)


class LocationShareRequest(BaseModel):
    latitude: float = Field(ge=-90, le=90, allow_inf_nan=False)
    longitude: float = Field(ge=-180, le=180, allow_inf_nan=False)
    accuracy: float | None = Field(default=None, ge=0, allow_inf_nan=False)
    note: str | None = Field(default=None, max_length=500)
    # Which acquisition path produced the fix, so caregivers can tell a live
    # device-GPS position from a network estimate or a remembered one.
    source: Literal["device_gps", "fused_network", "cached_fix"] | None = None
    # When the fix was captured on the phone (may be older than the share).
    captured_at: datetime | None = None


def _enforce_channel_rbac(role: str | None, channel_type: str | None, *, is_write: bool) -> str | None:
    if role == "caregiver":
        if channel_type == "doctor_patient":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Caregivers are not permitted to access private doctor-patient consultations",
            )
        if channel_type is None and not is_write:
            return "family_patient"
    elif role == "patient":
        if channel_type == "doctor_caregiver":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Patients are not permitted to access direct doctor-caregiver consultations",
            )
    elif role == "doctor":
        if channel_type == "patient_caregiver":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Doctors are not permitted to access private patient-caregiver messages",
            )
    return channel_type


def _private_peer(patient_id: str, channel: str | None, peer: str | None,
                  principal: dict, *, required: bool = False) -> str | None:
    if principal.get("role") == "caregiver":
        own_id = str(principal["sub"])
        if peer is not None and peer != own_id:
            raise HTTPException(status_code=403, detail="Private conversation belongs to another caregiver")
        return own_id if channel in ("patient_caregiver", "doctor_caregiver") else None
    if channel not in ("patient_caregiver", "doctor_caregiver"):
        return None
    if not peer:
        if required:
            raise HTTPException(status_code=422, detail="Choose the caregiver for this private conversation")
        return None
    caregiver = users_store.get_user(peer)
    if (not caregiver or caregiver.get("role") != "caregiver" or caregiver.get("disabled")
            or not users_store.is_caregiver_linked(patient_id, peer)):
        raise HTTPException(status_code=403, detail="Caregiver is not linked to this patient")
    return peer


@router.get("/{patient_id}/message-peers")
def message_peers(patient_id: str, principal: dict = Depends(require_messenger)):
    authorize_patient_access(patient_id, principal, enforce=True)
    peers = []
    for uid in users_store.caregivers_for_patient(patient_id):
        if principal.get("role") == "caregiver" and uid != principal.get("sub"):
            continue
        user = users_store.get_user(uid)
        if user and not user.get("disabled"):
            peers.append({"id": uid, "name": user["name"]})
    return {"peers": peers}


@router.get("/{patient_id}/messages")
def list_messages(
    patient_id: str,
    channel_type: ChannelTypeLiteral | None = None,
    peer_user_id: str | None = Query(default=None, max_length=64),
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    latest: bool = False,
    principal: dict = Depends(require_messenger),
):
    """Retrieve messages for a patient scoped by channel and role permissions."""
    authorize_patient_access(patient_id, principal, enforce=True)
    role = principal.get("role")
    channel_type = _enforce_channel_rbac(role, channel_type, is_write=False)
    peer_user_id = _private_peer(patient_id, channel_type, peer_user_id, principal)

    msgs = messages_store.list_messages(
        patient_id=patient_id,
        channel_type=channel_type,
        peer_user_id=peer_user_id,
        limit=limit,
        offset=offset,
        latest=latest,
        viewer_id=str(principal["sub"]),
        viewer_role=role,
    )
    return {"messages": msgs}


@router.post("/{patient_id}/messages", status_code=201)
def send_message(
    patient_id: str,
    body: SendMessageRequest,
    principal: dict = Depends(require_messenger),
):
    """Send a message to any of the care circle or 1-on-1 channels (#10)."""
    authorize_patient_access(patient_id, principal, enforce=True)
    role = principal.get("role", "patient")
    sub = str(principal.get("sub", ""))
    _enforce_channel_rbac(role, body.channel_type, is_write=True)
    peer = _private_peer(patient_id, body.channel_type, body.peer_user_id, principal, required=True)

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
            client_message_id=str(body.client_message_id) if body.client_message_id else None,
            peer_user_id=peer,
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


@router.post("/{patient_id}/messages/read")
def mark_messages_read(
    patient_id: str,
    body: MarkReadRequest,
    principal: dict = Depends(require_messenger),
):
    """Mark messages in a channel as read by the current participant."""
    authorize_patient_access(patient_id, principal, enforce=True)
    role = principal.get("role")
    sub = str(principal.get("sub", ""))
    channel_type = _enforce_channel_rbac(role, body.channel_type, is_write=False)
    peer = _private_peer(patient_id, channel_type, body.peer_user_id, principal)
    updated = messages_store.mark_messages_read(
        patient_id=patient_id,
        reader_id=sub,
        channel_type=channel_type,
        peer_user_id=peer,
        viewer_role=role,
    )
    return {"ok": True, "updated": updated}


@router.post("/{patient_id}/location", status_code=200)
def share_location(
    patient_id: str,
    body: LocationShareRequest,
    principal: dict = Depends(require_messenger),
):
    """Update and broadcast patient's live location to family and care circle."""
    authorize_patient_access(patient_id, principal, enforce=True)
    sub = str(principal.get("sub", ""))
    role = principal.get("role", "patient")

    if role != "patient" or sub != patient_id:
        raise HTTPException(status_code=403, detail="Only the patient can share their location")

    loc_data = {
        "latitude": body.latitude,
        "longitude": body.longitude,
        "accuracy": body.accuracy,
        "updatedAt": messages_store._now(),
        "mapsUrl": f"https://maps.google.com/?q={body.latitude:.6f},{body.longitude:.6f}",
        "note": body.note,
        "source": body.source,
        "capturedAt": body.captured_at.isoformat() if body.captured_at else None,
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
    principal: dict = Depends(require_messenger),
):
    """Get the patient's last reported location coordinates."""
    authorize_patient_access(patient_id, principal, enforce=True)
    patient = cloud_store.get_patient(patient_id) or {}
    loc = patient.get("lastKnownLocation")
    if not loc:
        return {"location": None}
    return {"location": loc}
