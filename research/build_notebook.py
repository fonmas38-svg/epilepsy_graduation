#!/usr/bin/env python3
"""
Generator script to build the complete Dual-Model Colab Notebook:
research/colab_seizure_detection.ipynb

Features:
- Full comprehensive ARABIC explanations in all Markdown cells (الشرح والمفاهيم ونقاط المناقشة بالعربية بالكامل).
- ENGLISH ONLY inside Matplotlib plots (labels, titles, legends, confusion matrix ticks) to prevent text distortion/disconnection in Colab.
- Auto-install onnx and onnxscript to prevent ModuleNotFoundError.
"""

import json
from pathlib import Path

def make_cell(cell_type, source_lines):
    return {
        "cell_type": cell_type,
        "metadata": {},
        "source": [line + "\n" for line in source_lines] if isinstance(source_lines, list) else [source_lines + "\n"],
        **({"outputs": [], "execution_count": None} if cell_type == "code" else {})
    }

cells = []

# =============================================================================
# الغلاف والعنوان الرئيسي (باللغة العربية)
# =============================================================================
cells.append(make_cell("markdown", '# تجربة بحثية لكشف أنماط EEG\n\nA: مقاطع Bonn حقيقية لكشف النوبة الجارية. B: موجات صناعية مولدة، وليست CHB-MIT ولا تسجيلات مرضى. لا يثبت هذا الدفتر التنبؤ بنوبة مستقبلية أو صلاحية الاستخدام الطبي. تطبيق الهاتف الحالي ينفذ قواعد تجريبية ولا يشغّل أوزان ONNX. لا توجد نسبة دقة مضمونة.'))

# =============================================================================
# القسم 0 — تجهيز البيئة وتثبيت المكتبات
# =============================================================================
cells.append(make_cell("markdown", '## 0 — إعداد بيئة البحث\nهذه الخلية تثبت مكتبات بيئة كولاب عند تشغيلها يدويًا.'))

cells.append(make_cell("code", [
    "# تثبيت المكتبات والتأكد من توفر onnx و onnxscript لتفادي أخطاء التصدير في Colab",
    "import subprocess, sys",
    "for pkg in ['numpy', 'pandas', 'scipy', 'matplotlib', 'torch', 'onnx', 'onnxscript']:",
    "    subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', pkg])",
    "",
    "import os, json, time, urllib.request",
    "from pathlib import Path",
    "import numpy as np",
    "import pandas as pd",
    "from scipy import signal",
    "import matplotlib.pyplot as plt",
    "import torch",
    "import torch.nn as nn",
    "from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler",
    "",
    "# ضبط الخطوط اللاتينية النقية لمنع أي تشوه في رسومات Matplotlib",
    "plt.rcParams['font.sans-serif'] = 'DejaVu Sans'",
    "plt.rcParams['axes.unicode_minus'] = False",
    "",
    "# تثبيت البذرة العشوائية لضمان التكرارية العلمية في المناقشة (Reproducibility)",
    "SEED = 42",
    "np.random.seed(SEED)",
    "torch.manual_seed(SEED)",
    "if torch.cuda.is_available():",
    "    torch.cuda.manual_seed_all(SEED)",
    "",
    "DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')",
    "print(f'✅ جهاز الحساب المتاح: {DEVICE}')",
    "if DEVICE.type == 'cuda':",
    "    print(f'⚡ اسم بطاقة الرسوميات السحابية: {torch.cuda.get_device_name(0)}')",
    "print('تم تجهيز البيئة بنجاح ✓')"
]))

# =============================================================================
# القسم 1 — قاعدة البيانات الأولى A (Bonn) للنموذج المحلي
# =============================================================================
cells.append(make_cell("markdown", '## 1 — بيانات Bonn\nتستخدم لمهمة الكشف داخل النافذة؛ لا تحوي أوقات بدء نوبات متصلة لتقييم التنبؤ.'))

cells.append(make_cell("code", [
    "DATA_DIR = Path('data')",
    "DATA_DIR.mkdir(exist_ok=True)",
    "BONN_CSV = DATA_DIR / 'bonn_epilepsy.csv'",
    "BONN_URL = 'https://raw.githubusercontent.com/xterm99/kaggle-epileptic-seizure-recognition/main/data/Epileptic%20Seizure%20Recognition.csv'",
    "",
    "if not BONN_CSV.exists() or BONN_CSV.stat().st_size < 1_000_000:",
    "    print('⬇️ جاري تنزيل قاعدة بيانات Bonn من السحابة...')",
    "    req = urllib.request.Request(BONN_URL, headers={'User-Agent': 'Mozilla/5.0'})",
    "    with urllib.request.urlopen(req, timeout=120) as resp:",
    "        BONN_CSV.write_bytes(resp.read())",
    "    print(f'✅ تم تنزيل البيانات بنجاح: {BONN_CSV.stat().st_size / 1024 / 1024:.2f} MB')",
    "else:",
    "    print('الملف موجود مسبقاً في الذاكرة السحابية ✓')",
    "",
    "df_A = pd.read_csv(BONN_CSV)",
    "print(f'أبعاد البيانات A: {df_A.shape[0]:,} صف × {df_A.shape[1]} عمود') ",
    "print('توزيع الفئات الأصلية:', df_A.iloc[:, -1].value_counts().to_dict())"
]))

# =============================================================================
# القسم 2 — أنبوب معالجة الإشارة الرقمية (DSP) وعرض الإشارة
# =============================================================================
cells.append(make_cell("markdown", '## 2 — معالجة إشارة Bonn\nإعادة أخذ العينات والترشيح وتطبيع النافذة. تقسيم مجموعات التسجيل لا يثبت استقلال المرضى البيولوجيين.'))

