"""Epilepsy monitoring API — graduation project entrypoint."""
import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.device_hub import DeviceHub
from app.ml.classifier import RiskClassifier
from app.routers import (
    accounts,
    alerts,
    analyze,
    auth,
    cloud_dataset,
    device,
    health,
    model_info,
    simulate,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    app.state.classifier = RiskClassifier.load()
    app.state.device_hub = DeviceHub(window_size=128)
    logging.getLogger("epilepsy").info(
        "startup: active engine = %s",
        app.state.classifier.engine_info()["active_engine"],
    )
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
    yield


app = FastAPI(
    title="Epilepsy Monitoring API",
    description="Smart epileptic patient monitoring and early seizure prediction (graduation)",
    version="2.2.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(accounts.router)
app.include_router(analyze.router)
app.include_router(simulate.router)
app.include_router(alerts.router)
app.include_router(device.router)
app.include_router(cloud_dataset.router)
app.include_router(model_info.router)
