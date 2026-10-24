"""Inventory local research artifacts without claiming an independent evaluation."""
import hashlib
import json
from pathlib import Path

import h5py
import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    datasets = []
    for path in sorted((ROOT / "research").rglob("*.h5")):
        with h5py.File(path, "r") as f:
            datasets.append({
                "path": path.relative_to(ROOT).as_posix(), "sha256": digest(path),
                "shape": list(f["X"].shape), "positive_windows": int(np.sum(f["y"][:] == 1)),
                "negative_windows": int(np.sum(f["y"][:] == 0)),
                "group_count": int(len(np.unique(f["subject"][:]))) if "subject" in f else None,
                "attributes": {k: str(v) for k, v in f.attrs.items()},
                "independent_holdout_verified": False,
            })
    weights = [{"path": p.relative_to(ROOT).as_posix(), "sha256": digest(p)}
               for p in sorted((ROOT / "backend" / "models").glob("*.pt"))]
    report = {
        "purpose": "local_artifact_inventory_not_accuracy_evaluation",
        "clinically_validated": False, "datasets": datasets, "weights": weights,
        "continuous_edf_files": len(list((ROOT / "research").rglob("*.edf"))),
        "current_sources": [
            {"path": name, "sha256": digest(ROOT / name)}
            for name in ("research/colab_seizure_detection.ipynb",
                         "research/build_notebook.py", "research/train_seizure_cloud.py")
        ],
        "current_sources_proven_to_produce_saved_weights": False,
        "conclusion": "Prospective seizure prediction accuracy cannot be verified from these local artifacts.",
        "required_evidence": [
            "Frozen training notebook/script and dataset version",
            "Patient-disjoint train/validation/test group lists and predictions",
            "Weights hash, exact preprocessing, montage, units, sample rate and window duration",
            "Continuous held-out recordings and seizure onset annotations for event-based metrics",
        ],
    }
    out = ROOT / "docs" / "MODEL_ARTIFACT_AUDIT.json"
    out.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(out)


if __name__ == "__main__":
    main()
