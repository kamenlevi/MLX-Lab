"""Streaming chat inference for the Chat tab.

A single run holds one loaded model and processes one or more chat turns,
streaming token-level events back to Swift. Each turn is initiated by a
"chat" op carrying the current message list; the model is loaded once and
reused for subsequent turns with the same model path.

Event sequence per turn:

    {"event": "first_token", "ms": 123.4}
    {"event": "token", "text": "Hel", "tps": 41.7}
    ...
    {"event": "done", "result": {"generation_tokens": N,
                                 "generation_tps": X,
                                 "prompt_tokens": P,
                                 "prompt_tps": Y,
                                 "peak_memory_gb": Z,
                                 "finish_reason": "stop"}}
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

from _ipc import done, emit, error, log, progress


_LOADED: dict[str, Any] = {"path": None, "model": None, "tokenizer": None}


def _ensure_loaded(req_id: str, model_path: str) -> tuple[Any, Any]:
    from mlx_lm import load  # type: ignore

    if _LOADED["path"] == model_path and _LOADED["model"] is not None:
        return _LOADED["model"], _LOADED["tokenizer"]

    progress(req_id, 0.05, "load", f"loading {Path(model_path).name}")
    model, tokenizer = load(model_path)
    _LOADED.update(path=model_path, model=model, tokenizer=tokenizer)
    return model, tokenizer


def _apply_chat_template(tokenizer, messages: list[dict[str, str]]) -> str:
    """Render messages into a prompt string using the tokenizer's chat
    template when present; fall back to a plain role-prefixed format."""
    try:
        return tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
    except Exception:
        out = []
        for m in messages:
            out.append(f"{m['role']}: {m['content']}")
        out.append("assistant:")
        return "\n".join(out)


def chat(req_id: str, model_path: str, messages: list[dict[str, str]],
         max_tokens: int = 512, temperature: float = 0.7,
         top_p: float = 0.95) -> dict[str, Any]:
    from mlx_lm.generate import stream_generate  # type: ignore
    from mlx_lm.sample_utils import make_sampler  # type: ignore

    model, tokenizer = _ensure_loaded(req_id, model_path)
    prompt = _apply_chat_template(tokenizer, messages)

    sampler = make_sampler(temp=temperature, top_p=top_p)

    first_t: float | None = None
    last: Any = None
    t0 = time.monotonic()
    n = 0
    for resp in stream_generate(model, tokenizer, prompt,
                                max_tokens=max_tokens, sampler=sampler):
        if first_t is None:
            first_t = time.monotonic()
            emit({"id": req_id, "event": "first_token",
                  "ms": (first_t - t0) * 1000.0})
        last = resp
        n += 1
        emit({"id": req_id, "event": "token",
              "text": resp.text,
              "tps": float(getattr(resp, "generation_tps", 0.0))})

    if last is None:
        raise RuntimeError("no tokens generated")

    return {
        "generation_tokens": int(getattr(last, "generation_tokens", n)),
        "generation_tps": float(getattr(last, "generation_tps", 0.0)),
        "prompt_tokens": int(getattr(last, "prompt_tokens", 0)),
        "prompt_tps": float(getattr(last, "prompt_tps", 0.0)),
        "peak_memory_gb": float(getattr(last, "peak_memory", 0.0)),
        "finish_reason": getattr(last, "finish_reason", "stop") or "stop",
        "first_token_ms": (first_t - t0) * 1000.0 if first_t else 0.0,
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="One-shot chat over a converted MLX model.")
    p.add_argument("--id", default="cli")
    p.add_argument("--model-path", required=True)
    p.add_argument("--prompt", required=True, help="user message text")
    p.add_argument("--system", default=None, help="optional system prompt")
    p.add_argument("--max-tokens", type=int, default=256)
    p.add_argument("--temperature", type=float, default=0.7)
    p.add_argument("--top-p", type=float, default=0.95)
    args = p.parse_args(argv)

    messages: list[dict[str, str]] = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
    messages.append({"role": "user", "content": args.prompt})

    try:
        result = chat(args.id, args.model_path, messages,
                      max_tokens=args.max_tokens,
                      temperature=args.temperature,
                      top_p=args.top_p)
        done(args.id, result)
        return 0
    except Exception as e:
        error(args.id, f"chat failed: {e}", exc=e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