cells.append(make_cell("code", [
    "TARGET_FS = 256",
    "BONN_FS = 173.61",
    "",
    "id_col = df_A.columns[0]",
    "label_col = df_A.columns[-1]",
    "feat_cols = df_A.columns[1:-1]",
    "",
    "raw_X_A = df_A[feat_cols].to_numpy(dtype=np.float64)",
    "raw_y_A = (df_A[label_col].to_numpy() == 1).astype(np.int64)",
    "",
    "# تجميع مقاطع التسجيل نفسه؛ هوية المريض غير متاحة",
    "def extract_recording_group(row_id):",
    "    parts = str(row_id).split('.')",
    "    return parts[2] if len(parts) > 2 else parts[-1]",
    "",
    "g_keys_A = df_A[label_col].astype(str) + '_' + df_A[id_col].map(extract_recording_group).astype(str)",
    "u_groups_A = {k: idx for idx, k in enumerate(sorted(g_keys_A.unique()))}",
    "groups_A = g_keys_A.map(u_groups_A).to_numpy(dtype=np.int32)",
    "",
    "processed_X_A, processed_y_A, processed_g_A = [], [], []",
    "for i in range(len(raw_X_A)):",
    "    sig = raw_X_A[i:i+1, :]",
    "    n_out = int(round(sig.shape[-1] * TARGET_FS / BONN_FS))",
    "    sig_resampled = signal.resample(sig, n_out, axis=-1)",
    "    # مرشح تمرير نطاق Butterworth 0.5-40Hz",
    "    sos = signal.butter(4, [0.5 / (TARGET_FS/2), 40.0 / (TARGET_FS/2)], btype='bandpass', output='sos')",
    "    clean = signal.sosfiltfilt(sos, sig_resampled, axis=-1)",
    "    clean = (clean - clean.mean()) / (clean.std() + 1e-8)",
    "    if np.max(np.abs(clean)) > 500.0 or np.std(clean) < 1e-6:",
    "        continue",
    "    processed_X_A.append(clean.astype(np.float32))",
    "    processed_y_A.append(raw_y_A[i])",
    "    processed_g_A.append(groups_A[i])",
    "",
    "win_len = min(x.shape[-1] for x in processed_X_A)",
    "X_A = np.stack([x[:, :win_len] for x in processed_X_A]).astype(np.float32)",
    "y_A = np.asarray(processed_y_A, dtype=np.int64)",
    "g_A = np.asarray(processed_g_A, dtype=np.int32)",
    "",
    "print(f'✅ تم تجهيز بيانات A: {X_A.shape[0]:,} مقطع بطول {win_len} نقطة (تردد {TARGET_FS}Hz)')",
    "print(f'   مقاطع نوبات (إيجابي): {y_A.sum():,} | مقاطع سليمة (سلبي): {(y_A==0).sum():,}')"
]))

# عرض الإشارة قبل وبعد المعالجة (تسميات إنجليزية لمنع التقطع)
cells.append(make_cell("code", [
    "# مقارنة بصرية للإشارة قبل وبعد المعالجة (نصوص إنجليزية واضحة)",
    "sample_idx = np.where(raw_y_A == 1)[0][0]",
    "raw_example = raw_X_A[sample_idx]",
    "clean_example = X_A[sample_idx, 0]",
    "",
    "fig, axes = plt.subplots(1, 2, figsize=(14, 4))",
    "axes[0].plot(raw_example, color='#d63031', linewidth=1.2)",
    "axes[0].set_title('Raw EEG Signal (Seizure Episode)', fontsize=13, fontweight='bold')",
    "axes[0].set_xlabel('Sample Index (Original 173.6 Hz)', fontsize=11)",
    "axes[0].set_ylabel('Amplitude (uV)', fontsize=11)",
    "axes[0].grid(True, alpha=0.3)",
    "",
    "axes[1].plot(clean_example, color='#0984e3', linewidth=1.2)",
    "axes[1].set_title('Preprocessed EEG (256 Hz Bandpass + Z-Score)', fontsize=13, fontweight='bold')",
    "axes[1].set_xlabel('Sample Index (Resampled 256 Hz)', fontsize=11)",
    "axes[1].set_ylabel('Normalized Amplitude (Z-Score)', fontsize=11)",
    "axes[1].grid(True, alpha=0.3)",
    "",
    "plt.tight_layout()",
    "plt.show()"
]))

# =============================================================================
# القسم 3 — قاعدة البيانات الثانية B (Preictal Benchmark) للنموذج السحابي
# =============================================================================
cells.append(make_cell("markdown", '## 3 — بيانات B الصناعية\nمولد موجات رياضي لاختبار التدريب والتصدير. أرقام المجموعات صناعية وليست معرفات مرضى. النتائج على هذه البيانات ليست دقة سريرية ولا مهلة إنذار.'))

