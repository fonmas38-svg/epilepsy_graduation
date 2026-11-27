"""Build the virtual-sensor library of REAL EEG segments for the mobile simulator.

The simulator must stream real, varied brain signals so the on-phone and cloud
models are tested honestly. Segments come from the Bonn dataset, restricted to
the *held-out test recordings* of the training split (`splits.patient_wise_split`,
seed 42), so no window the models were trained on is ever replayed to them.

Each 178-sample Bonn chunk (173.61 Hz, ~1.03 s) is resampled to 262 samples at
256 Hz (the models' input window) and scaled from microvolts to the app's
normalized units, keeping the amplitude differences between classes (seizure
EEG is ~5x larger than a calm baseline — z-scoring would erase that).

Categories (Bonn class -> simulator use):
  ictal       class 1  (seizure activity)              -> seizure phases
  interictal  class 2  (epileptogenic zone, between)   -> pre-ictal / recovery
  baseline    class 3,4,5 (opposite zone, healthy)     -> stable

Output (mobile/assets/simulator/):
  seizure_library.bin   int16 little-endian, value = round(units * 1000)
  seizure_library.json  categories -> {offset, count}, window, fs, provenance

Run from research/:  python scripts/build_simulator_library.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import h5py
import numpy as np
import pandas as pd
from scipy.signal import resample

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from splits import patient_wise_split  # noqa: E402

CSV = ROOT / "data" / "epileptic_seizure_recognition.csv"
PROCESSED = ROOT / "data" / "bonn_processed.h5"
OUT = ROOT.parent / "mobile" / "assets" / "simulator"
WINDOW = 262
UV_PER_UNIT = 200.0          # calm Bonn EEG (~50-70 uV std) -> ~0.3 units
PER_CATEGORY = 400           # windows kept per category (size ~0.6 MB)
SEED = 42


def _recording_suffix(row_name: str) -> str:
    parts = str(row_name).split(".")
    return parts[2] if len(parts) > 2 else parts[-1]


def main() -> None:
    df = pd.read_csv(CSV)
    id_col, label_col = df.columns[0], df.columns[-1]
    raw = df[df.columns[1:-1]].to_numpy(dtype=np.float64)
    cls = df[label_col].to_numpy()

    # Same recording grouping as bonn_prep.py, then the same seeded split.
    keys = df[label_col].astype(str) + "_" + df[id_col].map(_recording_suffix).astype(str)
    uniq = {k: i for i, k in enumerate(sorted(keys.unique()))}
    subjects = keys.map(uniq).to_numpy(dtype=np.int32)
    with h5py.File(PROCESSED, "r") as f:
        trained_subjects = f["subject"][:]
    _, _, _, groups = patient_wise_split(trained_subjects, seed=SEED)
    # EdgeSeizureNet (train_seizure_cloud.py) used its own 70/15/15
    # recording split with the same seed: keep only recordings held out of
    # BOTH trainings, so neither the cloud nor the phone model has seen them.
    uniq = np.unique(subjects)
    np.random.default_rng(SEED).shuffle(uniq)
    n = len(uniq)
    edge_test = set(uniq[int(round(0.7 * n)) + int(round(0.15 * n)):].tolist())
    test_subjects = set(groups["test"]) & edge_test
    held_out = np.isin(subjects, list(test_subjects))

    categories = {
        "ictal": (cls == 1),
        "interictal": (cls == 2),
        "baseline": np.isin(cls, (3, 4, 5)),
    }
    rng = np.random.default_rng(SEED)
    blobs, meta = [], {}
    offset = 0
    for name, mask in categories.items():
        idx = np.flatnonzero(mask & held_out)
        if len(idx) == 0:
            raise SystemExit(f"no held-out windows for {name}")
        rng.shuffle(idx)
        idx = idx[:PER_CATEGORY]
        windows = resample(raw[idx], WINDOW, axis=1)
        windows = windows - windows.mean(axis=1, keepdims=True)
        units = np.clip(windows / UV_PER_UNIT, -32.0, 32.0)
        q = np.round(units * 1000).astype("<i2")
        blobs.append(q.reshape(-1))
        meta[name] = {
            "offset": offset,
            "count": int(len(idx)),
            "std_units": round(float(units.std()), 4),
        }
        offset += len(idx)

    OUT.mkdir(parents=True, exist_ok=True)
    np.concatenate(blobs).tofile(OUT / "seizure_library.bin")
    (OUT / "seizure_library.json").write_text(json.dumps({
        "version": 1,
        "window": WINDOW,
        "fs": 256,
        "scale": 1000,
        "units": "normalized_demo (uV / 200)",
        "source": "Bonn EEG (Andrzejak et al. 2001), recordings held out of BOTH "
                  "the cloud CNN-LSTM and the EdgeSeizureNet training splits",
        "held_out_recordings": len(test_subjects),
        "categories": meta,
    }, indent=2), encoding="utf-8")
    size = (OUT / "seizure_library.bin").stat().st_size
    print(json.dumps(meta), f"{size / 1024:.0f} KiB")


if __name__ == "__main__":
    main()
