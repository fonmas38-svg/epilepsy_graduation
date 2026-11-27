"""Score the virtual sensor's episodes with every model the app uses.

Input: research/data/sim_episodes.json, written by
`mobile/test/tool/dump_simulator_episodes_test.dart` (real generator, real EEG
library, ground truth per 2 s window, and the phone model's own verdict).

Engines scored per window:
  cloud  - backend RiskClassifier.predict_window (CNN-LSTM fusion + forecast)
  edge   - EdgeSeizureNet ONNX exactly as the phone runs it (bandpass + z-score)
  phone  - the phone's combined offline verdict recorded by the Dart tool

Reports, per seizure type and engine: episode detection rate, mean time to
detect, early-warning rate (forecast during pre-ictal), false alarms in calm
time and in the non-epileptic artefact scenario.

Run from repo root:  python research/scripts/evaluate_simulator_models.py
"""
from __future__ import annotations

import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
os.environ.setdefault("APP_ENV", "demo")

from app.ml.classifier import RiskClassifier  # noqa: E402
from app.schemas import VitalWindow  # noqa: E402

DUMP = ROOT / "research" / "data" / "sim_episodes.json"
EDGE = ROOT / "mobile" / "assets" / "models" / "edge_seizure_model.onnx"
SOS = butter(4, [0.5 / 128, 40 / 128], btype="bandpass", output="sos")


def edge_session():
    import onnxruntime as ort

    path = EDGE if EDGE.exists() else ROOT / "backend" / "models" / "edge_seizure_model.onnx"
    s = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    return s, s.get_inputs()[0].name


def edge_prob(sess, name, eeg) -> float | None:
    x = sosfiltfilt(SOS, np.asarray(eeg, dtype=np.float64))
    sd = x.std()
    if sd < 1e-6:
        return None
    x = ((x - x.mean()) / (sd + 1e-8)).astype(np.float32).reshape(1, 1, -1)
    logits = sess.run(None, {name: x})[0].reshape(-1)
    m = logits.max()
    e = np.exp(logits - m)
    return float(e[1] / e.sum())


def label_from_p(p, hi=0.5, watch=0.35):
    if p is None:
        return "stable"
    return "high_risk" if p >= hi else "watch" if p >= watch else "stable"


def main() -> None:
    rows = json.loads(DUMP.read_text(encoding="utf-8"))
    clf = RiskClassifier.load()
    sess, name = edge_session()

    scored = []
    for r in rows:
        res = clf.predict_window(VitalWindow(
            patient_id="sim", eeg=r["eeg"], ecg=r["ecg"], motion=r["motion"], hr=r["hr"],
        ))
        p_edge = edge_prob(sess, name, r["eeg"])
        scored.append({
            **{k: r[k] for k in ("episode", "type", "phase", "seizure", "preictal")},
            "cloud": res.label,
            "cloud_pred": bool(res.predicted),
            "cloud_forecast": res.preictal_prob,
            "edge": label_from_p(p_edge),
            "edge_p": p_edge,
            "phone": r["phone_label"],
            "phone_pred": bool(r["phone_predicted"]),
        })

    report = {}
    for engine, pred_key in (("cloud", "cloud_pred"), ("edge", None), ("phone", "phone_pred")):
        by_type = defaultdict(lambda: {"episodes": set(), "detected": {}, "onset": {},
                                       "warned": set(), "fa_windows": 0, "calm_windows": 0,
                                       "seizure_windows": 0, "seizure_hits": 0})
        for i, s in enumerate(scored):
            t = s["type"] or "calm"
            b = by_type[t]
            alarm = s[engine] == "high_risk"
            if s["seizure"]:
                b["episodes"].add(s["episode"])
                b["onset"].setdefault(s["episode"], i)
                b["seizure_windows"] += 1
                b["seizure_hits"] += alarm
                if alarm:
                    b["detected"].setdefault(s["episode"], i)
            else:
                b["calm_windows"] += 1
                b["fa_windows"] += alarm
            if pred_key and s["preictal"] and s[pred_key]:
                b["warned"].add(s["episode"])
        out = {}
        for t, b in by_type.items():
            n = len(b["episodes"])
            lat = [(b["detected"][e] - b["onset"][e]) * 2 for e in b["detected"]]
            out[t] = {
                "seizures": n,
                "detected": f"{len(b['detected'])}/{n}" if n else "-",
                "time_to_detect_s": round(float(np.mean(lat)), 1) if lat else None,
                "seizure_window_recall": round(b["seizure_hits"] / b["seizure_windows"], 3) if b["seizure_windows"] else None,
                "early_warning": f"{len(b['warned'] & b['episodes'])}/{n}" if n and pred_key else "-",
                "false_alarm_window_rate": round(b["fa_windows"] / b["calm_windows"], 3) if b["calm_windows"] else None,
            }
        report[engine] = out

    # Per-phase confusion for cloud & edge, to see where errors come from.
    phase = defaultdict(lambda: defaultdict(int))
    for s in scored:
        phase[f"cloud|{s['phase']}"][s["cloud"]] += 1
        phase[f"edge|{s['phase']}"][s["edge"]] += 1
        phase[f"phone|{s['phase']}"][s["phone"]] += 1
    fc = defaultdict(list)
    for s in scored:
        if s["cloud_forecast"] is not None:
            fc[s["phase"]].append(s["cloud_forecast"])
    report["phase_confusion"] = {k: dict(v) for k, v in sorted(phase.items())}
    report["cloud_forecast_mean_by_phase"] = {k: round(float(np.mean(v)), 3) for k, v in fc.items()}
    out_path = ROOT / "research" / "data" / "sim_eval_report.json"
    out_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
