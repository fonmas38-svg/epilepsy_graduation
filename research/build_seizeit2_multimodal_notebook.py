"""Builds research/colab_seizeit2_multimodal.ipynb.

Tests the idea: train on the CHANGE of brain + heart + movement signals
relative to each patient's own normal state, using many earlier patients and
rules from the literature. Data: SeizeIT2 (OpenNeuro ds005873, CC0): 125
patients with wearable behind-the-ear EEG (256 Hz), chest ECG (256 Hz) and
movement (25 Hz), the same sensor set as the app.

Compared, all patient-disjoint (5-fold by patient):
  modalities  : eeg / ecg / mov / all
  scaling     : absolute vs relative-to-own-baseline (first 2 h of normal data)
  rules       : relative + monotonic research rules (HR up, HRV down -> risk up)
Optional: the app's own seizure DETECTOR (edge_seizure_model.onnx) is checked on
real wearable seizures if that file is placed in the Drive folder.
Run:  python research/build_seizeit2_multimodal_notebook.py
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
# تجربة الإشارات الثلاث (الدماغ + القلب + الحركة) على بيانات SeizeIT2

**الفكرة المختبَرة:** تدريب النموذج على **مقدار تغيّر** إشارات الدماغ والقلب والحركة عن حالة المريض الطبيعية،
باستخدام بيانات 125 مريضًا سابقًا وقواعد من الأبحاث — ثم قياس عدد المرضى الذين يتفوّق فيهم التنبؤ على الصدفة.

**البيانات:** SeizeIT2 (رخصة CC0، بلا تسجيل): EEG خلف الأذن + تخطيط قلب + حركة، من أجهزة قابلة للارتداء — نفس حساسات تطبيقنا.

**التشغيل في Colab:**
1. **لا يحتاج GPU:** Runtime → Change runtime type → **CPU**.
2. *(اختياري لاختبار كاشف النوبات الحقيقي للتطبيق)* ارفع الملف `mobile/assets/models/edge_seizure_model.onnx`
   إلى مجلد Drive: `MyDrive/epilepsy_preictal/` **قبل** التشغيل.
3. **Runtime → Run all** واسمح بالوصول إلى Google Drive.
4. **المدة:** التنزيل والاستخراج لـ125 مريضًا قد يأخذ 3–6 ساعات (حوالي 100GB تُنزَّل مريضًا مريضًا وتُحذف فورًا).
   إن انقطعت الجلسة شغّل **Run all** مرة أخرى؛ يكمل من المريض الذي توقف عنده. يمكن تقسيمه على عدة أيام.
5. **النتيجة:** في أعلى **ملفاتي** في Drive باسم `seizeit2_multimodal_outputs.zip`.

### المشاكل المتوقعة وحلولها
| المشكلة المتوقعة | الحل في الدفتر |
|---|---|
| انقطاع التنزيل من خوادم OpenNeuro | تنزيل قابل للاستكمال مع إعادة المحاولة؛ مريض فاشل يُسجَّل ويُتخطّى |
| امتلاء القرص أو Drive (البيانات ~100GB) | تنزيل مريض واحد، استخراج الخصائص، ثم حذف ملفاته فورًا؛ Drive يحفظ الخصائص فقط (ميغابايتات) |
| انقطاع الجلسة بعد ساعات | حفظ خصائص كل مريض في Drive فور انتهائه، وحفظ نتيجة كل تجربة؛ الاستكمال تلقائي |
| مرضى بلا تخطيط قلب أو حركة (~3%) | الخصائص المفقودة تبقى فارغة (NaN) والنموذج يتعامل معها؛ ويُذكر ذلك في التقرير |
| معدل عيّنات مختلف عن 256 Hz | إعادة أخذ العيّنات تلقائيًا |
| تخطيط قلب مقلوب القطبية أو مشوَّش | اكتشاف القطبية تلقائيًا + رفض النبضات غير الفيزيولوجية + مؤشر جودة لكل 30 ثانية |
| التسجيلات منقطعة (عدة ملفات) وتوقيتها الحقيقي مخفي | كل ملف يُعالج منفصلًا؛ لا نفترض اتصالًا بين الملفات |
| نوبات في أول 30 دقيقة من ملف | لا توجد فترة «ما قبل» كاملة لها: تُستبعد من تقييم التنبؤ وتُعدّ في التقرير |
| نوبات متقاربة تخلط «ما قبل النوبة» بما بعد نوبة سابقة | نستخدم «النوبات القائدة» فقط (بلا نوبة خلال 60 دقيقة قبلها) |
| فحص مقاومة الأقطاب (impd) يسبب إشارات مزيفة | فترات `impd` تُستبعد |
| **تسرّب** بين التدريب والاختبار | تقسيم حسب المريض (5 مجموعات)؛ ساعتا التكيّف للمريض المختبَر تُحذفان من اختباره |
| اختيار العتبة بالنظر إلى نوبات الاختبار | العتبة من ساعتي الإشارة العادية للمريض فقط |
| عدم توازن الفئات | موازنة الأوزان + سقف لعدد العيّنات العادية لكل مريض |
| ادعاء النجاح بالصدفة | مقارنة بإنذار عشوائي بنفس المعدل + اختبار إحصائي لكل مريض ولمجموع المرضى |
| خطأ في مريض أو تجربة واحدة | `try` لكل مريض ولكل تجربة؛ يُسجَّل الخطأ ويكمل الباقي |
| عدم العثور على ملف النتيجة | طباعة المسار الكامل + نسخة في أعلى «ملفاتي» + تنزيل تلقائي |
""")

