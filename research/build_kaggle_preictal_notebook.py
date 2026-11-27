"""Writes research/kaggle_train_preictal_chbmit.ipynb (run: python build_kaggle_preictal_notebook.py).

The notebook runs entirely on Kaggle (or Colab): it downloads real CHB-MIT
scalp EEG from PhysioNet, builds pre-ictal / inter-ictal / ictal windows with a
patient-wise split, trains CloudPreictalNet with the exact architecture the
backend and the phone load, evaluates it honestly (window + event level), and
exports the model, its meta file and a real pre-ictal library for the app's
virtual sensor.
"""
import json
from pathlib import Path

CELLS = []


def md(text):
    CELLS.append({"cell_type": "markdown", "metadata": {}, "source": text.strip("\n")})


def code(text):
    CELLS.append({"cell_type": "code", "metadata": {}, "execution_count": None,
                  "outputs": [], "source": text.strip("\n")})


md("""
# تدريب نموذج التنبؤ بالنوبة على بيانات CHB-MIT الحقيقية

**قبل التشغيل في Kaggle:** من القائمة الجانبية فعّل **Internet: On**، ويُفضّل **Accelerator: GPU T4**.
ثم اضغط **Run All**. يستغرق التنزيل والتدريب نحو 40–90 دقيقة حسب عدد المرضى.

في النهاية حمّل الملف `preictal_model_outputs.zip` من قسم **Output**، وانسخ محتوياته:
- `cloud_preictal_model.pt` و`cloud_preictal_model.meta.json` و`cloud_preictal_model.onnx` → إلى `backend/models/`
- `cloud_preictal_model.onnx` و`cloud_preictal_model.meta.json` → إلى `mobile/assets/models/`
- `seizure_library_chbmit.bin` و`seizure_library_chbmit.json` → إلى `mobile/assets/simulator/`
""")

code("""
!pip -q install mne==1.8.0 onnx onnxscript onnxruntime
import os, re, json, math, random, urllib.request, zipfile, time
from pathlib import Path
import numpy as np
import torch, torch.nn as nn
from scipy.signal import butter, sosfiltfilt
from sklearn.metrics import roc_auc_score
import mne
mne.set_log_level('ERROR')
SEED = 42
random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
DEV = 'cuda' if torch.cuda.is_available() else 'cpu'
print('device', DEV)
""")

md("## 1. الإعدادات")
code("""
BASE = 'https://physionet.org/files/chbmit/1.0.0/'
# Patients with several seizures and long recordings. Add more for a stronger model.
PATIENTS = ['chb01', 'chb02', 'chb03', 'chb05', 'chb08', 'chb10', 'chb18', 'chb20']
TEST_PATIENTS = ['chb18', 'chb20']        # never used for training or threshold choice
VAL_PATIENTS = ['chb10']                  # threshold is chosen here
SEIZURE_FREE_FILES_PER_PATIENT = 4        # inter-ictal recordings to download per patient
CHANNELS = ['F7-T7', 'T7-P7', 'FP1-F7']   # first one present in the file is used (single channel, like the app)
FS, WIN = 256, 262                        # app/model contract
PRE_START_MIN, PRE_END_MIN = 30, 5        # pre-ictal = 30..5 min before onset
INTER_GAP_MIN = 60                        # inter-ictal = at least 60 min from any seizure
DATA = Path('/kaggle/working/chbmit') if Path('/kaggle').exists() else Path('chbmit')
DATA.mkdir(parents=True, exist_ok=True)
""")

