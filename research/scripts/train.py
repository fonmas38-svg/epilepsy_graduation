"""
Step 5 — CNN-1D + LSTM on the raw harmonized signal.

Task: binary preictal(1) vs interictal(0)  [Bonn MVP: ictal(1) vs non-ictal(0)].
Class imbalance handled via focal loss (default) or class weights.
Reported metrics are the ones that matter clinically:
    Sensitivity (recall of the positive class) and FPR/hour,
NOT accuracy (useless under heavy imbalance).

Usage:
    python scripts/train.py --dataset bonn                 # patient-wise on Bonn
    python scripts/train.py --dataset chbmit               # patient-wise on CHB-MIT
    python scripts/train.py --lodo chbmit siena            # train chbmit, test siena
    python scripts/train.py --dataset bonn --loss weighted --epochs 15
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

import splits as S

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "results"
MODELS = ROOT / "models"

try:
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader, Dataset, WeightedRandomSampler
except ImportError:  # pragma: no cover
    raise SystemExit(
        "PyTorch not installed. Install CPU wheel:\n"
        "  pip install torch --index-url https://download.pytorch.org/whl/cpu"
    )


# ------------------------------ model ------------------------------
class CNN1D_LSTM(nn.Module):
    """Conv stack extracts local morphology; LSTM models temporal evolution."""

    def __init__(self, in_ch: int, n_classes: int = 2, hidden: int = 64):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv1d(in_ch, 32, 7, padding=3), nn.BatchNorm1d(32), nn.ReLU(),
            nn.MaxPool1d(2),
            nn.Conv1d(32, 64, 5, padding=2), nn.BatchNorm1d(64), nn.ReLU(),
            nn.MaxPool1d(2),
            nn.Conv1d(64, 64, 3, padding=1), nn.BatchNorm1d(64), nn.ReLU(),
            nn.MaxPool1d(2),
        )
        self.lstm = nn.LSTM(64, hidden, batch_first=True, bidirectional=True)
        self.head = nn.Sequential(
            nn.Dropout(0.3), nn.Linear(hidden * 2, 64), nn.ReLU(),
            nn.Dropout(0.3), nn.Linear(64, n_classes),
        )

    def forward(self, x):                 # x: (B, C, L)
        z = self.features(x)              # (B, 64, L')
        z = z.transpose(1, 2)             # (B, L', 64)
        out, _ = self.lstm(z)             # (B, L', 2*hidden)
        z = out.mean(dim=1)               # temporal average pool
        return self.head(z)


# --------------------------- focal loss ---------------------------
class FocalLoss(nn.Module):
    def __init__(self, alpha=None, gamma: float = 2.0):
        super().__init__()
        self.gamma = gamma
        self.alpha = alpha  # tensor of per-class weights or None

    def forward(self, logits, target):
        ce = nn.functional.cross_entropy(logits, target, weight=self.alpha, reduction="none")
        pt = torch.exp(-ce)
        return ((1 - pt) ** self.gamma * ce).mean()


# ------------------------------ data ------------------------------
class ArrayDS(Dataset):
    def __init__(self, X, y):
        self.X = torch.from_numpy(np.ascontiguousarray(X)).float()
        self.y = torch.from_numpy(np.ascontiguousarray(y)).long()

    def __len__(self):
        return len(self.y)

    def __getitem__(self, i):
        return self.X[i], self.y[i]


# ---------------------------- metrics ----------------------------
def clinical_metrics(y_true, y_prob, fs, win_sec, threshold=0.5):
    """Sensitivity, specificity, FPR/hour at a decision threshold."""
    y_pred = (y_prob >= threshold).astype(int)
    tp = int(((y_pred == 1) & (y_true == 1)).sum())
    fn = int(((y_pred == 0) & (y_true == 1)).sum())
    fp = int(((y_pred == 1) & (y_true == 0)).sum())
    tn = int(((y_pred == 0) & (y_true == 0)).sum())
    sens = tp / (tp + fn) if (tp + fn) else 0.0
    spec = tn / (tn + fp) if (tn + fp) else 0.0
    # FPR/hour: false positives per hour of NEGATIVE (interictal) data seen
    neg_hours = (tn + fp) * win_sec / 3600.0
    fpr_h = fp / neg_hours if neg_hours > 0 else 0.0
    return {
        "threshold": round(float(threshold), 3),
        "sensitivity": round(sens, 4), "specificity": round(spec, 4),
        "fpr_per_hour": round(fpr_h, 4),
        "tp": tp, "fn": fn, "fp": fp, "tn": tn,
    }


def best_threshold_for_target(y_true, y_prob, fs, win_sec, min_sens=0.8):
    """Pick the threshold with lowest FPR/h that still reaches min_sens."""
    best = None
    for t in np.linspace(0.05, 0.95, 19):
        m = clinical_metrics(y_true, y_prob, fs, win_sec, t)
        if m["sensitivity"] >= min_sens:
            if best is None or m["fpr_per_hour"] < best["fpr_per_hour"]:
                best = m
    return best or clinical_metrics(y_true, y_prob, fs, win_sec, 0.5)


# ---------------------------- training ----------------------------
def run_epoch(model, loader, device, loss_fn, opt=None):
    train = opt is not None
    model.train(train)
    total, probs, gts = 0.0, [], []
    for xb, yb in loader:
        xb, yb = xb.to(device), yb.to(device)
        with torch.set_grad_enabled(train):
            logits = model(xb)
            loss = loss_fn(logits, yb)
            if train:
                opt.zero_grad(); loss.backward(); opt.step()
        total += float(loss.detach()) * len(yb)
        probs.append(torch.softmax(logits.detach(), 1)[:, 1].cpu().numpy())
        gts.append(yb.cpu().numpy())
    return total / len(loader.dataset), np.concatenate(probs), np.concatenate(gts)


def train(data, fs, win_sec, loss_kind="focal", epochs=12, bs=128, lr=1e-3, seed=42, tag="bonn"):
    torch.manual_seed(seed)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    Xtr, ytr = data["train"]; Xva, yva = data["val"]; Xte, yte = data["test"]
    in_ch = Xtr.shape[1]
    print(f"device={device} in_ch={in_ch} train={Xtr.shape} val={Xva.shape} test={Xte.shape}")

    # imbalance handling
    classes, counts = np.unique(ytr, return_counts=True)
    freq = {int(c): int(n) for c, n in zip(classes, counts)}
    w = torch.tensor([len(ytr) / (2 * freq.get(0, 1)), len(ytr) / (2 * freq.get(1, 1))],
                     dtype=torch.float32, device=device)
    print(f"class counts={freq}  weights={w.tolist()}")
    loss_fn = FocalLoss(alpha=w, gamma=2.0) if loss_kind == "focal" else nn.CrossEntropyLoss(weight=w)

    # balanced sampler so minority preictal is seen enough
    sample_w = np.array([1.0 / freq[int(c)] for c in ytr])
    sampler = WeightedRandomSampler(sample_w, len(sample_w), replacement=True)
    tr_loader = DataLoader(ArrayDS(Xtr, ytr), batch_size=bs, sampler=sampler)
    va_loader = DataLoader(ArrayDS(Xva, yva), batch_size=bs)
    te_loader = DataLoader(ArrayDS(Xte, yte), batch_size=bs)

    model = CNN1D_LSTM(in_ch).to(device)
    opt = torch.optim.Adam(model.parameters(), lr=lr, weight_decay=1e-4)

    best_j, best_state = -1.0, None
    for ep in range(1, epochs + 1):
        tr_loss, _, _ = run_epoch(model, tr_loader, device, loss_fn, opt)
        va_loss, vp, vg = run_epoch(model, va_loader, device, loss_fn)
        vm = clinical_metrics(vg, vp, fs, win_sec, 0.5)
        # Youden's J balances sensitivity and specificity, so it does NOT reward
        # the degenerate all-positive predictor (which has spec=0 -> J=0).
        j = vm["sensitivity"] + vm["specificity"] - 1.0
        print(f"ep{ep:02d} train_loss={tr_loss:.4f} val_loss={va_loss:.4f} "
              f"val_sens={vm['sensitivity']:.3f} val_spec={vm['specificity']:.3f} "
              f"val_fpr/h={vm['fpr_per_hour']:.3f} J={j:.3f}")
        if j > best_j:
            best_j = j
            best_state = {k: v.cpu().clone() for k, v in model.state_dict().items()}

    if best_state:
        model.load_state_dict(best_state)

    # final test with clinically-tuned threshold picked on validation
    _, vp, vg = run_epoch(model, va_loader, device, loss_fn)
    tuned = best_threshold_for_target(vg, vp, fs, win_sec, min_sens=0.8)
    _, tp_prob, tg = run_epoch(model, te_loader, device, loss_fn)
    test_default = clinical_metrics(tg, tp_prob, fs, win_sec, 0.5)
    test_tuned = clinical_metrics(tg, tp_prob, fs, win_sec, tuned["threshold"])

    RESULTS.mkdir(parents=True, exist_ok=True)
    MODELS.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), MODELS / f"cnn_lstm_{tag}.pt")
    report = {
        "dataset_tag": tag, "loss": loss_kind, "epochs": epochs,
        "fs": int(fs), "window_sec": win_sec,
        "val_tuned_threshold": tuned,
        "test_at_0.5": test_default,
        "test_at_tuned_threshold": test_tuned,
        "note": "Sensitivity + FPR/h are the reported metrics; accuracy omitted by design.",
        "caveat": (
            "FPR/hour is only physically meaningful on CONTINUOUS recordings "
            "(CHB-MIT/Siena). Bonn windows are isolated ~1s segments, so its FPR/h "
            "is not a real alarm rate -- use specificity for Bonn instead."
            if tag == "bonn" else
            "FPR/hour computed over continuous interictal data."
        ),
    }
    (RESULTS / f"metrics_{tag}.json").write_text(json.dumps(report, indent=2))
    print("\n=== TEST (default 0.5) ===", json.dumps(test_default, indent=2))
    print("=== TEST (tuned thr) ===", json.dumps(test_tuned, indent=2))
    print(f"saved model -> {MODELS / f'cnn_lstm_{tag}.pt'}")
    print(f"saved metrics -> {RESULTS / f'metrics_{tag}.json'}")
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", help="patient-wise on this H5 (bonn/chbmit/siena)")
    ap.add_argument("--lodo", nargs=2, metavar=("TRAIN", "TEST"), help="leave-one-dataset-out")
    ap.add_argument("--loss", choices=["focal", "weighted"], default="focal")
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--batch", type=int, default=128)
    args = ap.parse_args()

    if args.lodo:
        tr, te = args.lodo
        data = S.make_lodo(tr, te)
        fs = int(data["attrs"].get("fs", 256)); tag = f"lodo_{tr}_to_{te}"
    elif args.dataset:
        data = S.make_patient_wise(args.dataset)
        fs = int(data["attrs"].get("fs", 256)); tag = args.dataset
    else:
        raise SystemExit("pass --dataset NAME or --lodo TRAIN TEST")

    win_sec = data["train"][0].shape[-1] / fs
    train(data, fs, win_sec, loss_kind=args.loss, epochs=args.epochs, bs=args.batch, tag=tag)


if __name__ == "__main__":
    main()
