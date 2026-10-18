import asyncio
import atexit
import concurrent.futures
import os
import re
import shutil
import tempfile
import time
from collections import OrderedDict
from collections.abc import AsyncGenerator

import espeakng_loader
import numpy as np
import onnxruntime as ort
from kokoro_onnx import Kokoro
from kokoro_onnx.config import EspeakConfig

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audio import AudioService
from app.services.languages import DEFAULT_VOICE
from app.services.pronunciation import EMPTY_RULES, PronunciationRules
from app.services.voice_blends import blend_styles
from app.services.voices import VoiceSpec, builtin_spec, voice_spec

log = get_logger(__name__)

SEGMENT_PAUSE_SECONDS = {".": 0.35, "!": 0.35, "?": 0.35, ":": 0.2, ";": 0.2, ",": 0.12}
DEFAULT_SEGMENT_PAUSE_SECONDS = 0.1
MIN_PAUSE_SCALE = 0.5
MAX_PAUSE_SCALE = 2.0

# Periods that almost never end a sentence. Each segment is synthesized on its
# own, so a break after "Dr." spoke it with a full stop and split the transcript
# line. Words that often do end one ("etc.", "Inc.", "p.m.", "U.S.", a lone
# capital, years) are left out.
_NO_BREAK_AFTER_RE = re.compile(
    r"^\(?\d{1,3}[.)]$|(?:^|\s)"
    r"(?:[Mm]rs?|[Mm]s|[Dd]r|[Pp]rof|[Ss]r|[Jj]r|[Ss]t|vs|cf|al|fig|approx|e\.g|i\.e)\.$"
)
_SEGMENT_SENTENCE_END_RE = re.compile(
    r"[.!?\u3002\uff01\uff1f\u0964][\"'\u201d\u2019)\]]*$"
)

# espeak-ng stores the data directory handed to `espeak_Initialize()` in a
# fixed 160-byte global (`char path_home[N_PATH_HOME]`). A longer path is NOT
# reported as an error to the caller: espeak-ng silently discards it and falls
# back through $ESPEAK_DATA_PATH, then $HOME/espeak-ng-data, then the
# PATH_ESPEAK_DATA baked into the wheel at build time — which, for the
# espeakng-loader wheels, is a GitHub Actions runner path that exists on no
# user's machine. It then fails to read `phontab` and the deprecated
# `espeak_Initialize()` entry point calls exit(1) directly, killing the whole
# backend process below Python: no exception, no traceback, nothing for
# `_load_engine_background`'s `except Exception` to catch.
#
# Our own data directory is
#   <HOME>/Library/Application Support/com.himudigonda.Voqora/VoqoraServer
#   /_internal/espeakng_loader/espeak-ng-data
# whose fixed tail is already 105 bytes, so the whole thing fits only while the
# user's home directory stays under ~47 bytes. That holds for an ordinary
# /Users/<name> home and breaks for a network/mobile home, a relocated home, a
# container path, or any test harness that points HOME at a temp directory.
# Measured against the shipped libespeak-ng 1.52.0: 159 bytes initialises
# cleanly, 160 bytes exits 1.
_ESPEAK_PATH_HOME_LIMIT = 159

_espeak_short_data_path: str | None = None


def _espeak_visible_length(path: str) -> int:
    """Bytes espeak-ng will actually store for `path`.

    phonemizer runs the configured directory through `pathlib.Path.resolve()`
    before calling `espeak_Initialize()`, so a symlink is useless here — only
    the fully resolved path counts against espeak-ng's buffer.
    """
    return len(os.fsencode(os.path.realpath(path)))


