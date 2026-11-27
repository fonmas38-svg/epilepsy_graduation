"""Builds research/colab_preictal_personal.ipynb.

Patient-specific pre-ictal experiment. The patient-independent trend model
(colab_train_preictal_trend.ipynb) was no better than a random alarm at the
same rate (test sensitivity 0.71 vs 0.70 by chance). The literature's positive
results are mostly patient-specific, so this notebook asks: trained on a
patient's OWN earlier seizures, does the model beat chance on that patient?

It reuses the 12-feature cache that the trend notebook saved to Google Drive
(features_v2/), so nothing is downloaded again and no GPU is needed.

Problems anticipated and handled (see the "safeguards" list in the notebook):
missing Drive/cache, object-dtype arrays, patients with too few seizures or no
inter-ictal data, leakage between train and test, threshold chosen on test
data, tiny/imbalanced data, disconnects (per-patient resume), one patient
crashing the run, and claiming success without a statistical test.
Run:  python research/build_preictal_personal_notebook.py
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
# تجربة التنبؤ الشخصي: نموذج خاص بكل مريض

**السؤال:** إذا تعلّم النموذج من نوبات المريض **نفسه** السابقة، هل يتنبأ بنوبته التالية أفضل من إنذار عشوائي؟

**التشغيل في Colab:**
1. **لا يحتاج GPU:** Runtime → Change runtime type → **CPU** (أسرع في الحجز ولا يُستهلك رصيد GPU).
2. **Runtime → Run all** واسمح بالوصول إلى Google Drive (نفس الحساب الذي درّبت عليه سابقًا).
3. يستخدم الخصائص المحفوظة في `MyDrive/epilepsy_preictal/features_v2/` — **لا تنزيل من جديد**.
4. المدة: من 20 إلى 40 دقيقة تقريبًا. إن انقطعت الجلسة شغّل Run all مرة أخرى؛ يكمل من المريض الذي توقف عنده.
5. النتيجة: `MyDrive/epilepsy_preictal/preictal_personal_outputs.zip` — أرسلها كما هي.

### الاحتياطات المدمجة (مشاكل متوقعة وحلولها)
| المشكلة المتوقعة | الحل في الدفتر |
|---|---|
| Drive غير موصول أو مجلد الخصائص غير موجود | فحص في البداية ورسالة واضحة بالعربية، والبحث عن المجلد في أماكن بديلة |
| الخصائص محفوظة كمصفوفات `object` (خطأ `sqrt` السابق) | تحويل كل مقطع إلى `float32` عند التحميل وفحص القيم غير الصالحة (NaN/Inf) |
| مريض لديه نوبة أو نوبتان فقط | يُستبعد (نحتاج 3 نوبات على الأقل) ويُذكر السبب في التقرير |
| مريض بلا تسجيلات بين النوبات (مثل chb24) | يُستبعد ويُذكر السبب |
| **تسرّب** بيانات الاختبار إلى التدريب | اختبار «اترك نوبة واحدة خارجًا»، وتسجيلات بين النوبات تُقسَّم إلى **كتل زمنية متصلة** لا إلى نوافذ متجاورة |
| اختيار العتبة على بيانات الاختبار (نتيجة متفائلة كاذبة) | العتبة تُختار داخل بيانات التدريب فقط (تحقق داخلي) |
| بيانات قليلة وغير متوازنة | نماذج بسيطة (انحدار لوجستي + أشجار تعزيز صغيرة) مع موازنة الفئات، بدل شبكة عميقة |
| ادعاء النجاح بالصدفة | مقارنة بإنذار عشوائي بنفس المعدل + **اختبار إحصائي** لكل مريض |
| انقطاع الجلسة | حفظ نتيجة كل مريض فور انتهائه في Drive واستكمال الباقي |
| خطأ في مريض واحد يوقف كل شيء | كل مريض داخل `try`؛ يُسجَّل الخطأ ويُكمل الباقون |
| نسخة مكتبة مختلفة في Colab | فحص الإصدارات وطباعة تحذير؛ الكود يستخدم دوال مستقرة فقط |
""")

