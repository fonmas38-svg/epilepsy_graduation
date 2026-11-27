"""Builds research/colab_train_preictal_trend.ipynb.

Why a second notebook: the first one (kaggle_train_preictal_chbmit.ipynb)
asked a 1-second window whether a seizure comes in the next 30 minutes. Two
Colab runs gave test AUC ~0.70 and 125-145 false warnings per hour: pre-ictal
change is slow and is not visible in one second. This notebook trains on the
TREND of the EEG over minutes instead, with all CHB-MIT patients:

  1 s window (262 samples, the app's packet) -> 12 scale-free features
  last 120 windows (2 min)                   -> small GRU -> pre-ictal probability

The features only need the app's existing 262-sample packets, so the phone
and the backend can compute them later without a new sensor contract.
Run:  python research/build_preictal_trend_notebook.py
"""
import json
from pathlib import Path

CELLS = []


def md(text):
    CELLS.append({"cell_type": "markdown", "metadata": {}, "source": text.strip("\n")})


def code(text):
    CELLS.append({"cell_type": "code", "metadata": {}, "execution_count": None,
                  "outputs": [], "source": text.strip("\n")})


md(r"""
# نموذج التنبؤ بالنوبة من «اتجاه» الإشارة عبر الدقائق (CHB-MIT كامل)

**لماذا هذا الدفتر؟** الدفتر السابق كان يحكم من ثانية واحدة فقط، فكانت النتيجة ضعيفة
(AUC ≈ 0.70 وأكثر من 120 إنذارًا كاذبًا في الساعة). علامات ما قبل النوبة تغيّرات بطيئة،
لذلك هذا الدفتر:
- يحسب 12 خاصية لكل ثانية (توزيع الترددات، الشدة، التعقيد...).
- ينظر إلى آخر **دقيقتين** معًا ويتعلّم اتجاه التغيّر.
- يستخدم **كل مرضى CHB-MIT** (حتى 24 مريضًا) بدل 8.
- يقيس النتيجة كما في الواقع: نسبة النوبات التي سبقها إنذار، و**عدد الإنذارات الكاذبة في الساعة**.

**التشغيل في Google Colab:**
1. **Runtime → Change runtime type → T4 GPU** ثم **Save**.
2. **Runtime → Run all** ثم اسمح بالوصول إلى **Google Drive**.
3. يحفظ كل شيء في `MyDrive/epilepsy_preictal/` (نفس مجلد الدفتر السابق، فيعيد استخدام الملفات المنزّلة).
4. يحذف ملف EEG الكبير بعد استخراج خصائصه حتى لا تمتلئ مساحة Drive (15GB).
5. **إذا انقطعت الجلسة:** شغّل **Run all** مرة أخرى؛ يكمل من حيث توقف.
6. النتيجة: `MyDrive/epilepsy_preictal/preictal_trend_outputs.zip` — أرسلها كما هي.

التنزيل والاستخراج لكل المرضى يأخذ عدة ساعات؛ يمكن تكراره على جلسات متعددة.
""")

code(r"""
!pip -q install mne==1.8.0 onnx onnxscript onnxruntime
import os, re, json, random, time, zipfile, subprocess
from pathlib import Path
import numpy as np
import torch, torch.nn as nn
from scipy.signal import butter, sosfiltfilt
from scipy.stats import skew, kurtosis
from sklearn.metrics import roc_auc_score
import mne
mne.set_log_level('ERROR')
SEED = 42
random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
DEV = 'cuda' if torch.cuda.is_available() else 'cpu'
print('device', DEV)
try:
    from google.colab import drive
    drive.mount('/content/drive')
    WORK = Path('/content/drive/MyDrive/epilepsy_preictal')
except ImportError:
    WORK = Path('/kaggle/working') if Path('/kaggle').exists() else Path('work')
WORK.mkdir(parents=True, exist_ok=True)
print('saving everything to', WORK)
""")

