"""Builds research/colab_preictal_adapt.ipynb.

Zero-seizure adaptation experiment. The patient-specific notebook beat chance
in 7/20 patients, but needs >=3 recorded seizures per patient first. Here the
model learns from OTHER patients' seizures and adapts to a new patient using
only a few hours of that patient's NORMAL (inter-ictal) EEG, which the app can
collect on day one. Three variants, all leave-one-patient-out:

  population : one global feature scaling (what we had before)
  baseline   : each patient's features scaled by their own normal-EEG baseline
  coral      : baseline + CORAL covariance alignment to the training patients

The alarm threshold of the new patient is also set label-free: the lowest one
that keeps that patient's adaptation hours under the false-alarm target.
Run:  python research/build_preictal_adapt_notebook.py
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
# تجربة التنبؤ لكل مريض دون انتظار نوبات (التكيّف من الإشارة العادية)

**الفكرة:** النموذج يتعلم من نوبات **المرضى الآخرين**، ثم يتكيّف مع المريض الجديد باستخدام
ساعات قليلة من إشارته **العادية فقط** (بلا نوبات) — وهذا ما يستطيع التطبيق جمعه من اليوم الأول.

نقارن ثلاث طرق، وفي كل مرة يُستبعد مريض كامل من التدريب ثم يُختبر:
1. **population** — النموذج العام كما هو (المرجع).
2. **baseline** — خصائص كل مريض تُقاس نسبةً إلى حالته الطبيعية.
3. **coral** — baseline + محاذاة توزيع الخصائص مع مرضى التدريب (CORAL).

**التشغيل في Colab:**
1. **لا يحتاج GPU:** Runtime → Change runtime type → **CPU**.
2. **Runtime → Run all** واسمح بالوصول إلى Google Drive بنفس الحساب.
3. يستخدم الخصائص المحفوظة في `MyDrive/epilepsy_preictal/features_v2/` — لا تنزيل من جديد.
4. المدة: من 30 إلى 60 دقيقة تقريبًا. إن انقطعت الجلسة شغّل Run all مرة أخرى؛ يكمل من المريض الذي توقف عنده.
5. **مكان النتيجة:** Drive → **ملفاتي** → مجلد `epilepsy_preictal` → `preictal_adapt_outputs.zip`
   (قائمة «الملفات المقترحة» في الصفحة الرئيسية لا تعرض كل الملفات؛ ابحث بالاسم إن لم تجده).

### المشاكل المتوقعة وحلولها
| المشكلة المتوقعة | الحل في الدفتر |
|---|---|
| Drive غير موصول أو مجلد الخصائص مفقود | فحص في البداية ورسالة عربية واضحة |
| مصفوفات `object` / قيم NaN أو Inf | تحويل إلى `float32` وتنظيف كل مقطع |
| **تسرّب**: ساعات التكيّف تُستخدم في الاختبار | ساعات التكيّف تُحذف من بيانات الاختبار نهائيًا |
| **تسرّب**: استخدام نوبات المريض الجديد في التكيّف | التكيّف يستخدم تسجيلات **بين النوبات** فقط (≥ 60 دقيقة بعيدًا عن أي نوبة) |
| اختيار العتبة بالنظر إلى نوبات الاختبار | العتبة تُحدَّد من ساعات التكيّف العادية فقط (بلا أي نوبة) |
| مريض بلا تسجيلات عادية كافية للتكيّف والاختبار (مثل chb24) | يُستبعد ويُذكر السبب |
| مريض بلا نوبات قابلة للاختبار | يُستبعد ويُذكر السبب |
| مصفوفة تغاير شبه منفردة في CORAL | إضافة تنظيم (`eps·I`) وحساب الجذر عبر القيم الذاتية الآمنة |
| انحراف معياري صفري في خط الأساس | حد أدنى للانحراف حتى لا نقسم على صفر |
| ذاكرة/وقت كبيران مع 23 مريضًا تدريبيًا | سقف لعدد تسلسلات التدريب لكل مريض، ونماذج سريعة |
| مقارنة غير عادلة بين الطرق | نفس المرضى ونفس ساعات التكيّف ونفس بيانات الاختبار لكل الطرق |
| ادعاء النجاح بالصدفة | مقارنة بإنذار عشوائي بنفس المعدل + اختبار إحصائي لكل مريض ولمجموع المرضى |
| انقطاع الجلسة | حفظ نتيجة كل مريض فور انتهائه واستكمال الباقي |
| خطأ في مريض واحد | `try` لكل مريض؛ يُسجَّل الخطأ ويكمل الباقون |
| عدم العثور على ملف النتيجة | طباعة المسار الكامل + تنزيل تلقائي + نسخة ثانية في جذر «ملفاتي» |
""")

