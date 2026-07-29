"""Test different ONNX Runtime thread configurations to find optimal setting."""

import time

import onnxruntime as ort
from kokoro_onnx import Kokoro

from app.core.config import settings

TEST_TEXT = "Hello there"  # 2 words, matches _FIRST_SEG_WORDS
WARMUP_RUNS = 3
BENCH_RUNS = 10


def bench_config(threads: int) -> float:
    """Benchmark a specific intra_op_num_threads setting. Returns avg ms."""
    opts = ort.SessionOptions()
    opts.enable_mem_pattern = True
    opts.enable_cpu_mem_arena = True
    opts.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    opts.add_session_config_entry("session.intra_op.allow_spinning", "1")
    opts.intra_op_num_threads = threads

    session = ort.InferenceSession(
        settings.MODEL_PATH, opts, providers=["CPUExecutionProvider"]
    )
    model = Kokoro.from_session(session, settings.VOICES_PATH)

    # Warmup
    for _ in range(WARMUP_RUNS):
        model.create(TEST_TEXT, "af_bella", 1.0, "en-us")

    # Bench
    times = []
    for _ in range(BENCH_RUNS):
        t0 = time.perf_counter()
        model.create(TEST_TEXT, "af_bella", 1.0, "en-us")
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)

    avg = sum(times) / len(times)
    mn = min(times)
    return avg, mn


if __name__ == "__main__":
    import multiprocessing

    cores = multiprocessing.cpu_count()
    print(f"CPU cores: {cores}")
    print(f"Test text: '{TEST_TEXT}' ({len(TEST_TEXT.split())} words)")
    print(f"Warmup: {WARMUP_RUNS}, Bench: {BENCH_RUNS}\n")

    print(f"{'Threads':<10} {'Avg (ms)':<12} {'Min (ms)':<12}")
    print("-" * 34)

    # Test 0 (auto), 1, 2, 4, 6, 8, cores
    configs = sorted(set([0, 1, 2, 4, 6, 8, cores]))
    for t in configs:
        avg, mn = bench_config(t)
        label = f"{t} (auto)" if t == 0 else str(t)
        print(f"{label:<10} {avg:<12.1f} {mn:<12.1f}")
