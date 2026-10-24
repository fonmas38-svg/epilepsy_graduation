"""
Step 3 — EDF (CHB-MIT / Siena) -> harmonized HDF5 with preictal/interictal labels.

Runnable once you have EDF files under data_raw/chbmit or data_raw/siena
(see scripts/download_data.py). Requires MNE.

CHB-MIT: seizure times come from 'chbXX-summary.txt' (per-file "Seizure Start
         Time" / "End Time" in seconds relative to that EDF).
Siena:   seizure times come from 'Seizures-list-PNxx.txt' (Registration start +
         Seizure start/end clock times). ECG channel is kept when present.

Normalization uses only each window, without labels or future subject baselines.
Recording-level zero-phase filters remain OFFLINE preprocessing: prospective
performance must be evaluated separately with the deployed causal pipeline.

Output data_processed/<dataset>.h5:
    X       float32 (N, C, win_len)
    y       int64   (N,)   1=preictal, 0=interictal
    subject int32   (N,)
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

import h5py
import numpy as np

import harmonize as H
import windows as W

ROOT = Path(__file__).resolve().parents[1]

# Common 10-20 scalp channels shared across CHB-MIT & Siena (bipolar names vary;
# we match loosely by stripping '-REF'/'-LE' and uppercasing).
COMMON_1020 = [
    "FP1", "FP2", "F3", "F4", "C3", "C4", "P3", "P4", "O1", "O2",
    "F7", "F8", "T7", "T8", "P7", "P8", "FZ", "CZ", "PZ",
]


def _norm_ch(name: str) -> str:
    n = name.upper().replace("EEG ", "").strip()
    return n.replace("T3", "T7").replace("T4", "T8").replace("T5", "P7").replace("T6", "P8")


def _pick_channels(raw):
    mapping = {}
    for ch in raw.ch_names:
        key = _norm_ch(ch)
        parts = key.split("-")
        if parts[0] not in COMMON_1020 or any(p not in COMMON_1020 + ["REF", "LE"] for p in parts):
            continue
        if key in mapping:
            raise ValueError(f"Ambiguous duplicate channel {key}")
        mapping[key] = ch
    names = sorted(mapping)
    if len(names) < 4:
        return None, []
    return [mapping[k] for k in names], names


# ----------------------- CHB-MIT summary parsing -----------------------
def parse_chbmit_summary(summary_path: Path) -> dict[str, list[tuple[float, float]]]:
    seizures: dict[str, list[tuple[float, float]]] = {}
    cur = None
    starts: list[float] = []
    ends: list[float] = []
    for line in summary_path.read_text(errors="ignore").splitlines():
        line = line.strip()
        if line.startswith("File Name:"):
            if cur:
                if len(starts) != len(ends):
                    raise ValueError(f"Incomplete seizure times for {cur}")
                seizures[cur] = list(zip(starts, ends))
            cur = line.split(":", 1)[1].strip()
            starts, ends = [], []
        elif "Seizure" in line and "Start Time" in line:
            m = re.search(r"(\d+)\s*seconds", line)
            if m:
                starts.append(float(m.group(1)))
        elif "Seizure" in line and "End Time" in line:
            m = re.search(r"(\d+)\s*seconds", line)
            if m:
                ends.append(float(m.group(1)))
    if cur:
        if len(starts) != len(ends):
            raise ValueError(f"Incomplete seizure times for {cur}")
        seizures[cur] = list(zip(starts, ends))
    return seizures


def load_chbmit(root: Path, cfg: H.HarmonizeConfig):
    """Yield (subject_id, edf_path, seizures[(on,off)])."""
    for subj_dir in sorted(root.glob("chb*")):
        if not subj_dir.is_dir():
            continue
        summaries = list(subj_dir.glob("*summary.txt"))
        if len(summaries) != 1:
            raise ValueError(f"Missing or ambiguous seizure annotation: {subj_dir.name}")
        sez = parse_chbmit_summary(summaries[0])
        subj_id = int(re.sub(r"\D", "", subj_dir.name))
        for edf in sorted(subj_dir.glob("*.edf")):
            if edf.name not in sez:
                raise ValueError(f"No explicit seizure annotation for {edf.name}")
            # PhysioNet documents chb01 and chb21 as the same individual.
            yield (1 if subj_id == 21 else subj_id), edf, sez[edf.name]


def load_siena(root: Path, cfg: H.HarmonizeConfig):
    """Yield (subject_id, edf_path, seizures[(on,off)]). Siena onset parsed from list file."""
    for subj_dir in sorted(root.glob("PN*")):
        if not subj_dir.is_dir():
            continue
        subj_id = int(re.sub(r"\D", "", subj_dir.name)) if re.search(r"\d", subj_dir.name) else 0
        listing = list(subj_dir.glob("Seizures-list*.txt"))
        # Siena's list uses clock times; a robust parse is left per-subject. If a
        # sidecar '<edf>.tsv' with onset,offset seconds exists, prefer it.
        per_file = _parse_siena_list(listing[0]) if listing else {}
        for edf in sorted(subj_dir.glob("*.edf")):
            sez = per_file.get(edf.name, [])
            tsv = edf.with_suffix(".seizures.tsv")
            if tsv.exists():
                sez = [tuple(map(float, ln.split())) for ln in tsv.read_text().splitlines() if ln.strip()]
            if not tsv.exists() and edf.name not in per_file:
                raise ValueError(f"Missing verified annotation for {edf.name}; supply .seizures.tsv")
            yield subj_id, edf, sez


def _parse_siena_list(path: Path) -> dict[str, list[tuple[float, float]]]:
    """Best-effort: extract 'Seizure start/end' seconds if the file states them as seconds."""
    out: dict[str, list[tuple[float, float]]] = {}
    cur = None
    start = end = None
    for line in path.read_text(errors="ignore").splitlines():
        l = line.strip()
        fm = re.search(r"File name:\s*(\S+\.edf)", l, re.I)
        if fm:
            cur = fm.group(1)
        sm = re.search(r"Seizure start.*?(\d+)\s*sec", l, re.I)
        em = re.search(r"Seizure end.*?(\d+)\s*sec", l, re.I)
        if sm:
            start = float(sm.group(1))
        if em and cur is not None and start is not None:
            end = float(em.group(1))
            out.setdefault(cur, []).append((start, end))
            start = end = None
    return out


def build(dataset: str, cfg: H.HarmonizeConfig) -> None:
    import mne

    root = ROOT / "data_raw" / ("chbmit" if dataset == "chbmit" else "siena")
    loader = load_chbmit if dataset == "chbmit" else load_siena
    spec_fs = cfg.target_fs

    # First pass: collect windows grouped by subject for per-subject normalization.
    by_subject: dict[int, dict] = {}
    expected_names = None
    for subj_id, edf, seizures in loader(root, cfg):
        try:
            raw = mne.io.read_raw_edf(edf, preload=True, verbose="ERROR")
        except Exception as e:  # noqa: BLE001
            print(f"  skip {edf.name}: {e}")
            continue
        picks, names = _pick_channels(raw)
        if picks is None:
            print(f"  skip {edf.name}: <4 common channels")
            continue
        if expected_names is None:
            expected_names = names
        elif names != expected_names:
            raise ValueError(f"Montage mismatch in {edf.name}; do not silently truncate channels")
        fs_in = raw.info["sfreq"]
        data = raw.get_data(picks=picks) * 1e6  # V -> uV
        clean = H.clean_signal(data, fs_in, cfg)  # (C, samples) @ target_fs
        spec = W.WindowSpec(fs=spec_fs)
        b = by_subject.setdefault(subj_id, {"pre": [], "inter": []})
        for win, label in W.iter_windows(clean, seizures, spec):
            if H.window_is_artifact(win, cfg):
                continue
            (b["pre"] if label == W.LABEL_PREICTAL else b["inter"]).append(win.astype(np.float32))
        print(f"  {edf.name}: sez={len(seizures)} pre={len(b['pre'])} inter={len(b['inter'])}")

    Xs, ys, subs = [], [], []
    for subj_id, b in by_subject.items():
        inter = b["inter"]
        if not inter and not b["pre"]:
            continue
        for label, windows in ((W.LABEL_PREICTAL, b["pre"]), (W.LABEL_INTERICTAL, inter)):
            for win in windows:
                mu = win.mean(axis=-1, keepdims=True)
                sd = win.std(axis=-1, keepdims=True)
                Xs.append((win - mu) / np.maximum(sd, 1e-8))
                ys.append(label)
                subs.append(subj_id)

    if not Xs:
        raise SystemExit(f"no windows produced for {dataset}. Check EDF files exist under {root}")

    X = np.stack(Xs).astype(np.float32)
    y = np.asarray(ys, dtype=np.int64)
    subject = np.asarray(subs, dtype=np.int32)

    out = ROOT / "data_processed" / f"{dataset}.h5"
    out.parent.mkdir(parents=True, exist_ok=True)
    with h5py.File(out, "w") as f:
        f.create_dataset("X", data=X, compression="gzip")
        f.create_dataset("y", data=y)
        f.create_dataset("subject", data=subject)
        f.attrs["channel_names"] = expected_names
        f.attrs["units"] = "window_zscore_from_microvolts"
        f.attrs["preprocessing"] = "offline_record_filter_then_window_zscore_v2"
        f.attrs["prospectively_validated"] = False
        f.attrs["fs"] = spec_fs
        f.attrs["dataset"] = dataset
        f.attrs["task"] = "prediction(preictal_vs_interictal)"
    print(f"saved {out}  X={X.shape}  preictal={int(y.sum())}  interictal={int((y==0).sum())}"
          f"  subjects={len(set(subject.tolist()))}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", choices=["chbmit", "siena"])
    ap.add_argument("--notch", type=float, default=50.0, help="50 EU / 60 US")
    args = ap.parse_args()
    cfg = H.HarmonizeConfig(notch_freq=args.notch)
    build(args.dataset, cfg)


if __name__ == "__main__":
    main()
