"""Seizure DETECTOR on SeizeIT2 wearable features v2 (10-s epochs).

Input: work/seizeit2_v2/sub-*.npz from research/extract_seizeit2_v2.py
  X columns: EEG ch1 (17) | EEG ch2 (17) | heart (4) | movement chest (3) + head (3)
Patient-disjoint 5-fold evaluation; thresholds chosen on held-out TRAINING
patients for each false-alarm target, never on test patients.

Event metrics:
  sensitivity  seizures with an alarm between onset and end + 60 s
  false/day    alarms outside every seizure window (onset-60 s .. end+5 min)
  latency      seconds from onset to the first alarm
Also reported by seizure type (bilateral tonic-clonic, motor, non-motor).
Run: python research/train_detector_seizeit2.py [features_dir] [out_dir]
"""
import json
import sys
import time
from pathlib import Path

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score

FEAT = Path(sys.argv[1] if len(sys.argv) > 1 else "work/seizeit2_v2")
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else "work/detector_outputs")
OUT.mkdir(parents=True, exist_ok=True)
EPOCH = 10
CTX = 60                    # 10 min of history
BASE_EPOCHS = 720           # first 2 h far from seizures = personal baseline
NEG_GAP = 60                # negatives >= 10 min from any seizure
REFRACT = 30                # 5 min between alarms
POST = 6                    # detection allowed until end + 60 s
FA_DAY = [24, 12, 4, 1]     # false-alarm targets per day
SEED = 42
rng = np.random.default_rng(SEED)
EEG1, EEG2 = list(range(0, 17)), list(range(17, 34))
ECG, MOV = list(range(34, 38)), list(range(38, 44))
K = 44
VARIANTS = {
    'app (eeg1+ecg+mov)': EEG1 + ECG + MOV, 'all (eeg2+ecg+mov)': EEG1 + EEG2 + ECG + MOV,
}
SMOOTH = int(__import__('os').environ.get('SMOOTH', '2'))     # decision on mean prob of last N epochs
MAX_NEG = int(__import__('os').environ.get('MAX_NEG', '12000'))


def kind(t):
    t = t.lower()
    if 'f2b' in t or 'bi' in t or 'tc' in t:
        return 'bilateral_tonic_clonic'
    if '_nm' in t:
        return 'non_motor'
    if '_m' in t:
        return 'motor'
    return 'unknown'


def build(X, run, base):
    med = np.nanmedian(X[base], 0) if base.sum() >= 30 else np.nanmedian(X, 0)
    sc = np.nanstd(X[base], 0) if base.sum() >= 30 else np.nanstd(X, 0)
    med = np.where(np.isfinite(med), med, 0.0); sc = np.where(np.isfinite(sc) & (sc > 1e-3), sc, 1.0)
    R = ((X - med) / sc).astype(np.float32)
    n = len(X)
    prev_mean = np.full((n, K), np.nan, np.float32); prev1 = np.full((n, K), np.nan, np.float32)
    max3 = np.full((n, K), np.nan, np.float32); max6 = np.full((n, K), np.nan, np.float32)
    mean3 = np.full((n, K), np.nan, np.float32)
    for r in np.unique(run):
        idx = np.flatnonzero(run == r); Y = R[idx]
        if len(Y) > 1:
            prev1[idx[1:]] = Y[:-1]
        if len(Y) >= 3:
            W3 = np.lib.stride_tricks.sliding_window_view(Y, 3, axis=0)
            max3[idx[2:]] = np.nanmax(W3, 2); mean3[idx[2:]] = np.nanmean(W3, 2)
        if len(Y) >= 6:
            max6[idx[5:]] = np.nanmax(np.lib.stride_tricks.sliding_window_view(Y, 6, axis=0), 2)
        if len(Y) > CTX:
            prev_mean[idx[CTX:]] = np.nanmean(np.lib.stride_tricks.sliding_window_view(Y[:-1], CTX, axis=0), 2)
    return np.concatenate([R, R - prev_mean, R - prev1, max3, mean3, max6], 1)


def cols(c):
    return [b * K + j for b in range(6) for j in c]


