#!/usr/bin/env python3
"""
One-shot INT8 dynamic quantization for the Kokoro ONNX model.

Usage:
    cd backend && uv run python scripts/quantize_model.py

Strategy:
  1. Try full INT8 quantization (all ops). If the produced model is not runnable
     on the CPU provider (ConvInteger not implemented), fall back to step 2.
  2. MatMul+Gather-only quantization — quantizes attention/linear weights but
     leaves Conv layers in FP32. This always produces a runnable model.

Creates kokoro-v1.0-int8.onnx (or replaces it with the best viable variant).
Prints file sizes and a 5-run latency comparison for 1-, 2-, and 5-word segments.
"""

import os
import sys
import time

# Add backend root to path so app.core.config is importable
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import onnxruntime as ort
from kokoro_onnx import Kokoro
from onnxruntime.quantization import QuantType, quantize_dynamic

from app.core.config import settings


def make_session(path: str) -> ort.InferenceSession:
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    opts.intra_op_num_threads = min(6, os.cpu_count() or 4)
    return ort.InferenceSession(path, opts, providers=["CPUExecutionProvider"])


def bench(model: Kokoro, test_cases: list, label: str) -> None:
    model.create("Hello.", "af_bella", 1.0, "en-us")  # warm-up
    print(f"\n  [{label}]")
    for seg_label, seg_text in test_cases:
        times = []
        for _ in range(5):
            t = time.perf_counter()
            model.create(seg_text, "af_bella", 1.0, "en-us")
            times.append((time.perf_counter() - t) * 1000)
        avg = sum(times) / len(times)
        best = min(times)
        print(f"    {seg_label:8s}: avg={avg:.0f}ms  best={best:.0f}ms")


def main() -> None:
    fp32_path = settings.MODEL_PATH
    int8_path = fp32_path.replace(".onnx", "-int8.onnx")

    if not os.path.exists(fp32_path):
        print(f"[quantize] ERROR: FP32 model not found at {fp32_path}")
        sys.exit(1)

    test_cases = [
        ("1-word", "Hello"),
        ("2-word", "Hello world"),
        ("5-word", "Hello world this is interesting"),
    ]

    # ── FP32 baseline ─────────────────────────────────────────────────────────
    fp32_mb = os.path.getsize(fp32_path) / 1_048_576
    print(f"[quantize] FP32 model: {fp32_mb:.1f} MB")
    print("[quantize] Benchmarking FP32 baseline (5 warm runs each)...")
    bench(
        Kokoro.from_session(make_session(fp32_path), settings.VOICES_PATH),
        test_cases,
        "FP32 baseline",
    )

    # ── Attempt 1: Full INT8 quantization ─────────────────────────────────────
    print("\n[quantize] Attempting full INT8 quantization (all ops)...")
    t0 = time.perf_counter()
    quantize_dynamic(fp32_path, int8_path, weight_type=QuantType.QInt8)
    print(f"[quantize] Quantization done in {time.perf_counter() - t0:.1f}s")

    int8_mb = os.path.getsize(int8_path) / 1_048_576
    reduction = 100 * (1 - int8_mb / fp32_mb)
    print(
        f"[quantize] Size: {fp32_mb:.1f} MB → {int8_mb:.1f} MB  ({reduction:.0f}% smaller)"
    )

    try:
        model_int8 = Kokoro.from_session(make_session(int8_path), settings.VOICES_PATH)
        bench(model_int8, test_cases, "INT8 full")
        print(f"\n[quantize] Full INT8 model is ready: {int8_path}")
        return
    except Exception as e:
        print(f"[quantize] Full INT8 not runnable ({type(e).__name__}: {e})")
        print("[quantize] Falling back to MatMul+Gather quantization...")

    # ── Attempt 2: MatMul+Gather only (always CPU-runnable) ───────────────────
    t0 = time.perf_counter()
    quantize_dynamic(
        fp32_path,
        int8_path,
        weight_type=QuantType.QInt8,
        op_types_to_quantize=["MatMul", "Gather"],
    )
    print(
        f"[quantize] MatMul+Gather quantization done in {time.perf_counter() - t0:.1f}s"
    )

    int8_mb = os.path.getsize(int8_path) / 1_048_576
    reduction = 100 * (1 - int8_mb / fp32_mb)
    print(
        f"[quantize] Size: {fp32_mb:.1f} MB → {int8_mb:.1f} MB  ({reduction:.0f}% smaller)"
    )

    model_int8 = Kokoro.from_session(make_session(int8_path), settings.VOICES_PATH)
    bench(model_int8, test_cases, "INT8 MatMul+Gather")

    print(f"\n[quantize] Quantized model (MatMul+Gather) is ready: {int8_path}")
    print("[quantize] Backend will auto-detect it at startup via ACTIVE_MODEL_PATH.")


if __name__ == "__main__":
    main()
