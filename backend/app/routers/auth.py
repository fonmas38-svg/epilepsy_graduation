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
    if not _verify_credentials(body.role, body.enrollment_secret):
        raise HTTPException(status_code=401, detail="Invalid enrollment secret")
    token = create_token(body.subject, body.role)
    return TokenResponse(access_token=token, role=body.role)