cells.append(make_cell("code", [
    "def generate_dataset_b_preictal(win_len, n_samples=6000):",
    "    np.random.seed(123)",
    "    t = np.arange(win_len) / 256.0",
    "    X_list, y_list, g_list = [], [], []",
    "    for i in range(n_samples):",
    "        synthetic_group = i % 15 # artificial groups, not patients",
    "        is_preictal = 1 if (i % 4 == 0) else 0 # عدم توازن سريري واقعي 1:3",
    "        eeg = (0.5 * np.sin(2 * np.pi * 10.0 * t + np.random.uniform(0, 2*np.pi)) +",
    "               0.3 * np.sin(2 * np.pi * 20.0 * t) + 0.4 * np.random.randn(win_len))",
    "        if is_preictal:",
    "            slow_surge = 1.2 * np.sin(2 * np.pi * 3.5 * t + np.random.uniform(0, 2*np.pi))",
    "            spikes = np.zeros(win_len)",
    "            locs = np.random.choice(win_len, size=5, replace=False)",
    "            spikes[locs] = np.random.choice([-1, 1], size=5) * np.random.uniform(2.5, 4.0, size=5)",
    "            eeg = eeg + slow_surge + spikes",
    "        eeg = (eeg - eeg.mean()) / (eeg.std() + 1e-8)",
    "        X_list.append(eeg.reshape(1, win_len).astype(np.float32))",
    "        y_list.append(is_preictal)",
    "        g_list.append(synthetic_group)",
    "    return np.stack(X_list).astype(np.float32), np.asarray(y_list, dtype=np.int64), np.asarray(g_list, dtype=np.int32)",
    "",
    "X_B, y_B, g_B = generate_dataset_b_preictal(win_len=win_len)",
    "print(f'✅ تم تجهيز بيانات B المستقلة: {X_B.shape[0]:,} عينة')",
    "print(f'   طور ما قبل النوبة (Preictal): {y_B.sum():,} | طور طبيعي (Interictal): {(y_B==0).sum():,}')"
]))

# =============================================================================
# القسم 4 — بناء المعماريات العصبية من الصفر
# =============================================================================
cells.append(make_cell("markdown", '## 4 — الشبكات\nبناء EdgeSeizureNet وCloudPreictalNet. الاسم المعماري لا يثبت المهمة الطبية.'))

cells.append(make_cell("code", [
    "class EdgeSeizureNet(nn.Module):",
    "    '''النموذج المحلي فائق الخفة للهاتف (Offline Mode) مع الحفاظ على الترددات الصرعية.'''",
    "    def __init__(self, in_ch=1, n_classes=2):",
    "        super().__init__()",
    "        self.features = nn.Sequential(",
    "            nn.Conv1d(in_ch, 32, kernel_size=7, padding=3),",
    "            nn.BatchNorm1d(32),",
    "            nn.ReLU(),",
    "            nn.MaxPool1d(2),",
    "            nn.Conv1d(32, 64, kernel_size=5, padding=2),",
    "            nn.BatchNorm1d(64),",
    "            nn.ReLU(),",
    "            nn.MaxPool1d(2),",
    "            nn.Conv1d(64, 64, kernel_size=3, padding=1),",
    "            nn.BatchNorm1d(64),",
    "            nn.ReLU(),",
    "            nn.MaxPool1d(2),",
    "        )",
    "        self.lstm = nn.LSTM(64, 32, batch_first=True, bidirectional=True)",
    "        self.classifier = nn.Sequential(",
    "            nn.Dropout(0.25),",
    "            nn.Linear(64, 32),",
    "            nn.ReLU(),",
    "            nn.Linear(32, n_classes),",
    "        )",
    "    def forward(self, x):",
    "        z = self.features(x).transpose(1, 2)",
    "        out, _ = self.lstm(z)",
    "        return self.classifier(out.mean(dim=1))",
    "",
    "class CloudPreictalNet(nn.Module):",
    "    '''النموذج السحابي عالي السعة مع Self-Attention و BiLSTM للتنبؤ المسبق.'''",
    "    def __init__(self, in_ch=1, n_classes=2, hidden_dim=64, num_heads=4):",
    "        super().__init__()",
    "        self.c1 = nn.Conv1d(in_ch, 24, kernel_size=3, padding=1)",
    "        self.c2 = nn.Conv1d(in_ch, 24, kernel_size=5, padding=2)",
    "        self.c3 = nn.Conv1d(in_ch, 24, kernel_size=7, padding=3)",
    "        self.bn = nn.BatchNorm1d(72)",
    "        self.relu = nn.ReLU()",
    "        self.pool = nn.MaxPool1d(2)",
    "        self.attn = nn.MultiheadAttention(embed_dim=72, num_heads=num_heads, batch_first=True)",
    "        self.lstm = nn.LSTM(72, hidden_dim, batch_first=True, bidirectional=True)",
    "        self.head = nn.Sequential(",
    "            nn.Dropout(0.3),",
    "            nn.Linear(hidden_dim * 2, 64),",
    "            nn.ReLU(),",
    "            nn.Dropout(0.3),",
    "            nn.Linear(64, n_classes)",
    "        )",
    "    def forward(self, x):",
    "        z = torch.cat([self.c1(x), self.c2(x), self.c3(x)], dim=1)",
    "        z = self.pool(self.relu(self.bn(z)))",
    "        z_t = z.transpose(1, 2)",
    "        attn_out, _ = self.attn(z_t, z_t, z_t)",
    "        lstm_out, _ = self.lstm(attn_out)",
    "        return self.head(lstm_out.mean(dim=1))",
    "",
    "edge_model = EdgeSeizureNet(in_ch=1).to(DEVICE)",
    "cloud_model = CloudPreictalNet(in_ch=1).to(DEVICE)",
    "print(f'🔹 عدد معاملات نموذج الهاتف (EdgeSeizureNet): {sum(p.numel() for p in edge_model.parameters()):,} معامل')",
    "print(f'🔹 عدد معاملات النموذج السحابي (CloudPreictalNet): {sum(p.numel() for p in cloud_model.parameters()):,} معامل')"
]))

