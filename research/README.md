# مسار أبحاث ونماذج الذكاء الاصطناعي (AI Research & Dual-Model Engine)
## النظام الهجين المزدوج لكشف والتنبؤ بنوبات الصرع (Dual-Model Hybrid AI System)

> 🔬 **الملخص التنفيذي:**
> يحتوي هذا المجلد على خط الأنابيب البحثي الكامل لتدريب وتقييم نموذجي الذكاء الاصطناعي المطورين من الصفر بلغة **PyTorch**:
> 1. **النموذج الطرفي للهاتف (`EdgeSeizureNet`):** لكشف النوبة اللحظي داخل التطبيق بدون إنترنت (Offline).
> 2. **النموذج السحابي العميق (`CloudPreictalNet`):** للتنبؤ المسبق بالنوبة (15-30 دقيقة) وتصفية الإنذارات الكاذبة (Online).

---

## 1. المعمارية الهجينة المزدوجة (Dual-Model Architecture)

```
                              ┌────────────────────────────────────────────────────────┐
                              │                 إشارات المريض الحيوية                 │
                              │          (EEG + ECG + Motion + Heart Rate)             │
                              └──────────────────────────┬─────────────────────────────┘
                                                         │
                                ┌────────────────────────┴────────────────────────┐
                                │                                                 │
                                ▼                                                 ▼
        ┌──────────────────────────────────────────────┐  ┌──────────────────────────────────────────────┐
        │   📱 نموذج الهاتف المحلي (Offline Edge)       │  │   ☁️ نموذج السحابة المتقدم (Online Cloud)     │
        │             [EdgeSeizureNet]                 │  │             [CloudPreictalNet]               │
        ├──────────────────────────────────────────────┤  ├──────────────────────────────────────────────┤
        │ • المعمارية: 3-Layer Conv1D + BiLSTM         │  │ • المعمارية: Multi-Scale Conv1D + Self-Attn  │
        │ • الهدف: كشف النوبة الفوري (Ictal Detection) │  │ • الهدف: التنبؤ المبكر (15-30 min Preictal)  │
        │ • قاعدة البيانات: Bonn Dataset (Real EEG)    │  │ • قاعدة البيانات: CHB-MIT Preictal Benchmark │
        │ • الحجم: 205 KB (ONNX FP32)                  │  │ • الحجم: 412 KB (PyTorch State Dict / ONNX)  │
        │ • زمن التنفيذ: < 2 ms على معالج الهاتف       │  │ • الموثوقية: استدلال عميق متعدد المستشعرات  │
        │ • الحساسية (Sensitivity): 94.20%             │  │ • الحساسية (Sensitivity): 100.0%             │
        │ • النوعية (Specificity): 92.68%              │  │ • النوعية (Specificity): 99.89%              │
        └──────────────────────┬───────────────────────┘  └──────────────────────┬───────────────────────┘
                               │                                                 │
                               └────────────────────────┬────────────────────────┘
                                                        │
                                                        ▼
                                    ┌───────────────────────────────────────┐
                                    │    🤝 بوابة الدمج المشترك الهجينة     │
                                    │      (Dual Ensemble Stacking Gate)    │
                                    │    P_fusion = max(P_cloud, 0.6*P_c    │
                                    │                + 0.4*P_edge)          │
                                    ├───────────────────────────────────────┤
                                    │ • الحساسية الكلية: 100.0%             │
                                    │ • النوعية الكلية: 100.0%              │
                                    │ • عتبة القرار المثلى (Youden J): 0.60 │
                                    └───────────────────────────────────────┘
```

---

## 2. بنية المجلد والملفات (Directory Structure)

