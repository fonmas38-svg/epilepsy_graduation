"""
Step 4 — data splitting.

Two modes, both leakage-safe:
  patient-wise : split SUBJECTS (not windows, not time) into train/val/test so no
                 subject appears in two folds. This is the honest baseline; a
                 random window split would leak because adjacent windows are near-
                 identical.
  LODO         : Leave-One-Dataset-Out. Train on one dataset's H5, test on
                 another's (e.g. train chbmit -> test siena) to show cross-dataset
                 generalization.

Loaders return numpy arrays ready for the torch Dataset in train.py.
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
PROC = ROOT / "data_processed"


def load_h5(name: str):
    path = PROC / f"{name}.h5"
    if not path.exists():
        raise SystemExit(f"missing {path}. Build it first (bonn_prep.py / edf_prep.py).")
    with h5py.File(path, "r") as f:
        return (
            f["X"][:],            # (N, C, L)
            f["y"][:],            # (N,)
            f["subject"][:],      # (N,)
            dict(f.attrs),
        )


def patient_wise_split(subject: np.ndarray, seed: int = 42, ratios=(0.6, 0.2, 0.2)):
    """Return boolean masks (train, val, test) splitting UNIQUE subjects."""
    ratios = np.asarray(ratios, dtype=float)
    if (ratios.shape != (3,) or not np.isfinite(ratios).all()
            or (ratios < 0).any() or not np.isclose(ratios.sum(), 1)):
        raise ValueError("Three nonnegative ratios summing to one are required")
    subject = np.asarray(subject)
    if subject.ndim != 1 or not len(subject):
        raise ValueError("Subject identifiers must be a nonempty vector")
    subs = np.unique(subject)
    active = np.flatnonzero(ratios > 0)
    if len(subs) < len(active):
        raise ValueError("Not enough independent subjects for disjoint nonempty folds")
    np.random.default_rng(seed).shuffle(subs)
    counts = np.zeros(3, dtype=int)
    counts[active] = 1
    for _ in range(len(subs) - len(active)):
        idx = active[np.argmax((ratios * len(subs) - counts)[active])]
        counts[idx] += 1
    tr, va, te = np.split(subs, np.cumsum(counts)[:2])
    masks = tuple(np.isin(subject, group) for group in (tr, va, te))
    return (*masks, {"train": tr.tolist(), "val": va.tolist(), "test": te.tolist()})


def make_patient_wise(name: str, seed: int = 42):
    X, y, subject, attrs = load_h5(name)
    tr, va, te, groups = patient_wise_split(subject, seed)
    print(f"[{name}] subjects -> train {groups['train']} | val {groups['val']} | test {groups['test']}")
    return {
        "train": (X[tr], y[tr]),
        "val": (X[va], y[va]),
        "test": (X[te], y[te]),
        "attrs": attrs,
    }


def make_lodo(train_name: str, test_name: str, val_frac: float = 0.15, seed: int = 42):
    """Leave-One-Dataset-Out: train on train_name subjects, test on all of test_name."""
    if train_name == test_name or not 0 < val_frac < 1:
        raise ValueError("LODO requires different datasets and 0 < val_frac < 1")
    Xtr, ytr, str_, a1 = load_h5(train_name)
    Xte, yte, ste, a2 = load_h5(test_name)
    if Xtr.shape[1:] != Xte.shape[1:]:
        raise ValueError("LODO requires matching channel and window shapes; implicit truncation is unsafe")
    for key in ("fs", "task", "channel_names", "units"):
        if key not in a1 or key not in a2 or not np.array_equal(a1[key], a2[key]):
            raise ValueError(f"LODO requires matching documented {key}")
    # carve a validation set from TRAIN subjects (still patient-wise)
    tr_mask, va_mask, _, groups = patient_wise_split(str_, seed, ratios=(1 - val_frac, val_frac, 0.0))
    print(f"[lodo] train={train_name} ({len(np.unique(str_))} subj) -> test={test_name} ({len(np.unique(ste))} subj)")
    return {
        "train": (Xtr[tr_mask], ytr[tr_mask]),
        "val": (Xtr[va_mask], ytr[va_mask]),
        "test": (Xte, yte),
        "attrs": a1,
    }


if __name__ == "__main__":
    import sys

    name = sys.argv[1] if len(sys.argv) > 1 else "bonn"
    d = make_patient_wise(name)
    for k in ("train", "val", "test"):
        X, y = d[k]
        print(f"  {k}: X={X.shape} pos={int(y.sum())} neg={int((y==0).sum())}")