code(r"""
!pip -q install mne==1.8.0 onnxruntime
import os, re, sys, json, time, zipfile, shutil, traceback, warnings, subprocess, urllib.request
from pathlib import Path
import numpy as np
import mne
from scipy.signal import butter, sosfiltfilt, find_peaks, resample_poly
from scipy.stats import skew, kurtosis, binomtest
import sklearn
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import roc_auc_score
warnings.filterwarnings('ignore'); mne.set_log_level('ERROR')
print('numpy', np.__version__, '| sklearn', sklearn.__version__, '| mne', mne.__version__)
SEED = 42; rng = np.random.default_rng(SEED)
try:
    from google.colab import drive
    drive.mount('/content/drive')
    MYDRIVE = Path('/content/drive/MyDrive'); WORK = MYDRIVE / 'epilepsy_preictal'
    TMP = Path('/content/seizeit2_tmp')        # local disk, deleted per subject
except ImportError:
    MYDRIVE = None; WORK = Path('work'); TMP = Path('work/tmp')
WORK.mkdir(parents=True, exist_ok=True); TMP.mkdir(parents=True, exist_ok=True)
FEAT = WORK / 'seizeit2_features'; FEAT.mkdir(exist_ok=True)
OUT = WORK / 'seizeit2_outputs'; OUT.mkdir(exist_ok=True)
RES = OUT / 'runs'; RES.mkdir(exist_ok=True)
print('saving to', WORK)
""")

md("## 1. الإعدادات")
code(r"""
S3 = 'https://s3.amazonaws.com/openneuro.org'
DS = 'ds005873'
FS, WIN, STEP = 256, 262, 256     # app EEG contract
EPOCH = 30                        # one feature row per 30 s
CTX = 20                          # 10 minutes of context (20 epochs)
PRE_START_MIN, PRE_END_MIN = 30, 5
LEAD_GAP_MIN = 60                 # lead seizure: no seizure in the previous 60 min
INTER_GAP_MIN = 60
ADAPT_HOURS = 2.0
REFRACTORY_MIN = 30
TARGET_FALSE_PER_HOUR = 0.5
MAX_INTER_PER_PATIENT = 3000
N_FOLDS = 5
MAX_SUBJECTS = None               # e.g. 20 for a quick first run; None = all
DETECTOR = WORK / 'edge_seizure_model.onnx'
EEG_F = ['rel_delta', 'rel_theta', 'rel_alpha', 'rel_beta', 'rel_gamma', 'sef90', 'log_power',
         'line_length', 'hjorth_mobility', 'hjorth_complexity', 'skewness', 'kurtosis']
ECG_F = ['hr', 'rmssd', 'sdnn', 'ecg_quality']
MOV_F = ['acc_std', 'acc_jerk', 'gyro_mean']
BASE_F = EEG_F + ECG_F + MOV_F
""")