code(r"""
import sys, json, time, zipfile, shutil, traceback, warnings
from pathlib import Path
import numpy as np
import sklearn
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import HistGradientBoostingClassifier
from scipy.stats import binomtest
warnings.filterwarnings('ignore')
print('python', sys.version.split()[0], '| numpy', np.__version__, '| sklearn', sklearn.__version__)
SEED = 42
rng = np.random.default_rng(SEED)
WORK = None
try:
    from google.colab import drive
    drive.mount('/content/drive')
    MYDRIVE = Path('/content/drive/MyDrive')
    cands = [MYDRIVE / 'epilepsy_preictal']
except ImportError:
    MYDRIVE = None
    cands = [Path('/kaggle/working'), Path('work')]
for c in cands:
    if (c / 'features_v2').exists():
        WORK = c; break
if WORK is None and MYDRIVE is not None:
    for f in MYDRIVE.glob('*/features_v2'):
        WORK = f.parent; break
if WORK is None:
    raise SystemExit('لم أجد مجلد features_v2 في Google Drive. شغّل دفتر colab_train_preictal_trend حتى '
                     'نهاية الخطوة 3 أولًا، وتأكد أنك تستخدم نفس حساب Google.')
CACHE = WORK / 'features_v2'
OUT = WORK / 'adapt_outputs'; OUT.mkdir(exist_ok=True)
RESULTS = OUT / 'per_patient'; RESULTS.mkdir(exist_ok=True)
print('features from', CACHE, '| patients', len(list(CACHE.glob('chb*.npz'))))
""")

md("## 1. الإعدادات")
code(r"""
SEQ, EVAL_EVERY, INTER_STRIDE = 120, 30, 60
BLOCK_MIN = 30
ADAPT_HOURS = 2.0           # normal EEG of the new patient used for adaptation (no seizures)
MIN_TEST_INTER_HOURS = 1.0  # normal EEG left for measuring false alarms
PRE_MIN, REFRACTORY_MIN = 25, 30
TARGET_FALSE_PER_HOUR = 0.5
MAX_TRAIN_SEQ_PER_PATIENT = 4000
EPS = 1e-3
REFRACT = REFRACTORY_MIN * 60 // EVAL_EVERY
VARIANTS = ['population', 'baseline', 'coral']
MODELS = ['logistic', 'boosting']
""")

