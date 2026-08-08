"""
Step: window labeling (preictal / interictal) from seizure onset times.

Agreed definitions (see research/README.md):
  preictal   = the last PREICTAL_MIN minutes before onset, EXCLUDING a
               SAFETY_GAP_MIN gap immediately before onset.
  interictal = segments at least INTERICTAL_GUARD_H hours away from ANY seizure.
  ictal + everything else = discarded for the PREDICTION task.

This module is dataset-agnostic: give it a signal, its fs, and a list of
seizure (onset, offset) times in seconds, and it yields labeled windows.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

PREICTAL_MIN = 30
SAFETY_GAP_MIN = 5
INTERICTAL_GUARD_H = 4
WINDOW_SEC = 5.0        # analysis window length
STRIDE_SEC = 5.0        # non-overlapping by default (raise overlap for more preictal)

LABEL_INTERICTAL = 0
LABEL_PREICTAL = 1


@dataclass
class WindowSpec:
    fs: int
    window_sec: float = WINDOW_SEC
    stride_sec: float = STRIDE_SEC
    preictal_min: int = PREICTAL_MIN
    safety_gap_min: int = SAFETY_GAP_MIN
    interictal_guard_h: int = INTERICTAL_GUARD_H

    @property
    def win_len(self) -> int:
        return int(round(self.window_sec * self.fs))

    @property
    def stride(self) -> int:
        return int(round(self.stride_sec * self.fs))


def _label_for_window(
    start_s: float, end_s: float, seizures: list[tuple[float, float]], spec: WindowSpec
) -> int | None:
    """Return LABEL_* for a window [start_s, end_s], or None to discard."""
    pre_lo = spec.preictal_min * 60
    gap = spec.safety_gap_min * 60
    guard = spec.interictal_guard_h * 3600

    for onset, offset in seizures:
        # discard ictal windows and the safety gap
        if start_s < offset and end_s > (onset - gap):
            # overlaps ictal or the safety gap -> ambiguous, drop
            if start_s < offset and end_s > onset:
                return None  # ictal overlap
            if onset - gap <= end_s <= onset:
                return None  # inside safety gap
        # preictal: window fully inside [onset - preictal_min, onset - gap]
        if (onset - pre_lo) <= start_s and end_s <= (onset - gap):
            return LABEL_PREICTAL

    # interictal: at least `guard` away from every seizure
    for onset, offset in seizures:
        if not (end_s < onset - guard or start_s > offset + guard):
            return None  # too close to a seizure to be safely interictal
    return LABEL_INTERICTAL


def iter_windows(
    sig: np.ndarray, seizures: list[tuple[float, float]], spec: WindowSpec
):
    """
    Yield (window, label) pairs.
    sig: (channels, samples) already harmonized to spec.fs.
    seizures: list of (onset_s, offset_s). Empty list => all interictal candidates.
    """
    n = sig.shape[-1]
    wl, st = spec.win_len, spec.stride
    for start in range(0, n - wl + 1, st):
        s_s = start / spec.fs
        e_s = (start + wl) / spec.fs
        label = _label_for_window(s_s, e_s, seizures, spec)
        if label is None:
            continue
        yield sig[:, start : start + wl], label
