"""SeizeIT2 feature extraction v2 for seizure DETECTION (10-s epochs).

v1 averaged per-second EEG features over 30 s, which hides ~1-minute seizures.
v2 keeps 10-s epochs, both behind-the-ear EEG channels (mean and max of the
per-second features), heart rate dynamics and movement rhythm (2-8 Hz power,
typical of clonic jerking). Seizure onsets, durations and types are saved per
file so results can be reported by seizure type.
Env: SHARD, NSHARDS. Output: work/seizeit2_v2/sub-*.npz
"""
import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

import mne
import numpy as np
from scipy.signal import butter, find_peaks, resample_poly, sosfiltfilt, welch
from scipy.stats import kurtosis, skew

mne.set_log_level("ERROR")
S3, DS = "https://s3.amazonaws.com/openneuro.org", "ds005873"
FS, WIN, STEP, EPOCH = 256, 262, 256, 10
OUT = Path("work/seizeit2_v2"); OUT.mkdir(parents=True, exist_ok=True)
TMP = Path("work/tmp_v2"); TMP.mkdir(parents=True, exist_ok=True)
SHARD, NSHARDS = int(os.environ.get("SHARD", 0)), int(os.environ.get("NSHARDS", 1))
SOS = butter(4, [0.5 / 128, 40 / 128], btype="bandpass", output="sos")
FREQS = np.fft.rfftfreq(WIN, 1 / FS); HANN = np.hanning(WIN)
BANDS = [(0.5, 4), (4, 8), (8, 13), (13, 30), (30, 40)]
MAXED = [6, 7, 0, 1, 11]     # log_power, line_length, rel_delta, rel_theta, kurtosis


def list_keys(prefix):
    keys, token = [], None
    while True:
        url = f"{S3}?list-type=2&prefix={prefix}" + (
            f"&continuation-token={urllib.parse.quote(token)}" if token else "")
        for a in range(5):
            try:
                xml = urllib.request.urlopen(url, timeout=60).read().decode(); break
            except Exception:
                time.sleep(5)
        else:
            raise RuntimeError("list " + prefix)
        keys += re.findall(r"<Key>([^<]+)</Key>", xml)
        m = re.search(r"<NextContinuationToken>([^<]+)</NextContinuationToken>", xml)
        if not m:
            return keys
        token = m.group(1)


def fetch(key, dest):
    part = dest.with_suffix(dest.suffix + ".part")
    for a in range(8):
        if subprocess.run(["curl", "-sSfL", "--retry", "5", "-C", "-", "-o", str(part),
                           f"{S3}/{key}"]).returncode == 0:
            part.rename(dest); return dest
        time.sleep(5)
    raise RuntimeError(key)


def win_feats(W):
    z = sosfiltfilt(SOS, np.asarray(W, np.float64), axis=1)
    P = np.abs(np.fft.rfft(z * HANN, axis=1)) ** 2
    band = (FREQS >= 0.5) & (FREQS < 40); tot = P[:, band].sum(1) + 1e-12
    rel = [P[:, (FREQS >= a) & (FREQS < b)].sum(1) / tot for a, b in BANDS]
    cum = np.cumsum(P * band, 1) / tot[:, None]; sef = FREQS[np.argmax(cum >= 0.9, axis=1)] / 40
    sd = z.std(1) + 1e-8; d1, d2 = np.diff(z, axis=1), np.diff(z, 2, axis=1)
    mob = d1.std(1) / sd; comp = (d2.std(1) / (d1.std(1) + 1e-8)) / (mob + 1e-8)
    return np.stack(rel + [sef, np.log(z.var(1) + 1e-12), np.abs(d1).mean(1) / sd, mob, comp,
                           skew(z, axis=1), np.clip(kurtosis(z, axis=1), -5, 50)], 1).astype(np.float32)


