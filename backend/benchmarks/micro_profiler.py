"""Micro-profiler: measures each phase inside TTSEngine.generate() individually."""

import asyncio
import time

import numpy as np
from kokoro_onnx import Kokoro

from app.core.config import settings
from app.services.audio import AudioService


def profile_inference():
    """Profile a single ONNX inference call in isolation."""
    model_path = settings.ACTIVE_MODEL_PATH
    print(f"Loading model: {model_path}")
    model = Kokoro(model_path, settings.VOICES_PATH)

    # Warmup
    for _ in range(3):
        model.create("Warmup sequence.", "af_bella", 1.0, "en-us")

    # Profile different segment sizes
    segments = {
        "2 words": "Hello there",
        "3 words": "Hello there friend",
        "4 words": "The cat sat down",
        "5 words": "The cat sat down quietly",
        "8 words": "The quick brown fox jumps over the fence",
        "15 words": "This is a medium length sentence designed for testing the throughput of the model inference",
        "30 words": "This is a very long and complex sentence designed to stress the inference engine by providing a massive amount of phonemes for the ONNX model to process at once",
    }

    print("\n=== ONNX Inference Time by Segment Size ===")
    print(
        f"{'Segment':<12} {'Words':>5} {'Inference':>10} {'Phonemize':>10} {'Total':>10}"
    )
    print("-" * 55)

    for name, text in segments.items():
        times = []
        for _ in range(5):
            t0 = time.perf_counter()
            audio, _ = model.create(text, "af_bella", 1.0, "en-us")
            t1 = time.perf_counter()
            times.append((t1 - t0) * 1000)

        avg = sum(times) / len(times)
        mn = min(times)
        print(f"{name:<12} {len(text.split()):>5} {avg:>9.1f}ms {mn:>9.1f}ms (min)")

    # Profile the overhead operations
    print("\n=== Overhead Operations ===")

    # Fade application
    dummy_audio = np.random.randn(24000).astype(np.float32)  # 1 second
    times = []
    for _ in range(1000):
        t0 = time.perf_counter()
        AudioService.apply_fade(dummy_audio, fade_in=False, fade_out=True)
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)
    print(f"apply_fade (1s audio):     {sum(times)/len(times):.3f}ms avg")

    # Silence generation
    times = []
    for _ in range(1000):
        t0 = time.perf_counter()
        AudioService.generate_silence(0.35)
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)
    print(f"generate_silence (0.35s):  {sum(times)/len(times):.3f}ms avg")

    # np.concatenate
    silence = AudioService.generate_silence(0.35)
    times = []
    for _ in range(1000):
        t0 = time.perf_counter()
        np.concatenate([dummy_audio, silence])
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)
    print(f"np.concatenate (1s+0.35s): {sum(times)/len(times):.3f}ms avg")

    # PCM encoding (clip + int16 conversion)
    times = []
    for _ in range(1000):
        t0 = time.perf_counter()
        samples = np.clip(dummy_audio * 1.0, -1.0, 1.0)
        (samples * 32767).astype(np.int16).tobytes()
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)
    print(f"PCM encode (clip+int16):   {sum(times)/len(times):.3f}ms avg")

    # .copy() cost (needed for fade)
    times = []
    for _ in range(1000):
        t0 = time.perf_counter()
        dummy_audio.copy()
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)
    print(f"np.copy (1s audio):        {sum(times)/len(times):.3f}ms avg")

    # Segment splitting
    from app.services.tts import TTSEngine

    long_text = "This is a very long and complex sentence designed to stress the inference engine by providing a massive amount of phonemes for the ONNX model to process at once."
    times = []
    for _ in range(10000):
        t0 = time.perf_counter()
        TTSEngine._split_segments(long_text)
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1000)
    print(f"_split_segments (30w):     {sum(times)/len(times):.4f}ms avg")

    # asyncio.get_running_loop + run_in_executor overhead (measured separately)
    print("\n=== Event Loop Overhead ===")

    async def measure_executor_overhead():
        loop = asyncio.get_running_loop()

        def noop():
            return None

        times_list = []
        for _ in range(100):
            t0 = time.perf_counter()
            await loop.run_in_executor(None, noop)
            t1 = time.perf_counter()
            times_list.append((t1 - t0) * 1000)
        print(f"run_in_executor (noop):    {sum(times_list)/len(times_list):.3f}ms avg")

    asyncio.run(measure_executor_overhead())

    # Check ONNX session info
    print("\n=== ONNX Session Info ===")
    try:
        import onnxruntime as ort

        opts = ort.SessionOptions()
        print(f"Default intra_op_threads:  {opts.intra_op_num_threads}")
        print(f"Default inter_op_threads:  {opts.inter_op_num_threads}")
        print(f"Graph opt level:           {opts.graph_optimization_level}")
        print(f"Available providers:       {ort.get_available_providers()}")
        print(f"Device:                    {ort.get_device()}")
    except ImportError:
        print("onnxruntime not directly importable (bundled in kokoro-onnx)")


if __name__ == "__main__":
    profile_inference()
