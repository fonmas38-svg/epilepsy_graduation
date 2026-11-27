"""Supabase Cloud Storage adapter for clinical PDF and EEG report files.

Security model:
* Credentials come only from the environment (``SUPABASE_URL`` and
  ``SUPABASE_SERVICE_ROLE_KEY``) or the git-ignored ``backend/.env``. Nothing
  is hard-coded: without configuration, uploads are refused, never sent to a
  default project.
* The bucket is private. Files are reached only through short-lived signed
  URLs issued by this backend after its own RBAC check, so a guessed path is
  useless.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import httpx

logger = logging.getLogger("epilepsy.storage")

BUCKET_NAME = "clinical-reports"
SIGNED_URL_SECONDS = int(os.getenv("REPORT_SIGNED_URL_SECONDS", "900"))


class StorageNotConfigured(RuntimeError):
    """Raised when Supabase credentials are absent."""


def _resolve_config() -> tuple[str, str]:
    url = (os.getenv("SUPABASE_URL") or "").strip().rstrip("/")
    key = (os.getenv("SUPABASE_SERVICE_ROLE_KEY") or "").strip()
    if not url or not key:
        env_file = Path(__file__).resolve().parents[1] / ".env"
        if env_file.exists():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line.startswith("SUPABASE_URL=") and not url:
                    url = line.split("=", 1)[1].strip().rstrip("/")
                elif line.startswith("SUPABASE_SERVICE_ROLE_KEY=") and not key:
                    key = line.split("=", 1)[1].strip()
    if not url or not key:
        raise StorageNotConfigured(
            "Report storage is not configured (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY)"
        )
    return url, key


def is_configured() -> bool:
    try:
        _resolve_config()
        return True
    except StorageNotConfigured:
        return False


def _headers(key: str) -> dict[str, str]:
    return {"apikey": key, "Authorization": f"Bearer {key}"}


def ensure_private_bucket(bucket: str = BUCKET_NAME) -> bool:
    """Create the bucket as private, or make an existing public one private."""
    url, key = _resolve_config()
    headers = _headers(key)
    try:
        with httpx.Client(timeout=8.0) as client:
            resp = client.get(f"{url}/storage/v1/bucket/{bucket}", headers=headers)
            if resp.status_code == 200:
                if resp.json().get("public"):
                    upd = client.put(
                        f"{url}/storage/v1/bucket/{bucket}",
                        headers=headers,
                        json={"id": bucket, "name": bucket, "public": False},
                    )
                    return upd.status_code in {200, 201}
                return True
            if resp.status_code in {400, 404}:
                create = client.post(
                    f"{url}/storage/v1/bucket",
                    headers=headers,
                    json={"id": bucket, "name": bucket, "public": False},
                )
                return create.status_code in {200, 201}
    except Exception as exc:  # noqa: BLE001
        logger.warning("Supabase storage bucket check failed: %s", exc)
    return False


def signed_url(path: str, bucket: str = BUCKET_NAME,
               expires_in: int = SIGNED_URL_SECONDS) -> str | None:
    """A time-limited link to one private object."""
    url, key = _resolve_config()
    try:
        with httpx.Client(timeout=8.0) as client:
            resp = client.post(
                f"{url}/storage/v1/object/sign/{bucket}/{path.lstrip('/')}",
                headers=_headers(key),
                json={"expiresIn": expires_in},
            )
            if resp.status_code == 200:
                signed = resp.json().get("signedURL") or resp.json().get("signedUrl")
                if signed:
                    return f"{url}/storage/v1{signed}" if signed.startswith("/") else signed
            logger.error("Supabase signed URL returned %s", resp.status_code)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Supabase signed URL failed: %s", exc)
    return None


def upload_clinical_report(
    file_bytes: bytes,
    filename: str,
    content_type: str = "application/pdf",
    bucket: str = BUCKET_NAME,
) -> dict[str, Any]:
    """Upload to the private bucket; return a short-lived signed link.

    Errors are reported with a stable code only: provider response bodies may
    contain configuration details and are logged, never returned to clients.
    """
    try:
        url, key = _resolve_config()
    except StorageNotConfigured:
        return {"success": False, "error": "storage_not_configured"}
    ensure_private_bucket(bucket)
    headers = _headers(key)
    headers["Content-Type"] = content_type
    headers["x-upsert"] = "false"
    clean = filename.lstrip("/")
    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.post(
                f"{url}/storage/v1/object/{bucket}/{clean}",
                headers=headers,
                content=file_bytes,
            )
            if resp.status_code in {200, 201}:
                return {
                    "success": True,
                    "bucket": bucket,
                    "path": clean,
                    "url": signed_url(clean, bucket),
                    "url_expires_in": SIGNED_URL_SECONDS,
                }
            logger.error("Supabase upload returned %s: %s", resp.status_code, resp.text[:300])
            return {"success": False, "error": "storage_rejected"}
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to upload clinical report: %s", exc)
        return {"success": False, "error": "storage_unreachable"}