md("## 2. التنزيل من OpenNeuro (قابل للاستكمال)")
code(r"""
def list_keys(prefix):
    keys, token = [], None
    while True:
        url = f'{S3}?list-type=2&prefix={prefix}' + (f'&continuation-token={urllib.parse.quote(token)}' if token else '')
        for attempt in range(5):
            try:
                xml = urllib.request.urlopen(url, timeout=60).read().decode(); break
            except Exception as e:
                print('list retry', attempt + 1, e); time.sleep(5)
        else:
            raise RuntimeError('cannot list ' + prefix)
        keys += re.findall(r'<Key>([^<]+)</Key>', xml)
        m = re.search(r'<NextContinuationToken>([^<]+)</NextContinuationToken>', xml)
        if not m: return keys
        token = m.group(1)

import urllib.parse
def fetch(key, dest):
    if dest.exists() and dest.stat().st_size > 0: return dest
    part = dest.with_suffix(dest.suffix + '.part')
    for attempt in range(8):
        r = subprocess.run(['curl', '-sSfL', '--retry', '5', '--retry-delay', '3', '-C', '-',
                            '-o', str(part), f'{S3}/{key}'])
        if r.returncode == 0:
            part.rename(dest); return dest
        time.sleep(5)
    raise RuntimeError('download failed ' + key)

subjects = sorted({k.split('/')[1] for k in list_keys(f'{DS}/sub-') if k.split('/')[1].startswith('sub-')})
if MAX_SUBJECTS: subjects = subjects[:MAX_SUBJECTS]
print(len(subjects), 'subjects')
""")

md("## 3. الخصائص (الدماغ 12 + القلب 4 + الحركة 3 لكل 30 ثانية)")
code(r"""
SOS_EEG = butter(4, [0.5 / (FS / 2), 40 / (FS / 2)], btype='bandpass', output='sos')
FREQS = np.fft.rfftfreq(WIN, 1 / FS); HANN = np.hanning(WIN)
BANDS = [(0.5, 4), (4, 8), (8, 13), (13, 30), (30, 40)]

def eeg_window_features(W):            # same as the trend notebook / app contract
    z = sosfiltfilt(SOS_EEG, np.asarray(W, np.float64), axis=1)
    P = np.abs(np.fft.rfft(z * HANN, axis=1)) ** 2
    band = (FREQS >= 0.5) & (FREQS < 40); tot = P[:, band].sum(1) + 1e-12
    rel = [P[:, (FREQS >= a) & (FREQS < b)].sum(1) / tot for a, b in BANDS]
    cum = np.cumsum(P * band, 1) / tot[:, None]; sef = FREQS[np.argmax(cum >= 0.9, axis=1)] / 40.0
    sd = z.std(1) + 1e-8; d1, d2 = np.diff(z, axis=1), np.diff(z, 2, axis=1)
    mob = d1.std(1) / sd; comp = (d2.std(1) / (d1.std(1) + 1e-8)) / (mob + 1e-8)
    return np.stack(rel + [sef, np.log(z.var(1) + 1e-12), np.abs(d1).mean(1) / sd, mob, comp,
                           skew(z, axis=1), np.clip(kurtosis(z, axis=1), -5, 50)], 1).astype(np.float32)

def to_fs(x, fs, target):
    fs = int(round(fs))
    if fs == target: return x
    g = np.gcd(fs, target); return resample_poly(x, target // g, fs // g)

def eeg_epochs(x, n_ep):
    out = np.full((n_ep, 12), np.nan, np.float32)
    idx = np.arange(0, len(x) - WIN, STEP)
    per_sec = np.full((len(idx), 12), np.nan, np.float32)
    for a in range(0, len(idx), 20000):
        j = idx[a:a + 20000]
        per_sec[a:a + len(j)] = eeg_window_features(np.stack([x[i:i + WIN] for i in j]))
    n = min(n_ep, len(per_sec) // EPOCH)
    if n: out[:n] = np.nanmean(per_sec[:n * EPOCH].reshape(n, EPOCH, 12), 1)
    return out

def ecg_epochs(e, fs, n_ep):
    out = np.full((n_ep, 4), np.nan, np.float32)
    if e is None or len(e) < fs * 60: return out
    x = sosfiltfilt(butter(3, [5 / (fs / 2), 20 / (fs / 2)], btype='bandpass', output='sos'), e)
    if np.percentile(x, 0.5) * -1 > np.percentile(x, 99.5): x = -x        # inverted polarity
    blk = int(10 * fs); thr = np.zeros_like(x)
    for a in range(0, len(x), blk):
        thr[a:a + blk] = 0.45 * np.percentile(x[a:a + blk], 99)
    pk, _ = find_peaks(x, distance=int(0.3 * fs))
    pk = pk[x[pk] > thr[pk]]
    t = pk / fs; rr = np.diff(t); tr = t[1:]
    ok = (rr > 0.3) & (rr < 2.0)
    ok[1:] &= np.abs(np.diff(rr)) < 0.3
    for i in range(n_ep):
        end = (i + 1) * EPOCH
        m5 = (tr > end - 300) & (tr <= end); m30 = (tr > end - EPOCH) & (tr <= end)
        v5, v30 = rr[m5 & ok], rr[m30 & ok]
        q = (m30 & ok).sum() / max(m30.sum(), 1)
        if len(v30) >= 10:
            out[i, 0] = 60 / np.median(v30)
        if len(v5) >= 60:
            out[i, 1] = np.sqrt(np.mean(np.diff(v5) ** 2)) * 1000; out[i, 2] = v5.std() * 1000
        out[i, 3] = q
    return out

def mov_epochs(raw, n_ep):
    out = np.full((n_ep, 3), np.nan, np.float32)
    if raw is None: return out
    names = raw.ch_names; fs = raw.info['sfreq']
    def pick(prefix, kind):
        ch = [c for c in names if c.startswith(prefix) and kind in c]
        return raw.get_data(picks=ch) if len(ch) == 3 else None
    acc = pick('ECGEMG SD', 'ACC'); gyr = pick('ECGEMG SD', 'GYR')
    if acc is None: acc, gyr = pick('EEG SD', 'ACC'), pick('EEG SD', 'GYR')
    if acc is None: return out
    mag = np.sqrt((acc ** 2).sum(0)); gm = np.sqrt((gyr ** 2).sum(0)) if gyr is not None else None
    s = int(EPOCH * fs)
    for i in range(min(n_ep, len(mag) // s)):
        seg = mag[i * s:(i + 1) * s]
        out[i, 0] = seg.std(); out[i, 1] = np.abs(np.diff(seg)).mean()
        if gm is not None: out[i, 2] = gm[i * s:(i + 1) * s].mean()
    return out
""")

