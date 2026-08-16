"""In-process operational metrics.

Deliberately dependency-free: no Prometheus client, no external collector. The
goal is that a demo or single-worker deployment can answer "is inference slow?"
and "are notifications failing?" from one endpoint.

A multi-worker deployment would report per-worker numbers, so a shared store
(Redis / a real metrics backend) is the documented upgrade path.
"""
from __future__ import annotations

import time
from collections import defaultdict, deque
from threading import Lock

# Bounded so a long run cannot grow memory without limit.
_LATENCY_WINDOW = 500


class Metrics:
    def __init__(self) -> None:
        self._lock = Lock()
        self._counters: dict[str, int] = defaultdict(int)
        self._latencies: dict[str, deque[float]] = defaultdict(
            lambda: deque(maxlen=_LATENCY_WINDOW)
        )
        self._started = time.monotonic()

    def increment(self, name: str, amount: int = 1) -> None:
        with self._lock:
            self._counters[name] += amount

    def observe(self, name: str, milliseconds: float) -> None:
        with self._lock:
            self._latencies[name].append(float(milliseconds))

    @staticmethod
    def _percentile(values: list[float], fraction: float) -> float:
        if not values:
            return 0.0
        ordered = sorted(values)
        # Nearest-rank percentile: exact for small samples and needs no interpolation.
        index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
        return round(ordered[index], 2)

    def snapshot(self) -> dict:
        with self._lock:
            counters = dict(self._counters)
            latencies = {name: list(values) for name, values in self._latencies.items()}
            uptime = time.monotonic() - self._started
        summaries = {}
        for name, values in latencies.items():
            if not values:
                continue
            summaries[name] = {
                "count": len(values),
                "avg_ms": round(sum(values) / len(values), 2),
                "p50_ms": self._percentile(values, 0.50),
                "p95_ms": self._percentile(values, 0.95),
                "max_ms": round(max(values), 2),
            }
        return {
            "uptime_seconds": round(uptime, 1),
            "counters": counters,
            "latency": summaries,
        }

    def reset(self) -> None:
        """Used by tests to keep assertions independent."""
        with self._lock:
            self._counters.clear()
            self._latencies.clear()


metrics = Metrics()


class track_latency:
    """Context manager recording elapsed milliseconds under ``name``."""

    def __init__(self, name: str) -> None:
        self.name = name
        self._start = 0.0

    def __enter__(self) -> "track_latency":
        self._start = time.perf_counter()
        return self

    def __exit__(self, *_exc_info) -> None:
        metrics.observe(self.name, (time.perf_counter() - self._start) * 1000)
        return None
