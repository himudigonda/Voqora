#!/usr/bin/env python3
"""
Voqora Comprehensive TTS Benchmark
=====================================
Benchmarks all engines (Kokoro, Kitten nano/micro/mini) across:
  - Multiple voices
  - Multiple speeds (0.5x–2.5x)
  - Multiple text lengths (short / medium / long / paragraph)
  - N=5 warm runs per config

Metrics collected:
  - TTFA   : Time To First Audio byte (ms) — latency user perceives
  - TTTotal: Total time until last byte received (ms)
  - AudioDur: Duration of generated audio (seconds)
  - RTF    : Real-Time Factor = inference_time / audio_duration (lower=faster)
  - Throughput: Audio seconds generated per second of wall-clock time

Usage:
    cd /path/to/Voqora/backend
    uv run python ../scripts/benchmark_all.py
"""

import json
import struct
import sys
import time
from dataclasses import dataclass, field
from statistics import mean, median, stdev
from typing import Optional

import requests

BASE_URL = "http://localhost:10101"
SAMPLE_RATE = 24000  # Kokoro & KittenTTS both output 24kHz mono
BYTES_PER_SAMPLE = 2  # int16
WAV_HEADER_BYTES = 44

# ─── Corpus ────────────────────────────────────────────────────────────────────
TEXTS = {
    "short": "Hello, world!",
    "medium": "The quick brown fox jumps over the lazy dog near the riverbank.",
    "long": (
        "Artificial intelligence has transformed many industries over the past decade. "
        "From healthcare diagnostics to autonomous vehicles, machine learning models "
        "are being deployed at unprecedented scale. Text-to-speech technology, once "
        "requiring expensive hardware, now runs efficiently on consumer devices."
    ),
    "paragraph": (
        "In the beginning, there was silence. Then came language, and with it, the "
        "power to communicate across time and space. Today, neural text-to-speech "
        "systems synthesize natural-sounding speech with remarkable fidelity. "
        "The journey from rule-based concatenative synthesis to end-to-end neural "
        "models has been remarkable. Modern systems like Kokoro and KittenTTS "
        "demonstrate that high-quality speech synthesis is achievable at low latency "
        "on commodity hardware. This benchmark measures exactly that capability."
    ),
}

