"""Long-running JSON-line RPC server spawned by the Swift host.

Reads one JSON request per stdin line, dispatches it to a worker thread, and
streams events back over stdout. Multiple requests can run concurrently;
correlation is via the request `id` field.

Request shape:

    {"op": "convert", "id": "abc", "model": "Qwen/Qwen3-0.6B", "quant": "q4",
     "out_dir": "/path/to/dest"}
    {"op": "benchmark", "id": "abc", "model_path": "...",
     "prefill_tokens": 512, "decode_tokens": 128}
    {"op": "chat", "id": "abc", "model_path": "...",
     "messages": [{"role": "user", "content": "hi"}],
     "max_tokens": 256, "temperature": 0.7, "top_p": 0.95}
    {"op": "ping", "id": "abc"}
    {"op": "shutdown", "id": "abc"}

Operational events flow back via `_ipc.emit` (progress/log/token/done/error).
"""

from __future__ import annotations

import json
import sys
import threading
import time
import traceback
from typing import Any

import _ipc
from _ipc import done, emit, error, log

# Lazy imports inside handlers so a missing model dep doesn't kill the server.


def _handle_ping(req: dict[str, Any]) -> None:
    done(req["id"], {"pong": True, "time": time.time()})


def _handle_convert(req: dict[str, Any]) -> None:
    import convert as conv  # type: ignore

    rid = req["id"]
    try:
        result = conv.run(
            rid,
            model=req["model"],
            quant=req["quant"],
            out_dir=req["out_dir"],
            revision=req.get("revision"),
            trust_remote_code=bool(req.get("trust_remote_code", False)),
        )
        done(rid, result)
    except Exception as e:
        error(rid, f"convert failed: {e}", exc=e)


def _handle_benchmark(req: dict[str, Any]) -> None:
    import benchmark as bm  # type: ignore

    rid = req["id"]
    try:
        result = bm.run(
            rid,
            model_path=req["model_path"],
            prefill_tokens=int(req.get("prefill_tokens", 512)),
            decode_tokens=int(req.get("decode_tokens", 128)),
            do_perplexity=bool(req.get("perplexity", True)),
            warmup=bool(req.get("warmup", True)),
        )
        done(rid, result)
    except Exception as e:
        error(rid, f"benchmark failed: {e}", exc=e)


def _handle_chat(req: dict[str, Any]) -> None:
    import inference as inf  # type: ignore

    rid = req["id"]
    try:
        result = inf.chat(
            rid,
            model_path=req["model_path"],
            messages=req["messages"],
            max_tokens=int(req.get("max_tokens", 512)),
            temperature=float(req.get("temperature", 0.7)),
            top_p=float(req.get("top_p", 0.95)),
        )
        done(rid, result)
    except Exception as e:
        error(rid, f"chat failed: {e}", exc=e)


HANDLERS = {
    "ping": _handle_ping,
    "convert": _handle_convert,
    "benchmark": _handle_benchmark,
    "chat": _handle_chat,
}


def _dispatch(req: dict[str, Any]) -> None:
    op = req.get("op")
    rid = req.get("id", "_noid")
    if op == "shutdown":
        done(rid, {"goodbye": True})
        sys.exit(0)
    handler = HANDLERS.get(op or "")
    if handler is None:
        error(rid, f"unknown op: {op!r}")
        return
    handler(req)


def main() -> int:
    emit({"id": "_ready", "event": "ready", "pid": __import__("os").getpid()})
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            error("_parse", f"invalid JSON: {e}")
            continue
        if not isinstance(req, dict) or "op" not in req or "id" not in req:
            error(req.get("id", "_invalid") if isinstance(req, dict) else "_invalid",
                  "request must be an object with 'op' and 'id'")
            continue
        t = threading.Thread(target=_dispatch, args=(req,), daemon=True)
        t.start()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        _ipc.fatal(f"server crashed: {e}", exc=e)