md("## 2. التحميل والخصائص")
code(r"""
def clean(seg):
    a = np.asarray(seg, np.float32)
    if a.ndim != 2 or a.shape[1] != 12:
        return None
    return np.nan_to_num(a, nan=0.0, posinf=0.0, neginf=0.0)

def blocks(segs):
    n = BLOCK_MIN * 60
    return [s[a:a + n] for s in segs for a in range(0, len(s), n) if len(s[a:a + n]) >= SEQ]

def seq_feats(seg, stride):
    ends = np.arange(SEQ, len(seg) + 1, stride)
    if len(ends) == 0:
        return np.zeros((0, 36), np.float32)
    S = np.stack([seg[e - SEQ:e] for e in ends]).copy()
    S[..., 6] -= np.median(S[..., 6], axis=1, keepdims=True)
    t = np.linspace(-1, 1, SEQ)[None, :, None]
    slope = (S * t).mean(1) / (t ** 2).mean()
    return np.nan_to_num(np.concatenate([S.mean(1), S.std(1), slope], 1)).astype(np.float32)

P = {}
for f in sorted(CACHE.glob('chb*.npz')):
    try:
        z = np.load(f, allow_pickle=True)
        pre = [s for s in (clean(x) for x in z['pre']) if s is not None and len(s) >= SEQ]
        inter = blocks([s for s in (clean(x) for x in z['inter']) if s is not None and len(s) >= SEQ])
        need = int(ADAPT_HOURS * 3600)
        adapt, test_inter, used = [], [], 0
        for b in inter:                      # first blocks -> adaptation, rest -> test
            (adapt if used < need else test_inter).append(b); used += len(b)
        P[f.stem] = {'pre': pre, 'adapt': adapt, 'test_inter': test_inter,
                     'adapt_h': sum(map(len, adapt)) / 3600, 'test_h': sum(map(len, test_inter)) / 3600}
    except Exception as e:
        print('cannot read', f.name, e)
for p, d in P.items():
    print(p, 'seizures', len(d['pre']), '| adapt h', round(d['adapt_h'], 1), '| test h', round(d['test_h'], 1))
""")

md("## 3. خط الأساس الشخصي و CORAL")
code(r"""
def baseline_stats(adapt_blocks):
    X = np.concatenate([seq_feats(b, INTER_STRIDE) for b in adapt_blocks])
    return X.mean(0), np.maximum(X.std(0), 1e-3), X

def sqrtm_psd(C, inv=False):
    w, V = np.linalg.eigh((C + C.T) / 2)
    w = np.maximum(w, EPS)
    return (V * (w ** (-0.5 if inv else 0.5))) @ V.T

def coral_map(Xt_adapt, Cs):
    # whiten the target with its own covariance, re-colour with the source one
    Ct = np.cov(Xt_adapt, rowvar=False) + EPS * np.eye(Xt_adapt.shape[1])
    return sqrtm_psd(Ct, inv=True) @ sqrtm_psd(Cs + EPS * np.eye(Cs.shape[0]))

def patient_matrix(d, stride_pre=EVAL_EVERY):
    Xp = [seq_feats(s, stride_pre) for s in d['pre']]
    Xi = [seq_feats(b, INTER_STRIDE) for b in d['adapt'] + d['test_inter']]
    X = np.concatenate(Xp + Xi)
    y = np.r_[np.ones(sum(map(len, Xp))), np.zeros(sum(map(len, Xi)))]
    if len(X) > MAX_TRAIN_SEQ_PER_PATIENT:
        idx = rng.choice(len(X), MAX_TRAIN_SEQ_PER_PATIENT, replace=False)
        X, y = X[idx], y[idx]
    return X, y

def alarm_onsets(p, thr, k=3, n=5):
    hist, quiet, onsets = [], 0, []
    for v in p:
        hist = (hist + [v >= thr])[-n:]
        if quiet > 0:
            quiet -= 1; continue
        if sum(hist) >= k:
            onsets.append(1); quiet = REFRACT; hist = []
    return onsets
""")