```
research/
├── DEFENSE_GUIDE_AR.md           # دليل الأسئلة والأجوبة النموذجية لمناقشة التخرج 🎓
├── colab_seizure_detection.ipynb  # دفتر Google Colab التفاعلي للتدريب السحابي على GPU
├── train_seizure_cloud.py        # سكربت التدريب المستقل (Python Standalone Script)
├── build_notebook.py             # سكربت توليد وتحديث دفتر Colab آلياً
├── requirements-research.txt     # متطلبات بيئة التدريب والبحث (PyTorch, SciPy, etc.)
├── models/                       # أوزان النماذج والإعدادات الناتجة:
│   ├── dual_model_config.json    # ملف المقاييس وإعدادات الدمج الشاملة
│   ├── edge_seizure_model.onnx   # نموذج الهاتف بصيغة ONNX (مضمّن بتطبيق الموبايل)
│   ├── edge_seizure_model.pt     # أوزان نموذج الهاتف بصيغة PyTorch
│   ├── cloud_preictal_model.pt   # أوزان النموذج السحابي بصيغة PyTorch
│   └── cloud_preictal_model.onnx # النموذج السحابي بصيغة ONNX
├── scripts/                      # أدوات معالجة البيانات وتقسيم التسجيلات السريرية:
│   ├── download_data.py          # تنزيل قواعد البيانات المفتوحة
│   ├── bonn_prep.py              # معالجة وتقطيع بيانات Bonn
│   ├── edf_prep.py               # قراءة ملفات EDF وتحويلها
│   ├── harmonize.py              # توحيد التردد (256Hz) والترشيح (0.5-40Hz)
│   ├── splits.py                 # تقسيم المرضى (Patient-wise Split) لمنع تسريب البيانات
│   └── windows.py                # استخراج النوافذ الزمنية
└── results/                      # تقارير ومصفوفات الالتباس
```

---

## 3. كيفية التدريب وتشغيل التجارب (How to Train)

### الخيار أ: التدريب السحابي عبر Google Colab (موصى به)
1. افتح [Google Colab](https://colab.research.google.com/).
2. ارفع الدفتر: [`research/colab_seizure_detection.ipynb`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/research/colab_seizure_detection.ipynb).
3. اختر نوع البيئة: `Runtime` ← `Change runtime type` ← `T4 GPU`.
4. شغّل الخلايا بالتسلسل؛ سيقوم الدفتر بـ:
   - تنزيل ومعالجة البيانات السريرية وتوليد النوافذ الزمنية.
   - بناء معماريات `EdgeSeizureNet` و `CloudPreictalNet` من الصفر.
   - التدريب بدالة `Focal Loss` وموازنة الفئات.
   - تصدير الأوزان بصيغتي `pt` و `onnx` وتحميلها كملف مضغوط.

### الخيار ب: التدريب المحلي أو عبر سطر الأوامر (Standalone Python)
```bash
cd research
pip install -r requirements-research.txt
python train_seizure_cloud.py
```

---

## 4. التكامل مع بيئات التشغيل (System Integration)

* **داخل تطبيق الموبايل (`mobile/`):**
  * تم نسخ `edge_seizure_model.onnx` و `dual_model_config.json` إلى:
    [`mobile/assets/models/`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/mobile/assets/models/)
  * تتولى خدمة [`mobile/lib/services/edge_model_service.dart`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/mobile/lib/services/edge_model_service.dart) استدعاء النموذج محلياً عند انقطاع الإنترنت لحماية المريض.

* **داخل خادم الـ Backend (`backend/`):**
  * تم نسخ `cloud_preictal_model.pt` و `cloud_preictal_model.meta.json` إلى:
    [`backend/models/`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/backend/models/)
  * يتولى محرك [`backend/app/ml/preictal_model.py`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/backend/app/ml/preictal_model.py) و [`backend/app/ml/classifier.py`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/backend/app/ml/classifier.py) تشغيل النموذج السحابي مع حساب وقت الأمان التنازلي قبل النوبة.

---

## 5. دليل مناقشة التخرج
للاطلاع على الأسئلة المتوقعة من لجنة التحكيم الأكاديمية وإجاباتها النموذجية العلمية، راجع:
👉 **[`research/DEFENSE_GUIDE_AR.md`](file:///c:/Users/tc/AndroidStudioProjects/epilepsy_graduation_project/research/DEFENSE_GUIDE_AR.md)**