# =============================================================================
# القسم 5 — دالة Focal Loss ومقاييس التقييم السريري
# =============================================================================
cells.append(make_cell("markdown", '## 5 — الخسارة والتقسيم\nفصل مجموعات التدريب والتحقق والاختبار. تستخدم الموازنة بالعينات مرة واحدة لتجنب مضاعفة وزن الأقلية.'))

cells.append(make_cell("code", [
    "class FocalLoss(nn.Module):",
    "    def __init__(self, alpha=None, gamma=2.0):",
    "        super().__init__()",
    "        self.gamma = gamma",
    "        self.alpha = alpha",
    "    def forward(self, logits, target):",
    "        ce = nn.functional.cross_entropy(logits, target, weight=self.alpha, reduction='none')",
    "        pt = torch.exp(-ce)",
    "        return (((1.0 - pt) ** self.gamma) * ce).mean()",
    "",
    "class FastDataset(Dataset):",
    "    def __init__(self, X, y):",
    "        self.X = torch.from_numpy(np.ascontiguousarray(X)).float()",
    "        self.y = torch.from_numpy(np.ascontiguousarray(y)).long()",
    "    def __len__(self): return len(self.y)",
    "    def __getitem__(self, i): return self.X[i], self.y[i]",
    "",
    "def clinical_metrics(y_true, y_prob, threshold=0.5):",
    "    y_pred = (y_prob >= threshold).astype(int)",
    "    tp = int(((y_pred == 1) & (y_true == 1)).sum())",
    "    fn = int(((y_pred == 0) & (y_true == 1)).sum())",
    "    fp = int(((y_pred == 1) & (y_true == 0)).sum())",
    "    tn = int(((y_pred == 0) & (y_true == 0)).sum())",
    "    sens = tp / (tp + fn) if (tp + fn) > 0 else 0.0",
    "    spec = tn / (tn + fp) if (tn + fp) > 0 else 0.0",
    "    return {'sensitivity': sens, 'specificity': spec, 'tp': tp, 'fn': fn, 'fp': fp, 'tn': tn}",
    "",
    "def split_data(groups, ratios=(0.7, 0.15, 0.15), seed=42):",
    "    uniq = np.unique(groups)",
    "    np.random.default_rng(seed).shuffle(uniq)",
    "    n = len(uniq)",
    "    tr_g, va_g, te_g = uniq[:int(0.7*n)], uniq[int(0.7*n):int(0.85*n)], uniq[int(0.85*n):]",
    "    return np.isin(groups, tr_g), np.isin(groups, va_g), np.isin(groups, te_g)"
]))

# =============================================================================
# القسم 6 — التدريب العملي للنموذجين مع موازنة الفئات الصارمة
# =============================================================================
cells.append(make_cell("markdown", '## 6 — التدريب البحثي\nتدريب A للكشف وتدريب B الصناعي مع A. لا يمكن تفسير المهمة المختلطة كإثبات توقع النوبات.'))

cells.append(make_cell("code", [
    "# تدريب نموذج الهاتف مع موازنة الفئات الصارمة لمنع تفويت النوبات",
    "tr_A, va_A, te_A = split_data(g_A, seed=SEED)",
    "",
    "# حساب أوزان الفئات لموازنة دالة الخسارة Focal Loss",
    "c_counts_A = np.bincount(y_A[tr_A])",
    "w_A = torch.tensor([len(y_A[tr_A]) / (2.0 * c_counts_A[0]), len(y_A[tr_A]) / (2.0 * c_counts_A[1])], dtype=torch.float32, device=DEVICE)",
    "loss_fn_A = FocalLoss(alpha=None, gamma=2.0)",
    "",
    "# معاين عشوائي موزون يسحب 50% نوبات و 50% سليم في كل دفعة",
    "s_w_A = np.array([1.0 / c_counts_A[int(c)] for c in y_A[tr_A]])",
    "sampler_A = WeightedRandomSampler(s_w_A, len(s_w_A), replacement=True)",
    "",
    "loader_tr_A = DataLoader(FastDataset(X_A[tr_A], y_A[tr_A]), batch_size=128, sampler=sampler_A)",
    "loader_va_A = DataLoader(FastDataset(X_A[va_A], y_A[va_A]), batch_size=128, shuffle=False)",
    "loader_te_A = DataLoader(FastDataset(X_A[te_A], y_A[te_A]), batch_size=128, shuffle=False)",
    "",
    "opt_edge = torch.optim.AdamW(edge_model.parameters(), lr=1.5e-3, weight_decay=1e-4)",
    "edge_history = []",
    "best_edge_j, best_edge_state = -1.0, None",
    "",
    "print('🚀 [1/2] بدء تدريب نموذج الهاتف المحلي (EdgeSeizureNet) مع المعاينة المتوازنة...')",
    "for ep in range(1, 10):",
    "    edge_model.train()",
    "    tr_loss = 0.0",
    "    for xb, yb in loader_tr_A:",
    "        xb, yb = xb.to(DEVICE), yb.to(DEVICE)",
    "        opt_edge.zero_grad()",
    "        loss = loss_fn_A(edge_model(xb), yb)",
    "        loss.backward(); opt_edge.step()",
    "        tr_loss += loss.item() * len(yb)",
    "    tr_loss /= len(loader_tr_A.dataset)",
    "",
    "    edge_model.eval()",
    "    va_loss, p_list, y_list = 0.0, [], []",
    "    with torch.no_grad():",
    "        for xb, yb in loader_va_A:",
    "            xb, yb = xb.to(DEVICE), yb.to(DEVICE)",
    "            out = edge_model(xb)",
    "            va_loss += loss_fn_A(out, yb).item() * len(yb)",
    "            p_list.append(torch.softmax(out, 1)[:, 1].cpu().numpy())",
    "            y_list.append(yb.cpu().numpy())",
    "    va_loss /= len(loader_va_A.dataset)",
    "    m = clinical_metrics(np.concatenate(y_list), np.concatenate(p_list), threshold=0.5)",
    "    j = m['sensitivity'] + m['specificity'] - 1.0",
    "    edge_history.append({'epoch': ep, 'train_loss': tr_loss, 'val_loss': va_loss, **m})",
    "    print(f'Edge Epoch [{ep}/9] | Loss: {tr_loss:.4f}/{va_loss:.4f} | Sens: {m[\"sensitivity\"]*100:.1f}% | Spec: {m[\"specificity\"]*100:.1f}% | Youden-J: {j:.3f}')",
    "    if j > best_edge_j:",
    "        best_edge_j = j",
    "        best_edge_state = {k: v.cpu().clone() for k, v in edge_model.state_dict().items()}",
    "",
    "edge_model.load_state_dict(best_edge_state)",
    "print('✅ اكتمل تدريب نموذج الهاتف بنجاح.')"
]))

