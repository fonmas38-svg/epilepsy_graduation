"""Runs research/colab_seizeit2_multimodal.ipynb headless on GitHub Actions.

MODE=extract : features for subjects[SHARD::NSHARDS] -> work/seizeit2_features
MODE=analyze : experiments + summary on all collected features -> work/seizeit2_outputs
The notebook stays the single source of the code; this only picks its cells.
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NB = ROOT / "research" / "colab_seizeit2_multimodal.ipynb"
MODE = os.environ.get("MODE", "extract")
SHARD = int(os.environ.get("SHARD", "0"))
NSHARDS = int(os.environ.get("NSHARDS", "1"))

cells = [c["source"] for c in json.loads(NB.read_text(encoding="utf-8"))["cells"]
         if c["cell_type"] == "code"]
cells = ["\n".join(l for l in c.splitlines() if not l.lstrip().startswith("!")) for c in cells]
# 0 setup, 1 settings, 2 subject list, 3 features, 4 labels/detector,
# 5 extraction, 6 baseline/context, 7 experiments, 8 summary
DETECTOR = ROOT / "mobile" / "assets" / "models" / "edge_seizure_model.onnx"
g = {"__name__": "__main__"}


def run(i):
    print(f"--- cell {i}", flush=True)
    exec(compile(cells[i], f"cell{i}", "exec"), g)


run(0)
run(1)
g["DETECTOR"] = DETECTOR
if MODE == "extract":
    run(2)
    g["subjects"] = g["subjects"][SHARD::NSHARDS]
    print(f"shard {SHARD}/{NSHARDS}: {len(g['subjects'])} subjects", flush=True)
    run(3)
    run(4)
    run(5)
    if not g["subjects"] or not list(g["FEAT"].glob("sub-*.npz")):
        sys.exit("no subject produced features: failing the job instead of hiding it")
elif MODE == "analyze":
    for i in (3, 4, 6, 7, 8):
        run(i)
else:
    sys.exit("MODE must be extract or analyze")
