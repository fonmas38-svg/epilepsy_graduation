"""Authenticated mobile push-token registration endpoints."""
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app import push_tokens_store, users_store
from app.auth import require_role

router = APIRouter(prefix="/notifications", tags=["notifications"])
require_account = require_role("patient", "caregiver", "doctor", "admin")


class PushTokenRequest(BaseModel):
    token: str = Field(..., min_length=20, max_length=4096)
    platform: str = Field(default="unknown", min_length=1, max_length=32)


@router.post("/device-token", status_code=201)
def register_device_token(
    body: PushTokenRequest,
    principal: dict = Depends(require_account),
):
    user_id = str(principal["sub"])
    push_tokens_store.register(user_id, body.token, body.platform.lower())
    users_store.log(user_id, principal.get("role"), "register_push_token", user_id,
                    {"platform": body.platform.lower()})
    return {"status": "registered", "registered_devices": push_tokens_store.count_for_user(user_id)}


@router.delete("/device-token")
def unregister_device_token(
    body: PushTokenRequest,
    principal: dict = Depends(require_account),
):
    user_id = str(principal["sub"])
    removed = push_tokens_store.unregister(user_id, body.token)
    if removed:
        users_store.log(user_id, principal.get("role"), "unregister_push_token", user_id,
                        {"platform": body.platform.lower()})
    return {"status": "removed" if removed else "not_found",
            "registered_devices": push_tokens_store.count_for_user(user_id)}


@router.get("/device-token/status")
def device_token_status(principal: dict = Depends(require_account)):
    # Deliberately return only a count; registration tokens are never exposed.
    return {"registered_devices": push_tokens_store.count_for_user(str(principal["sub"]))}