code(r"""
import os, sys, json, time, zipfile, traceback, warnings
from pathlib import Path
import numpy as np
import sklearn
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import make_pipeline
from scipy.stats import binomtest
warnings.filterwarnings('ignore')
print('python', sys.version.split()[0], '| numpy', np.__version__, '| sklearn', sklearn.__version__)
if tuple(int(x) for x in sklearn.__version__.split('.')[:2]) < (1, 0):
    print('تحذير: نسخة sklearn قديمة؛ شغّل: !pip -q install -U scikit-learn')
SEED = 42
rng = np.random.default_rng(SEED)
""")

md("## 1. الوصول إلى الخصائص المحفوظة")
code(r"""
WORK = None
try:
    from google.colab import drive
    drive.mount('/content/drive')
    candidates = [Path('/content/drive/MyDrive/epilepsy_preictal')]
except ImportError:
    candidates = [Path('/kaggle/working'), Path('work')]
candidates += [Path('/content/drive/MyDrive').glob('**/features_v2')] if Path('/content/drive/MyDrive').exists() else []
for c in candidates:
    if isinstance(c, Path):
        if (c / 'features_v2').exists():
            WORK = c; break
    else:   # search results (generator)
        for found in c:
            WORK = found.parent; break
        if WORK: break
if WORK is None:
    raise SystemExit('لم أجد مجلد features_v2 في Google Drive. شغّل دفتر colab_train_preictal_trend '
                     'حتى نهاية الخطوة 3 أولًا، وتأكد أنك سجّلت الدخول بنفس حساب Google.')
CACHE = WORK / 'features_v2'
OUT = WORK / 'personal_outputs'; OUT.mkdir(exist_ok=True)
RESULTS = OUT / 'per_patient'; RESULTS.mkdir(exist_ok=True)
print('features from', CACHE, '| files', len(list(CACHE.glob('*.npz'))))
""")

md("## 2. الإعدادات")
code(r"""
SEQ = 120              # 2 minutes of 1-second feature rows, as in the trend model
EVAL_EVERY = 30        # one prediction every 30 s (training stride for pre-ictal too)
INTER_STRIDE = 60      # sparser stride for the (much longer) inter-ictal data
BLOCK_MIN = 30         # inter-ictal recordings are cut into contiguous 30-min blocks
PRE_MIN = 25           # pre-ictal window length used (30..5 min before onset)
REFRACTORY_MIN = 30
TARGET_FALSE_PER_HOUR = 0.5
MIN_SEIZURES = 3       # need >=2 seizures to train when one is held out
MIN_INTER_HOURS = 1.0
REFRACT = REFRACTORY_MIN * 60 // EVAL_EVERY
""")

md("## 3. التحميل الآمن والخصائص المجمّعة")
code(r"""
def clean(seg):
    a = np.asarray(seg, np.float32)          # fixes object-dtype arrays
    if a.ndim != 2 or a.shape[1] != 12:
        return None
    if not np.isfinite(a).all():
        a = np.nan_to_num(a, nan=0.0, posinf=0.0, neginf=0.0)
    return a

def load(p):
    z = np.load(CACHE / f'{p}.npz', allow_pickle=True)
    pre = [s for s in (clean(x) for x in z['pre']) if s is not None and len(s) >= SEQ]
    inter = [s for s in (clean(x) for x in z['inter']) if s is not None and len(s) >= SEQ]
    return pre, inter

def blocks(segs):
    # contiguous 30-minute blocks: test blocks never share time with train blocks
    n = BLOCK_MIN * 60
    out = []
    for s in segs:
        for a in range(0, len(s), n):
            b = s[a:a + n]
            if len(b) >= SEQ: out.append(b)
    return out

def seq_feats(seg, stride):
    # (n_seq, 36): mean, std and slope of each feature over the last 2 minutes.
    # log_power (col 6) is made relative to its own window, as in the trend model.
    ends = np.arange(SEQ, len(seg) + 1, stride)
    if len(ends) == 0:
        return np.zeros((0, 36), np.float32)
    S = np.stack([seg[e - SEQ:e] for e in ends]).copy()
    S[..., 6] -= np.median(S[..., 6], axis=1, keepdims=True)
    t = np.linspace(-1, 1, SEQ)[None, :, None]
    slope = (S * t).mean(1) / (t ** 2).mean()
    return np.concatenate([S.mean(1), S.std(1), slope], 1).astype(np.float32)

def alarm_onsets(p, thr, k=3, n=5):
    hist, quiet, onsets = [], 0, []
    for i, v in enumerate(p):
        hist = (hist + [v >= thr])[-n:]
        if quiet > 0:
            quiet -= 1; continue
        if sum(hist) >= k:
            onsets.append(i); quiet = REFRACT; hist = []
    return onsets
""")