md("## 2. التنزيل من PhysioNet")
code("""
def fetch(url, dest):
    # Resumable download: PhysioNet drops long connections, so curl resumes
    # (-C -) and retries; the file is only accepted once complete.
    import subprocess
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    part = dest.with_suffix(dest.suffix + '.part')
    for attempt in range(8):
        r = subprocess.run(['curl', '-sSfL', '--retry', '5', '--retry-delay', '3',
                            '-C', '-', '-o', str(part), url])
        if r.returncode == 0:
            part.rename(dest)
            return dest
        print('retry', attempt + 1, url); time.sleep(5)
    raise RuntimeError(url)

def parse_summary(text):
    files, cur = {}, None
    for line in text.splitlines():
        m = re.match(r'File Name:\\s*(\\S+)', line)
        if m:
            cur = m.group(1); files[cur] = []
            continue
        m = re.match(r'Seizure\\s*\\d*\\s*Start Time:\\s*(\\d+)', line)
        if m and cur:
            files[cur].append([int(m.group(1)), None]); continue
        m = re.match(r'Seizure\\s*\\d*\\s*End Time:\\s*(\\d+)', line)
        if m and cur and files[cur]:
            files[cur][-1][1] = int(m.group(1))
    return files

plan = {}
for p in PATIENTS:
    (DATA / p).mkdir(exist_ok=True)
    s = fetch(f'{BASE}{p}/{p}-summary.txt', DATA / p / f'{p}-summary.txt').read_text(errors='ignore')
    files = parse_summary(s)
    with_seizures = [f for f, sz in files.items() if sz]
    free = [f for f, sz in files.items() if not sz]
    random.Random(SEED).shuffle(free)
    chosen = with_seizures + free[:SEIZURE_FREE_FILES_PER_PATIENT]
    plan[p] = {f: files[f] for f in chosen}
    for f in chosen:
        fetch(f'{BASE}{p}/{f}', DATA / p / f)
    print(p, 'seizure files', len(with_seizures), 'downloaded', len(chosen))
""")

md("## 3. استخراج المقاطع (ما قبل النوبة / بين النوبات / النوبة)")
code("""
SOS = butter(4, [0.5 / (FS / 2), 40 / (FS / 2)], btype='bandpass', output='sos')

def load_channel(path):
    raw = mne.io.read_raw_edf(path, preload=False, verbose='ERROR')
    names = [c.upper() for c in raw.ch_names]
    for want in CHANNELS:
        if want in names:
            idx = names.index(want)
            x = raw.get_data(picks=[idx])[0] * 1e6   # volts -> microvolts
            if int(raw.info['sfreq']) != FS:
                return None
            return x
    return None

def windows(x, start_s, end_s, stride):
    a, b = int(start_s * FS), int(end_s * FS)
    a, b = max(a, 0), min(b, len(x))
    return [x[i:i + WIN] for i in range(a, b - WIN, stride)]

rng = np.random.default_rng(SEED)
data = {p: {'pre': [], 'inter': [], 'ictal': []} for p in PATIENTS}
for p, files in plan.items():
    for f, seizures in files.items():
        x = load_channel(DATA / p / f)
        if x is None:
            print('skip (channel/fs)', f); continue
        dur = len(x) / FS
        if seizures:
            for s, e in seizures:
                data[p]['ictal'] += windows(x, s, e, WIN // 2)
                data[p]['pre'] += windows(x, s - PRE_START_MIN * 60, s - PRE_END_MIN * 60, WIN // 2)
            # inter-ictal inside seizure files: far from every seizure
            ok = np.ones(len(x), bool)
            for s, e in seizures:
                ok[max(0, int((s - INTER_GAP_MIN * 60) * FS)):int((e + INTER_GAP_MIN * 60) * FS)] = False
            for i in range(0, len(x) - WIN, WIN * 8):
                if ok[i:i + WIN].all():
                    data[p]['inter'].append(x[i:i + WIN])
        else:
            data[p]['inter'] += windows(x, 0, dur, WIN * 4)
    print(p, {k: len(v) for k, v in data[p].items()})
""")

