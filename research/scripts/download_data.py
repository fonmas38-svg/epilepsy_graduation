"""
Step 1 — data acquisition.

Bonn (Epileptic Seizure Recognition CSV) is fetched automatically from a public
mirror. CHB-MIT and Siena require you to accept a PhysioNet data-use agreement
first, so for those we only *print* the exact commands rather than run them.

Usage:
    python scripts/download_data.py            # fetch Bonn + print PhysioNet steps
    python scripts/download_data.py --chbmit   # download 1 CHB-MIT subject (after agreement)
    python scripts/download_data.py --siena     # download 1 Siena subject
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data_raw"
BONN_CSV = RAW / "bonn" / "epileptic_seizure_recognition.csv"

# Public GitHub mirror of the UCI "Epileptic Seizure Recognition" repackaging of
# the Bonn set (11500 x 179, 178 samples/segment + label). Verified reachable.
BONN_MIRRORS = [
    "https://raw.githubusercontent.com/xterm99/kaggle-epileptic-seizure-recognition/main/data/Epileptic%20Seizure%20Recognition.csv",
]


def fetch_bonn() -> None:
    BONN_CSV.parent.mkdir(parents=True, exist_ok=True)
    if BONN_CSV.exists() and BONN_CSV.stat().st_size > 1_000_000:
        print(f"[bonn] already present: {BONN_CSV} ({BONN_CSV.stat().st_size} bytes)")
        return
    last_err = None
    for url in BONN_MIRRORS:
        try:
            print(f"[bonn] downloading {url}")
            req = urllib.request.Request(url, headers={"User-Agent": "research/1.0"})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
            if len(data) < 1_000_000:
                raise ValueError(f"file too small ({len(data)} bytes), likely a 404 page")
            BONN_CSV.write_bytes(data)
            print(f"[bonn] saved {BONN_CSV} ({len(data)} bytes)")
            return
        except Exception as e:  # noqa: BLE001
            last_err = e
            print(f"[bonn] mirror failed: {e}")
    raise SystemExit(
        f"[bonn] all mirrors failed ({last_err}). Download 'Epileptic Seizure "
        f"Recognition.csv' manually from Kaggle and place it at {BONN_CSV}"
    )


PHYSIONET_HELP = """
================ CHB-MIT & Siena (manual consent required) ================

1. Create a free account at https://physionet.org/register/
2. Open each database page and click 'Files' -> accept the data use agreement:
     CHB-MIT : https://physionet.org/content/chbmit/1.0.0/
     Siena   : https://physionet.org/content/siena-scalp-eeg/1.0.0/
3. Then download. Two options:

   (a) Python + wfdb (one subject at a time -- recommended, small):
       import wfdb
       wfdb.dl_database('chbmit', dl_dir='data_raw/chbmit', records=['chb01'])
       wfdb.dl_database('siena-scalp-eeg', dl_dir='data_raw/siena',
                        records=['PN00'])

   (b) wget the whole DB (LARGE: CHB-MIT ~40+ GB, Siena ~20 GB):
       wget -r -N -c -np https://physionet.org/files/chbmit/1.0.0/
       wget -r -N -c -np https://physionet.org/files/siena-scalp-eeg/1.0.0/

This script can run option (a) for ONE subject if you pass --chbmit / --siena
AFTER you have accepted the agreement (wfdb reads the public files).
==========================================================================
"""


def fetch_physionet(db: str, dl_dir: Path, record: str) -> None:
    try:
        import wfdb
    except ImportError:
        raise SystemExit("wfdb not installed. pip install -r requirements-research.txt")
    dl_dir.mkdir(parents=True, exist_ok=True)
    print(f"[{db}] downloading record {record} into {dl_dir} ...")
    wfdb.dl_database(db, dl_dir=str(dl_dir), records=[record])
    print(f"[{db}] done. EDF files under {dl_dir}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--chbmit", action="store_true", help="download chb01 (needs agreement)")
    ap.add_argument("--siena", action="store_true", help="download PN00 (needs agreement)")
    args = ap.parse_args()

    fetch_bonn()

    if args.chbmit:
        fetch_physionet("chbmit", RAW / "chbmit", "chb01")
    if args.siena:
        fetch_physionet("siena-scalp-eeg", RAW / "siena", "PN00")

    if not (args.chbmit or args.siena):
        print(PHYSIONET_HELP)


if __name__ == "__main__":
    main()
