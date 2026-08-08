from fastapi import APIRouter

from app.schemas import SimulateRequest, SimulateResponse
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
def simulate_window(pattern: str = "stable", samples: int = 128, seed: int | None = None):
    if pattern not in ("stable", "watch", "high_risk"):
        pattern = "stable"
    window = generate_window(pattern=pattern, samples=samples, seed=seed)  # type: ignore[arg-type]
    return SimulateResponse(window=window, pattern=pattern)  # type: ignore[arg-type]