# تدريب النموذج السحابي مع موازنة الفئات
cells.append(make_cell("code", [
    "# تدريب النموذج السحابي على بيانات B مع دمج بيانات A للتعميم والموازنة",
    "tr_B, va_B, te_B = split_data(g_B, seed=SEED)",
    "Xtr_Cloud = np.concatenate([X_B[tr_B], X_A[tr_A][:len(X_B[tr_B])]], axis=0)",
    "ytr_Cloud = np.concatenate([y_B[tr_B], y_A[tr_A][:len(y_B[tr_B])]], axis=0)",
    "",
    "c_counts_Cloud = np.bincount(ytr_Cloud)",
    "w_Cloud = torch.tensor([len(ytr_Cloud) / (2.0 * c_counts_Cloud[0]), len(ytr_Cloud) / (2.0 * c_counts_Cloud[1])], dtype=torch.float32, device=DEVICE)",
    "loss_fn_B = FocalLoss(alpha=None, gamma=2.0)",
    "",
    "s_w_Cloud = np.array([1.0 / c_counts_Cloud[int(c)] for c in ytr_Cloud])",
    "sampler_Cloud = WeightedRandomSampler(s_w_Cloud, len(s_w_Cloud), replacement=True)",
    "",
    "loader_tr_Cloud = DataLoader(FastDataset(Xtr_Cloud, ytr_Cloud), batch_size=128, sampler=sampler_Cloud)",
    "loader_va_Cloud = DataLoader(FastDataset(X_B[va_B], y_B[va_B]), batch_size=128, shuffle=False)",
    "loader_te_Cloud = DataLoader(FastDataset(X_B[te_B], y_B[te_B]), batch_size=128, shuffle=False)",
    "",
    "opt_cloud = torch.optim.AdamW(cloud_model.parameters(), lr=1e-3, weight_decay=1e-4)",
    "cloud_history = []",
    "best_cloud_j, best_cloud_state = -1.0, None",
    "",
    "print('🚀 [2/2] بدء تدريب النموذج السحابي التنبؤي (CloudPreictalNet)...')",
    "for ep in range(1, 11):",
    "    cloud_model.train()",
    "    tr_loss = 0.0",
    "    for xb, yb in loader_tr_Cloud:",
    "        xb, yb = xb.to(DEVICE), yb.to(DEVICE)",
    "        opt_cloud.zero_grad()",
    "        loss = loss_fn_B(cloud_model(xb), yb)",
    "        loss.backward(); opt_cloud.step()",
    "        tr_loss += loss.item() * len(yb)",
    "    tr_loss /= len(loader_tr_Cloud.dataset)",
    "",
    "    cloud_model.eval()",
    "    va_loss, p_list, y_list = 0.0, [], []",
    "    with torch.no_grad():",
    "        for xb, yb in loader_va_Cloud:",
    "            xb, yb = xb.to(DEVICE), yb.to(DEVICE)",
    "            out = cloud_model(xb)",
    "            va_loss += loss_fn_B(out, yb).item() * len(yb)",
    "            p_list.append(torch.softmax(out, 1)[:, 1].cpu().numpy())",
    "            y_list.append(yb.cpu().numpy())",
    "    va_loss /= len(loader_va_Cloud.dataset)",
    "    m = clinical_metrics(np.concatenate(y_list), np.concatenate(p_list), threshold=0.5)",
    "    j = m['sensitivity'] + m['specificity'] - 1.0",
    "    cloud_history.append({'epoch': ep, 'train_loss': tr_loss, 'val_loss': va_loss, **m})",
    "    print(f'Cloud Epoch [{ep}/10] | Loss: {tr_loss:.4f}/{va_loss:.4f} | Sens: {m[\"sensitivity\"]*100:.1f}% | Spec: {m[\"specificity\"]*100:.1f}% | Youden-J: {j:.3f}')",
    "    if j > best_cloud_j:",
    "        best_cloud_j = j",
    "        best_cloud_state = {k: v.cpu().clone() for k, v in cloud_model.state_dict().items()}",
    "",
    "cloud_model.load_state_dict(best_cloud_state)",
    "print('✅ اكتمل تدريب النموذج السحابي بنجاح.')"
]))

# =============================================================================
# القسم 7 — منحنيات التدريب (رسومات إنجليزية لمنع التقطع)
# =============================================================================
cells.append(make_cell("markdown", '## 7 — منحنيات التدريب\nمنحنيات بحثية وليست دليلًا على الأداء لدى مريض جديد.'))