md("## 4. أمثلة تشويش (ليست نوبة) + المعالجة")
code("""
def artefact(x, r):
    y = x.copy()
    kind = r.integers(4)
    if kind == 0:   # electrode pops
        for _ in range(r.integers(1, 5)):
            i = r.integers(0, WIN); y[i:i + 3] += r.choice([-1, 1]) * r.uniform(150, 400)
    elif kind == 1: # slow drift / sweat
        y += np.cumsum(r.normal(0, 6, WIN))
    elif kind == 2: # movement burst (broadband, high amplitude)
        a = r.integers(0, WIN - 60); y[a:a + 60] += r.normal(0, r.uniform(60, 200), 60)
    else:           # chewing / EMG-like high-frequency noise
        y += r.normal(0, r.uniform(20, 60), WIN) * np.sin(np.linspace(0, 40 * np.pi, WIN))
    return y

def prep(x):
    z = sosfiltfilt(SOS, np.asarray(x, np.float64))
    return ((z - z.mean()) / (z.std() + 1e-8)).astype(np.float32)

def build(patients, augment):
    X, y = [], []
    for p in patients:
        for w in data[p]['pre']:
            X.append(prep(w)); y.append(1)
        inter = data[p]['inter']
        for w in inter:
            X.append(prep(w)); y.append(0)
        if augment:   # artefacts are NOT pre-ictal
            for w in rng.choice(len(inter), size=min(len(inter), len(data[p]['pre'])), replace=False):
                X.append(prep(artefact(inter[w], rng))); y.append(0)
    X, y = np.stack(X)[:, None, :], np.array(y)
    return X, y

train_p = [p for p in PATIENTS if p not in TEST_PATIENTS + VAL_PATIENTS]
Xtr, ytr = build(train_p, True)
Xva, yva = build(VAL_PATIENTS, True)
Xte, yte = build(TEST_PATIENTS, True)
print('train', Xtr.shape, ytr.mean().round(3), '| val', Xva.shape, '| test', Xte.shape)
""")

md("## 5. النموذج (نفس البنية التي يحمّلها الخادم والهاتف)")
code("""
class CloudPreictalNet(nn.Module):
    def __init__(self, in_ch=1, n_classes=2, hidden_dim=64, num_heads=4):
        super().__init__()
        self.c1 = nn.Conv1d(in_ch, 24, kernel_size=3, padding=1)
        self.c2 = nn.Conv1d(in_ch, 24, kernel_size=5, padding=2)
        self.c3 = nn.Conv1d(in_ch, 24, kernel_size=7, padding=3)
        self.bn = nn.BatchNorm1d(72)
        self.relu = nn.ReLU()
        self.pool = nn.MaxPool1d(2)
        self.attn = nn.MultiheadAttention(embed_dim=72, num_heads=num_heads, batch_first=True)
        self.lstm = nn.LSTM(72, hidden_dim, batch_first=True, bidirectional=True)
        self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(hidden_dim * 2, 64), nn.ReLU(),
                                  nn.Dropout(0.3), nn.Linear(64, n_classes))
    def forward(self, x):
        z = torch.cat([self.c1(x), self.c2(x), self.c3(x)], dim=1)
        z = self.pool(self.relu(self.bn(z)))
        z_t = z.transpose(1, 2)
        a, _ = self.attn(z_t, z_t, z_t)
        o, _ = self.lstm(a)
        return self.head(o.mean(dim=1))

def probs(model, X, bs=512):
    model.eval(); out = []
    with torch.no_grad():
        for i in range(0, len(X), bs):
            out.append(torch.softmax(model(torch.from_numpy(X[i:i + bs]).to(DEV)), 1)[:, 1].cpu().numpy())
    return np.concatenate(out)

model = CloudPreictalNet().to(DEV)
w = torch.tensor([1.0, (ytr == 0).sum() / max((ytr == 1).sum(), 1)], dtype=torch.float32, device=DEV)
lossf = nn.CrossEntropyLoss(weight=w / w.mean())
opt = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-3)
best, best_state, patience = -1, None, 0
Xt, yt = torch.from_numpy(Xtr), torch.from_numpy(ytr)
for epoch in range(25):
    model.train(); perm = torch.randperm(len(Xt))
    for i in range(0, len(perm), 256):
        idx = perm[i:i + 256]
        xb = Xt[idx].to(DEV); yb = yt[idx].to(DEV)
        xb = xb * (1 + 0.1 * torch.randn(len(xb), 1, 1, device=DEV))   # amplitude jitter
        opt.zero_grad(); loss = lossf(model(xb), yb); loss.backward(); opt.step()
    auc = roc_auc_score(yva, probs(model, Xva))
    print(f'epoch {epoch} val AUC {auc:.3f}')
    if auc > best:
        best, best_state, patience = auc, {k: v.cpu().clone() for k, v in model.state_dict().items()}, 0
    else:
        patience += 1
        if patience >= 5: break
model.load_state_dict(best_state)
""")

