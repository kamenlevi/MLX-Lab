"""Benchmark a converted MLX model.

Measures three things on a local MLX model directory:

  1. Prefill throughput (tok/s) — how fast a long prompt is processed.
  2. Decode throughput (tok/s) — steady-state generation speed after warmup.
  3. Peak Metal memory during the run (GB).
  4. Perplexity on a fixed WikiText-2 sample (mean negative log-likelihood
     exponentiated over a sliding window).

The perplexity sample is a small, version-pinned plaintext shipped with the
backend so runs are reproducible without a network dependency. See
`data/wikitext2_sample.txt`.
"""

from __future__ import annotations

import argparse
import math
import statistics
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from _ipc import done, emit, error, log, progress


PERPLEXITY_SAMPLE = Path(__file__).parent / "data" / "wikitext2_sample.txt"


@dataclass
class BenchResult:
    model_path: str
    prefill_tokens: int
    prefill_tps: float
    decode_tokens: int
    decode_tps: float
    first_token_ms: float
    peak_memory_gb: float
    active_memory_gb: float
    perplexity: float | None
    perplexity_tokens: int
    elapsed_seconds: float

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


def _reset_memory_counters() -> None:
    import mlx.core as mx  # type: ignore

    # Older mlx versions used mx.metal.*; newer expose mx.reset_peak_memory.
    for name in ("reset_peak_memory",):
        fn = getattr(mx, name, None) or getattr(getattr(mx, "metal", None), name, None)
        if fn is not None:
            fn()
            return


def _read_memory_gb() -> tuple[float, float]:
    import mlx.core as mx  # type: ignore

    def _get(name: str) -> int:
        fn = getattr(mx, name, None) or getattr(getattr(mx, "metal", None), name, None)
        return int(fn()) if fn is not None else 0

    peak = _get("get_peak_memory")
    active = _get("get_active_memory")
    return peak / (1024 ** 3), active / (1024 ** 3)


