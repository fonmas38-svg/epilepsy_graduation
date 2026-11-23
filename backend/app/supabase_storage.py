"""Supabase Cloud Storage adapter for clinical PDF and EEG report files.

Provides seamless upload and signed/public URL generation for medical records,
utilizing the Supabase Storage REST API backed by the free 1 GB cloud storage tier.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any
import httpx

logger = logging.getLogger("epilepsy.storage")

DEFAULT_SUPABASE_URL = "https://vigxfzfalfvenepuoelz.supabase.co"
DEFAULT_SERVICE_KEY = "sb_secret_KSXdt6bZPwgiYojvM4f7GQ_k1a6q83X"
BUCKET_NAME = "clinical-reports"


def _resolve_config() -> tuple[str, str]:
    """Resolve Supabase URL and service key from environment or fallback config."""
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

    return url or DEFAULT_SUPABASE_URL, key or DEFAULT_SERVICE_KEY


def _get_headers() -> dict[str, str]:
    _, key = _resolve_config()
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
    }


def ensure_bucket_exists(bucket: str = BUCKET_NAME) -> bool:
    """Ensure the target bucket exists, creating it if needed."""
    url, _ = _resolve_config()
    headers = _get_headers()
    target_url = f"{url}/storage/v1/bucket/{bucket}"
    try:
        with httpx.Client(timeout=8.0) as client:
            resp = client.get(target_url, headers=headers)
            if resp.status_code == 200:
                return True
            if resp.status_code == 404:
                create_resp = client.post(
                    f"{url}/storage/v1/bucket",
                    headers=headers,
                    json={"id": bucket, "name": bucket, "public": True},
                )
                return create_resp.status_code in {200, 201}
    except Exception as exc:  # noqa: BLE001
        logger.warning("Supabase storage bucket check failed: %s", exc)
    return False


def upload_clinical_report(
    file_bytes: bytes,
    filename: str,
    content_type: str = "application/pdf",
    bucket: str = BUCKET_NAME,
) -> dict[str, Any]:
    """Upload a report file to Supabase Cloud Storage and return its public URL."""
    url, _ = _resolve_config()
    headers = _get_headers()
    headers["Content-Type"] = content_type
    headers["x-upsert"] = "true"

    clean_filename = filename.lstrip("/")
    upload_url = f"{url}/storage/v1/object/{bucket}/{clean_filename}"

    try:
        with httpx.Client(timeout=15.0) as client:
            resp = client.post(upload_url, headers=headers, content=file_bytes)
            if resp.status_code in {200, 201}:
                public_url = f"{url}/storage/v1/object/public/{bucket}/{clean_filename}"
                logger.info("Uploaded clinical report to Supabase Storage: %s", clean_filename)
                return {
                    "success": True,
                    "bucket": bucket,
                    "path": clean_filename,
                    "url": public_url,
                }
            logger.error(
                "Supabase Storage upload returned %s: %s", resp.status_code, resp.text
            )
            return {
                "success": False,
                "status_code": resp.status_code,
                "error": resp.text,
            }
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to upload clinical report to Supabase Storage: %s", exc)
        return {"success": False, "error": str(exc)}