# ─── Engine Configs ─────────────────────────────────────────────────────────────
ENGINES = [
    {"engine": "kokoro", "model": None,    "voices": ["af_bella", "af_sarah", "am_adam", "am_michael", "bf_emma", "bf_isabella", "bm_george", "bm_lewis"]},
    {"engine": "kitten", "model": "nano",  "voices": ["Bella", "Jasper", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo"]},
    {"engine": "kitten", "model": "micro", "voices": ["Bella", "Jasper", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo"]},
    {"engine": "kitten", "model": "mini",  "voices": ["Bella", "Jasper", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo"]},
]

SPEEDS = [0.5, 1.0, 1.5, 2.0, 2.5]

# For full matrix we use a representative voice per engine + all speeds + all texts
# For voice comparison we use 1 text + 1 speed and sweep all voices
BENCHMARK_VOICE_PER_ENGINE = {
    "kokoro/": "af_bella",
    "kitten/nano": "Bella",
    "kitten/micro": "Bella",
    "kitten/mini": "Bella",
}

N_WARMUP = 1   # runs that are discarded
N_MEASURE = 3  # runs that are averaged (kept low for time; increase for more precision)
ENGINE_LOAD_TIMEOUT = 120  # seconds to wait for model load (Kokoro ~60s cold)


# ─── Helpers ────────────────────────────────────────────────────────────────────

def engine_label(cfg: dict) -> str:
    if cfg["model"]:
        return f"kitten/{cfg['model']}"
    return "kokoro/"


def switch_engine(engine: str, model: Optional[str] = None) -> bool:
    payload: dict = {"engine": engine}
    if model:
        payload["model"] = model
    try:
        r = requests.post(f"{BASE_URL}/engine", json=payload, timeout=30)
        if r.status_code == 200:
            return True
        print(f"  ⚠ switch_engine failed: {r.status_code} {r.text[:80]}")
        return False
    except Exception as e:
        print(f"  ⚠ switch_engine error: {e}")
        return False


def wait_ready(timeout: float = 60.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            r = requests.get(f"{BASE_URL}/health", timeout=5)
            if r.status_code == 200 and r.json().get("loaded"):
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


@dataclass
class RunResult:
    ttfa_ms: float       # time to first audio byte after WAV header
    total_ms: float      # time until stream closes
    audio_dur_s: float   # duration of generated audio from sample count
    rtf: float           # total_ms/1000 / audio_dur_s
    throughput: float    # audio_dur_s / (total_ms/1000)
    pcm_bytes: int       # raw PCM bytes received


@dataclass
class BenchmarkResult:
    engine: str
    voice: str
    speed: float
    text_label: str
    text_len: int
    runs: list[RunResult] = field(default_factory=list)

    def ttfa_ms_stats(self):
        vals = [r.ttfa_ms for r in self.runs]
        return _stats(vals)

    def total_ms_stats(self):
        vals = [r.total_ms for r in self.runs]
        return _stats(vals)

    def audio_dur_stats(self):
        vals = [r.audio_dur_s for r in self.runs]
        return _stats(vals)

    def rtf_stats(self):
        vals = [r.rtf for r in self.runs]
        return _stats(vals)

    def throughput_stats(self):
        vals = [r.throughput for r in self.runs]
        return _stats(vals)


def _stats(vals: list[float]) -> dict:
    if not vals:
        return {"mean": 0, "median": 0, "min": 0, "max": 0, "stdev": 0}
    return {
        "mean":   mean(vals),
        "median": median(vals),
        "min":    min(vals),
        "max":    max(vals),
        "stdev":  stdev(vals) if len(vals) > 1 else 0.0,
    }


def prewarm_request(text: str, voice: str, speed: float) -> bool:
    """POST /prewarm and wait for it to complete (it's fire-and-forget, so we sleep)."""
    payload = {"text": text, "voice": voice, "speed": speed}
    try:
        requests.post(f"{BASE_URL}/prewarm", json=payload, timeout=10)
        time.sleep(2.5)  # give background task time to generate and cache
        return True
    except Exception:
        return False


def run_single(text: str, voice: str, speed: float) -> Optional[RunResult]:
    """POST /speak, measure TTFA and collect all PCM."""
    payload = {"text": text, "voice": voice, "speed": speed, "volume": 1.0}
    try:
        t0 = time.perf_counter()
        with requests.post(f"{BASE_URL}/speak", json=payload, stream=True, timeout=120) as r:
            if r.status_code != 200:
                print(f"    ⚠ /speak returned {r.status_code}")
                return None

            ttfa_ms = None
            total_bytes = 0
            pcm_bytes = 0

            for chunk in r.iter_content(chunk_size=4096):
                if not chunk:
                    continue
                now = time.perf_counter()
                total_bytes += len(chunk)

                # First audio byte is right after the 44-byte WAV header
                if ttfa_ms is None and total_bytes > WAV_HEADER_BYTES:
                    ttfa_ms = (now - t0) * 1000

            t1 = time.perf_counter()
            total_ms = (t1 - t0) * 1000

            # PCM bytes = total bytes - WAV header
            pcm_bytes = max(0, total_bytes - WAV_HEADER_BYTES)
            # Duration from sample count: pcm_bytes / (sample_rate * bytes_per_sample)
            n_samples = pcm_bytes // BYTES_PER_SAMPLE
            audio_dur_s = n_samples / SAMPLE_RATE if n_samples > 0 else 0.001

            if ttfa_ms is None:
                ttfa_ms = total_ms  # no audio received — fallback

            rtf = (total_ms / 1000) / audio_dur_s
            throughput = audio_dur_s / (total_ms / 1000)

            return RunResult(
                ttfa_ms=ttfa_ms,
                total_ms=total_ms,
                audio_dur_s=audio_dur_s,
                rtf=rtf,
                throughput=throughput,
                pcm_bytes=pcm_bytes,
            )
    except Exception as e:
        print(f"    ⚠ run_single error: {e}")
        return None


# ─── Main benchmark logic ────────────────────────────────────────────────────────

def benchmark_config(
    engine_cfg: dict,
    voice: str,
    speed: float,
    text_label: str,
    text: str,
    n_warmup: int = N_WARMUP,
    n_measure: int = N_MEASURE,
) -> Optional[BenchmarkResult]:
    label = engine_label(engine_cfg)
    result = BenchmarkResult(
        engine=label,
        voice=voice,
        speed=speed,
        text_label=text_label,
        text_len=len(text),
    )

    # Warmup runs (discarded)
    for _ in range(n_warmup):
        run_single(text, voice, speed)

    # Measured runs
    for i in range(n_measure):
        r = run_single(text, voice, speed)
        if r:
            result.runs.append(r)

    if not result.runs:
        return None
    return result


def print_progress(msg: str):
    print(f"  {msg}", flush=True)


# ─── Report generation ──────────────────────────────────────────────────────────

def fmt_ms(stats: dict) -> str:
    return f"{stats['mean']:.0f}ms (±{stats['stdev']:.0f}, min={stats['min']:.0f}, max={stats['max']:.0f})"


def fmt_s(stats: dict) -> str:
    return f"{stats['mean']:.3f}s"


def fmt_rtf(stats: dict) -> str:
    return f"{stats['mean']:.3f}x"


def fmt_throughput(stats: dict) -> str:
    return f"{stats['mean']:.2f}x"


def generate_markdown(results: list[BenchmarkResult], system_info: dict) -> str:
    lines = []

    lines.append("# Voqora TTS Benchmark Report")
    lines.append("")
    lines.append(f"> Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"> Platform: {system_info.get('platform', 'macOS')}")
    lines.append(f"> N warmup: {N_WARMUP} | N measured: {N_MEASURE} per config")
    lines.append("")

    lines.append("## Glossary")
    lines.append("")
    lines.append("| Term | Definition |")
    lines.append("|------|-----------|")
    lines.append("| **TTFA** | Time To First Audio — ms from request to first PCM byte; what the user perceives as startup latency |")
    lines.append("| **TTTotal** | Total streaming time until last byte received |")
    lines.append("| **Audio Dur** | Duration of the generated speech audio |")
    lines.append("| **RTF** | Real-Time Factor = wall_time / audio_dur; <1.0 means faster-than-realtime |")
    lines.append("| **Throughput** | Audio seconds generated per second; RTF⁻¹ |")
    lines.append("")

    lines.append("## System Info")
    lines.append("")
    lines.append("```")
    for k, v in system_info.items():
        lines.append(f"{k}: {v}")
    lines.append("```")
    lines.append("")

    # ── Section 1: Speed benchmark (medium text, default voice) ──────────────────
    lines.append("---")
    lines.append("")
    lines.append("## 1. Speed Scaling — TTFA & RTF (medium text, representative voice)")
    lines.append("")
    lines.append("How each engine handles different playback speeds. Lower TTFA = more responsive. Lower RTF = faster inference.")
    lines.append("")

    speed_results = [r for r in results if r.text_label == "medium" and "voice_sweep" not in r.text_label]

    engines_seen = sorted({r.engine for r in speed_results})
    for eng in engines_seen:
        eng_results = [r for r in speed_results if r.engine == eng]
        if not eng_results:
            continue
        lines.append(f"### {eng}")
        lines.append("")
        lines.append("| Speed | Voice | TTFA (mean±σ) | TTTotal | Audio Dur | RTF | Throughput |")
        lines.append("|-------|-------|---------------|---------|-----------|-----|------------|")
        for r in sorted(eng_results, key=lambda x: x.speed):
            lines.append(
                f"| {r.speed}x | {r.voice} "
                f"| {fmt_ms(r.ttfa_ms_stats())} "
                f"| {fmt_ms(r.total_ms_stats())} "
                f"| {fmt_s(r.audio_dur_stats())} "
                f"| {fmt_rtf(r.rtf_stats())} "
                f"| {fmt_throughput(r.throughput_stats())} |"
            )
        lines.append("")

    # ── Section 2: Text Length benchmark (1.0x speed, default voice) ─────────────
    lines.append("---")
    lines.append("")
    lines.append("## 2. Text Length Scaling (speed=1.0x, representative voice)")
    lines.append("")
    lines.append("How TTFA and RTF change with input length. TTFA should be low and stable (only depends on first segment).")
    lines.append("")

    length_results = [r for r in results if r.speed == 1.0 and r.text_label in TEXTS]
    engines_seen = sorted({r.engine for r in length_results})
    for eng in engines_seen:
        eng_results = [r for r in length_results if r.engine == eng]
        if not eng_results:
            continue
        lines.append(f"### {eng}")
        lines.append("")
        lines.append("| Text | Chars | TTFA | TTTotal | Audio Dur | RTF |")
        lines.append("|------|-------|------|---------|-----------|-----|")
        for r in sorted(eng_results, key=lambda x: x.text_len):
            lines.append(
                f"| {r.text_label} | {r.text_len} "
                f"| {fmt_ms(r.ttfa_ms_stats())} "
                f"| {fmt_ms(r.total_ms_stats())} "
                f"| {fmt_s(r.audio_dur_stats())} "
                f"| {fmt_rtf(r.rtf_stats())} |"
            )
        lines.append("")

    # ── Section 3: Voice comparison (medium text, 1.0x speed) ────────────────────
    lines.append("---")
    lines.append("")
    lines.append("## 3. Voice Comparison (medium text, speed=1.0x)")
    lines.append("")
    lines.append("All voices for each engine. Measures per-voice latency variation.")
    lines.append("")

    voice_results = [r for r in results if r.text_label == "voice_sweep"]
    engines_seen = sorted({r.engine for r in voice_results})
    for eng in engines_seen:
        eng_results = [r for r in voice_results if r.engine == eng]
        if not eng_results:
            continue
        lines.append(f"### {eng}")
        lines.append("")
        lines.append("| Voice | TTFA | TTTotal | Audio Dur | RTF |")
        lines.append("|-------|------|---------|-----------|-----|")
        for r in sorted(eng_results, key=lambda x: x.voice):
            lines.append(
                f"| {r.voice} "
                f"| {fmt_ms(r.ttfa_ms_stats())} "
                f"| {fmt_ms(r.total_ms_stats())} "
                f"| {fmt_s(r.audio_dur_stats())} "
                f"| {fmt_rtf(r.rtf_stats())} |"
            )
        lines.append("")

    # ── Section 3b: Prewarm cache TTFA ───────────────────────────────────────────
    prewarm_res = [r for r in results if r.text_label == "prewarm_cache"]
    if prewarm_res:
        lines.append("---")
        lines.append("")
        lines.append("## 3b. Prewarm Cache TTFA (the path real users experience)")
        lines.append("")
        lines.append(
            "Swift calls `/prewarm` when clipboard changes. The next `/speak` hits the "
            "cache and streams the first segment instantly. **This is the TTFA users actually feel.**"
        )
        lines.append("")
        lines.append("| Engine | Voice | TTFA (cache hit) | TTTotal | RTF |")
        lines.append("|--------|-------|-----------------|---------|-----|")
        seen = set()
        for r in prewarm_res:
            key = (r.engine, r.voice)
            if key in seen:
                continue
            seen.add(key)
            ttfas = [run.ttfa_ms for run in r.runs]
            total_ms = [run.total_ms for run in r.runs]
            rtfs = [run.rtf for run in r.runs]
            lines.append(
                f"| {r.engine} | {r.voice} "
                f"| **{mean(ttfas):.0f}ms** "
                f"| {mean(total_ms):.0f}ms "
                f"| {mean(rtfs):.3f}x |"
            )
        lines.append("")

    # ── Section 4: Engine comparison summary ─────────────────────────────────────
    lines.append("---")
    lines.append("")
    lines.append("## 4. Engine Comparison Summary (medium text, speed=1.0x)")
    lines.append("")

    # Find 1.0x medium results for each engine
    summary_results = [r for r in results if r.speed == 1.0 and r.text_label == "medium"]
    lines.append("| Engine | Model Size | Voice | TTFA | RTF | Throughput |")
    lines.append("|--------|-----------|-------|------|-----|------------|")

    MODEL_SIZES = {
        "kokoro/": "326 MB (FP32)",
        "kitten/nano": "57 MB",
        "kitten/micro": "41 MB",
        "kitten/mini": "78 MB",
    }

    for r in sorted(summary_results, key=lambda x: x.engine):
        size = MODEL_SIZES.get(r.engine, "?")
        lines.append(
            f"| {r.engine} | {size} | {r.voice} "
            f"| {fmt_ms(r.ttfa_ms_stats())} "
            f"| {fmt_rtf(r.rtf_stats())} "
            f"| {fmt_throughput(r.throughput_stats())} |"
        )
    lines.append("")

    # ── Section 5: Paragraph benchmark (stress test) ──────────────────────────────
    lines.append("---")
    lines.append("")
    lines.append("## 5. Paragraph Stress Test (speed=1.0x and 2.0x, representative voice)")
    lines.append("")
    lines.append("Tests sustained throughput on long-form text (~4 sentences). TTFA should remain low; RTF shows total pipeline speed.")
    lines.append("")

    para_results = [r for r in results if r.text_label == "paragraph"]
    engines_seen = sorted({r.engine for r in para_results})
    if para_results:
        lines.append("| Engine | Speed | TTFA | TTTotal | Audio Dur | RTF | Throughput |")
        lines.append("|--------|-------|------|---------|-----------|-----|------------|")
        for r in sorted(para_results, key=lambda x: (x.engine, x.speed)):
            lines.append(
                f"| {r.engine} | {r.speed}x "
                f"| {fmt_ms(r.ttfa_ms_stats())} "
                f"| {fmt_ms(r.total_ms_stats())} "
                f"| {fmt_s(r.audio_dur_stats())} "
                f"| {fmt_rtf(r.rtf_stats())} "
                f"| {fmt_throughput(r.throughput_stats())} |"
            )
        lines.append("")

    # ── Section 6: Raw data ───────────────────────────────────────────────────────
    lines.append("---")
    lines.append("")
    lines.append("## 6. Raw Run Data")
    lines.append("")
    lines.append("<details>")
    lines.append("<summary>Click to expand all individual runs</summary>")
    lines.append("")
    lines.append("| Engine | Voice | Speed | Text | Run | TTFA(ms) | Total(ms) | AudioDur(s) | RTF |")
    lines.append("|--------|-------|-------|------|-----|----------|-----------|-------------|-----|")
    for r in results:
        for i, run in enumerate(r.runs):
            lines.append(
                f"| {r.engine} | {r.voice} | {r.speed}x | {r.text_label} | {i+1} "
                f"| {run.ttfa_ms:.1f} | {run.total_ms:.1f} | {run.audio_dur_s:.3f} | {run.rtf:.3f} |"
            )
    lines.append("")
    lines.append("</details>")
    lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("*Generated by `scripts/benchmark_all.py` — Voqora TTS Benchmark Suite*")

    return "\n".join(lines)


# ─── Entry point ─────────────────────────────────────────────────────────────────

def get_system_info() -> dict:
    import platform
    info = {
        "OS": platform.platform(),
        "Python": platform.python_version(),
        "Machine": platform.machine(),
        "Processor": platform.processor(),
    }
    try:
        import subprocess
        cpu_brand = subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], stderr=subprocess.DEVNULL
        ).decode().strip()
        info["CPU"] = cpu_brand
    except Exception:
        pass
    try:
        import subprocess
        mem_bytes = int(subprocess.check_output(
            ["sysctl", "-n", "hw.memsize"], stderr=subprocess.DEVNULL
        ).decode().strip())
        info["RAM"] = f"{mem_bytes // (1024**3)} GB"
    except Exception:
        pass
    return info


def check_server() -> bool:
    try:
        r = requests.get(f"{BASE_URL}/health", timeout=5)
        return r.status_code == 200
    except Exception:
        return False


def main():
    print("=" * 60)
    print("  Voqora TTS Comprehensive Benchmark")
    print("=" * 60)
    print()

    if not check_server():
        print("❌ Server not reachable at localhost:10101")
        print("   Start it with: cd backend && uv run python app/main.py")
        sys.exit(1)

    system_info = get_system_info()
    for k, v in system_info.items():
        print(f"  {k}: {v}")
    print()

    all_results: list[BenchmarkResult] = []
    total_configs = 0

    # ── Phase 1: Speed + text-length sweep (representative voice, all speeds, all texts) ──
    print("Phase 1: Speed & text-length sweep")
    print("-" * 40)

    for eng_cfg in ENGINES:
        label = engine_label(eng_cfg)
        voice = BENCHMARK_VOICE_PER_ENGINE.get(label, eng_cfg["voices"][0])

        print(f"\n▶ Engine: {label}  voice={voice}")

        # Switch engine
        ok = switch_engine(eng_cfg["engine"], eng_cfg["model"])
        if not ok:
            print(f"  ⚠ Could not switch to {label}, skipping.")
            continue

        # Wait for model to load
        print(f"  Waiting for model load...", end=" ", flush=True)
        if not wait_ready(timeout=ENGINE_LOAD_TIMEOUT):
            print("TIMEOUT — skipping")
            continue
        print("ready")

        for speed in SPEEDS:
            for text_label, text in TEXTS.items():
                if text_label == "paragraph" and speed not in (1.0, 2.0):
                    # Paragraph only at 1.0 and 2.0 to save time
                    continue
                total_configs += 1
                print(f"  speed={speed}x  text={text_label} ({len(text)}c)  ", end="", flush=True)
                result = benchmark_config(
                    eng_cfg, voice, speed, text_label, text
                )
                if result:
                    all_results.append(result)
                    ttfa = result.ttfa_ms_stats()["mean"]
                    rtf = result.rtf_stats()["mean"]
                    print(f"TTFA={ttfa:.0f}ms  RTF={rtf:.3f}x")
                else:
                    print("FAILED")

    # ── Phase 2: Voice sweep (medium text, 1.0x speed) ──────────────────────────
    print("\n\nPhase 2: Voice sweep (medium text, 1.0x)")
    print("-" * 40)

    for eng_cfg in ENGINES:
        label = engine_label(eng_cfg)

        print(f"\n▶ Engine: {label}")
        ok = switch_engine(eng_cfg["engine"], eng_cfg["model"])
        if not ok:
            print(f"  ⚠ skip")
            continue
        if not wait_ready(timeout=120):
            print("  ⚠ load timeout, skip")
            continue

        for voice in eng_cfg["voices"]:
            print(f"  voice={voice:<14}", end="", flush=True)
            result = benchmark_config(
                eng_cfg, voice, 1.0, "voice_sweep", TEXTS["medium"],
                n_warmup=1, n_measure=2
            )
            if result:
                all_results.append(result)
                ttfa = result.ttfa_ms_stats()["mean"]
                rtf = result.rtf_stats()["mean"]
                print(f"TTFA={ttfa:.0f}ms  RTF={rtf:.3f}x")
            else:
                print("FAILED")

    # ── Phase 3: Prewarm cache TTFA (medium text, 1.0x, representative voice) ────
    print("\n\nPhase 3: Prewarm cache TTFA (medium text, 1.0x)")
    print("-" * 40)
    print("  (prewarm → wait 2.5s → speak — measures cache-hit TTFA)")

    prewarm_results: list[BenchmarkResult] = []
    for eng_cfg in ENGINES:
        label = engine_label(eng_cfg)
        voice = BENCHMARK_VOICE_PER_ENGINE.get(label, eng_cfg["voices"][0])
        text = TEXTS["medium"]

        print(f"\n▶ Engine: {label}  voice={voice}")
        ok = switch_engine(eng_cfg["engine"], eng_cfg["model"])
        if not ok:
            print("  ⚠ skip")
            continue
        if not wait_ready(timeout=ENGINE_LOAD_TIMEOUT):
            print("  ⚠ load timeout, skip")
            continue

        # Warmup speak so the model is hot
        run_single(text, voice, 1.0)

        # Prewarm then measure TTFA
        for _ in range(2):
            prewarm_request(text, voice, 1.0)
            r = run_single(text, voice, 1.0)
            if r:
                pw_result = BenchmarkResult(
                    engine=label, voice=voice, speed=1.0,
                    text_label="prewarm_cache", text_len=len(text),
                )
                pw_result.runs.append(r)
                prewarm_results.append(pw_result)
                print(f"  TTFA={r.ttfa_ms:.0f}ms  RTF={r.rtf:.3f}x  (prewarm cache hit)")

    all_results.extend(prewarm_results)

    # ── Generate report ──────────────────────────────────────────────────────────
    print("\n\nGenerating report...")
    md = generate_markdown(all_results, system_info)

    out_path = "/Users/himudigonda/Desktop/benchmarks.md"
    with open(out_path, "w") as f:
        f.write(md)

    print(f"✅ Report written to: {out_path}")
    print(f"   Total configs benchmarked: {total_configs}")
    print(f"   Total results collected:   {len(all_results)}")

    # Also dump raw JSON for analysis
    json_path = "/Users/himudigonda/Desktop/benchmarks_raw.json"
    raw = []
    for r in all_results:
        for run in r.runs:
            raw.append({
                "engine": r.engine, "voice": r.voice, "speed": r.speed,
                "text_label": r.text_label, "text_len": r.text_len,
                "ttfa_ms": run.ttfa_ms, "total_ms": run.total_ms,
                "audio_dur_s": run.audio_dur_s, "rtf": run.rtf,
                "throughput": run.throughput, "pcm_bytes": run.pcm_bytes,
            })
    with open(json_path, "w") as f:
        json.dump(raw, f, indent=2)
    print(f"✅ Raw JSON written to:  {json_path}")


if __name__ == "__main__":
    main()