md("## 6. التقييم الصادق (مرضى لم يُدرَّب عليهم)")
code("""
pva, pte = probs(model, Xva), probs(model, Xte)
# Threshold chosen on VALIDATION patients only: highest that keeps >= 95% specificity.
cands = np.linspace(0.3, 0.95, 66)
spec = [((pva[yva == 0] < t).mean(), t) for t in cands]
THR = float(min((t for s, t in spec if s >= 0.95), default=0.8))
def window_metrics(p, y, t):
    pred = p >= t
    return dict(auc=round(float(roc_auc_score(y, p)), 3),
                sensitivity=round(float(pred[y == 1].mean()), 3),
                specificity=round(float((~pred[y == 0]).mean()), 3))
test_w = window_metrics(pte, yte, THR)
print('threshold', THR, 'val', window_metrics(pva, yva, THR), 'TEST', test_w)

# Event level with the app's rule: early warning when 3 of the last 5 windows are above threshold.
def sustained(p, k=3, n=5):
    h, out = [], []
    for v in p:
        h.append(v >= THR); h = h[-n:]; out.append(sum(h) >= k)
    return np.array(out)
events = {'seizures': 0, 'warned': 0, 'false_warnings_per_hour': None}
inter_seconds, false_onsets = 0, 0
for p in TEST_PATIENTS:
    pre = data[p]['pre']
    # pre-ictal windows of each seizure are contiguous in extraction order (step = WIN/2)
    per_seizure = max(1, int((PRE_START_MIN - PRE_END_MIN) * 60 * FS / (WIN // 2)))
    for s in range(0, len(pre), per_seizure):
        chunk = np.stack([prep(w) for w in pre[s:s + per_seizure]])[:, None, :]
        if len(chunk) < 5: continue
        events['seizures'] += 1
        events['warned'] += bool(sustained(probs(model, chunk)).any())
    inter = np.stack([prep(w) for w in data[p]['inter']])[:, None, :]
    alarm = sustained(probs(model, inter))
    false_onsets += int(np.sum(alarm[1:] & ~alarm[:-1]) + alarm[0])
    inter_seconds += len(inter) * WIN / FS
events['false_warnings_per_hour'] = round(false_onsets / max(inter_seconds / 3600, 1e-9), 2)
print('TEST events', events)
""")