md("## 4. التسميات وكاشف التطبيق (اختياري)")
code(r"""
DET = None
if DETECTOR.exists():
    import onnxruntime as ort
    DET = ort.InferenceSession(str(DETECTOR), providers=['CPUExecutionProvider'])
    print('app detector found: it will be checked on real wearable seizures')
else:
    print('app detector not uploaded: detection check skipped (optional)')

def det_probs(x, a_s, b_s):
    idx = np.arange(max(int(a_s * FS), 0), min(int(b_s * FS), len(x)) - WIN, STEP)
    if len(idx) == 0: return np.zeros(0)
    W = sosfiltfilt(SOS_EEG, np.stack([x[i:i + WIN] for i in idx]).astype(np.float64), axis=1)
    W = ((W - W.mean(1, keepdims=True)) / (W.std(1, keepdims=True) + 1e-8)).astype(np.float32)[:, None, :]
    out = []
    for a in range(0, len(W), 2048):
        z = DET.run(None, {'eeg_stream': W[a:a + 2048]})[0]
        e = np.exp(z - z.max(1, keepdims=True)); out.append((e / e.sum(1, keepdims=True))[:, 1])
    return np.concatenate(out)

def sustained(p, thr=0.5, k=3, n=5):
    h, out = [], []
    for v in p:
        h = (h + [v >= thr])[-n:]; out.append(sum(h) >= k)
    return np.array(out, bool)

def label_epochs(events, n_ep):
    sz = [(float(o), float(d)) for o, d, t in events if str(t).startswith('sz')]
    impd = [(float(o), float(d)) for o, d, t in events if str(t) == 'impd']
    lab = np.zeros(n_ep, np.int8)          # 0 other, 1 inter, 2 pre, 3 ictal
    sid = np.full(n_ep, -1, np.int16)
    t0 = np.arange(n_ep) * EPOCH; t1 = t0 + EPOCH
    far = np.ones(n_ep, bool)
    for o, d in sz:
        far &= (t1 <= o - INTER_GAP_MIN * 60) | (t0 >= o + d + INTER_GAP_MIN * 60)
    lab[far] = 1
    lead = []
    for k, (o, d) in enumerate(sz):
        prev_end = max([po + pd for po, pd in sz if po < o] or [-1e9])
        is_lead = o - prev_end >= LEAD_GAP_MIN * 60 and o >= PRE_START_MIN * 60
        lead.append(is_lead)
        if is_lead:
            m = (t0 >= o - PRE_START_MIN * 60) & (t1 <= o - PRE_END_MIN * 60)
            lab[m] = 2; sid[m] = k
    for o, d in sz:
        lab[(t1 > o) & (t0 < o + d)] = 3
    for o, d in impd:
        lab[(t1 > o) & (t0 < o + d)] = 0
    return lab, sid, sz, lead
""")

