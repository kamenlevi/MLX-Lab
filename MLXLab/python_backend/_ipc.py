"""Shared JSON-line IPC helpers for the MLX Lab backend.

Every event written to stdout is a single JSON object on one line, terminated
by '\n'. Each event MUST include an `id` (string, request correlation) and an
`event` (one of: 'progress', 'log', 'done', 'error', 'token', 'stats').

The Swift parent reads stdout line-by-line. stderr is reserved for unstructured
diagnostics that should never be parsed as protocol output.
"""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any


def emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def progress(req_id: str, pct: float, stage: str, message: str = "") -> None:
    emit({"id": req_id, "event": "progress", "pct": max(0.0, min(1.0, pct)),
          "stage": stage, "message": message})


def log(req_id: str, message: str, level: str = "info") -> None:
    emit({"id": req_id, "event": "log", "level": level, "message": message})


def done(req_id: str, result: dict[str, Any]) -> None:
    emit({"id": req_id, "event": "done", "result": result})


def error(req_id: str, message: str, *, exc: BaseException | None = None) -> None:
    payload: dict[str, Any] = {"id": req_id, "event": "error", "message": message}
    if exc is not None:
        payload["traceback"] = "".join(traceback.format_exception(exc))
    emit(payload)


def fatal(message: str, exc: BaseException | None = None) -> None:
    """For startup-time failures before an id is established."""
    emit({"id": "_fatal", "event": "error", "message": message,
          "traceback": "".join(traceback.format_exception(exc)) if exc else ""})
    sys.exit(1)
