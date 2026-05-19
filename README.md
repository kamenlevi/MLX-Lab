# MLX Lab

A native macOS app for converting, quantizing, benchmarking, and chatting with
local LLMs in MLX format on Apple Silicon.

## What it does

1. **Browse & search HuggingFace** for compatible models (Llama, Qwen, Mistral,
   Gemma, Phi families).
2. **Convert** any HF model to MLX with the quantization of your choice
   (`Q3`, `Q4`, `Q6`, `Q8`, or `fp16`) — every time, locally; no reliance on
   pre-converted community uploads.
3. **Benchmark** each variant: prefill tok/s, decode tok/s, first-token
   latency, peak Metal memory, and perplexity on a fixed WikiText-2 sample.
4. **Compare** two or more variants side by side with native Swift Charts.
5. **Chat** with any local model — streaming, with live tok/s.
6. **Manage** a library of converted models that survives restarts.

## Requirements

- Apple Silicon Mac (M-series). MLX is Apple-Silicon-only.
- macOS Sonoma 14 or newer (Sequoia recommended).
- Xcode 15+ to build.
- Homebrew Python 3.11 in `PATH`: `brew install python@3.11`.
- A few GB of free disk for the venv and however many GB for the models
  themselves (a 32B Q4 model is ≈ 18 GB).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project
  file: `brew install xcodegen`.

## Building

```bash
make bootstrap          # generates MLXLab.xcodeproj from project.yml
open MLXLab.xcodeproj   # ⌘R to run
```

On first launch the app creates a Python venv under
`~/Library/Application Support/MLXLab/venv` and `pip install`s `mlx-lm`,
`huggingface_hub`, `tqdm`, and `datasets`. This takes a few minutes the first
time and never again. If you don't have `python@3.11` on `PATH`, open
Settings → General and point MLX Lab at your interpreter.

## How it's wired

```
SwiftUI App  ──▶  PythonBridge  ──stdin/stdout JSON lines──▶  python_backend/server.py
                                                                  ├─ convert.py    (mlx_lm.convert wrapper)
                                                                  ├─ benchmark.py  (tok/s, memory, perplexity)
                                                                  └─ inference.py  (streaming chat)
SwiftData ◀─ library catalog + benchmark history
```

The Swift side never imports MLX directly — it spawns a single long-running
Python child and talks to it over JSON-line RPC. The protocol is documented at
the top of `MLXLab/python_backend/server.py`.

## Project layout

```
MLXLab/
├── App/             SwiftUI app lifecycle, menu, root tabs
├── Views/
│   ├── Library/     Local model list, sizes, benchmark history
│   ├── Convert/     HF search + quant picker + progress
│   ├── Benchmark/   Run + visualize benchmark for one model
│   ├── Compare/     Bar charts across multiple variants
│   ├── Chat/        Streaming inference UI
│   └── Settings/    Python path, defaults, help
├── Models/          SwiftData entities
├── Services/        PythonBridge, ModelLibrary, HFClient, AppPaths
├── Resources/       Info.plist, entitlements, Assets.xcassets
└── python_backend/  Python child; shipped inside the .app bundle
```

## Notes on quantization labels

MLX uses affine quantization parameterized by `q_bits` and `q_group_size`. The
GGUF `_K` suffixes (e.g. `Q4_K_M`) have **no MLX equivalent** — they describe
GGUF-specific mixed-precision schemes. The Q3/Q4/Q6/Q8 labels in MLX Lab map
directly to 3/4/6/8-bit affine quantization with a group size of 64, which is
the standard `mlx_lm.convert` default. `fp16` means no quantization (weights
are saved in float16).

## Testing the Python backend in isolation

```bash
make python-test    # ping/shutdown smoke test

# A real run (requires mlx + mlx-lm installed):
cd MLXLab/python_backend
python convert.py --model Qwen/Qwen3-0.6B --quant q4 --out-dir /tmp/qwen-q4
python benchmark.py --model-path /tmp/qwen-q4
python inference.py --model-path /tmp/qwen-q4 --prompt "Hello"
```

## Non-goals (v1)

- No GGUF support — MLX format only.
- No bundled Python — relies on system/Homebrew Python.
- No custom quantization code — wraps `mlx_lm.convert`.
- No generic OpenAI-compatible server — chat tab only.