md("## 1. الإعدادات")
code(r"""
BASE = 'https://physionet.org/files/chbmit/1.0.0/'
PATIENTS = [f'chb{i:02d}' for i in range(1, 25)]
TEST_PATIENTS = ['chb18', 'chb20', 'chb22', 'chb23']   # never used for training or threshold
VAL_PATIENTS = ['chb10', 'chb14']                       # threshold is chosen here
SEIZURE_FREE_FILES_PER_PATIENT = 4
CHANNELS = ['F7-T7', 'T7-P7', 'FP1-F7']   # single channel, like the app
FS, WIN, STEP = 256, 262, 256             # app packet: 262 samples; one feature row per second
SEQ = 120                                  # 2 minutes of history per prediction
EVAL_EVERY = 30                            # the app re-evaluates every 30 s
PRE_START_MIN, PRE_END_MIN = 30, 5         # pre-ictal = 30..5 min before onset
INTER_GAP_MIN = 60                         # inter-ictal = >= 60 min from any seizure
REFRACTORY_MIN = 30                        # after a warning, no new warning for 30 min
TARGET_FALSE_PER_HOUR = 0.5                # threshold goal on validation patients
DELETE_EDF_AFTER_EXTRACT = True            # keeps Google Drive under its free 15GB
DATA = WORK / 'chbmit'; DATA.mkdir(parents=True, exist_ok=True)
CACHE = WORK / 'features_v2'; CACHE.mkdir(exist_ok=True)
CKPT = WORK / 'trend_checkpoint.pt'
OUT = WORK / 'trend_outputs'; OUT.mkdir(exist_ok=True)
""")

md("## 2. الخصائص (نفس الحساب الذي سيجريه الهاتف والخادم)")
code(r"""
SOS = butter(4, [0.5 / (FS / 2), 40 / (FS / 2)], btype='bandpass', output='sos')
FREQS = np.fft.rfftfreq(WIN, 1 / FS)
HANN = np.hanning(WIN)
BANDS = [(0.5, 4), (4, 8), (8, 13), (13, 30), (30, 40)]
FEATURES = ['rel_delta', 'rel_theta', 'rel_alpha', 'rel_beta', 'rel_gamma', 'sef90',
            'log_power', 'line_length', 'hjorth_mobility', 'hjorth_complexity',
            'skewness', 'kurtosis']

def features(W):
    # W: (n, 262) raw windows in any amplitude unit -> (n, 12). Scale-free except
    # log_power, which is made relative to its own 2-minute sequence later.
    z = sosfiltfilt(SOS, np.asarray(W, np.float64), axis=1)
    P = np.abs(np.fft.rfft(z * HANN, axis=1)) ** 2
    band = (FREQS >= 0.5) & (FREQS < 40)
    tot = P[:, band].sum(1) + 1e-12
    rel = [P[:, (FREQS >= a) & (FREQS < b)].sum(1) / tot for a, b in BANDS]
    cum = np.cumsum(P * band, 1) / tot[:, None]
    sef = FREQS[np.argmax(cum >= 0.9, axis=1)] / 40.0
    sd = z.std(1) + 1e-8
    d1, d2 = np.diff(z, axis=1), np.diff(z, 2, axis=1)
    mob = d1.std(1) / sd
    comp = (d2.std(1) / (d1.std(1) + 1e-8)) / (mob + 1e-8)
    ll = np.abs(d1).mean(1) / sd
    F = np.stack(rel + [sef, np.log(z.var(1) + 1e-12), ll, mob, comp,
                        skew(z, axis=1), np.clip(kurtosis(z, axis=1), -5, 50)], 1)
    return F.astype(np.float32)

def seq_normalize(S):
    # S: (..., SEQ, 12). Amplitude differs between devices/units: keep only how
    # power changes inside the 2 minutes.
    S = S.copy()
    S[..., 6] -= np.median(S[..., 6], axis=-1, keepdims=True)
    return S
print(len(FEATURES), 'features')
""")