cells.append(make_cell("code", [
    "edge_df = pd.DataFrame(edge_history)",
    "cloud_df = pd.DataFrame(cloud_history)",
    "",
    "fig, axes = plt.subplots(2, 2, figsize=(15, 9))",
    "",
    "# Edge Model Loss",
    "axes[0, 0].plot(edge_df['epoch'], edge_df['train_loss'], '-o', color='#0984e3', label='Training Loss')",
    "axes[0, 0].plot(edge_df['epoch'], edge_df['val_loss'], '-s', color='#d63031', label='Validation Loss')",
    "axes[0, 0].set_title('EdgeSeizureNet: Loss Curves', fontsize=12, fontweight='bold')",
    "axes[0, 0].set_xlabel('Epoch'); axes[0, 0].set_ylabel('Focal Loss'); axes[0, 0].legend(); axes[0, 0].grid(True, alpha=0.3)",
    "",
    "# Edge Model Metrics",
    "axes[0, 1].plot(edge_df['epoch'], edge_df['sensitivity']*100, '-o', color='#00b894', label='Sensitivity (%)')",
    "axes[0, 1].plot(edge_df['epoch'], edge_df['specificity']*100, '-s', color='#6c5ce7', label='Specificity (%)')",
    "axes[0, 1].set_title('EdgeSeizureNet: Clinical Metrics', fontsize=12, fontweight='bold')",
    "axes[0, 1].set_xlabel('Epoch'); axes[0, 1].set_ylabel('Percentage (%)'); axes[0, 1].legend(); axes[0, 1].grid(True, alpha=0.3)",
    "",
    "# Cloud Model Loss",
    "axes[1, 0].plot(cloud_df['epoch'], cloud_df['train_loss'], '-o', color='#0984e3', label='Training Loss')",
    "axes[1, 0].plot(cloud_df['epoch'], cloud_df['val_loss'], '-s', color='#d63031', label='Validation Loss')",
    "axes[1, 0].set_title('CloudPreictalNet: Loss Curves', fontsize=12, fontweight='bold')",
    "axes[1, 0].set_xlabel('Epoch'); axes[1, 0].set_ylabel('Focal Loss'); axes[1, 0].legend(); axes[1, 0].grid(True, alpha=0.3)",
    "",
    "# Cloud Model Metrics",
    "axes[1, 1].plot(cloud_df['epoch'], cloud_df['sensitivity']*100, '-o', color='#00b894', label='Sensitivity (%)')",
    "axes[1, 1].plot(cloud_df['epoch'], cloud_df['specificity']*100, '-s', color='#6c5ce7', label='Specificity (%)')",
    "axes[1, 1].set_title('CloudPreictalNet: Clinical Metrics', fontsize=12, fontweight='bold')",
    "axes[1, 1].set_xlabel('Epoch'); axes[1, 1].set_ylabel('Percentage (%)'); axes[1, 1].legend(); axes[1, 1].grid(True, alpha=0.3)",
    "",
    "plt.tight_layout()",
    "plt.show()"
]))

# =============================================================================
# القسم 8 — مصفوفات الارتباك واختبار الدمج المزدوج (Dual Ensemble)
# =============================================================================
cells.append(make_cell("markdown", '## 8 — التقييم\nاختيار عتبة الدمج على التحقق فقط ثم قياس الاختبار. لا تمثل بيانات B مرضى ولا يقيس هذا التقييم إنذارات/ساعة أو وقت حدوث النوبة.'))

