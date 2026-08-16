"""Structured (JSON) logging.

One JSON object per line so logs can be grepped, shipped, or loaded into pandas
without a custom parser. Enabled by default; set LOG_FORMAT=text for a
human-friendly local console.
"""
from __future__ import annotations

import json
import logging
import os

# Attributes present on every LogRecord; anything else was passed via `extra`
# and is therefore structured context worth emitting.
_STANDARD = {
    "args", "asctime", "created", "exc_info", "exc_text", "filename",
    "funcName", "levelname", "levelno", "lineno", "module", "msecs",
    "message", "msg", "name", "pathname", "process", "processName",
    "relativeCreated", "stack_info", "thread", "threadName", "taskName",
}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        # default=str keeps a stray non-serializable value from killing the log.
        return json.dumps(payload, ensure_ascii=False, default=str)


def configure_logging() -> None:
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    use_json = os.getenv("LOG_FORMAT", "json").lower() == "json"
    handler = logging.StreamHandler()
    handler.setFormatter(
        JsonFormatter()
        if use_json
        else logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    root = logging.getLogger()
    # Replace existing handlers so repeated calls (tests, reload) don't duplicate lines.
    for existing in list(root.handlers):
        root.removeHandler(existing)
    root.addHandler(handler)
    root.setLevel(level)