md("## 3. التنزيل والاستخراج (يكمل بعد الانقطاع، ويحذف ملفات EDF بعد استخراجها)")
code(r"""
def fetch(url, dest):
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    part = dest.with_suffix(dest.suffix + '.part')
    for attempt in range(8):
        r = subprocess.run(['curl', '-sSfL', '--retry', '5', '--retry-delay', '3',
                            '-C', '-', '-o', str(part), url])
        if r.returncode == 0:
            part.rename(dest); return dest
        print('retry', attempt + 1, url); time.sleep(5)
    raise RuntimeError(url)

def parse_summary(text):
    files, cur = {}, None
    for line in text.splitlines():
        m = re.match(r'File Name:\s*(\S+)', line)
        if m:
            cur = m.group(1); files[cur] = []; continue
        m = re.match(r'Seizure\s*\d*\s*Start Time:\s*(\d+)', line)
        if m and cur:
            files[cur].append([int(m.group(1)), None]); continue
        m = re.match(r'Seizure\s*\d*\s*End Time:\s*(\d+)', line)
        if m and cur and files[cur]:
            files[cur][-1][1] = int(m.group(1))
    return files

def load_channel(path):
    raw = mne.io.read_raw_edf(path, preload=False, verbose='ERROR')
    if int(raw.info['sfreq']) != FS:
        return None
    names = [c.upper() for c in raw.ch_names]
    for want in CHANNELS:
        if want in names:
            return raw.get_data(picks=[names.index(want)])[0] * 1e6
    return None

def feat_segment(x, a_s, b_s):
    a, b = max(int(a_s * FS), 0), min(int(b_s * FS), len(x))
    idx = np.arange(a, b - WIN, STEP)
    if len(idx) == 0:
        return None
    return features(np.stack([x[i:i + WIN] for i in idx]))

def extract(p):
    cached = CACHE / f'{p}.npz'
    if cached.exists():
        return
    (DATA / p).mkdir(exist_ok=True)
    try:
        s = fetch(f'{BASE}{p}/{p}-summary.txt', DATA / p / f'{p}-summary.txt').read_text(errors='ignore')
    except RuntimeError:
        print(p, 'no summary, skipped'); return
    files = parse_summary(s)
    seiz = [f for f, sz in files.items() if sz]
    free = [f for f, sz in files.items() if not sz]
    random.Random(SEED).shuffle(free)
    pre, inter, n_seizures = [], [], 0
    for f in seiz + free[:SEIZURE_FREE_FILES_PER_PATIENT]:
        path = fetch(f'{BASE}{p}/{f}', DATA / p / f)
        x = load_channel(path)
        if x is not None:
            sz = files[f]
            for s0, e0 in sz:
                n_seizures += 1
                seg = feat_segment(x, s0 - PRE_START_MIN * 60, s0 - PRE_END_MIN * 60)
                if seg is not None and len(seg) >= SEQ:
                    pre.append(seg)
            ok = np.ones(len(x), bool)
            for s0, e0 in sz:
                ok[max(0, int((s0 - INTER_GAP_MIN * 60) * FS)):int((e0 + INTER_GAP_MIN * 60) * FS)] = False
            # contiguous inter-ictal runs
            edges = np.flatnonzero(np.diff(np.r_[0, ok.astype(np.int8), 0]))
            for a, b in zip(edges[::2], edges[1::2]):
                seg = feat_segment(x, a / FS, b / FS)
                if seg is not None and len(seg) >= SEQ:
                    inter.append(seg)
        if DELETE_EDF_AFTER_EXTRACT:
            path.unlink(missing_ok=True)
    np.savez_compressed(cached, pre=np.array(pre, dtype=object),
                        inter=np.array(inter, dtype=object), n_seizures=n_seizures)
    print(p, 'pre segments', len(pre), 'inter hours',
          round(sum(len(s) for s in inter) / 3600, 1))

for p in PATIENTS:
    extract(p)

data = {}
for p in PATIENTS:
    f = CACHE / f'{p}.npz'
    if f.exists():
        z = np.load(f, allow_pickle=True)
        # equal-length segments are saved as one object array: force float32
        data[p] = {k: [np.asarray(s, np.float32) for s in z[k]] for k in ('pre', 'inter')}
print('patients ready', len(data))
""")

md("## 4. بناء التسلسلات (دقيقتان لكل عيّنة)")
code(r"""
def sequences(segments, stride):
    out = []
    for seg in segments:
        for end in range(SEQ, len(seg) + 1, stride):
            out.append(np.asarray(seg[end - SEQ:end], np.float32))
    return np.stack(out) if out else np.zeros((0, SEQ, len(FEATURES)), np.float32)

def build(patients, stride_pre=10, stride_inter=60):
    X, y = [], []
    for p in patients:
        if p not in data: continue
        a = sequences(data[p]['pre'], stride_pre); b = sequences(data[p]['inter'], stride_inter)
        X += [a, b]; y += [np.ones(len(a)), np.zeros(len(b))]
    return seq_normalize(np.concatenate(X).astype(np.float32)), np.concatenate(y).astype(np.int64)

train_p = [p for p in data if p not in TEST_PATIENTS + VAL_PATIENTS]
Xtr, ytr = build(train_p)
MU = Xtr.reshape(-1, Xtr.shape[-1]).mean(0); SD = Xtr.reshape(-1, Xtr.shape[-1]).std(0) + 1e-6
norm = lambda X: ((X - MU) / SD).astype(np.float32)
Xtr = norm(Xtr)
Xva, yva = build(VAL_PATIENTS, 30, 30); Xva = norm(Xva)
print('train', Xtr.shape, 'pre ratio', ytr.mean().round(3), '| val', Xva.shape, '| train patients', train_p)
""")