md("## 4. التدريب والاختبار لكل مريض (اترك نوبة خارجًا)")
code(r"""
MODELS = {
    'logistic': lambda: make_pipeline(StandardScaler(), LogisticRegression(
        C=0.1, class_weight='balanced', max_iter=2000)),
    'boosting': lambda: HistGradientBoostingClassifier(
        max_depth=3, max_iter=150, learning_rate=0.05, l2_regularization=1.0,
        class_weight='balanced', random_state=SEED),
}

def fit(kind, pre_segs, inter_blocks):
    Xp = [seq_feats(s, EVAL_EVERY) for s in pre_segs]
    Xi = [seq_feats(b, INTER_STRIDE) for b in inter_blocks]
    X = np.concatenate(Xp + Xi); y = np.r_[np.ones(sum(map(len, Xp))), np.zeros(sum(map(len, Xi)))]
    if y.min() == y.max():
        raise ValueError('only one class in training data')
    return MODELS[kind]().fit(X, y)

def score(m, seg):
    X = seq_feats(seg, EVAL_EVERY)
    return m.predict_proba(X)[:, 1] if len(X) else np.zeros(0)

def choose_threshold(kind, pre_segs, inter_blocks):
    # Inner cross-validation on TRAINING data only: hold out each training seizure
    # and an interleaved share of inter-ictal blocks, collect out-of-fold scores,
    # then take the most sensitive threshold within the false-alarm target.
    K = len(pre_segs)
    pre_scores, inter_scores, hours = [], [], 0.0
    for k in range(K):
        tr_pre = [s for i, s in enumerate(pre_segs) if i != k]
        te_inter = inter_blocks[k::K]; tr_inter = [b for i, b in enumerate(inter_blocks) if i % K != k]
        if not tr_inter or not te_inter:
            continue
        m = fit(kind, tr_pre, tr_inter)
        pre_scores.append(score(m, pre_segs[k]))
        inter_scores += [score(m, b) for b in te_inter]; hours += sum(len(b) for b in te_inter) / 3600
    best = 0.99
    for thr in np.round(np.arange(0.99, 0.29, -0.01), 2):
        fph = sum(len(alarm_onsets(s, thr)) for s in inter_scores) / max(hours, 1e-9)
        if fph <= TARGET_FALSE_PER_HOUR:
            best = float(thr)
        else:
            break
    return best

def run_patient(p, kind):
    pre, inter = load(p)
    inter_b = blocks(inter)
    inter_h = sum(len(b) for b in inter_b) / 3600
    if len(pre) < MIN_SEIZURES:
        return {'patient': p, 'model': kind, 'skipped': f'only {len(pre)} usable seizures (need {MIN_SEIZURES})'}
    if inter_h < MIN_INTER_HOURS:
        return {'patient': p, 'model': kind, 'skipped': f'only {inter_h:.1f} h inter-ictal'}
    K = len(pre)
    # contiguous groups of blocks per fold (less leakage than interleaving)
    groups = np.array_split(np.arange(len(inter_b)), K)
    warned, false, hours, thrs = 0, 0, 0.0, []
    for k in range(K):
        te_idx = set(groups[k].tolist())
        tr_pre = [s for i, s in enumerate(pre) if i != k]
        tr_inter = [b for i, b in enumerate(inter_b) if i not in te_idx]
        te_inter = [inter_b[i] for i in sorted(te_idx)]
        thr = choose_threshold(kind, tr_pre, tr_inter); thrs.append(thr)
        m = fit(kind, tr_pre, tr_inter)
        warned += bool(alarm_onsets(score(m, pre[k]), thr))
        false += sum(len(alarm_onsets(score(m, b), thr)) for b in te_inter)
        hours += sum(len(b) for b in te_inter) / 3600
    fph = false / max(hours, 1e-9)
    chance = float(1 - np.exp(-fph * PRE_MIN / 60))      # random alarm, same rate
    pval = float(binomtest(warned, K, min(max(chance, 1e-6), 1 - 1e-6), alternative='greater').pvalue)
    return {'patient': p, 'model': kind, 'seizures': K, 'warned': warned,
            'sensitivity': round(warned / K, 3), 'false_warnings_per_hour': round(fph, 3),
            'interictal_hours': round(hours, 1), 'chance_sensitivity': round(chance, 3),
            'p_value': round(pval, 4), 'beats_chance': bool(pval < 0.05 and warned / K > chance),
            'thresholds': thrs}

patients = sorted(f.stem for f in CACHE.glob('chb*.npz'))
for p in patients:
    for kind in MODELS:
        f = RESULTS / f'{p}_{kind}.json'
        if f.exists():
            continue                                   # resume after a disconnect
        t0 = time.time()
        try:
            r = run_patient(p, kind)
        except Exception as e:                         # one patient never stops the run
            r = {'patient': p, 'model': kind, 'error': f'{type(e).__name__}: {e}',
                 'trace': traceback.format_exc()[-1500:]}
        r['seconds'] = round(time.time() - t0, 1)
        f.write_text(json.dumps(r, indent=1))
        print(p, kind, {k: r.get(k) for k in ('sensitivity', 'false_warnings_per_hour',
                                             'chance_sensitivity', 'p_value', 'skipped', 'error')})
""")