md("## 4. التدريب والاختبار (اترك مريضًا خارجًا)")
code(r"""
usable = [p for p, d in P.items() if d['pre'] and d['adapt']]
# training-side transforms per patient are computed once (each patient's own baseline)
TRAIN = {}
for p in usable:
    d = P[p]
    X, y = patient_matrix(d)
    mu, sd, Xa = baseline_stats(d['adapt'])
    TRAIN[p] = {'X': X, 'y': y, 'mu': mu, 'sd': sd}

def make(kind):
    if kind == 'logistic':
        return LogisticRegression(C=0.1, class_weight='balanced', max_iter=3000)
    return HistGradientBoostingClassifier(max_depth=3, max_iter=200, learning_rate=0.05,
                                          l2_regularization=1.0, class_weight='balanced',
                                          random_state=SEED)

def run_patient(target):
    d = P[target]
    if not d['pre']:
        return {'skipped': 'no usable seizures'}
    if d['adapt_h'] < ADAPT_HOURS * 0.9:
        return {'skipped': f"only {d['adapt_h']:.1f} h normal EEG for adaptation"}
    if d['test_h'] < MIN_TEST_INTER_HOURS:
        return {'skipped': f"only {d['test_h']:.1f} h normal EEG left for testing"}
    src = [p for p in usable if p != target]
    Xs_raw = np.concatenate([TRAIN[p]['X'] for p in src]); ys = np.concatenate([TRAIN[p]['y'] for p in src])
    Xs_base = np.concatenate([(TRAIN[p]['X'] - TRAIN[p]['mu']) / TRAIN[p]['sd'] for p in src])
    g_mu, g_sd = Xs_raw.mean(0), np.maximum(Xs_raw.std(0), 1e-3)
    t_mu, t_sd, Xt_adapt = baseline_stats(d['adapt'])
    Cs = np.cov(Xs_base[ys == 0], rowvar=False)
    A = coral_map((Xt_adapt - t_mu) / t_sd, Cs)
    tf = {
        'population': (lambda X: (X - g_mu) / g_sd, (Xs_raw - g_mu) / g_sd),
        'baseline': (lambda X: (X - t_mu) / t_sd, Xs_base),
        'coral': (lambda X: ((X - t_mu) / t_sd) @ A, Xs_base),
    }
    out = {}
    for variant, (f_target, Xtrain) in tf.items():
        for kind in MODELS:
            m = make(kind).fit(Xtrain, ys)
            sc = lambda seg: m.predict_proba(f_target(seq_feats(seg, EVAL_EVERY)))[:, 1]
            # label-free threshold from the adaptation (normal) hours only
            ad = [sc(b) for b in d['adapt']]
            thr = 0.99
            for t in np.round(np.arange(0.99, 0.04, -0.01), 2):
                if sum(len(alarm_onsets(s, t)) for s in ad) / d['adapt_h'] <= TARGET_FALSE_PER_HOUR:
                    thr = float(t)
                else:
                    break
            warned = sum(bool(alarm_onsets(sc(s), thr)) for s in d['pre'])
            false = sum(len(alarm_onsets(sc(b), thr)) for b in d['test_inter'])
            fph = false / d['test_h']; K = len(d['pre'])
            chance = float(1 - np.exp(-fph * PRE_MIN / 60))
            pv = float(binomtest(warned, K, min(max(chance, 1e-6), 1 - 1e-6), alternative='greater').pvalue)
            out[f'{variant}/{kind}'] = {
                'seizures': K, 'warned': warned, 'sensitivity': round(warned / K, 3),
                'false_warnings_per_hour': round(fph, 3), 'test_hours': round(d['test_h'], 1),
                'chance_sensitivity': round(chance, 3), 'p_value': round(pv, 4),
                'beats_chance': bool(pv < 0.05 and warned / K > chance), 'threshold': thr}
    return out

for target in sorted(P):
    f = RESULTS / f'{target}.json'
    if f.exists():
        continue
    t0 = time.time()
    try:
        r = run_patient(target)
    except Exception as e:
        r = {'error': f'{type(e).__name__}: {e}', 'trace': traceback.format_exc()[-1500:]}
    r = {'patient': target, 'seconds': round(time.time() - t0, 1), **r}
    f.write_text(json.dumps(r, indent=1))
    brief = {k: (v['sensitivity'], v['false_warnings_per_hour'], v['beats_chance'])
             for k, v in r.items() if isinstance(v, dict)}
    print(target, brief or r.get('skipped') or r.get('error'))
""")