def _resolve_espeak_data_path() -> str:
    """Return an espeak-ng data directory short enough for its 160-byte buffer.

    The bundled directory is used as-is whenever it fits. When it does not, it
    is mirrored into a private temporary directory, which is always far
    shorter, so espeak-ng keeps the path we gave it instead of silently falling
    back to a compiled-in default that does not exist. The mirror is built from
    hard links, so it costs a few hundred directory entries rather than a copy
    of the ~19 MB of voice data; a real copy is the fallback when the temporary
    directory turns out to be on another filesystem.
    """
    global _espeak_short_data_path

    real_path = espeakng_loader.get_data_path()
    if _espeak_visible_length(real_path) <= _ESPEAK_PATH_HOME_LIMIT:
        return real_path

    if _espeak_short_data_path is not None:
        return _espeak_short_data_path

    # The default temporary directory first (private to this user on macOS),
    # then /tmp, in case TMPDIR is itself relocated somewhere long.
    for directory in (None, "/tmp"):
        holder = None
        try:
            holder = tempfile.mkdtemp(prefix="voqora-espeak-", dir=directory)
            mirror = os.path.join(holder, "espeak-ng-data")
            if _espeak_visible_length(holder) + len(b"/espeak-ng-data") > (
                _ESPEAK_PATH_HOME_LIMIT
            ):
                raise OSError("temporary directory is itself too long")
            try:
                shutil.copytree(real_path, mirror, copy_function=os.link)
            except (OSError, shutil.Error):
                # Different filesystem, or a link limit: fall back to a copy.
                shutil.rmtree(mirror, ignore_errors=True)
                shutil.copytree(real_path, mirror)
        except (OSError, shutil.Error):
            if holder is not None:
                shutil.rmtree(holder, ignore_errors=True)
            continue

        atexit.register(shutil.rmtree, holder, True)
        _espeak_short_data_path = mirror
        log.info(
            "tts.espeak_data_path_shortened",
            extra={
                "original_bytes": _espeak_visible_length(real_path),
                "shortened_bytes": _espeak_visible_length(mirror),
            },
        )
        return mirror

    # Nothing shorter was available. Hand espeak-ng the real path anyway so the
    # failure stays identical to what it would have been, and leave a breadcrumb
    # explaining the exit(1) that is about to happen.
    log.error(
        "tts.espeak_data_path_too_long",
        extra={
            "failure_code": "espeak_data_path_too_long",
            "original_bytes": _espeak_visible_length(real_path),
            "limit_bytes": _ESPEAK_PATH_HOME_LIMIT,
        },
    )
    return real_path


# Module-level preemption lock: interactive /speak holds this; the audiobook
# TTS phase awaits it between every page so a hotkey request fires within one
# page-generation latency (≈350 ms) and the audiobook job pauses gracefully
# until the interactive request finishes, then resumes the next page.
interactive_tts_lock: asyncio.Lock = asyncio.Lock()