md("## 5. الخلاصة الصادقة")
code(r"""
rows = [json.loads(f.read_text()) for f in sorted(RESULTS.glob('*.json'))]
summary = {}
for kind in MODELS:
    ok = [r for r in rows if r['model'] == kind and 'sensitivity' in r]
    if not ok:
        summary[kind] = {'patients_evaluated': 0}; continue
    sz = sum(r['seizures'] for r in ok); w = sum(r['warned'] for r in ok)
    hrs = sum(r['interictal_hours'] for r in ok)
    fph = sum(r['false_warnings_per_hour'] * r['interictal_hours'] for r in ok) / max(hrs, 1e-9)
    chance = float(1 - np.exp(-fph * PRE_MIN / 60))
    summary[kind] = {
        'patients_evaluated': len(ok),
        'patients_beating_chance': sum(r['beats_chance'] for r in ok),
        'seizures': sz, 'warned': w, 'sensitivity': round(w / sz, 3),
        'false_warnings_per_hour': round(fph, 3), 'chance_sensitivity': round(chance, 3),
        'p_value_pooled': round(float(binomtest(w, sz, min(max(chance, 1e-6), 1 - 1e-6),
                                                alternative='greater').pvalue), 5),
        'beats_chance_patients': [r['patient'] for r in ok if r['beats_chance']],
    }
skipped = {r['patient']: r.get('skipped') or r.get('error') for r in rows if 'sensitivity' not in r}
report = {'summary': summary, 'skipped_or_failed': skipped, 'per_patient': rows,
          'settings': {'seq_s': SEQ, 'eval_every_s': EVAL_EVERY, 'block_min': BLOCK_MIN,
                       'target_false_per_hour': TARGET_FALSE_PER_HOUR, 'refractory_min': REFRACTORY_MIN},
          'notes': 'Leave-one-seizure-out per patient; thresholds chosen by inner CV on training data only; '
                   'chance = random alarms at the same false-alarm rate (Poisson), one-sided binomial test.'}
(OUT / 'personal_report.json').write_text(json.dumps(report, indent=1))
print(json.dumps(summary, indent=1))
print('skipped/failed:', skipped)
ZIP = WORK / 'preictal_personal_outputs.zip'
with zipfile.ZipFile(ZIP, 'w') as z:
    z.write(OUT / 'personal_report.json', 'personal_report.json')
    for f in RESULTS.glob('*.json'):
        z.write(f, 'per_patient/' + f.name)
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
out = Path(__file__).resolve().parent / "colab_preictal_personal.ipynb"
out.write_text(json.dumps(nb, ensure_ascii=False, indent=1), encoding="utf-8")
print("wrote", out)
