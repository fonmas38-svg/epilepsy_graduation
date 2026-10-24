"""Exercise the exported notebook's selection code without training or installing packages."""
import ast
import json
from pathlib import Path

import numpy as np

NOTEBOOK = Path(__file__).resolve().parents[2] / "research" / "colab_seizure_detection.ipynb"


def code_cells():
    notebook = json.loads(NOTEBOOK.read_text(encoding="utf-8"))
    return ["".join(c["source"]) for c in notebook["cells"] if c["cell_type"] == "code"]


def test_notebook_cells_compile_and_describe_synthetic_data():
    for i, source in enumerate(code_cells()):
        compile(source, f"notebook_cell_{i}", "exec")
    text = NOTEBOOK.read_text(encoding="utf-8")
    assert "synthetic_waveforms_not_CHB_MIT" in text
    assert "'clinically_validated': False" in text


def test_notebook_threshold_uses_validation_when_test_disagrees():
    definitions, selection = [], []
    for source in code_cells():
        for node in ast.parse(source).body:
            if isinstance(node, ast.FunctionDef) and node.name == "clinical_metrics":
                definitions.append(node)
            if isinstance(node, ast.For) and isinstance(node.target, ast.Name) and node.target.id == "thr":
                selection.append(node)
    assert len(definitions) == len(selection) == 1
    context = {
        "np": np, "best_ens_j": -1.0, "best_ens_thr": 0.5,
        "gt_B_val": np.array([0, 0, 1, 1]),
        "p_ensemble_val": np.array([0.1, 0.2, 0.8, 0.9]),
        "gt_B_test": np.array([0, 0, 1, 1]),
        "p_ensemble": np.array([0.9, 0.8, 0.2, 0.1]),
    }
    module = ast.Module(body=definitions + selection, type_ignores=[])
    exec(compile(module, "notebook_threshold", "exec"), context)
    assert context["best_ens_j"] == 1.0
    assert context["best_ens_thr"] == 0.25