md("## 5. الاستخراج: مريض تلو الآخر (يكمل بعد الانقطاع، ويحذف الملفات فورًا)")
code(r"""
def read_events(path):
    rows = path.read_text().strip().splitlines()
    head = rows[0].split('\t'); i_on, i_du, i_ty = head.index('onset'), head.index('duration'), head.index('eventType')
    return [(r.split('\t')[i_on], r.split('\t')[i_du], r.split('\t')[i_ty]) for r in rows[1:] if r.strip()]

def extract(sub):
    dest = FEAT / f'{sub}.npz'
    if dest.exists(): return 'cached'
    keys = list_keys(f'{DS}/{sub}/')
    runs = sorted({re.search(r'(run-\d+)', k).group(1) for k in keys if k.endswith('_eeg.edf')})
    F, L, S, R, det = [], [], [], [], {'seizures': 0, 'detected': 0, 'inter_hours': 0.0, 'false': 0}
    n_sz = n_lead = 0; missing = {'ecg': 0, 'mov': 0}
    for run in runs:
        d = TMP / sub; d.mkdir(parents=True, exist_ok=True)
        def get(mod, ext='edf'):
            k = [x for x in keys if f'{run}_' in x and x.endswith(f'_{mod}.{ext}')]
            return fetch(k[0], d / Path(k[0]).name) if k else None
        try:
            ev = get('events', 'tsv'); events = read_events(ev) if ev else []
            r_eeg = mne.io.read_raw_edf(get('eeg'), preload=False)
            x = to_fs(r_eeg.get_data(picks=[0])[0] * 1e6, r_eeg.info['sfreq'], FS)
            n_ep = len(x) // (EPOCH * FS)
            f_eeg = eeg_epochs(x, n_ep)
            p = get('ecg')
            if p:
                r = mne.io.read_raw_edf(p, preload=False); f_ecg = ecg_epochs(r.get_data(picks=[0])[0] * 1e6, r.info['sfreq'], n_ep)
            else:
                f_ecg = ecg_epochs(None, FS, n_ep); missing['ecg'] += 1
            p = get('mov')
            f_mov = mov_epochs(mne.io.read_raw_edf(p, preload=True) if p else None, n_ep)
            if not p: missing['mov'] += 1
            lab, sid, sz, lead = label_epochs(events, n_ep)
            n_sz += len(sz); n_lead += sum(lead)
            F.append(np.concatenate([f_eeg, f_ecg, f_mov], 1)); L.append(lab)
            S.append(np.where(sid >= 0, sid + 1000 * len(R), -1)); R.append(np.full(n_ep, len(R), np.int16))
            if DET is not None:
                for o, dd in sz:
                    det['seizures'] += 1
                    det['detected'] += bool(sustained(det_probs(x, o, o + dd + 30)).any())
                inter_ep = np.flatnonzero(lab == 1)
                if len(inter_ep):
                    pick = rng.choice(inter_ep, size=min(len(inter_ep), 120), replace=False)   # <= 1 h per run
                    for e in pick:
                        a = sustained(det_probs(x, e * EPOCH, (e + 1) * EPOCH))
                        det['false'] += int(a.any()); det['inter_hours'] += EPOCH / 3600
        except Exception as e:
            print(sub, run, 'skipped:', type(e).__name__, e)
        finally:
            shutil.rmtree(d, ignore_errors=True)       # free local disk right away
    if not F:
        return 'no usable runs'
    np.savez_compressed(dest, X=np.concatenate(F), lab=np.concatenate(L), sid=np.concatenate(S),
                        run=np.concatenate(R), n_sz=n_sz, n_lead=n_lead,
                        missing=json.dumps(missing), det=json.dumps(det))
    return f'ok: seizures {n_sz}, lead {n_lead}, hours {sum(map(len, L)) * EPOCH / 3600:.1f}, missing {missing}'

t_all = time.time()
for i, sub in enumerate(subjects):
    t0 = time.time()
    try:
        msg = extract(sub)
    except Exception as e:
        msg = f'FAILED {type(e).__name__}: {e}'
    if msg != 'cached':
        print(f'[{i + 1}/{len(subjects)}] {sub} {msg} ({time.time() - t0:.0f}s)')
print('extraction done in', round((time.time() - t_all) / 60), 'min |', len(list(FEAT.glob('sub-*.npz'))), 'subjects ready')
""")

