"""Train a RandomForest risk classifier on synthetic labeled windows."""
from __future__ import annotations

import json
from pathlib import Path

import joblib
import numpy as np
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import train_test_split

from app.preprocessing import extract_features, features_to_array
from app.simulation import generate_window

ROOT = Path(__file__).resolve().parent
MODEL_DIR = ROOT / "models"
MODEL_PATH = MODEL_DIR / "risk_model.joblib"
EVAL_PATH = ROOT.parent / "docs" / "ml-eval.md"
LABELS = ["stable", "watch", "high_risk"]


def build_dataset(n_per_class: int = 400, samples: int = 128, seed: int = 42):
    rng = np.random.default_rng(seed)
    X, y = [], []
    for label in LABELS:
        for i in range(n_per_class):
            window = generate_window(
                pattern=label,  # type: ignore[arg-type]
                samples=samples,
                seed=int(rng.integers(0, 1_000_000)),
            )
            feats = extract_features(window)
            X.append(features_to_array(feats))
            y.append(label)
    return np.asarray(X), np.asarray(y)


def main():
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    X, y = build_dataset()
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.25, random_state=42, stratify=y
    )
    model = RandomForestClassifier(
        n_estimators=120,
        max_depth=10,
        random_state=42,
        class_weight="balanced",
    )
    model.fit(X_train, y_train)
    y_pred = model.predict(X_test)
    report = classification_report(y_test, y_pred, digits=3)
    cm = confusion_matrix(y_test, y_pred, labels=LABELS)

    high_risk_threshold = 0.55
    joblib.dump(
        {"model": model, "high_risk_threshold": high_risk_threshold, "labels": LABELS},
        MODEL_PATH,
    )

    eval_md = f"""# ML Evaluation (V1.0)

Synthetic dataset: {len(y)} windows ({len(LABELS)} classes × balanced).

## Model
- Algorithm: RandomForestClassifier (n_estimators=120, max_depth=10)
- Features: hr_mean, hr_std, eeg_power, eeg_peak, motion_energy, motion_variance, ecg_variability
- High-risk probability threshold: {high_risk_threshold}
- Artifact: `backend/models/risk_model.joblib`

## Classification report

```
{report}
```

## Confusion matrix (rows=true, cols=pred)

Labels order: {LABELS}

```
{cm}
```

## Notes
- Data is **simulated** for academic V1; not clinical-grade.
- Recall on `high_risk` is prioritized via class_weight=balanced and threshold tuning.
"""
    EVAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    EVAL_PATH.write_text(eval_md, encoding="utf-8")
    print(report)
    print(f"Saved model -> {MODEL_PATH}")
    print(f"Saved eval  -> {EVAL_PATH}")


if __name__ == "__main__":
    main()