def to_fs(x, fs, target):
    fs = int(round(fs))
    if fs == target:
        return x
    g = np.gcd(fs, target); return resample_poly(x, target // g, fs // g)


def eeg_epochs(x, n_ep):
    idx = np.arange(0, len(x) - WIN, STEP)
    ps = np.full((len(idx), 12), np.nan, np.float32)
    for a in range(0, len(idx), 20000):
        j = idx[a:a + 20000]
        ps[a:a + len(j)] = win_feats(np.stack([x[i:i + WIN] for i in j]))
    out = np.full((n_ep, 17), np.nan, np.float32)
    n = min(n_ep, len(ps) // EPOCH)
    if n:
        B = ps[:n * EPOCH].reshape(n, EPOCH, 12)
        out[:n, :12] = np.nanmean(B, 1); out[:n, 12:] = np.nanmax(B[:, :, MAXED], 1)
    return out


def ecg_epochs(e, fs, n_ep):
    out = np.full((n_ep, 4), np.nan, np.float32)
    if e is None or len(e) < fs * 60:
        return out
    x = sosfiltfilt(butter(3, [5 / (fs / 2), 20 / (fs / 2)], btype="bandpass", output="sos"), e)
    if -np.percentile(x, 0.5) > np.percentile(x, 99.5):
        x = -x
    blk = int(10 * fs); thr = np.zeros_like(x)
    for a in range(0, len(x), blk):
        thr[a:a + blk] = 0.45 * np.percentile(x[a:a + blk], 99)
    pk, _ = find_peaks(x, distance=int(0.3 * fs)); pk = pk[x[pk] > thr[pk]]
    t = pk / fs; rr = np.diff(t); tr = t[1:]
    ok = (rr > 0.3) & (rr < 2.0); ok[1:] &= np.abs(np.diff(rr)) < 0.3
    for i in range(n_ep):
        end = (i + 1) * EPOCH
        a60, a10, b = np.searchsorted(tr, [end - 60, end - EPOCH, end], side="right")
        v10, v60 = rr[a10:b][ok[a10:b]], rr[a60:b][ok[a60:b]]
        if len(v10) >= 4:
            hr = 60 / v10; out[i, 0] = hr.mean(); out[i, 1] = hr.max()
        if len(v60) >= 20:
            out[i, 2] = np.sqrt(np.mean(np.diff(v60) ** 2)) * 1000
        out[i, 3] = ok[a10:b].sum() / max(b - a10, 1)
    return out


def mov_epochs(raw, n_ep):
    out = np.full((n_ep, 6), np.nan, np.float32)
    if raw is None:
        return out
    fs = raw.info["sfreq"]; s = int(EPOCH * fs)
    for j, dev in enumerate(("ECGEMG SD", "EEG SD")):
        acc = [c for c in raw.ch_names if c.startswith(dev) and "ACC" in c]
        gyr = [c for c in raw.ch_names if c.startswith(dev) and "GYR" in c]
        if len(acc) != 3:
            continue
        mag = np.sqrt((raw.get_data(picks=acc) ** 2).sum(0))
        gm = np.sqrt((raw.get_data(picks=gyr) ** 2).sum(0)) if len(gyr) == 3 else None
        for i in range(min(n_ep, len(mag) // s)):
            seg = mag[i * s:(i + 1) * s]
            out[i, 3 * j] = seg.std()
            f, pw = welch(seg - seg.mean(), fs=fs, nperseg=min(len(seg), 128))
            tot = pw[(f > 0.3)].sum() + 1e-12
            out[i, 3 * j + 1] = pw[(f >= 2) & (f <= 8)].sum() / tot
            if gm is not None:
                out[i, 3 * j + 2] = gm[i * s:(i + 1) * s].mean()
    return out


def read_events(p):
    rows = p.read_text().strip().splitlines(); h = rows[0].split("\t")
    i = [h.index("onset"), h.index("duration"), h.index("eventType")]
    return [tuple(r.split("\t")[k] for k in i) for r in rows[1:] if r.strip()]


subjects = sorted({k.split("/")[1] for k in list_keys(f"{DS}/sub-")
                   if k.split("/")[1].startswith("sub-")})[SHARD::NSHARDS]
print(f"shard {SHARD}/{NSHARDS}: {len(subjects)} subjects", flush=True)
for sub in subjects:
    t0 = time.time(); dest = OUT / f"{sub}.npz"
    if dest.exists():
        continue
    try:
        keys = list_keys(f"{DS}/{sub}/")
        runs = sorted({re.search(r"(run-\d+)", k).group(1) for k in keys if k.endswith("_eeg.edf")})
        F, L, R, SZ = [], [], [], []
        for ri, run in enumerate(runs):
            d = TMP / sub; d.mkdir(parents=True, exist_ok=True)

            def get(mod, ext="edf"):
                k = [x for x in keys if f"{run}_" in x and x.endswith(f"_{mod}.{ext}")]
                return fetch(k[0], d / Path(k[0]).name) if k else None
            try:
                ev = get("events", "tsv"); events = read_events(ev) if ev else []
                r = mne.io.read_raw_edf(get("eeg"), preload=False)
                chans = [to_fs(r.get_data(picks=[c])[0] * 1e6, r.info["sfreq"], FS)
                         for c in range(min(2, len(r.ch_names)))]
                n_ep = len(chans[0]) // (EPOCH * FS)
                fe = [eeg_epochs(x, n_ep) for x in chans]
                if len(fe) == 1:
                    fe.append(np.full_like(fe[0], np.nan))
                p = get("ecg")
                if p:
                    rr_ = mne.io.read_raw_edf(p, preload=False)
                    fc = ecg_epochs(rr_.get_data(picks=[0])[0] * 1e6, rr_.info["sfreq"], n_ep)
                else:
                    fc = ecg_epochs(None, FS, n_ep)
                p = get("mov")
                fm = mov_epochs(mne.io.read_raw_edf(p, preload=True) if p else None, n_ep)
                lab = np.zeros(n_ep, np.int8); t0e = np.arange(n_ep) * EPOCH
                for o, du, ty in events:
                    o, du = float(o), float(du)
                    m = (t0e + EPOCH > o) & (t0e < o + du)
                    if ty.startswith("sz"):
                        lab[m] = 1; SZ.append((ri, o, du, ty))
                    elif ty == "impd":
                        lab[m & (lab == 0)] = 2
                F.append(np.concatenate(fe + [fc, fm], 1)); L.append(lab)
                R.append(np.full(n_ep, ri, np.int32))
            except Exception as e:
                print(sub, run, "skipped:", type(e).__name__, e, flush=True)
            finally:
                shutil.rmtree(d, ignore_errors=True)
        if F:
            np.savez_compressed(dest, X=np.concatenate(F), lab=np.concatenate(L),
                                run=np.concatenate(R), seizures=json.dumps(SZ))
            print(f"{sub} ok: files {len(runs)}, seizures {len(SZ)}, hours "
                  f"{sum(map(len, L)) * EPOCH / 3600:.1f} ({time.time() - t0:.0f}s)", flush=True)
    except Exception as e:
        print(sub, "FAILED", type(e).__name__, e, flush=True)
if not list(OUT.glob("sub-*.npz")):
    raise SystemExit("no features produced")
