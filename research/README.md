# Research: real-data seizure prediction pipeline

> ⚠️ **Medical disclaimer.** This is a graduation research prototype, **not** a
> certified clinical device. It must never be used for real patient care,
> diagnosis, or treatment decisions. Seizure *prediction* (preictal detection)
> is an open, unsolved problem; state-of-the-art systems reach ~70–90 %
> sensitivity at ~0.1–0.3 false alarms/hour. Treat any higher number with
> suspicion — it is almost always data leakage.

This folder is **separate** from the running `backend/` service so nothing here
can break the working API. It builds a second, research-grade model that can be
wired into the backend later.

## Two different tasks (important)

| | Backend classifier (existing) | Research model (here) |
|---|---|---|
| Task | 3-class state: `stable/watch/high_risk` | binary: `preictal` vs `interictal` |
| Input | 128-sample window, 7 hand features | raw multichannel signal, 256 Hz |
| Model | sklearn (RF/GB/LogReg) | CNN-1D + LSTM (PyTorch) |
| Goal | live risk display | early-warning **prediction** |

## Datasets & licensing

| Dataset | Signals | Access | Notes |
|---|---|---|---|
| **Bonn** (Epileptic Seizure Recognition CSV) | single-channel EEG, 178 pts | mirror (auto-downloaded) | seizure **detection**, MVP only — no timing info, so *no real preictal* |
| **CHB-MIT** | scalp EEG (multi-ch) | PhysioNet, open | needs use-agreement click-through; ~40+ GB |
| **Siena** | scalp EEG **+ ECG** | PhysioNet, open (credentialed) | best fit for your EEG+ECG device |
| **TUH TUSZ** | scalp EEG | TUH, **signed data agreement + email** | cannot be automated; register at isip.piconepress.com |

### What you must do manually
- **CHB-MIT / Siena**: create a free PhysioNet account, open each database page,
  accept the data-use agreement, then run `scripts/download_data.py` with your
  credentials (or `wget -r` the printed URL). See the script for exact commands.
- **TUSZ**: email TUH and sign their agreement. There is no direct-download link;
  do not attempt to scrape it.

## Pipeline order

```
scripts/download_data.py      # 1. fetch Bonn (auto) + print CHB-MIT/Siena steps
scripts/bonn_prep.py          # 2. Bonn CSV  -> data_processed/bonn.h5   (runnable NOW)
scripts/harmonize.py          # 3. EDF (CHB-MIT/Siena) -> data_processed/<ds>.h5
scripts/splits.py             # 4. patient-wise + Leave-One-Dataset-Out index files
scripts/train.py              # 5. CNN1D+LSTM, focal loss, Sensitivity + FPR/h
```

## Harmonization contract (all datasets normalized to this)

- channels: 10–20 montage subset, common set across datasets
- resample: **256 Hz**
- filter: band-pass **0.5–40 Hz** + **notch** (50 Hz EU / 60 Hz US)
- artifact rejection: drop windows with |amp| > `clip_uv` or flatlines
- normalization: **per-subject z-score** (fit on that subject's interictal only)
- windows: `preictal` = last **30 min** before onset with a **5 min** safety gap;
  `interictal` = anything **> 4 h** away from any seizure

## Honest limitation of the Bonn MVP
Bonn has **no seizure-onset timestamps**, so it cannot express *preictal*. We use
it only to prove the model/plumbing on **real EEG** (ictal vs non-ictal detection).
Real *prediction* requires CHB-MIT/Siena, which carry event timing.
