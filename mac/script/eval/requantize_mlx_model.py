#!/usr/bin/env python3
"""Requantizes an MLX affine-quantized model folder to fewer bits, locally.

Used for the 4-bit recognizer experiment (DICTATION_ARCHITECTURE §15)
without downloading another build: every quantized weight of the source
(for example Qwen3-ASR 1.7B 8-bit) is dequantized and quantized again at
`--bits`; unquantized tensors (the audio encoder) are copied as they are.
The result is a lower bound for a build quantized once from the original
weights, because it is quantized twice.

Usage (through the shared build lock, with a cache limit and memory_guard):
  python3 requantize_mlx_model.py SRC_DIR DST_DIR --bits 4 [--cache-limit-mb 1024]
Needs Python MLX (mlx.core); prints sizes only.
"""

import argparse
import json
import shutil
from pathlib import Path

import mlx.core as mx


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--bits", type=int, default=4)
    parser.add_argument("--cache-limit-mb", type=int, default=1024)
    args = parser.parse_args()
    mx.set_cache_limit(args.cache_limit_mb * 1024 * 1024)

    config = json.loads((args.source / "config.json").read_text())
    quantization = config["quantization"]
    group_size, bits = quantization["group_size"], quantization["bits"]
    if args.bits >= bits:
        raise SystemExit("requantize only to fewer bits")
    weights = mx.load(str(args.source / "model.safetensors"))
    out = {}
    requantized = 0
    for name, value in weights.items():
        if name.endswith(".scales") or name.endswith(".biases"):
            continue
        base = name[: -len(".weight")] if name.endswith(".weight") else None
        if base and f"{base}.scales" in weights:
            full = mx.dequantize(
                value, weights[f"{base}.scales"], weights[f"{base}.biases"],
                group_size=group_size, bits=bits,
            )
            q, scales, biases = mx.quantize(full, group_size=group_size, bits=args.bits)
            mx.eval(q, scales, biases)
            out[name], out[f"{base}.scales"], out[f"{base}.biases"] = q, scales, biases
            requantized += 1
        else:
            out[name] = value
    args.destination.mkdir(parents=True, exist_ok=False)
    mx.save_safetensors(
        str(args.destination / "model.safetensors"), out, metadata={"format": "mlx"}
    )
    for item in args.source.iterdir():
        if item.name in ("model.safetensors", "config.json", "model.safetensors.index.json"):
            continue
        if item.is_file():
            shutil.copy2(item, args.destination / item.name)
    for key in ("quantization", "quantization_config"):
        if key in config:
            config[key] = {**config[key], "bits": args.bits}
    (args.destination / "config.json").write_text(json.dumps(config, indent=2))
    size = (args.destination / "model.safetensors").stat().st_size
    print(f"requantized {requantized} layers to {args.bits} bits; weights {size / 1e9:.2f} GB")


if __name__ == "__main__":
    main()