md("## 6. خط الأساس الشخصي وسياق 10 دقائق")
code(r"""
P = {}
for f in sorted(FEAT.glob('sub-*.npz')):
    z = np.load(f)
    P[f.stem] = {k: z[k] for k in ('X', 'lab', 'sid', 'run')}
    P[f.stem]['missing'] = json.loads(str(z['missing'])); P[f.stem]['det'] = json.loads(str(z['det']))

def adapt_mask(d):
    inter = np.flatnonzero(d['lab'] == 1)
    m = np.zeros(len(d['lab']), bool); m[inter[:int(ADAPT_HOURS * 3600 / EPOCH)]] = True
    return m

def context(X, run):
    # per epoch: current value, mean and slope over the last 10 minutes (same file only)
    n, k = X.shape; out = np.full((n, k * 3), np.nan, np.float32)
    t = np.arange(CTX) - (CTX - 1) / 2; tt = (t ** 2).sum()
    for r in np.unique(run):
        idx = np.flatnonzero(run == r)
        Y = X[idx]
        if len(Y) < CTX: continue
        Wv = np.lib.stride_tricks.sliding_window_view(Y, CTX, axis=0)      # (n-CTX+1, k, CTX)
        mean = np.nanmean(Wv, 2)
        slope = np.nansum((Wv - mean[..., None]) * t, 2) / tt
        j = idx[CTX - 1:]
        out[j, :k] = Y[CTX - 1:]; out[j, k:2 * k] = mean; out[j, 2 * k:] = slope
    return out

for p, d in P.items():
    am = adapt_mask(d); d['adapt'] = am
    base = d['X'][am]
    med = np.nanmedian(base, 0) if len(base) else np.full(d['X'].shape[1], np.nan)
    sc = np.nanstd(base, 0) if len(base) else np.full(d['X'].shape[1], np.nan)
    sc = np.where(np.isfinite(sc) & (sc > 1e-3), sc, 1.0); med = np.where(np.isfinite(med), med, 0.0)
    d['C_abs'] = context(d['X'], d['run'])
    d['C_rel'] = context((d['X'] - med) / sc, d['run'])
    d['adapt_h'] = am.sum() * EPOCH / 3600
print(len(P), 'patients |', sum((d['lab'] == 2).any() for d in P.values()), 'with lead pre-ictal data')
""")