md("## 5. الخلاصة والمقارنة")
code(r"""
rows = [json.loads(f.read_text()) for f in sorted(RESULTS.glob('*.json'))]
summary = {}
for key in [f'{v}/{m}' for v in VARIANTS for m in MODELS]:
    ok = [(r['patient'], r[key]) for r in rows if key in r]
    if not ok:
        continue
    sz = sum(x['seizures'] for _, x in ok); w = sum(x['warned'] for _, x in ok)
    hrs = sum(x['test_hours'] for _, x in ok)
    fph = sum(x['false_warnings_per_hour'] * x['test_hours'] for _, x in ok) / max(hrs, 1e-9)
    chance = float(1 - np.exp(-fph * PRE_MIN / 60))
    summary[key] = {
        'patients_evaluated': len(ok), 'patients_beating_chance': sum(x['beats_chance'] for _, x in ok),
        'seizures': sz, 'warned': w, 'sensitivity': round(w / sz, 3),
        'false_warnings_per_hour': round(fph, 3), 'chance_sensitivity': round(chance, 3),
        'p_value_pooled': float(binomtest(w, sz, min(max(chance, 1e-6), 1 - 1e-6), alternative='greater').pvalue),
        'beats_chance_patients': [p for p, x in ok if x['beats_chance']]}
skipped = {r['patient']: r.get('skipped') or r.get('error') for r in rows
           if not any(isinstance(v, dict) for v in r.values())}
print(f"{'method':22s} {'patients>chance':>16s} {'sens':>6s} {'chance':>7s} {'FP/h':>6s} {'p':>9s}")
for k, s in summary.items():
    print(f"{k:22s} {str(s['patients_beating_chance']) + '/' + str(s['patients_evaluated']):>16s} "
          f"{s['sensitivity']:6.3f} {s['chance_sensitivity']:7.3f} {s['false_warnings_per_hour']:6.2f} {s['p_value_pooled']:9.2g}")
print('skipped/failed:', skipped)
personal = WORK / 'personal_outputs' / 'personal_report.json'
if personal.exists():   # side-by-side with the patient-specific experiment
    ps = json.loads(personal.read_text())['summary']
    print('\npatient-specific (needs >=3 seizures):',
          {k: (v.get('patients_beating_chance'), v.get('sensitivity'), v.get('chance_sensitivity')) for k, v in ps.items()})
report = {'summary': summary, 'skipped_or_failed': skipped, 'per_patient': rows,
          'settings': {'adapt_hours': ADAPT_HOURS, 'target_false_per_hour': TARGET_FALSE_PER_HOUR,
                       'seq_s': SEQ, 'eval_every_s': EVAL_EVERY, 'refractory_min': REFRACTORY_MIN},
          'notes': 'Leave-one-patient-out. The new patient contributes only ADAPT_HOURS of inter-ictal EEG '
                   '(no seizures) for baseline/CORAL and for the threshold; those hours are excluded from testing.'}
(OUT / 'adapt_report.json').write_text(json.dumps(report, indent=1))
ZIP = WORK / 'preictal_adapt_outputs.zip'
with zipfile.ZipFile(ZIP, 'w') as zf:
    zf.write(OUT / 'adapt_report.json', 'adapt_report.json')
    for f in RESULTS.glob('*.json'):
        zf.write(f, 'per_patient/' + f.name)
if MYDRIVE is not None:
    shutil.copy(ZIP, MYDRIVE / ZIP.name)   # second copy at the top of «My Drive»
try:
    from google.colab import files
    files.download(str(ZIP))
except Exception:
    pass
print('\nالنتيجة محفوظة في:', ZIP)
if MYDRIVE is not None:
    print('ونسخة ثانية في أعلى «ملفاتي»:', MYDRIVE / ZIP.name)
""")

nb = {"cells": CELLS, "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"},
                                   "language_info": {"name": "python"}},
      "nbformat": 4, "nbformat_minor": 5}
out = Path(__file__).resolve().parent / "colab_preictal_adapt.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("wrote", out)
