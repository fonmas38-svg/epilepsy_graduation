"""Authentication endpoints: issue JWTs for devices and clinicians.

Demo credential model (graduation MVP): a shared per-role enrollment secret maps
to a JWT. In production replace `_verify_credentials` with a real user store
(hashed passwords) / device certificate check.
"""
from __future__ import annotations

import os

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.auth import Role, create_token
from app import users_store
from app.settings import settings

router = APIRouter(prefix="/auth", tags=["auth"])

# Enrollment secrets (override via env in real deployments).
_ENROLL_SECRETS = {
    "device": os.getenv("ENROLL_DEVICE_SECRET", "enroll-device-demo"),
    "doctor": os.getenv("ENROLL_DOCTOR_SECRET", "enroll-doctor-demo"),
    "caregiver": os.getenv("ENROLL_CAREGIVER_SECRET", "enroll-caregiver-demo"),
    "patient": os.getenv("ENROLL_PATIENT_SECRET", "enroll-patient-demo"),
}


class TokenRequest(BaseModel):
    subject: str = Field(..., min_length=1, description="device_id or user_id")
    role: Role = "device"
    enrollment_secret: str = Field(..., min_length=1)
    patient_id: str | None = Field(default=None, min_length=1, max_length=128)


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    role: Role


def _verify_credentials(role: str, secret: str) -> bool:
    expected = _ENROLL_SECRETS.get(role)
    return expected is not None and secret == expected


@router.post("/token", response_model=TokenResponse)
def issue_token(body: TokenRequest):
    """Exchange an enrollment secret for a signed, expiring JWT."""
    if body.role != "device" and settings.is_production:
        raise HTTPException(
            status_code=400,
            detail="Human accounts must authenticate with /auth/login",
        )
    if body.role != "device" and settings.require_patient_auth:
        user = users_store.get_user(body.subject)
        if not user or user.get("role") != body.role or user.get("disabled"):
            raise HTTPException(status_code=401, detail="active account not found")
    if body.role == "device" and settings.is_production and not body.patient_id:
        raise HTTPException(status_code=400, detail="patient_id is required for device enrollment")
    if body.role == "device" and settings.is_production:
        from app import device_store

        device = device_store.verify_enrollment(
            body.subject, str(body.patient_id), body.enrollment_secret
        )
        if not device:
            raise HTTPException(status_code=401, detail="Invalid or inactive device enrollment")
        extra = {
            "patient_id": device["patientId"],
            "credential_version": device["credentialVersion"],
        }
    else:
        if not _verify_credentials(body.role, body.enrollment_secret):
            raise HTTPException(status_code=401, detail="Invalid enrollment secret")
        extra = {"patient_id": body.patient_id} if body.role == "device" and body.patient_id else None
    token = create_token(body.subject, body.role, extra=extra)
    return TokenResponse(access_token=token, role=body.role)
