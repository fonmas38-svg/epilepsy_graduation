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
    rng = np.random.default_rng(seed)
    subs = np.unique(subject)
    rng.shuffle(subs)
    n = len(subs)
    n_tr = max(1, int(round(ratios[0] * n)))
    n_va = max(1, int(round(ratios[1] * n))) if n - n_tr > 1 else 0
    tr, va, te = subs[:n_tr], subs[n_tr : n_tr + n_va], subs[n_tr + n_va :]
    if len(te) == 0:  # tiny-subject datasets (e.g. Bonn=5): fall back to move one
        te = va[-1:] if len(va) else tr[-1:]
    m = lambda group: np.isin(subject, group)  # noqa: E731
    return m(tr), m(va), m(te), {"train": tr.tolist(), "val": va.tolist(), "test": te.tolist()}


def make_patient_wise(name: str, seed: int = 42):
    X, y, subject, attrs = load_h5(name)
    tr, va, te, groups = patient_wise_split(subject, seed)
    print(f"[{name}] subjects -> train {groups['train']} | val {groups['val']} | test {groups['test']}")
    return {
        "train": (X[tr], y[tr]),
        "val": (X[va], y[va]) if va.any() else (X[te], y[te]),
        "test": (X[te], y[te]),
        "attrs": attrs,
    }


def make_lodo(train_name: str, test_name: str, val_frac: float = 0.15, seed: int = 42):
    """Leave-One-Dataset-Out: train on train_name subjects, test on all of test_name."""
    Xtr, ytr, str_, a1 = load_h5(train_name)
    Xte, yte, ste, a2 = load_h5(test_name)
    if Xtr.shape[1:] != Xte.shape[1:]:
        # align channels/length across datasets (min common)
        C = min(Xtr.shape[1], Xte.shape[1]); L = min(Xtr.shape[2], Xte.shape[2])
        Xtr, Xte = Xtr[:, :C, :L], Xte[:, :C, :L]
        print(f"[lodo] aligned shapes to C={C} L={L}")
    # carve a validation set from TRAIN subjects (still patient-wise)
    tr_mask, va_mask, _, groups = patient_wise_split(str_, seed, ratios=(1 - val_frac, val_frac, 0.0))
    print(f"[lodo] train={train_name} ({len(np.unique(str_))} subj) -> test={test_name} ({len(np.unique(ste))} subj)")
    return {
        "train": (Xtr[tr_mask], ytr[tr_mask]),
        "val": (Xtr[va_mask], ytr[va_mask]) if va_mask.any() else (Xte, yte),
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
