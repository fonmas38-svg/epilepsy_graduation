"""
Step 2 (runnable NOW) — Bonn 'Epileptic Seizure Recognition' CSV -> HDF5.

The CSV has 11500 rows x (1 id + 178 samples + 1 label). Original recordings are
sampled at 173.61 Hz; each 178-sample row is a 1.0 s segment. The 5 classes:
    1 = seizure (ictal)          -> positive
    2..5 = non-seizure states    -> negative
Bonn has NO onset timing, so this is DETECTION (ictal vs non-ictal), used only to
prove the model on real EEG. The 'subject' id is parsed from the row identifier
so patient-wise splitting still works.

The UCI repackaging DESTROYED per-patient identity: the row id 'X21.V1.791' is
(chunk_index . V1 . recording_suffix), where a single 4097-sample Bonn recording
was cut into 23 chunks of 178 samples. The only leakage-safe grouping we can
recover is the ORIGINAL RECORDING = (label, suffix): its 23 chunks are near-
duplicates and MUST stay in the same fold. We use that as the 'subject' group.
(True biological subject is unrecoverable from this CSV -- documented limitation.)

Output HDF5 (data_processed/bonn.h5):
    X       float32 (N, 1, win_len)   harmonized single-channel windows
    y       int64   (N,)              1=ictal, 0=non-ictal
    subject int32   (N,)              original-recording group id (leakage guard)
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pandas as pd

import harmonize as H

ROOT = Path(__file__).resolve().parents[1]
CSV = ROOT / "data_raw" / "bonn" / "epileptic_seizure_recognition.csv"
OUT = ROOT / "data_processed" / "bonn.h5"

BONN_FS = 173.61  # original Bonn sampling rate


def _recording_suffix(row_name: str) -> str:
    """Row id 'X21.V1.791' -> '791' (original-recording suffix within a class)."""
    parts = str(row_name).split(".")
    return parts[2] if len(parts) > 2 else parts[-1]


def main() -> None:
    if not CSV.exists():
        raise SystemExit(f"missing {CSV}. Run: python scripts/download_data.py")
    df = pd.read_csv(CSV)
    id_col = df.columns[0]
    label_col = df.columns[-1]
    feat_cols = df.columns[1:-1]
    assert len(feat_cols) == 178, f"expected 178 sample cols, got {len(feat_cols)}"

    cfg = H.HarmonizeConfig(notch_freq=0.0)  # Bonn was analog-filtered; skip notch
    raw = df[feat_cols].to_numpy(dtype=np.float64)
    labels = (df[label_col].to_numpy() == 1).astype(np.int64)  # class 1 = seizure
    # leakage-safe group = original recording = (label, suffix). Encode as one int.
    suf = df[id_col].map(_recording_suffix).astype(str)
    grp_keys = (df[label_col].astype(str) + "_" + suf)
    uniq = {k: i for i, k in enumerate(sorted(grp_keys.unique()))}
    subjects = grp_keys.map(uniq).to_numpy(dtype=np.int32)

    xs, ys, subs = [], [], []
    for i in range(raw.shape[0]):
        seg = raw[i : i + 1, :]                      # (1, 178)
        clean = H.clean_signal(seg, BONN_FS, cfg)     # (1, ~262) @ 256 Hz
        # z-score per segment (Bonn has no long interictal baseline per subject)
        m, s = clean.mean(), clean.std() + 1e-8
        clean = (clean - m) / s
        if H.window_is_artifact(clean, cfg):
            continue
        xs.append(clean.astype(np.float32))
        ys.append(int(labels[i]))
        subs.append(int(subjects[i]))

    win_len = min(x.shape[-1] for x in xs)
    X = np.stack([x[:, :win_len] for x in xs]).astype(np.float32)  # (N,1,win_len)
    y = np.asarray(ys, dtype=np.int64)
    subject = np.asarray(subs, dtype=np.int32)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with h5py.File(OUT, "w") as f:
        f.create_dataset("X", data=X, compression="gzip")
        f.create_dataset("y", data=y)
        f.create_dataset("subject", data=subject)
        f.attrs["fs"] = H.TARGET_FS
        f.attrs["dataset"] = "bonn"
        f.attrs["task"] = "detection(ictal_vs_nonictal)"
    print(f"saved {OUT}  X={X.shape}  pos={int(y.sum())}  neg={int((y==0).sum())}"
          f"  subjects={len(set(subject.tolist()))}")


if __name__ == "__main__":
    main()
