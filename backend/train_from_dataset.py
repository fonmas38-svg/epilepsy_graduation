"""Train risk model from offline dataset (MVP without hardware)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data" / "epilepsy_signal_dataset.csv"
MODEL_PATH = ROOT / "models" / "risk_model.joblib"
EVAL_PATH = ROOT.parent / "docs" / "ml-eval.md"
SAMPLES = 128
LABELS = ["stable", "watch", "high_risk"]


def features_from_row(row: pd.Series) -> np.ndarray:
    eeg = np.array([row[f"eeg_{i}"] for i in range(SAMPLES)], dtype=float)
    ecg = np.array([row[f"ecg_{i}"] for i in range(SAMPLES)], dtype=float)
    motion = np.array([row[f"motion_{i}"] for i in range(SAMPLES)], dtype=float)
    hr = float(row["hr"])
    return np.array(
        [
            hr,
            float(np.std(ecg)),
            float(np.mean(eeg**2)),
            float(np.max(np.abs(eeg))),
            float(np.mean(motion**2)),
            float(np.var(motion)),
            float(np.std(ecg)),
        ],
        dtype=float,
    )


def load_xy(path: Path):
    if not path.exists():
        import runpy

        runpy.run_path(str(path.parent / "build_dataset.py"), run_name="__main__")
    df = pd.read_csv(path)
    X = np.vstack([features_from_row(df.iloc[i]) for i in range(len(df))])
    y = df["label_name"].astype(str).to_numpy()
    return X, y


def main():
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DATA
    X, y = load_xy(csv_path)
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.25, random_state=42, stratify=y
    )

    candidates = {
        "logreg": Pipeline(
            [
                ("scaler", StandardScaler()),
                ("clf", LogisticRegression(max_iter=2000, class_weight="balanced")),
            ]
        ),
        "rf": RandomForestClassifier(
            n_estimators=200, max_depth=12, class_weight="balanced", random_state=42
        ),
        "gb": GradientBoostingClassifier(random_state=42),
    }

    best_name, best_model, best_score = None, None, -1
    reports = []
    for name, model in candidates.items():
        model.fit(X_train, y_train)
        pred = model.predict(X_test)
        # prioritize high_risk recall via macro F1 proxy
        from sklearn.metrics import f1_score

        score = f1_score(y_test, pred, average="macro")
        rep = classification_report(y_test, pred, digits=3)
        reports.append((name, score, rep, confusion_matrix(y_test, pred, labels=LABELS)))
        print(f"{name}: macro-F1={score:.4f}")
        if score > best_score:
            best_name, best_model, best_score = name, model, score

    MODEL_PATH.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(
        {
            "model": best_model,
            "high_risk_threshold": 0.55,
            "labels": LABELS,
            "source": str(csv_path),
            "algorithm": best_name,
        },
        MODEL_PATH,
    )

    lines = [
        f"# ML Evaluation (MVP without hardware)\n",
        f"- Dataset: `{csv_path.name}`\n",
        f"- Best algorithm: **{best_name}** (macro-F1={best_score:.4f})\n",
        f"- Artifact: `backend/models/risk_model.joblib`\n",
        "\n## Notes\n",
        "- Labels include `watch` as pre-ictal/rising-risk (soft prediction) and `high_risk` as seizure-like activity.\n",
        "- Replace dataset later with clinical recordings without changing the API.\n",
    ]
    for name, score, rep, cm in reports:
        lines.append(f"\n## {name} (macro-F1={score:.4f})\n\n```\n{rep}\n```\n\nConfusion:\n```\n{cm}\n```\n")
    EVAL_PATH.write_text("".join(lines), encoding="utf-8")
    print("saved", MODEL_PATH)
    print("best", best_name, best_score)


if __name__ == "__main__":
    main()