md("## 5. النموذج والتدريب (يكمل بعد الانقطاع)")
code(r"""
class PreictalTrendNet(nn.Module):
    def __init__(self, n_feat=12, hidden=64):
        super().__init__()
        self.inp = nn.Sequential(nn.Linear(n_feat, hidden), nn.GELU())
        self.conv = nn.Conv1d(hidden, hidden, 5, padding=2)
        self.gru = nn.GRU(hidden, hidden, num_layers=2, batch_first=True, dropout=0.2)
        self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(hidden * 2, 2))
    def forward(self, x):                 # x: (batch, 120, 12)
        h = self.inp(x)
        h = h + torch.relu(self.conv(h.transpose(1, 2))).transpose(1, 2)
        o, _ = self.gru(h)
        return self.head(torch.cat([o[:, -1], o.mean(1)], 1))

def probs(model, X, bs=1024):
    model.eval(); out = []
    with torch.no_grad():
        for i in range(0, len(X), bs):
            out.append(torch.softmax(model(torch.from_numpy(X[i:i + bs]).to(DEV)), 1)[:, 1].cpu().numpy())
    return np.concatenate(out) if out else np.zeros(0)

model = PreictalTrendNet().to(DEV)
w = torch.tensor([1.0, (ytr == 0).sum() / max((ytr == 1).sum(), 1)], dtype=torch.float32, device=DEV)
lossf = nn.CrossEntropyLoss(weight=w / w.mean())
opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-2)
best, best_state, patience, start = -1, None, 0, 0
if CKPT.exists():
    ck = torch.load(CKPT, map_location=DEV, weights_only=False)
    model.load_state_dict(ck['model']); opt.load_state_dict(ck['opt'])
    best, best_state, patience, start = ck['best'], ck['best_state'], ck['patience'], ck['epoch'] + 1
    print('resuming from epoch', start, 'best val AUC', round(best, 3))
Xt, yt = torch.from_numpy(Xtr), torch.from_numpy(ytr)
for epoch in range(start, 40):
    if patience >= 6: break
    model.train(); perm = torch.randperm(len(Xt))
    for i in range(0, len(perm), 256):
        idx = perm[i:i + 256]
        xb = Xt[idx].to(DEV); yb = yt[idx].to(DEV)
        xb = xb + 0.05 * torch.randn_like(xb)
        opt.zero_grad(); loss = lossf(model(xb), yb); loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0); opt.step()
    auc = roc_auc_score(yva, probs(model, Xva))
    print(f'epoch {epoch} val AUC {auc:.3f}')
    if auc > best:
        best, best_state, patience = auc, {k: v.cpu().clone() for k, v in model.state_dict().items()}, 0
    else:
        patience += 1
    torch.save({'model': model.state_dict(), 'opt': opt.state_dict(), 'best': best,
                'best_state': best_state, 'patience': patience, 'epoch': epoch}, CKPT)
model.load_state_dict(best_state)
""")

md("## 6. التقييم الواقعي: إنذار لكل نوبة؟ وكم إنذارًا كاذبًا في الساعة؟")
code(r"""
REFRACT = REFRACTORY_MIN * 60 // EVAL_EVERY

def alarm_onsets(p, thr, k=3, n=5):
    # app rule: warning when 3 of the last 5 evaluations are above threshold;
    # then quiet for REFRACTORY_MIN minutes.
    hist, quiet, onsets = [], 0, []
    for i, v in enumerate(p):
        hist = (hist + [v >= thr])[-n:]
        if quiet > 0:
            quiet -= 1; continue
        if sum(hist) >= k:
            onsets.append(i); quiet = REFRACT; hist = []
    return onsets

def segment_probs(segs):
    return [probs(model, norm(seq_normalize(sequences([s], EVAL_EVERY)))) for s in segs]

def events(patients, thr, cache={}):
    warned = seizures = false = 0; hours = 0.0
    for p in patients:
        if p not in data: continue
        key = (p, id(model))
        if key not in cache:
            cache[key] = (segment_probs(data[p]['pre']), segment_probs(data[p]['inter']))
        pre, inter = cache[key]
        for pp in pre:
            seizures += 1; warned += bool(alarm_onsets(pp, thr))
        for ip, seg in zip(inter, data[p]['inter']):
            false += len(alarm_onsets(ip, thr)); hours += len(seg) / 3600
    return dict(seizures=seizures, warned=warned,
                sensitivity=round(warned / max(seizures, 1), 3),
                false_warnings_per_hour=round(false / max(hours, 1e-9), 3),
                interictal_hours=round(hours, 1))

# Threshold from VALIDATION patients only: the lowest (most sensitive) one that
# keeps false warnings under the target.
cands = np.round(np.arange(0.30, 0.99, 0.01), 2)
val = [(t, events(VAL_PATIENTS, t)) for t in cands]
ok = [(t, e) for t, e in val if e['false_warnings_per_hour'] <= TARGET_FALSE_PER_HOUR]
THR, val_ev = ok[0] if ok else val[-1]
Xte, yte = build(TEST_PATIENTS, 30, 30); Xte = norm(Xte)
test_auc = round(float(roc_auc_score(yte, probs(model, Xte))), 3)
test_ev = events(TEST_PATIENTS, THR)
chance = round(min(1.0, (PRE_START_MIN - PRE_END_MIN) / 60 * test_ev['false_warnings_per_hour']
                   * (REFRACTORY_MIN / 60 + 1)), 3)
print('threshold', THR, '\nVAL', val_ev, '\nTEST AUC', test_auc, '\nTEST', test_ev,
      '\nrandom alarm with the same rate would catch about', chance)
""")

