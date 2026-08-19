"""Epilepsy monitoring API — graduation project entrypoint."""
import asyncio
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import alert_outbox, notification_delivery
from app.device_hub import DeviceHub
from app.logging_setup import configure_logging
from app.metrics import metrics
from app.settings import settings, validate_production_settings
from app.middleware import RequestGuardMiddleware
from app.ml.classifier import RiskClassifier
from app.routers import (
    accounts,
    alerts,
    analyze,
    auth,
    cloud_dataset,
    clinical,
    device,
    health,
    model_info,
    notifications,
    simulate,
)


def deliver_notification(payload: dict) -> None:
    """Deliver one queued alert.

    The selected delivery adapter raises on failure; the outbox records the
    attempt and retries with backoff, so failure is never silent.
    """
    notification_delivery.deliver(payload)
    metrics.increment("notifications_delivered")


async def _drain_outbox_forever(interval: float) -> None:
    """Background worker: retries due notifications until cancelled."""
    while True:
        try:
            await asyncio.sleep(interval)
            # Off the event loop: the outbox uses blocking SQLite calls.
            result = await asyncio.to_thread(
                alert_outbox.process_once, deliver_notification
            )
            if result["processed"]:
                logging.getLogger("epilepsy.outbox").info(
                    "outbox drained", extra=result
                )
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - the worker must survive any failure
            logging.getLogger("epilepsy.outbox").exception("outbox worker cycle failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    configure_logging()
    validate_production_settings()
    if settings.is_production:
        notification_delivery.validate_configuration()
    app.state.classifier = RiskClassifier.load()
    app.state.device_hub = DeviceHub(window_size=128)
    logging.getLogger("epilepsy").info(
        "startup: active engine = %s",
        app.state.classifier.engine_info()["active_engine"],
    )
    # Import any legacy JSON stores BEFORE seeding: seeding would populate the
    # database and cause the (deliberately conservative) importer to skip.
    try:
        from app.store_migration import import_legacy_stores

        outcome = import_legacy_stores()
        for entry in outcome["imported"]:
            logging.getLogger("epilepsy").info(
                "migrated %s into SQLite (%s); backup at %s",
                entry["store"], entry["stats"], entry["backup"],
            )
    except Exception:  # pragma: no cover - never block startup on migration
        logging.getLogger("epilepsy").exception("legacy store import failed")
    # Ensure an initial system-administrator account exists for the web dashboard.
    # Idempotent; warns loudly if the built-in default password is in use.
    try:
        from app import users_store

        seeded = users_store.seed_admin()
        if seeded and seeded.get("usedDefaultPassword"):
            logging.getLogger("epilepsy").warning(
                "SECURITY: seeded admin '%s' with the DEFAULT password — set "
                "ADMIN_PASSWORD (and JWT_SECRET, AUTH_ALLOW_LEGACY_TOKEN=0) before deploying.",
                seeded["user"]["username"],
            )
        elif seeded:
            logging.getLogger("epilepsy").info(
                "seeded admin account '%s'", seeded["user"]["username"]
            )
    except Exception:  # pragma: no cover - never block startup on seeding
        logging.getLogger("epilepsy").exception("admin seeding failed")

    # Opt-out via OUTBOX_WORKER_ENABLED=0 (tests drive the drain deterministically).
    worker: asyncio.Task | None = None
    if os.getenv("OUTBOX_WORKER_ENABLED", "1") == "1":
        interval = float(os.getenv("OUTBOX_POLL_SECONDS", "10"))
        worker = asyncio.create_task(_drain_outbox_forever(interval))
    try:
        yield
    finally:
        if worker is not None:
            worker.cancel()
            try:
                await worker
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass


app = FastAPI(
    title="Epilepsy Monitoring API",
    description="Smart epileptic patient monitoring and early seizure prediction (graduation)",
    version="2.3.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.cors_origins),
    allow_credentials=("*" not in settings.cors_origins),
    allow_methods=["*"],
    allow_headers=["*"],
)
app.add_middleware(RequestGuardMiddleware)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(accounts.router)
app.include_router(analyze.router)
app.include_router(simulate.router)
app.include_router(alerts.router)
app.include_router(device.router)
app.include_router(cloud_dataset.router)
app.include_router(model_info.router)
app.include_router(clinical.router)
app.include_router(notifications.router)
