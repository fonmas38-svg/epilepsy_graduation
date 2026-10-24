from fastapi import APIRouter, Query

from app.schemas import RiskLabel, SimulateRequest, SimulateResponse
from app.simulation import generate_window

router = APIRouter(prefix="/simulate", tags=["simulate"])


@router.post("/stream", response_model=SimulateResponse)
def simulate_stream(body: SimulateRequest):
    window = generate_window(
        pattern=body.pattern,
        samples=body.samples,
        seed=body.seed,
    )
    return SimulateResponse(window=window, pattern=body.pattern)


@router.get("/window", response_model=SimulateResponse)
def simulate_window(pattern: RiskLabel = "stable", samples: int = Query(default=262, ge=32, le=1024), seed: int | None = None):
    window = generate_window(pattern=pattern, samples=samples, seed=seed)  # type: ignore[arg-type]
    return SimulateResponse(window=window, pattern=pattern)  # type: ignore[arg-type]
