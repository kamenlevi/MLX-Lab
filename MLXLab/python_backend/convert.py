"""Convert a HuggingFace model to MLX format with optional quantization.

Wraps `mlx_lm.convert.convert`. Because the upstream call doesn't expose
fine-grained progress, we segment progress into download → load → quantize →
save phases and emit progress events at each boundary. Real per-layer progress
is approximated by hooking the Hub download (snapshot_download) where possible.

Usage (CLI, for testing without the Swift host):

    python -m python_backend.convert \\
        --id test1 \\
        --model Qwen/Qwen3-0.6B \\
        --quant q4 \\
        --out-dir /tmp/qwen3-q4

The same module is invoked by the long-running JSON-IPC server in `server.py`.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path
from typing import Any

from _ipc import done, emit, error, log, progress


# Map UI-facing quant labels to mlx_lm.convert kwargs.
# MLX uses affine quantization with q_bits + q_group_size; the GGUF "_K" suffix
# has no direct MLX equivalent, so we treat Q3_K/Q4_K/Q6/Q8 as labels for
# affine quantization at the corresponding bit-width with the standard group
# size of 64. fp16 means no quantization (dtype passthrough).
QUANT_PRESETS: dict[str, dict[str, Any]] = {
    "q3":    {"quantize": True,  "q_bits": 3, "q_group_size": 64},
    "q3_k":  {"quantize": True,  "q_bits": 3, "q_group_size": 64},
    "q4":    {"quantize": True,  "q_bits": 4, "q_group_size": 64},
    "q4_k":  {"quantize": True,  "q_bits": 4, "q_group_size": 64},
    "q6":    {"quantize": True,  "q_bits": 6, "q_group_size": 64},
    "q8":    {"quantize": True,  "q_bits": 8, "q_group_size": 64},
    "fp16":  {"quantize": False, "dtype": "float16"},
    "bf16":  {"quantize": False, "dtype": "bfloat16"},
}


def normalize_quant(label: str) -> dict[str, Any]:
    key = label.lower().replace("-", "_")
    if key not in QUANT_PRESETS:
        raise ValueError(
            f"unknown quant '{label}'. Supported: {', '.join(QUANT_PRESETS)}"
        )
    return dict(QUANT_PRESETS[key])


def _stage_pump(req_id: str, stop: threading.Event, stage: str,
                start_pct: float, end_pct: float, duration_estimate: float) -> None:
    """Smoothly interpolate progress between two checkpoints so the UI moves
    even when the underlying operation gives no signal."""
    start = time.monotonic()
    while not stop.is_set():
        elapsed = time.monotonic() - start
        frac = min(0.99, elapsed / max(1e-6, duration_estimate))
        progress(req_id, start_pct + (end_pct - start_pct) * frac, stage)
        if stop.wait(0.4):
            return


def run(req_id: str, model: str, quant: str, out_dir: str,
        revision: str | None = None, trust_remote_code: bool = False) -> dict[str, Any]:
    out = Path(out_dir).expanduser().resolve()
    if out.exists() and any(out.iterdir()):
        raise FileExistsError(f"output directory '{out}' is not empty")
    out.parent.mkdir(parents=True, exist_ok=True)

    kwargs = normalize_quant(quant)
    log(req_id, f"resolved quant '{quant}' -> {kwargs}")

    # Import lazily so import errors are reported via IPC, not at module load.
    from mlx_lm.convert import convert as mlx_convert  # type: ignore

    progress(req_id, 0.02, "prepare", f"converting {model}")

    # Phase 1: download + load (we can't see into this, so pump an estimate).
    stop = threading.Event()
    t0 = time.monotonic()
    pump = threading.Thread(
        target=_stage_pump,
        args=(req_id, stop, "download", 0.05, 0.55, 90.0),
        daemon=True,
    )
    pump.start()

    try:
        mlx_convert(
            hf_path=model,
            mlx_path=str(out),
            revision=revision,
            trust_remote_code=trust_remote_code,
            **kwargs,
        )
    finally:
        stop.set()
        pump.join(timeout=1.0)

    progress(req_id, 0.95, "save", "writing weights and tokenizer")

    # Inventory the output directory for the library entry.
    files = sorted(p.name for p in out.iterdir() if p.is_file())
    total_bytes = sum(p.stat().st_size for p in out.rglob("*") if p.is_file())

    config_path = out / "config.json"
    config_summary: dict[str, Any] = {}
    if config_path.exists():
        try:
            cfg = json.loads(config_path.read_text())
            for k in ("model_type", "architectures", "hidden_size",
                      "num_hidden_layers", "num_attention_heads",
                      "vocab_size", "max_position_embeddings", "quantization"):
                if k in cfg:
                    config_summary[k] = cfg[k]
        except Exception as e:
            log(req_id, f"could not parse config.json: {e}", level="warn")

    elapsed = time.monotonic() - t0
    progress(req_id, 1.0, "done", f"converted in {elapsed:.1f}s")

    return {
        "out_dir": str(out),
        "files": files,
        "size_bytes": total_bytes,
        "config": config_summary,
        "quant_label": quant,
        "elapsed_seconds": round(elapsed, 2),
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Convert an HF model to MLX format.")
    p.add_argument("--id", default="cli", help="IPC request id (default: cli)")
    p.add_argument("--model", required=True, help="HF repo id, e.g. Qwen/Qwen3-0.6B")
    p.add_argument("--quant", required=True,
                   choices=sorted(QUANT_PRESETS.keys()),
                   help="quantization preset")
    p.add_argument("--out-dir", required=True, help="destination directory")
    p.add_argument("--revision", default=None)
    p.add_argument("--trust-remote-code", action="store_true")
    args = p.parse_args(argv)

    try:
        result = run(args.id, args.model, args.quant, args.out_dir,
                     revision=args.revision,
                     trust_remote_code=args.trust_remote_code)
        done(args.id, result)
        return 0
    except Exception as e:
        error(args.id, f"convert failed: {e}", exc=e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