md("## 7. التجارب (تقسيم حسب المريض)")
code(r"""
k = len(BASE_F)
def cols(names):
    i = [BASE_F.index(n) for n in names]
    return [c for j in i for c in (j, k + j, 2 * k + j)]
MOD = {'eeg': cols(EEG_F), 'ecg': cols(ECG_F), 'mov': cols(MOV_F), 'all': cols(BASE_F)}
RULE_SIGN = {'hr': 1, 'rmssd': -1, 'sdnn': -1}         # research rules: HR up / HRV down -> risk up
EXPERIMENTS = [(m, s, False) for m in ('eeg', 'ecg', 'mov', 'all') for s in ('abs', 'rel')] + [('all', 'rel', True)]
REFRACT = REFRACTORY_MIN * 60 // EPOCH

def monotonic(cidx):
    cst = []
    for c in cidx:
        name = BASE_F[c % k]; cst.append(RULE_SIGN.get(name, 0))
    return cst

def alarm_onsets(p, thr, kk=3, n=5):
    h, quiet, on = [], 0, []
    for i, v in enumerate(p):
        h = (h + [v >= thr])[-n:]
        if quiet > 0: quiet -= 1; continue
        if sum(h) >= kk: on.append(i); quiet = REFRACT; h = []
    return on

pats = sorted(p for p, d in P.items() if (d['lab'] == 2).any())
perm = list(rng.permutation(pats)); folds = [perm[i::N_FOLDS] for i in range(N_FOLDS)]

def evaluate(m, cidx, scale, test):
    d = P[test]; C = d[f'C_{scale}'][:, cidx]
    ok = np.isfinite(C).any(1)
    prob = np.full(len(C), np.nan); prob[ok] = m.predict_proba(C[ok])[:, 1]
    runs = d['run']
    def onsets_where(mask):
        res = []
        for r in np.unique(runs):
            idx = np.flatnonzero((runs == r) & mask & np.isfinite(prob))
            res.append((idx, alarm_onsets(prob[idx], THR_[0])))
        return res
    # label-free threshold: adaptation hours only
    am = d['adapt']; best = 0.99
    for t in np.round(np.arange(0.99, 0.04, -0.01), 2):
        THR_[0] = t
        n_on = sum(len(o) for _, o in onsets_where(am))
        if n_on / max(d['adapt_h'], 1e-9) <= TARGET_FALSE_PER_HOUR: best = float(t)
        else: break
    THR_[0] = best
    # stream through each file, alarms counted where they start
    warned, seizures, false, hours = 0, 0, 0, 0.0
    test_mask = ~am
    for r in np.unique(runs):
        idx = np.flatnonzero((runs == r) & np.isfinite(prob))
        on = set(idx[alarm_onsets(prob[idx], best)]) if len(idx) else set()
        for s in np.unique(d['sid'][(runs == r) & (d['sid'] >= 0)]):
            pre = set(np.flatnonzero(d['sid'] == s)); seizures += 1; warned += bool(on & pre)
        inter = np.flatnonzero((runs == r) & (d['lab'] == 1) & test_mask)
        false += len(on & set(inter)); hours += len(inter) * EPOCH / 3600
    if seizures == 0 or hours < 0.5: return None
    fph = false / hours; chance = float(1 - np.exp(-fph * (PRE_START_MIN - PRE_END_MIN) / 60))
    pv = float(binomtest(warned, seizures, min(max(chance, 1e-6), 1 - 1e-6), alternative='greater').pvalue)
    return {'seizures': seizures, 'warned': warned, 'sensitivity': round(warned / seizures, 3),
            'false_warnings_per_hour': round(fph, 3), 'test_hours': round(hours, 1),
            'chance_sensitivity': round(chance, 3), 'p_value': round(pv, 4),
            'beats_chance': bool(pv < 0.05 and warned / seizures > chance), 'threshold': best}
THR_ = [0.5]

for mod, scale, rules in EXPERIMENTS:
    name = f'{mod}_{scale}' + ('_rules' if rules else '')
    for fi, test_p in enumerate(folds):
        f = RES / f'{name}_fold{fi}.json'
        if f.exists(): continue
        t0 = time.time()
        try:
            cidx = MOD[mod]; train_p = [p for p in pats if p not in test_p]
            Xs, ys = [], []
            for p in train_p:
                d = P[p]; C = d[f'C_{scale}'][:, cidx]
                pre = np.flatnonzero(d['lab'] == 2); inter = np.flatnonzero(d['lab'] == 1)
                inter = rng.choice(inter, size=min(len(inter), MAX_INTER_PER_PATIENT), replace=False) if len(inter) else inter
                sel = np.r_[pre, inter]; sel = sel[np.isfinite(C[sel]).any(1)]
                Xs.append(C[sel]); ys.append((d['lab'][sel] == 2).astype(int))
            Xs, ys = np.concatenate(Xs), np.concatenate(ys)
            m = HistGradientBoostingClassifier(max_depth=4, max_iter=300, learning_rate=0.05,
                                               l2_regularization=1.0, class_weight='balanced',
                                               monotonic_cst=monotonic(cidx) if rules else None,
                                               random_state=SEED).fit(Xs, ys)
            res = {p: evaluate(m, cidx, scale, p) for p in test_p}
            out = {'experiment': name, 'fold': fi, 'per_patient': {p: r for p, r in res.items() if r}}
        except Exception as e:
            out = {'experiment': name, 'fold': fi, 'error': f'{type(e).__name__}: {e}',
                   'trace': traceback.format_exc()[-1500:]}
        f.write_text(json.dumps(out, indent=1))
        print(name, 'fold', fi, 'done' if 'error' not in out else out['error'], f'({time.time() - t0:.0f}s)')
""")