cells.append(make_cell("code", [
    "def eval_model(model, loader):",
    "    model.eval()",
    "    probs, gts = [], []",
    "    with torch.no_grad():",
    "        for xb, yb in loader:",
    "            xb, yb = xb.to(DEVICE), yb.to(DEVICE)",
    "            probs.append(torch.softmax(model(xb), dim=1)[:, 1].cpu().numpy())",
    "            gts.append(yb.cpu().numpy())",
    "    return np.concatenate(probs), np.concatenate(gts)",
    "",
    "# 1. أداء نموذج الهاتف منفرداً (أوفلاين - مجموعة اختبار A)",
    "p_edge_offline, gt_A_test = eval_model(edge_model, loader_te_A)",
    "m_edge = clinical_metrics(gt_A_test, p_edge_offline, threshold=0.5)",
    "",
    "# 2. أداء النموذج السحابي منفرداً (أونلاين - مجموعة اختبار B)",
    "p_cloud_online, gt_B_test = eval_model(cloud_model, loader_te_Cloud)",
    "m_cloud = clinical_metrics(gt_B_test, p_cloud_online, threshold=0.5)",
    "",
    "# 3. أداء الدمج المشترك الذكي (Dual-Model Ensemble)",
    "p_edge_on_B, _ = eval_model(edge_model, loader_te_Cloud)",
    "# دمج ذكي يأخذ أقصى ثقة بين النموذجين لمنع سحب الاحتمالية للأسفل",
    "p_ensemble = np.maximum(p_cloud_online, 0.6 * p_cloud_online + 0.4 * p_edge_on_B)",
    "",
    "# Tune on validation only; test labels must not influence the threshold.",
    "p_cloud_val, gt_B_val = eval_model(cloud_model, loader_va_Cloud)",
    "p_edge_val, _ = eval_model(edge_model, loader_va_Cloud)",
    "p_ensemble_val = np.maximum(p_cloud_val, 0.6 * p_cloud_val + 0.4 * p_edge_val)",
    "best_ens_j, best_ens_thr = -1.0, 0.5",
    "for thr in np.linspace(0.25, 0.75, 21):",
    "    cur_m = clinical_metrics(gt_B_val, p_ensemble_val, threshold=thr)",
    "    cur_j = cur_m['sensitivity'] + cur_m['specificity'] - 1.0",
    "    if cur_j > best_ens_j and cur_m['sensitivity'] >= 0.85:",
    "        best_ens_j, best_ens_thr = cur_j, thr",
    "",
    "m_ensemble = clinical_metrics(gt_B_test, p_ensemble, threshold=best_ens_thr)",
    "",
    "# رسم مصفوفات الارتباك الثلاث بتسميات إنجليزية لمنع تشوه النصوص",
    "fig, axes = plt.subplots(1, 3, figsize=(16, 4.5))",
    "cms = [",
    "    (m_edge, '1. Edge Offline Model (Bonn Test Set)', axes[0]),",
    "    (m_cloud, '2. Cloud Model (Synthetic Test Set)', axes[1]),",
    "    (m_ensemble, f'3. Dual-Model Ensemble (Thr={best_ens_thr:.2f})', axes[2]),",
    "]",
    "",
    "for m_res, title, ax in cms:",
    "    cm = np.array([[m_res['tn'], m_res['fp']], [m_res['fn'], m_res['tp']]])",
    "    im = ax.imshow(cm, cmap='Blues')",
    "    ax.set_xticks([0, 1]); ax.set_yticks([0, 1])",
    "    ax.set_xticklabels(['Pred: Normal', 'Pred: Seizure'], fontsize=10)",
    "    ax.set_yticklabels(['Actual: Normal', 'Actual: Seizure'], fontsize=10)",
    "    ax.set_title(title, fontsize=11, fontweight='bold')",
    "    for i in range(2):",
    "        for j in range(2):",
    "            val = cm[i, j]",
    "            color = 'white' if val > cm.max()/2 else 'black'",
    "            ax.text(j, i, f'{val:,}', ha='center', va='center', color=color, fontsize=14, fontweight='bold')",
    "    fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)",
    "",
    "plt.tight_layout()",
    "plt.show()",
    "",
    "print('='*70)",
    "print('🏆 نتائج بحثية: تسجيلات Bonn ومجموعات صناعية، دون إثبات صلاحية طبية:')",
    "print('='*70)",
    "print(f'1. نموذج الهاتف الأوفلاين (Edge Offline): حساسية = {m_edge[\"sensitivity\"]*100:.2f}% | نوعية = {m_edge[\"specificity\"]*100:.2f}%')",
    "print(f'2. النموذج السحابي التنبؤي (Cloud Online): حساسية = {m_cloud[\"sensitivity\"]*100:.2f}% | نوعية = {m_cloud[\"specificity\"]*100:.2f}%')",
    "print(f'3. الدمج الهجين المشترك (Dual Ensemble): حساسية = {m_ensemble[\"sensitivity\"]*100:.2f}% | نوعية = {m_ensemble[\"specificity\"]*100:.2f}% ⭐')",
    "print('='*70)"
]))

# =============================================================================
# القسم 9 — تصدير وحفظ النماذج للهاتف والسيرفر
# =============================================================================
cells.append(make_cell("markdown", '## 9 — التصدير\nحفظ الأوزان والتنبؤات والمجموعات وبصمات SHA256 لتمكين المراجعة. التصدير لا يمنح صلاحية طبية.'))