md("## 7. التصدير (ONNX للهاتف والخادم)")
code(r"""
model.cpu().eval(); DEV = 'cpu'
torch.save(model.state_dict(), OUT / 'preictal_trend_model.pt')
torch.onnx.export(model, torch.zeros(1, SEQ, len(FEATURES)), OUT / 'preictal_trend_model.onnx',
                  input_names=['feature_seq'], output_names=['preictal_logits'],
                  dynamic_axes={'feature_seq': {0: 'batch'}, 'preictal_logits': {0: 'batch'}},
                  opset_version=17, dynamo=False)
import onnxruntime as ort
_s = ort.InferenceSession(str(OUT / 'preictal_trend_model.onnx'), providers=['CPUExecutionProvider'])
_x = Xte[:8]
assert np.abs(_s.run(None, {'feature_seq': _x})[0] - model(torch.from_numpy(_x)).detach().numpy()).max() < 1e-3
# Reference vectors so the Dart/Python feature code can be checked against this one.
ref_w = np.random.default_rng(1).normal(0, 30, (3, WIN))
meta = {
    'arch': 'PreictalTrendNet', 'input': 'feature_seq', 'seq_len': SEQ, 'features': FEATURES,
    'window': WIN, 'step_samples': STEP, 'fs': FS, 'bandpass_hz': [0.5, 40],
    'eval_every_s': EVAL_EVERY, 'feature_mean': MU.round(6).tolist(), 'feature_std': SD.round(6).tolist(),
    'seq_normalize': 'log_power minus its median over the sequence, then (x-mean)/std',
    'decision_threshold': float(THR), 'alarm_rule': '3 of last 5 evaluations', 'refractory_min': REFRACTORY_MIN,
    'preictal_min': PRE_START_MIN, 'safety_gap_min': PRE_END_MIN,
    'dataset': 'CHB-MIT scalp EEG, single channel ' + '/'.join(CHANNELS),
    'train_patients': train_p, 'val_patients': VAL_PATIENTS, 'test_patients': TEST_PATIENTS,
    'val_events': val_ev, 'test_auc': test_auc, 'test_events': test_ev,
    'random_predictor_sensitivity_same_alarm_rate': chance,
    'reference': {'windows': ref_w.round(4).tolist(), 'features': features(ref_w).round(5).tolist()},
    'notes': 'Patient-wise split; threshold from validation patients for <= '
             f'{TARGET_FALSE_PER_HOUR} false warnings/hour. Research model, not clinically validated.',
}
(OUT / 'preictal_trend_model.meta.json').write_text(json.dumps(meta, indent=1))
ZIP = WORK / 'preictal_trend_outputs.zip'
with zipfile.ZipFile(ZIP, 'w') as z:
    for f in OUT.iterdir():
        z.write(f, f.name)
print({k: meta[k] for k in ('decision_threshold', 'val_events', 'test_auc', 'test_events',
                            'random_predictor_sensitivity_same_alarm_rate')})
try:
    from google.colab import files
    files.download(str(ZIP))
except Exception:
    pass
print('Results saved to', ZIP)
""")

nb = {"cells": CELLS, "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"},
                                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 5}
out = Path(__file__).resolve().parent / "colab_train_preictal_trend.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("wrote", out)