md("## 8. الخلاصة: كم مريضًا تكسب كل إشارة وكل فكرة؟")
code(r"""
summary = {}
for mod, scale, rules in EXPERIMENTS:
    name = f'{mod}_{scale}' + ('_rules' if rules else '')
    rows = {}
    for f in RES.glob(f'{name}_fold*.json'):
        rows.update(json.loads(f.read_text()).get('per_patient', {}))
    if not rows: continue
    sz = sum(r['seizures'] for r in rows.values()); w = sum(r['warned'] for r in rows.values())
    hrs = sum(r['test_hours'] for r in rows.values())
    fph = sum(r['false_warnings_per_hour'] * r['test_hours'] for r in rows.values()) / max(hrs, 1e-9)
    ch = float(1 - np.exp(-fph * (PRE_START_MIN - PRE_END_MIN) / 60))
    summary[name] = {'patients_evaluated': len(rows), 'patients_beating_chance': sum(r['beats_chance'] for r in rows.values()),
                     'seizures': sz, 'warned': w, 'sensitivity': round(w / max(sz, 1), 3),
                     'chance_sensitivity': round(ch, 3), 'false_warnings_per_hour': round(fph, 3),
                     'p_value_pooled': float(binomtest(w, sz, min(max(ch, 1e-6), 1 - 1e-6), alternative='greater').pvalue) if sz else None,
                     'beats_chance_patients': sorted(p for p, r in rows.items() if r['beats_chance'])}
print(f"{'experiment':16s} {'patients>chance':>16s} {'sens':>6s} {'chance':>7s} {'FP/h':>6s} {'p':>9s}")
for n, s in summary.items():
    print(f"{n:16s} {str(s['patients_beating_chance']) + '/' + str(s['patients_evaluated']):>16s} {s['sensitivity']:6.3f} "
          f"{s['chance_sensitivity']:7.3f} {s['false_warnings_per_hour']:6.2f} {s['p_value_pooled']:9.2g}")
det = {'seizures': 0, 'detected': 0, 'inter_hours': 0.0, 'false': 0}
for d in P.values():
    for kk in det: det[kk] += d['det'].get(kk, 0)
detector = None
if det['seizures']:
    detector = {'seizures': det['seizures'], 'sensitivity': round(det['detected'] / det['seizures'], 3),
                'false_alarms_per_hour': round(det['false'] / max(det['inter_hours'], 1e-9), 3),
                'interictal_hours_sampled': round(det['inter_hours'], 1)}
    print('\napp detector on real wearable seizures:', detector)
missing = {'ecg_runs_missing': sum(d['missing']['ecg'] for d in P.values()),
           'mov_runs_missing': sum(d['missing']['mov'] for d in P.values())}
report = {'summary': summary, 'detector': detector, 'missing': missing, 'patients': len(P),
          'settings': {'epoch_s': EPOCH, 'context_min': CTX * EPOCH / 60, 'adapt_hours': ADAPT_HOURS,
                       'lead_gap_min': LEAD_GAP_MIN, 'target_false_per_hour': TARGET_FALSE_PER_HOUR,
                       'folds': N_FOLDS, 'features': BASE_F},
          'notes': 'SeizeIT2 (OpenNeuro ds005873, CC0). Patient-disjoint folds; per-patient threshold and '
                   'baseline from the first 2 h of normal data, excluded from testing; lead seizures only.'}
(OUT / 'seizeit2_report.json').write_text(json.dumps(report, indent=1))
ZIP = WORK / 'seizeit2_multimodal_outputs.zip'
with zipfile.ZipFile(ZIP, 'w') as zf:
    zf.write(OUT / 'seizeit2_report.json', 'seizeit2_report.json')
    for f in RES.glob('*.json'): zf.write(f, 'runs/' + f.name)
if MYDRIVE is not None: shutil.copy(ZIP, MYDRIVE / ZIP.name)
try:
    from google.colab import files; files.download(str(ZIP))
except Exception:
    pass
print('\nالنتيجة محفوظة في:', ZIP)
if MYDRIVE is not None: print('ونسخة في أعلى «ملفاتي»:', MYDRIVE / ZIP.name)
""")

nb = {"cells": CELLS, "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"},
                                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 5}
out = Path(__file__).resolve().parent / "colab_seizeit2_multimodal.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("wrote", out)