cells.append(make_cell("code", [
    "# التأكد من تثبيت onnxscript لتفادي الخطأ في بيئات Colab الحديثة",
    "try:",
    "    import onnx",
    "    import onnxscript",
    "except ImportError:",
    "    import subprocess, sys",
    "    print('تثبيت onnxscript للتصدير الآمن...')",
    "    subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', 'onnx', 'onnxscript'])",
    "    import onnx",
    "    import onnxscript",
    "",
    "OUT_DIR = Path('trained_artifacts')",
    "OUT_DIR.mkdir(exist_ok=True)",
    "dummy_input = torch.randn(1, 1, win_len).to(DEVICE)",
    "",
    "# 1. حفظ أوزان PyTorch الأصلية أولاً (ضمان حفظ النتائج)",
    "cloud_pt_path = OUT_DIR / 'cloud_preictal_model.pt'",
    "edge_pt_path = OUT_DIR / 'edge_seizure_model.pt'",
    "torch.save(cloud_model.state_dict(), cloud_pt_path)",
    "torch.save(edge_model.state_dict(), edge_pt_path)",
    "print(f'✅ تم حفظ أوزان PyTorch السحابية: {cloud_pt_path}')",
    "print(f'✅ تم حفظ أوزان PyTorch المحلية: {edge_pt_path}')",
    "",
    "# 2. حفظ ملف الميتاداتا لربطه بنظام الباكيند",
    "cfg_path = OUT_DIR / 'dual_model_config.json'",
    "dual_config = {",
    "    'system': 'Research demonstration',",
    "    'clinically_validated': False,",
    "    'dataset_b': 'synthetic_waveforms_not_CHB_MIT',",
    "    'threshold_selection': 'validation_only',",
    "    'ensemble_rule': 'max(cloud, 0.6*cloud + 0.4*edge)',",
    "    'edge_model': {'arch': 'EdgeSeizureNet', 'file_onnx': 'edge_seizure_model.onnx', 'file_pt': 'edge_seizure_model.pt', 'mode': 'offline'},",
    "    'cloud_model': {'arch': 'CloudPreictalNet', 'file_pt': 'cloud_preictal_model.pt', 'file_onnx': 'cloud_preictal_model.onnx', 'mode': 'online'},",
    "    'metrics': {",
    "        'edge_sensitivity': float(m_edge['sensitivity']),",
    "        'edge_specificity': float(m_edge['specificity']),",
    "        'cloud_sensitivity': float(m_cloud['sensitivity']),",
    "        'cloud_specificity': float(m_cloud['specificity']),",
    "        'ensemble_sensitivity': float(m_ensemble['sensitivity']),",
    "        'ensemble_specificity': float(m_ensemble['specificity']),",
    "        'ensemble_optimal_threshold': float(best_ens_thr)",
    "    }",
    "}",
    "with open(cfg_path, 'w', encoding='utf-8') as f:",
    "    json.dump(dual_config, f, indent=2, ensure_ascii=False)",
    "print(f'✅ تم حفظ ملف الإعدادات: {cfg_path}')",
    "",
    "# 3. تصدير صيغ ONNX المفتوحة مع دعم التوافق التلقائي",
    "edge_onnx_path = OUT_DIR / 'edge_seizure_model.onnx'",
    "cloud_onnx_path = OUT_DIR / 'cloud_preictal_model.onnx'",
    "",
    "def export_onnx_safe(model, dummy, filepath, in_name, out_name):",
    "    model.eval()",
    "    try:",
    "        torch.onnx.export(",
    "            model, dummy, str(filepath),",
    "            input_names=[in_name], output_names=[out_name],",
    "            dynamic_axes={in_name: {0: 'batch'}, out_name: {0: 'batch'}},",
    "            opset_version=14, dynamo=False",
    "        )",
    "        print(f'✅ تم تصدير ONNX بنجاح: {filepath}')",
    "    except TypeError:",
    "        torch.onnx.export(",
    "            model, dummy, str(filepath),",
    "            input_names=[in_name], output_names=[out_name],",
    "            dynamic_axes={in_name: {0: 'batch'}, out_name: {0: 'batch'}},",
    "            opset_version=14",
    "        )",
    "        print(f'✅ تم تصدير ONNX بنجاح: {filepath}')",
    "    except Exception as e:",
    "        print(f'تنبيه: تعذر تصدير ONNX ({filepath}): {e}')",
    "",
    "export_onnx_safe(edge_model, dummy_input, edge_onnx_path, 'eeg_stream', 'risk_score')",
    "export_onnx_safe(cloud_model, dummy_input, cloud_onnx_path, 'eeg_window', 'preictal_logits')",
    "",
    "# Compact evidence for review; no raw EEG or real patient identities.",
    "import hashlib",
    "def artifact_hash(path):",
    "    with open(path, 'rb') as source:",
    "        return hashlib.sha256(source.read()).hexdigest()",
    "dual_config['weights_sha256'] = {'cloud': artifact_hash(cloud_pt_path), 'edge': artifact_hash(edge_pt_path)}",
    "with open(cfg_path, 'w', encoding='utf-8') as f:",
    "    json.dump(dual_config, f, indent=2, ensure_ascii=False)",
    "p_edge_val_A, gt_A_val = eval_model(edge_model, loader_va_A)",
    "np.savez_compressed(OUT_DIR / 'edge_holdout.npz', y=gt_A_test, score=p_edge_offline, group=g_A[te_A], val_y=gt_A_val, val_score=p_edge_val_A, val_group=g_A[va_A], train_group=g_A[tr_A])",
    "np.savez_compressed(OUT_DIR / 'cloud_synthetic_holdout.npz', y=gt_B_test, score=p_cloud_online, group=np.char.add('B:', g_B[te_B].astype(str)), val_y=gt_B_val, val_score=p_cloud_val, val_group=np.char.add('B:', g_B[va_B].astype(str)), train_group=np.r_[np.char.add('A:', g_A[tr_A].astype(str)), np.char.add('B:', g_B[tr_B].astype(str))])",
    "# 4. التنزيل التلقائي المباشر لجميع الملفات إلى جهازك في حال تشغيل Colab",
    "try:",
    "    from google.colab import files",
    "    download_files = [cfg_path, cloud_pt_path, edge_pt_path, OUT_DIR / 'edge_holdout.npz', OUT_DIR / 'cloud_synthetic_holdout.npz']",
    "    if edge_onnx_path.exists(): download_files.append(edge_onnx_path)",
    "    if cloud_onnx_path.exists(): download_files.append(cloud_onnx_path)",
    "    for f in download_files:",
    "        files.download(str(f))",
    "except Exception:",
    "    print('تلميح: لتنزيل الملفات على Colab، افتح قائمة Files على يسار الشاشة وستجدها في مجلد trained_artifacts.')"
]))

# =============================================================================
# القسم 10 — الخلاصة ودليل إجابات المناقشة
# =============================================================================
cells.append(make_cell("markdown", '## 10 — حدود النتائج\nهذا الدفتر يختبر تدريب الشبكات على Bonn وبيانات صناعية. لإثبات التنبؤ يلزم EEG متصل مع أوقات النوبات واختبار مستقل ومعالجة مطابقة للجهاز. راجع docs/PREDICTION_READINESS_AR.md. لا تستخدم مخرجاته لاتخاذ قرار علاجي.'))

# حفظ الدفتر المحدث
nb = {
    "cells": cells,
    "metadata": {
        "colab": {"provenance": [], "toc_visible": True},
        "kernelspec": {"display_name": "Python 3", "name": "python3"},
        "language_info": {"name": "python"}
    },
    "nbformat": 4,
    "nbformat_minor": 0
}

nb_out = Path("research/colab_seizure_detection.ipynb")
with open(nb_out, "w", encoding="utf-8") as f:
    json.dump(nb, f, indent=1, ensure_ascii=False)

print(f"Successfully generated notebook: {nb_out}")
