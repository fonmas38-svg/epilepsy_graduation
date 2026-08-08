import time

from fastapi import APIRouter, Request

from app.schemas import AnalyzeResponse, VitalWindow

router = APIRouter(tags=["analyze"])


@router.post("/analyze", response_model=AnalyzeResponse)
def analyze_window(window: VitalWindow, request: Request):
    started = time.perf_counter()
    classifier = request.app.state.classifier
    result = classifier.predict_window(window)
    elapsed_ms = (time.perf_counter() - started) * 1000
    return AnalyzeResponse(
        label=result.label,
        confidence=result.confidence,
        features=result.features,
        processing_ms=round(elapsed_ms, 3),
        engine=result.engine,
        deep_prob=result.deep_prob,
        preictal_prob=result.preictal_prob,
        lead_time_min=result.lead_time_min,
        horizon_min=result.horizon_min,
        predicted=result.predicted,
        prediction_source=result.prediction_source,
        components=result.components or None,
    )