md("## 7. التصدير (الخادم + الهاتف)")
code("""
OUT = Path('/kaggle/working/outputs') if Path('/kaggle').exists() else Path('outputs')
OUT.mkdir(parents=True, exist_ok=True)
model.cpu().eval()
torch.save(model.state_dict(), OUT / 'cloud_preictal_model.pt')
ONNX_ARGS = dict(input_names=['eeg_window'], output_names=['preictal_logits'],
                 dynamic_axes={'eeg_window': {0: 'batch'}, 'preictal_logits': {0: 'batch'}},
                 opset_version=17)
try:   # classic exporter (the new dynamo one fails on this attention model)
    torch.onnx.export(model, torch.zeros(1, 1, WIN), OUT / 'cloud_preictal_model.onnx',
                      dynamo=False, **ONNX_ARGS)
except TypeError:   # older torch without the `dynamo` argument
    torch.onnx.export(model, torch.zeros(1, 1, WIN), OUT / 'cloud_preictal_model.onnx', **ONNX_ARGS)
import onnxruntime as ort   # verify the export matches PyTorch
_s = ort.InferenceSession(str(OUT / 'cloud_preictal_model.onnx'), providers=['CPUExecutionProvider'])
_x = Xte[:8]
assert np.abs(_s.run(None, {'eeg_window': _x})[0] - model(torch.from_numpy(_x)).detach().numpy()).max() < 1e-3
meta = {
    'arch': 'CloudPreictalNet', 'in_ch': 1, 'n_classes': 2, 'hidden_dim': 64, 'num_heads': 4,
    'input_len': WIN, 'fs': FS, 'channel': 'eeg',
    'task': 'prediction(preictal_vs_interictal)',
    'dataset': 'CHB-MIT scalp EEG (PhysioNet), single channel ' + '/'.join(CHANNELS),
    'train_patients': train_p, 'val_patients': VAL_PATIENTS, 'test_patients': TEST_PATIENTS,
    'preictal_min': PRE_START_MIN, 'safety_gap_min': PRE_END_MIN, 'horizon_min': float(PRE_START_MIN),
    'decision_threshold': round(THR, 3),
    'test_window_metrics': test_w,
    'test_event_metrics_3_of_5': events,
    'artefact_negatives': True,
    'notes': 'Patient-wise split; threshold chosen on validation patients for >=95% specificity. '
             'Research model, not clinically validated.',
}
(OUT / 'cloud_preictal_model.meta.json').write_text(json.dumps(meta, indent=2))
print(json.dumps(meta, indent=1))
""")

md("## 8. مكتبة مقاطع حقيقية للحساس الافتراضي (من مرضى الاختبار فقط)")
code("""
# Same binary format as the app's Bonn library. Units scaled so that inter-ictal
# activity has the same spread as the Bonn calm baseline (~0.28 app units).
inter_all = np.concatenate([np.stack(data[p]['inter']) for p in TEST_PATIENTS])
scale = 0.28 / (inter_all - inter_all.mean(1, keepdims=True)).std()
blobs, cats, off = [], {}, 0
for name, key in (('preictal', 'pre'), ('interictal_chbmit', 'inter'), ('ictal_chbmit', 'ictal')):
    arr = np.concatenate([np.stack(data[p][key]) for p in TEST_PATIENTS if data[p][key]])
    idx = rng.choice(len(arr), size=min(400, len(arr)), replace=False)
    w = arr[idx] - arr[idx].mean(1, keepdims=True)
    q = np.round(np.clip(w * scale, -32, 32) * 1000).astype('<i2')
    blobs.append(q.reshape(-1)); cats[name] = {'offset': off, 'count': int(len(idx))}; off += len(idx)
np.concatenate(blobs).tofile(OUT / 'seizure_library_chbmit.bin')
(OUT / 'seizure_library_chbmit.json').write_text(json.dumps({
    'version': 1, 'window': WIN, 'fs': FS, 'scale': 1000,
    'units': 'normalized_demo (CHB-MIT uV scaled to the Bonn calm spread)',
    'source': 'CHB-MIT test patients ' + ','.join(TEST_PATIENTS) + ' (never used in training)',
    'categories': cats}, indent=2))
with zipfile.ZipFile('/kaggle/working/preictal_model_outputs.zip' if Path('/kaggle').exists()
                     else 'preictal_model_outputs.zip', 'w') as z:
    for f in OUT.iterdir():
        z.write(f, f.name)
print('done:', [f.name for f in OUT.iterdir()])
""")

nb = {"cells": CELLS, "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"},
                                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 5}
out = Path(__file__).resolve().parent / "kaggle_train_preictal_chbmit.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("wrote", out)