P = {}
for f in sorted(FEAT.glob('sub-*.npz')):
    z = np.load(f)
    X, lab, run = z['X'].astype(np.float32), z['lab'], z['run']
    if len({len(X), len(lab), len(run)}) != 1:
        continue
    starts = np.r_[0, np.flatnonzero(np.diff(run)) + 1]
    first = {int(run[s]): int(s) for s in starts}
    sz = []
    for ri, o, du, ty in json.loads(str(z['seizures'])):
        if ri not in first:
            continue
        a = first[ri] + int(o // EPOCH); b = first[ri] + int(np.ceil((o + du) / EPOCH))
        b = min(b, len(lab)); sz.append((a, max(b, a + 1), kind(ty)))
    if not sz:
        continue
    near = np.zeros(len(lab), bool); window = np.zeros(len(lab), bool)
    for a, b, _ in sz:
        near[max(a - NEG_GAP, 0):b + NEG_GAP] = True; window[max(a - 6, 0):b + 30] = True
    normal = np.flatnonzero(~near & (lab == 0))
    base = np.zeros(len(lab), bool); base[normal[:BASE_EPOCHS]] = True
    P[f.stem] = {'F': build(X, run, base), 'run': run, 'sz': sz, 'pos': lab == 1,
                 'neg': ~near & (lab == 0), 'excl': window | base}
pats = sorted(P)
print(len(pats), 'patients |', sum(len(P[p]['sz']) for p in pats), 'seizures', flush=True)
folds = [list(rng.permutation(pats))[i::5] for i in range(5)]
folds = [sorted(f) for f in folds]


def alarms(p, run, thr):
    # only above-threshold epochs are visited; a new alarm needs REFRACT quiet
    # epochs since the previous one in the same file
    on, last, last_run = [], -10 ** 9, None
    for j in np.flatnonzero(p >= thr):
        if run[j] != last_run or j - last > REFRACT:
            on.append(j); last = j; last_run = run[j]
    return np.array(on, int)


def smooth(p, run):
    if SMOOTH <= 1:
        return p
    out = p.copy()
    for r in np.unique(run):
        idx = np.flatnonzero(run == r)
        c = np.cumsum(np.r_[0, p[idx]])
        k = np.minimum(np.arange(1, len(idx) + 1), SMOOTH)
        out[idx] = (c[1:] - c[np.maximum(np.arange(1, len(idx) + 1) - SMOOTH, 0)]) / k
    return out


def events(p, d, thr):
    on = alarms(p, d['run'], thr)
    det = []
    for a, b, k in d['sz']:
        w = on[(on >= a) & (on < b + POST)]
        det.append((k, len(w) > 0, (w[0] - a) * EPOCH + EPOCH / 2 if len(w) else None))
    hours = (~d['excl']).sum() * EPOCH / 3600
    false = int((~d['excl'][on]).sum()) if len(on) else 0
    return det, false, hours


def train(pp, c, max_neg=None):
    max_neg = max_neg or MAX_NEG
    Xs, ys = [], []
    for p in pp:
        d = P[p]; pos = np.flatnonzero(d['pos']); neg = np.flatnonzero(d['neg'])
        neg = rng.choice(neg, size=min(len(neg), max_neg), replace=False) if len(neg) else neg
        Xs.append(d['F'][np.r_[pos, neg]][:, c]); ys.append(np.r_[np.ones(len(pos)), np.zeros(len(neg))])
    return HistGradientBoostingClassifier(max_depth=6, max_iter=500, learning_rate=0.05,
                                          l2_regularization=1.0, class_weight='balanced',
                                          random_state=SEED).fit(np.concatenate(Xs), np.concatenate(ys))


GRID = np.r_[np.arange(0.995, 0.9, -0.005), np.arange(0.9, 0.3, -0.02)]


def thresholds(m, val, c):
    probs = {p: smooth(m.predict_proba(P[p]['F'][:, c])[:, 1], P[p]['run']) for p in val}
    out = {}
    for t in FA_DAY:
        chosen = 0.999
        for thr in GRID:
            fa = hrs = 0.0
            for p in val:
                _, f_, h_ = events(probs[p], P[p], thr); fa += f_; hrs += h_
            if 24 * fa / max(hrs, 1e-9) <= t:
                chosen = float(thr)
            else:
                break
        out[t] = chosen
    return out


results = {}
for name, c0 in VARIANTS.items():
    c = cols(c0); t0 = time.time()
    agg = {t: {'det': [], 'false': 0, 'hours': 0.0} for t in FA_DAY}
    ys, ps = [], []
    for test in folds:
        tr = [p for p in pats if p not in test]; val = tr[::4]; fit = [p for p in tr if p not in val]
        thr = thresholds(train(fit, c), val, c)
        m = train(tr, c)
        for p in test:
            d = P[p]; prob = smooth(m.predict_proba(d['F'][:, c])[:, 1], d['run'])
            sel = d['pos'] | d['neg']; ys.append(d['pos'][sel]); ps.append(prob[sel])
            for t in FA_DAY:
                det, f_, h_ = events(prob, d, thr[t])
                agg[t]['det'] += det; agg[t]['false'] += f_; agg[t]['hours'] += h_
    auc = float(roc_auc_score(np.concatenate(ys), np.concatenate(ps)))
    ops = {}
    for t, a in agg.items():
        det = a['det']; by = {}
        for k in ('bilateral_tonic_clonic', 'motor', 'non_motor', 'unknown'):
            dk = [x for x in det if x[0] == k]
            if dk:
                by[k] = {'seizures': len(dk), 'sensitivity': round(sum(x[1] for x in dk) / len(dk), 3)}
        lat = [x[2] for x in det if x[1]]
        ops[str(t)] = {'sensitivity': round(sum(x[1] for x in det) / max(len(det), 1), 3),
                       'seizures': len(det), 'false_alarms_per_day': round(24 * a['false'] / max(a['hours'], 1e-9), 2),
                       'median_latency_s': float(np.median(lat)) if lat else None, 'by_type': by}
    results[name] = {'epoch_auc': round(auc, 3), 'operating_points': ops}
    print(f"{name:20s} AUC {auc:.3f} | " + " | ".join(
        f"<= {t}/day: sens {ops[str(t)]['sensitivity']:.2f} (FA {ops[str(t)]['false_alarms_per_day']}/day)"
        for t in FA_DAY) + f" ({time.time() - t0:.0f}s)", flush=True)
    for k, v in ops['4']['by_type'].items():
        print(f"    at <=4/day  {k:24s} {v['sensitivity']:.2f} of {v['seizures']}", flush=True)

(OUT / 'detector_report.json').write_text(json.dumps({
    'patients': len(pats), 'seizures': sum(len(P[p]['sz']) for p in pats), 'results': results,
    'notes': 'SeizeIT2 wearable, 10-s epochs, patient-disjoint 5-fold; thresholds from held-out training '
             'patients; detection between onset and end+60 s; false alarms outside onset-60 s..end+5 min.'},
    indent=1))
print('saved', OUT / 'detector_report.json')