def _run_generation(req_id: str, model_path: str, prompt_tokens: int,
                    decode_tokens: int) -> dict[str, Any]:
    import mlx.core as mx  # type: ignore
    from mlx_lm import load  # type: ignore
    from mlx_lm.generate import stream_generate  # type: ignore

    progress(req_id, 0.05, "load", f"loading {model_path}")
    model, tokenizer = load(model_path)

    # Build a deterministic prompt of approx the requested length by repeating
    # a neutral seed. We don't need semantic content — only token count.
    seed = "The quick brown fox jumps over the lazy dog. "
    primer = seed * max(1, prompt_tokens // 10)
    ids = tokenizer.encode(primer)[:prompt_tokens]
    prompt = tokenizer.decode(ids)

    _reset_memory_counters()
    progress(req_id, 0.15, "prefill", f"prefilling {prompt_tokens} tokens")

    first_token_t: float | None = None
    last: Any = None
    t0 = time.monotonic()
    n_emitted = 0
    for resp in stream_generate(model, tokenizer, prompt, max_tokens=decode_tokens):
        if first_token_t is None:
            first_token_t = time.monotonic()
        last = resp
        n_emitted += 1
        if n_emitted % 16 == 0:
            progress(req_id, 0.15 + 0.55 * (n_emitted / max(1, decode_tokens)),
                     "decode", f"{n_emitted}/{decode_tokens} tokens")

    t1 = time.monotonic()
    if last is None:
        raise RuntimeError("stream_generate produced no tokens")

    first_token_ms = (first_token_t - t0) * 1000.0 if first_token_t else 0.0
    peak_gb, active_gb = _read_memory_gb()

    return {
        "prefill_tokens": int(getattr(last, "prompt_tokens", prompt_tokens)),
        "prefill_tps": float(getattr(last, "prompt_tps", 0.0)),
        "decode_tokens": int(getattr(last, "generation_tokens", n_emitted)),
        "decode_tps": float(getattr(last, "generation_tps", n_emitted / max(1e-6, t1 - t0))),
        "first_token_ms": first_token_ms,
        "peak_memory_gb": peak_gb or float(getattr(last, "peak_memory", 0.0)),
        "active_memory_gb": active_gb,
        "_model": model,
        "_tokenizer": tokenizer,
    }


def _perplexity(req_id: str, model, tokenizer, max_tokens: int = 512) -> tuple[float | None, int]:
    """Mean per-token negative log likelihood over a fixed WikiText2 sample.

    We split the sample into 256-token windows, run a single forward pass per
    window, gather the log-probability of the actual next token at each
    position, and average. Skipped gracefully if the sample file is missing.
    """
    if not PERPLEXITY_SAMPLE.exists():
        log(req_id, f"perplexity sample missing at {PERPLEXITY_SAMPLE}; skipping",
            level="warn")
        return None, 0

    import mlx.core as mx  # type: ignore
    import mlx.nn as nn  # type: ignore

    text = PERPLEXITY_SAMPLE.read_text()
    ids = tokenizer.encode(text)[:max_tokens + 1]
    if len(ids) < 32:
        log(req_id, "perplexity sample too short after tokenization; skipping",
            level="warn")
        return None, 0

    window = 256
    nlls: list[float] = []
    total = 0
    n_windows = max(1, (len(ids) - 1) // window)
    for w in range(n_windows):
        chunk = ids[w * window: w * window + window + 1]
        if len(chunk) < 2:
            break
        x = mx.array(chunk[:-1])[None, :]
        y = mx.array(chunk[1:])[None, :]
        logits = model(x)
        logits = logits.astype(mx.float32)
        # Cross-entropy averaged over the window.
        loss = nn.losses.cross_entropy(logits, y, reduction="mean")
        mx.eval(loss)
        nlls.append(float(loss.item()))
        total += y.size
        progress(req_id, 0.75 + 0.2 * ((w + 1) / n_windows), "perplexity",
                 f"window {w + 1}/{n_windows}")

    if not nlls:
        return None, 0
    mean_nll = statistics.fmean(nlls)
    return math.exp(mean_nll), total


def run(req_id: str, model_path: str, prefill_tokens: int = 512,
        decode_tokens: int = 128, do_perplexity: bool = True,
        warmup: bool = True) -> dict[str, Any]:
    path = Path(model_path).expanduser().resolve()
    if not path.exists():
        raise FileNotFoundError(f"model not found: {path}")

    t_start = time.monotonic()
    progress(req_id, 0.02, "init", "starting benchmark")

    if warmup:
        # A tiny pass to JIT-compile kernels; not counted in stats.
        try:
            from mlx_lm import load  # type: ignore
            from mlx_lm.generate import stream_generate  # type: ignore
            m, tok = load(str(path))
            for _ in stream_generate(m, tok, "Hello.", max_tokens=4):
                pass
            del m, tok
        except Exception as e:
            log(req_id, f"warmup skipped: {e}", level="warn")

    stats = _run_generation(req_id, str(path), prefill_tokens, decode_tokens)
    model = stats.pop("_model")
    tokenizer = stats.pop("_tokenizer")

    ppl: float | None = None
    ppl_tokens = 0
    if do_perplexity:
        progress(req_id, 0.72, "perplexity", "computing perplexity")
        try:
            ppl, ppl_tokens = _perplexity(req_id, model, tokenizer)
        except Exception as e:
            log(req_id, f"perplexity failed: {e}", level="warn")

    result = BenchResult(
        model_path=str(path),
        prefill_tokens=stats["prefill_tokens"],
        prefill_tps=stats["prefill_tps"],
        decode_tokens=stats["decode_tokens"],
        decode_tps=stats["decode_tps"],
        first_token_ms=stats["first_token_ms"],
        peak_memory_gb=stats["peak_memory_gb"],
        active_memory_gb=stats["active_memory_gb"],
        perplexity=ppl,
        perplexity_tokens=ppl_tokens,
        elapsed_seconds=round(time.monotonic() - t_start, 2),
    ).as_dict()
    progress(req_id, 1.0, "done", "")
    return result


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Benchmark a converted MLX model.")
    p.add_argument("--id", default="cli")
    p.add_argument("--model-path", required=True,
                   help="Path to converted MLX model directory")
    p.add_argument("--prefill-tokens", type=int, default=512)
    p.add_argument("--decode-tokens", type=int, default=128)
    p.add_argument("--skip-perplexity", action="store_true")
    p.add_argument("--no-warmup", action="store_true")
    args = p.parse_args(argv)

    try:
        result = run(args.id, args.model_path,
                     prefill_tokens=args.prefill_tokens,
                     decode_tokens=args.decode_tokens,
                     do_perplexity=not args.skip_perplexity,
                     warmup=not args.no_warmup)
        done(args.id, result)
        return 0
    except Exception as e:
        error(args.id, f"benchmark failed: {e}", exc=e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