class TTSEngine:
    _instance = None
    _model: Kokoro = None
    _executor = None

    # Idle-unload state
    _is_initializing: bool = False
    _load_event: asyncio.Event = asyncio.Event()
    _last_request_time: float = 0.0
    _IDLE_TIMEOUT: float = 300.0  # seconds of inactivity before unloading (5 min)

    # Lookahead cache: stores pre-computed first-segment audio keyed by
    # (segment_text, voice, speed).  Populated by prewarm_with_lookahead()
    # and consumed (popped) by generate() on the first segment.
    # Uses LRU eviction: most recently hit entries stay, oldest unused are removed.
    _lookahead_cache: OrderedDict = OrderedDict()
    _MAX_CACHE_ENTRIES: int = 10

    _style_cache: OrderedDict[str, np.ndarray] = OrderedDict()
    _MAX_STYLE_ENTRIES: int = 8

    @staticmethod
    def _lookahead_key(
        segment: str,
        voice: VoiceSpec,
        speed: float,
        lang: str,
        dictionary_version: int = 0,
        pause_scale: float = 1.0,
    ) -> tuple[str, str, float, str, int, float]:
        return (
            segment,
            voice.cache_tag,
            round(speed, 2),
            lang,
            dictionary_version,
            round(pause_scale, 2),
        )

    @classmethod
    def _has_voices(cls, spec: VoiceSpec) -> bool:
        return all(voice in cls._model.voices for voice, _ in spec.components)

    @classmethod
    def _voice_input(cls, spec: VoiceSpec) -> str | np.ndarray:
        if not spec.is_blend:
            return spec.id
        cached = cls._style_cache.get(spec.cache_tag)
        if cached is not None:
            cls._style_cache.move_to_end(spec.cache_tag)
            return cached
        style = blend_styles(
            [cls._model.get_voice_style(voice) for voice, _ in spec.components],
            [weight for _, weight in spec.components],
        )
        cls._style_cache[spec.cache_tag] = style
        while len(cls._style_cache) > cls._MAX_STYLE_ENTRIES:
            cls._style_cache.popitem(last=False)
        return style

    @staticmethod
    def _pause_seconds(segment: str, speed: float, pause_scale: float) -> float:
        stripped = segment.rstrip("\"'\u201d\u2019)]")
        last_char = stripped[-1] if stripped else ""
        pause = SEGMENT_PAUSE_SECONDS.get(last_char, DEFAULT_SEGMENT_PAUSE_SECONDS)
        return pause * pause_scale / speed

    @classmethod
    def touch(cls) -> None:
        """Reset the idle timer. Call at the start of every inference request."""
        cls._last_request_time = time.monotonic()

    @classmethod
    def is_loaded(cls) -> bool:
        return cls._model is not None

    @classmethod
    async def ensure_loaded(cls) -> None:
        """Reload the model if it was unloaded by the idle watcher.

        Safe to call concurrently: if two requests arrive simultaneously while
        cold, only one load will happen (the second waits via the asyncio.Event
        rather than a polling sleep loop).
        asyncio's cooperative scheduling ensures no await between the flag check
        and the flag set, so there's no TOCTOU race.
        """
        if cls._model is not None:
            return
        if cls._is_initializing:
            # Another coroutine is already loading — wait without polling.
            await cls._load_event.wait()
            return
        # No await between this check and the flag set → atomic in asyncio.
        cls._is_initializing = True
        cls._load_event.clear()
        try:
            log.info("tts.cold_start")
            loop = asyncio.get_running_loop()
            await loop.run_in_executor(None, cls.initialize)
            log.info("tts.model_reloaded")
        finally:
            cls._is_initializing = False
            cls._load_event.set()

    @classmethod
    def unload(cls) -> None:
        """Drop the ONNX session and executor to free ~600 MB of RAM.

        Called by idle_watcher; never called while a request is in-flight
        because the idle check guards on _last_request_time and asyncio
        cooperative scheduling prevents interleaving with active generate() calls.
        """
        if cls._model is None:
            return
        idle = time.monotonic() - cls._last_request_time
        log.info("tts.model_unload", extra={"idle_seconds": round(idle, 1)})
        cls._model = None
        if cls._executor is not None:
            # Cancel any pending (not yet running) futures to clean up cleanly.
            # wait=False prevents blocking on in-flight tasks; cancel_futures=True
            # ensures pending tasks don't run after unload.
            cls._executor.shutdown(wait=False, cancel_futures=True)
            cls._executor = None
        cls._lookahead_cache.clear()
        cls._style_cache.clear()
        log.info("tts.model_unloaded")

    @classmethod
    async def idle_watcher(cls) -> None:
        """Background asyncio task: unload model after IDLE_TIMEOUT of inactivity.

        Checks every 60 s. Skips unload if:
        - model is already unloaded
        - another coroutine is currently loading it
        - last request was within IDLE_TIMEOUT
        """
        while True:
            await asyncio.sleep(60)
            if cls._model is None or cls._is_initializing:
                continue
            if cls._last_request_time == 0:
                continue
            if time.monotonic() - cls._last_request_time > cls._IDLE_TIMEOUT:
                cls.unload()

    @classmethod
    async def prewarm_with_lookahead(
        cls,
        text: str,
        voice: str | VoiceSpec,
        speed: float,
        lang: str = "en-us",
        *,
        pause_scale: float = 1.0,
        pronunciation: PronunciationRules | None = None,
    ) -> None:
        """Pre-run inference on the first segment and store the result in the cache.

        Called by /prewarm when the client sends clipboard text + voice + speed.
        The next /speak with the same first segment + settings will pop the cached
        audio and stream it immediately (cache-hit path: <20ms TTFA).

        Safe to call even when another request is in-flight — it queues behind
        the single-threaded executor so espeak-ng never runs concurrently.
        """
        if not cls._model or not cls._executor:
            return

        segments = cls._split_segments(text)
        if not segments:
            return

        first_seg = segments[0].strip()
        spec = voice_spec(voice)
        rules = pronunciation or EMPTY_RULES
        spoken, _ = rules.speakable(first_seg)
        if spoken is None:
            return
        key = cls._lookahead_key(
            first_seg, spec, speed, lang, rules.version, pause_scale
        )

        if key in cls._lookahead_cache:
            # Move to end to mark as recently used (LRU)
            cls._lookahead_cache.move_to_end(key)
            log.debug("tts.lookahead_cached", extra={"segment_chars": len(first_seg)})
            return

        # Never log caller text. Prewarm receives clipboard/selection content
        # and these logs are retained and can be exported for support.
        log.info("tts.lookahead_precompute", extra={"segment_chars": len(first_seg)})
        loop = asyncio.get_running_loop()
        try:
            audio, _ = await loop.run_in_executor(
                cls._executor,
                cls._model.create,
                spoken,
                cls._voice_input(spec),
                speed,
                lang,
            )
        except Exception:
            log.warning(
                "tts.lookahead_error",
                extra={"failure_code": "lookahead_generation_failed"},
                exc_info=True,
            )
            return

        if audio is None:
            return

        # Evict LRU (oldest unused) entry when at capacity
        if len(cls._lookahead_cache) >= cls._MAX_CACHE_ENTRIES:
            cls._lookahead_cache.popitem(last=False)  # Remove least recently used

        cls._lookahead_cache[key] = audio
        cls._lookahead_cache.move_to_end(key)  # Mark as most recently used
        log.info("tts.lookahead_stored", extra={"segment_chars": len(first_seg)})

    @classmethod
    def initialize(cls):
        """Loads the ONNX model with optimized session and warms up inference."""
        # 1. Initialize the Executor lazily
        if cls._executor is None:
            # A dedicated, single background thread for ALL Kokoro/espeak operations.
            # This guarantees espeak-ng never runs concurrently and always stays on the
            # exact same C-thread, eliminating cross-thread memory leaks and hallucinations.
            cls._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)

        # 2. Initialize the Model with optimized ONNX session
        if cls._model is None:
            active_model_path = settings.ACTIVE_MODEL_PATH
            # Do not retain an app-private filesystem path in diagnostics.
            # The bundled model identity is already fixed by the sealed runtime.
            log.info("tts.model_load_start", extra={"model_source": "bundled"})
            try:
                sess_options = ort.SessionOptions()
                sess_options.enable_mem_pattern = True
                sess_options.enable_cpu_mem_arena = True
                sess_options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
                sess_options.graph_optimization_level = (
                    ort.GraphOptimizationLevel.ORT_ENABLE_ALL
                )
                # 4 intra-op threads: good balance on Apple Silicon — near-min latency
                # without the idle-CPU cost of spinning. (6 threads only saves ~27ms
                # but spinning burns 600%+ idle CPU — wrong trade-off for a desktop app.)
                sess_options.intra_op_num_threads = min(4, os.cpu_count() or 2)
                # ORT's default is allow_spinning=1 (enabled) on standard PyPI wheels —
                # leaving this unset does NOT avoid the busy-wait cost, it guarantees it.
                # Measured on this exact onnxruntime build: ~14% CPU during inter-
                # inference gaps when unset vs. ~0.4% when explicitly disabled (30x).
                sess_options.add_session_config_entry(
                    "session.intra_op.allow_spinning", "0"
                )

                # CPU-only: CoreML partitions only 43% of Kokoro's nodes, and the
                # data transfer overhead between CoreML and CPU makes it slower overall
                session = ort.InferenceSession(
                    active_model_path,
                    sess_options,
                    providers=["CPUExecutionProvider"],
                )

                # Pin the espeak-ng data directory explicitly. kokoro-onnx would
                # otherwise hand espeak-ng the bundled path verbatim, which
                # exits the process when it overflows espeak-ng's 160-byte
                # path buffer (see _resolve_espeak_data_path).
                cls._model = Kokoro.from_session(
                    session,
                    settings.VOICES_PATH,
                    espeak_config=EspeakConfig(data_path=_resolve_espeak_data_path()),
                )
                log.info("tts.model_loaded_warming")

                # Warm-up: first inference is 2-5x slower due to memory allocation
                # and espeak-ng phonemizer initialization
                cls._model.create("Hello.", "af_bella", 1.0, "en-us")
                log.info("tts.ready")
            except Exception:
                log.error(
                    "tts.fatal_error",
                    extra={"failure_code": "model_initialization_failed"},
                    exc_info=True,
                )
                raise

        # Mark load time so idle_watcher doesn't immediately unload on reload.
        cls.touch()

    # Minimum words before emitting a segment. All segments (including the first)
    # use this threshold — no special short-first-segment logic that caused audible
    # gaps at high speeds (2 words play in ~100ms at 2x, but next segment takes
    # ~350ms to generate, creating a jarring 250ms stutter).
    _NORMAL_SEG_WORDS = 5

    @classmethod
    def _split_segments(cls, text: str) -> list[str]:
        """Split text into segments for streaming inference.

        All segments use the same grouping threshold: emit when ≥5 words OR the
        part ends a sentence (.!?). Short sentences (< 5 words) that end with
        punctuation are emitted as-is; long sentences are chunked at 5-word
        boundaries. This produces uniform segment sizes so playback transitions
        coincide with natural pauses rather than sounding like buffering stalls.
        """
        raw_text = text.replace("\n", " ").strip()
        if not raw_text:
            return []

        # Split on punctuation to get natural sentence/clause boundaries
        raw_parts = [
            s.strip()
            for s in re.split(
                r"(?:(?<=[.!?:;,])|(?<=[.!?][\"'\u201d\u2019)\]])) +"
                r"|(?<=[\u3002\uff01\uff1f\uff0c\uff1b\uff1a\u0964])\s*",
                raw_text,
            )
            if s.strip()
        ]

        if not raw_parts:
            return [raw_text]

        merged: list[str] = []
        for part in raw_parts:
            if merged and _NO_BREAK_AFTER_RE.search(merged[-1]):
                merged[-1] = f"{merged[-1]} {part}"
            else:
                merged.append(part)
        raw_parts = merged

        # Group parts until ≥ _NORMAL_SEG_WORDS words OR a sentence ends (.!?)
        segments = []
        temp_seg = ""
        for part in raw_parts:
            temp_seg += (" " + part) if temp_seg else part
            word_count = len(temp_seg.split())
            ends_sentence = bool(_SEGMENT_SENTENCE_END_RE.search(temp_seg))

            if word_count >= cls._NORMAL_SEG_WORDS or ends_sentence:
                segments.append(temp_seg.strip())
                temp_seg = ""

        if temp_seg:
            segments.append(temp_seg.strip())

        return segments

    @classmethod
    async def generate(
        cls,
        text: str,
        voice: str | VoiceSpec,
        speed: float,
        lang: str = "en-us",
        failed_segments: list[str] | None = None,
        *,
        pause_scale: float = 1.0,
        pronunciation: PronunciationRules | None = None,
    ) -> AsyncGenerator[np.ndarray, None]:
        if not cls._model or not cls._executor:
            raise RuntimeError("Model not initialized. Call initialize() first.")

        segments = cls._split_segments(text)

        if not segments:
            return

        spec = voice_spec(voice)
        if not cls._has_voices(spec):
            log.warning(
                "tts.unknown_voice_fallback",
                extra={"requested": spec.id, "fallback": DEFAULT_VOICE},
            )
            spec = builtin_spec(DEFAULT_VOICE)
            lang = spec.lang
        voice_input = cls._voice_input(spec)
        rules = pronunciation or EMPTY_RULES

        loop = asyncio.get_running_loop()

        for i, seg_text in enumerate(segments):
            cls.touch()  # Keep idle timer alive throughout multi-segment generation
            seg_stripped = seg_text.strip()
            spoken, _ = rules.speakable(seg_stripped)
            if spoken is None:
                continue
            audio = None

            # Cache hit: first segment was pre-computed by prewarm_with_lookahead()
            if i == 0:
                key = cls._lookahead_key(
                    seg_stripped, spec, speed, lang, rules.version, pause_scale
                )
                cached = cls._lookahead_cache.pop(key, None)
                if cached is not None:
                    log.debug(
                        "tts.lookahead_hit", extra={"segment_chars": len(seg_stripped)}
                    )
                    audio = cached

            if audio is None:
                try:
                    audio, _ = await loop.run_in_executor(
                        cls._executor,
                        cls._model.create,
                        spoken,
                        voice_input,
                        speed,
                        lang,
                    )
                except Exception as e:
                    log.warning(
                        "tts.segment_error",
                        extra={
                            "segment_chars": len(seg_text),
                            "error_type": type(e).__name__,
                        },
                        exc_info=True,
                    )
                    if failed_segments is not None:
                        failed_segments.append(seg_stripped)
                    continue

            if audio is None:
                if failed_segments is not None:
                    failed_segments.append(seg_stripped)
                continue

            # Append inter-segment silence using pre-computed arrays
            # Speed-scaled pause: divide duration by speed so pauses feel proportional
            silence = AudioService.get_silence(
                cls._pause_seconds(seg_stripped, speed, pause_scale)
            )

            yield np.concatenate([audio, silence])
