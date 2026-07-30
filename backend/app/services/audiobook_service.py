"""AudiobookService — orchestrator for PDF → audiobook pipeline.

Singleton classmethods + ThreadPoolExecutor (mirrors TTSEngine pattern).
One book processes at a time via asyncio.Queue. Each pipeline phase is
idempotent: presence of the per-page output file IS the checkpoint.

Phases:
  extract  → pages/N.txt          (skip if exists)
  clean    → pages/N.clean.txt    (skip if exists; Gemini call)
  tts      → audio_pages/N.wav    (skip if exists; preempts to /speak)
  concat   → audio.wav            (cheap; recomputes page_to_time map)

Sections detection lives in Phase 2.
"""

import asyncio
import calendar
import concurrent.futures
import hashlib
import json
import os
import struct
import time
import wave
from typing import Any

import numpy as np

from app.core.config import settings as _settings
from app.core.logging import get_logger
from app.services.audiobook_store import AudiobookStore, _now_iso
from app.services.engine_manager import EngineManager
from app.services.gemini_cleaner import GeminiAuthError, GeminiCleaner
from app.services.pdf_extractor import PDFExtractor
from app.services.text_extractor import TextExtractor
from app.services.tts import interactive_tts_lock

log = get_logger(__name__)

# Pages with fewer extractable chars than this are treated as image-only
# and routed through Gemini vision OCR instead of text cleaning.
_OCR_TEXT_THRESHOLD = 50

# Re-exported for test imports — single definition in settings.AUDIO_SAMPLE_RATE
# since HARD-035. Keep the local name so existing call sites keep compiling.
SAMPLE_RATE = _settings.AUDIO_SAMPLE_RATE
BYTES_PER_SAMPLE = 2  # int16
WAV_HEADER_SIZE = 44


class AudiobookCancelled(Exception):
    """Raised inside a phase when the user has cancelled the job."""


class AudiobookService:
    _executor: concurrent.futures.ThreadPoolExecutor | None = None
    _queue: asyncio.Queue | None = None
    _worker_task: asyncio.Task | None = None
    _current_book_id: str | None = None
    # SSE subscribers: book_id → list[asyncio.Queue]
    _subscribers: dict[str, list[asyncio.Queue]] = {}
    # In-memory API keys per active job (never persisted).
    _job_keys: dict[str, str] = {}
    # Cancel flags set by /cancel endpoint; phases check between pages.
    _cancel_flags: dict[str, bool] = {}
    # Concurrency for Gemini cleaning (page-level parallelism).
    _CLEAN_PARALLELISM = 4

    # ---------- lifecycle ----------

    @classmethod
    def initialize(cls) -> None:
        if cls._executor is None:
            cls._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        if cls._queue is None:
            cls._queue = asyncio.Queue()
        if cls._worker_task is None or cls._worker_task.done():
            cls._worker_task = asyncio.create_task(cls._worker_loop())

    @classmethod
    async def shutdown(cls, grace_seconds: float = 2.0) -> None:
        """Graceful shutdown — used by FastAPI lifespan. See HARD-073.

        - Cancel the worker loop so the current pipeline coroutine stops at
          its next `_check_cancel()` point (between pages).
        - Wait up to `grace_seconds` for it to actually exit before forcing
          the executor down.
        - If a book is mid-flight, leave its status at whatever phase it was
          in — `resume_in_progress` on next launch will flip `cleaning` to
          `needs_key` and auto-resume `tts`/`concatenating`.
        """
        if cls._worker_task is not None and not cls._worker_task.done():
            cls._worker_task.cancel()
            try:
                await asyncio.wait_for(cls._worker_task, timeout=grace_seconds)
            except (TimeoutError, asyncio.CancelledError):
                pass
        if cls._executor is not None:
            cls._executor.shutdown(wait=False, cancel_futures=True)
            cls._executor = None
        cls._worker_task = None

    @classmethod
    async def _worker_loop(cls) -> None:
        assert cls._queue is not None
        while True:
            book_id = await cls._queue.get()
            try:
                cls._current_book_id = book_id
                await cls._run_pipeline(book_id)
            except Exception as e:
                log.error(
                    "audiobook.pipeline_fatal",
                    extra={"book_id": book_id, "error": str(e)},
                )
                if AudiobookStore.read_meta(book_id) is not None:
                    await AudiobookStore.update_meta(
                        book_id, status="failed", error=str(e)
                    )
                    cls._emit(book_id, "failed", error=str(e))
            finally:
                cls._current_book_id = None
                cls._job_keys.pop(book_id, None)
                cls._queue.task_done()

    # ---------- queue / SSE ----------

    @classmethod
    async def enqueue(cls, book_id: str, api_key: str) -> None:
        cls.initialize()
        assert cls._queue is not None
        cls._job_keys[book_id] = api_key
        cls._cancel_flags.pop(book_id, None)
        await AudiobookStore.update_meta(book_id, status="queued", error=None)
        await cls._queue.put(book_id)

    @classmethod
    def cancel(cls, book_id: str) -> bool:
        """Mark a running job for cancellation. Phases observe between pages."""
        cls._cancel_flags[book_id] = True
        return True

    @classmethod
    def is_processing(cls, book_id: str) -> bool:
        """Return True if this book is the currently-running job (or queued)."""
        if cls._current_book_id == book_id:
            return True
        # Also check in-flight via meta status — covers the queued window.
        meta = AudiobookStore.read_meta(book_id)
        if meta is None:
            return False
        return meta.get("status") in {
            "queued",
            "extracting",
            "cleaning",
            "sectioning",
            "tts",
            "concatenating",
        }

    @classmethod
    async def request_delete(cls, book_id: str) -> bool:
        """Coordinated delete: if the book is being processed, cancel the
        pipeline first and wait briefly for it to exit at the next page
        boundary. Then delete the directory. If not processing, delete now.
        Returns True if the book existed."""
        meta = AudiobookStore.read_meta(book_id)
        if meta is None:
            return False
        if cls.is_processing(book_id):
            cls.cancel(book_id)
            # Wait up to 5 s for the pipeline to drop the book at its next
            # checkpoint. Each phase calls _check_cancel() between pages.
            for _ in range(50):  # 50 × 100 ms
                if cls._current_book_id != book_id:
                    break
                await asyncio.sleep(0.1)
        AudiobookStore.delete_book(book_id)
        cls._cancel_flags.pop(book_id, None)
        cls._job_keys.pop(book_id, None)
        return True

    @classmethod
    async def retry_failed(cls, book_id: str, api_key: str) -> int:
        """Re-process pages currently listed in `meta.failed_pages`, OR resume
        a stuck book in `needs_key` / `failed` state.

        Deletes failed pages' cleaned text + per-page WAV + the final
        audio.wav (so concat re-runs), clears the failed list, and enqueues
        the book. Returns the number of pages slated for retry. For
        needs_key/failed without per-page failures, returns 0 but still
        enqueues a fresh pipeline run.
        """
        meta = AudiobookStore.read_meta(book_id)
        if meta is None:
            return 0
        failed = list(meta.get("failed_pages") or [])
        status = meta.get("status")
        # Allow resume from {needs_key, failed} even with empty failed_pages —
        # in those states the pipeline never reached the per-page retry stage
        # (e.g., user re-entered API key after restart). Without this guard,
        # the resume button is a silent no-op (C2).
        resumable_states = {"failed", "needs_key", "cancelled"}
        if not failed and status not in resumable_states:
            return 0
        for n in failed:
            for p in (
                AudiobookStore.page_clean_path(book_id, n),
                AudiobookStore.page_audio_path(book_id, n),
            ):
                try:
                    if os.path.exists(p):
                        os.remove(p)
                except OSError:
                    pass
        # Delete final concatenated audio so concat re-runs.
        for p in (
            AudiobookStore.audio_path(book_id),
            AudiobookStore.transcript_path(book_id),
        ):
            try:
                if os.path.exists(p):
                    os.remove(p)
            except OSError:
                pass
        await AudiobookStore.update_meta(
            book_id, failed_pages=[], error=None, status="queued"
        )
        await cls.enqueue(book_id, api_key)
        return len(failed)

    @classmethod
    def _check_cancel(cls, book_id: str) -> None:
        if cls._cancel_flags.get(book_id):
            raise AudiobookCancelled(book_id)

    @classmethod
    def subscribe(cls, book_id: str) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        cls._subscribers.setdefault(book_id, []).append(q)
        return q

    @classmethod
    def unsubscribe(cls, book_id: str, q: asyncio.Queue) -> None:
        subs = cls._subscribers.get(book_id, [])
        if q in subs:
            subs.remove(q)
        if not subs:
            cls._subscribers.pop(book_id, None)

    @classmethod
    def _emit(cls, book_id: str, event_type: str, **data: Any) -> None:
        payload = {"type": event_type, "book_id": book_id, **data}
        for q in cls._subscribers.get(book_id, []):
            try:
                q.put_nowait(payload)
            except asyncio.QueueFull:
                pass

    # ---------- resume on startup ----------

    @classmethod
    async def resume_in_progress(cls) -> None:
        """Scan store for in-progress books. If cleaning was in flight (needs key),
        flag as needs_key. Otherwise auto-resume non-clean phases."""
        cls.initialize()
        for meta in AudiobookStore.list_books():
            status = meta.get("status")
            if status not in {
                "queued",
                "extracting",
                "cleaning",
                "sectioning",
                "tts",
                "concatenating",
            }:
                continue
            book_id = meta["book_id"]
            # Books created before this flag existed used Gemini for every
            # page, so preserve that historical behavior for a resumable old
            # job. New books always persist an explicit false by default.
            uses_gemini_cleanup = bool(meta.get("uses_gemini_cleanup", True))
            if status == "cleaning" and uses_gemini_cleanup:
                # Needs the API key the user re-supplies via Resume.
                await AudiobookStore.update_meta(book_id, status="needs_key")
            elif status in {"tts", "concatenating"} or not uses_gemini_cleanup:
                # No key needed; safe to auto-resume.
                # Use empty key — TTS phase doesn't read it.
                await cls.enqueue(book_id, api_key="")
            else:
                # extracting / queued without key context: also flag needs_key
                # to keep it transparent (extraction is fast but cleaning is next).
                await AudiobookStore.update_meta(book_id, status="needs_key")

    # ---------- pipeline ----------

    @classmethod
    async def _run_pipeline(cls, book_id: str) -> None:
        meta = AudiobookStore.read_meta(book_id)
        if meta is None:
            log.warning("audiobook.meta_missing", extra={"book_id": book_id})
            return

        api_key = cls._job_keys.get(book_id, "")

        try:
            await cls._phase_extract(book_id)
            await cls._phase_clean(book_id, api_key)
            # Re-read meta — page_count + voice/speed haven't changed but other
            # fields might be updated by clean phase.
            meta = AudiobookStore.read_meta(book_id) or meta
            await cls._phase_section(book_id, api_key, meta)
            meta = AudiobookStore.read_meta(book_id) or meta
            await cls._phase_tts(book_id, meta)
            actual = await cls._phase_concat(book_id, meta)
            await AudiobookStore.update_meta(
                book_id, status="done", actual=actual, error=None
            )
            cls._emit(book_id, "done", actual=actual)
        except AudiobookCancelled:
            await AudiobookStore.update_meta(
                book_id, status="cancelled", error="Cancelled by user."
            )
            cls._emit(book_id, "cancelled", error="Cancelled by user.")
        except GeminiAuthError as e:
            await AudiobookStore.update_meta(
                book_id,
                status="failed",
                error="Invalid Gemini API key. Update in Settings.",
            )
            cls._emit(book_id, "failed", error=str(e))
        except Exception as e:
            await AudiobookStore.update_meta(book_id, status="failed", error=str(e))
            cls._emit(book_id, "failed", error=str(e))
        finally:
            cls._cancel_flags.pop(book_id, None)

    # ---------- phase: extract ----------

    @classmethod
    async def _phase_extract(cls, book_id: str) -> None:
        await AudiobookStore.update_meta(book_id, status="extracting")
        cls._emit(book_id, "phase_started", phase="extracting")
        loop = asyncio.get_running_loop()

        meta = AudiobookStore.read_meta(book_id) or {}
        file_ext = meta.get("file_ext", "pdf")
        is_pdf = file_ext == "pdf"
        source_path = AudiobookStore.source_file_path(book_id, file_ext)

        if is_pdf:
            page_count = await loop.run_in_executor(
                cls._executor, PDFExtractor.page_count, source_path
            )
            await loop.run_in_executor(
                cls._executor, PDFExtractor.render_cover, book_id
            )
        else:
            page_count = await loop.run_in_executor(
                cls._executor, TextExtractor.page_count, source_path
            )
            await loop.run_in_executor(
                cls._executor, TextExtractor.render_cover, book_id
            )

        # Track content hashes so duplicate pages (e.g. DocuSign PDFs that embed
        # the same page twice) are replaced with a silence marker rather than
        # generating identical audio twice.
        seen_content_hashes: set[str] = set()

        for n in range(1, page_count + 1):
            cls._check_cancel(book_id)
            # Honor /speak preemption between pages.
            async with interactive_tts_lock:
                pass
            out = AudiobookStore.page_raw_path(book_id, n)
            if not os.path.exists(out):
                if is_pdf:
                    await loop.run_in_executor(
                        cls._executor, PDFExtractor.extract_one, book_id, n
                    )
                else:
                    await loop.run_in_executor(
                        cls._executor, TextExtractor.extract_one, book_id, n
                    )

            # Deduplication: if this page's content is byte-identical to an
            # earlier page (content hash matches), pre-write "-" to the clean
            # file so the clean phase skips it and TTS writes silence instead
            # of repeating the same audio.
            # On resume, pages with both raw and clean files already present
            # must still be hashed so the seen_content_hashes set is correctly
            # populated for subsequent pages.
            clean_path = AudiobookStore.page_clean_path(book_id, n)
            if os.path.exists(out):
                try:
                    with open(out, encoding="utf-8") as f:
                        raw = f.read()
                    stripped = raw.strip()
                    if len(stripped) > 100:  # ignore trivially short / blank pages
                        h = hashlib.md5(stripped.encode()).hexdigest()
                        if h in seen_content_hashes:
                            if not os.path.exists(clean_path):
                                # Duplicate — write silence marker, bypass Gemini + TTS
                                tmp = clean_path + ".tmp"
                                os.makedirs(os.path.dirname(clean_path), exist_ok=True)
                                with open(tmp, "w", encoding="utf-8") as f:
                                    f.write("-")
                                os.replace(tmp, clean_path)
                        else:
                            seen_content_hashes.add(h)
                except OSError:
                    pass

            await AudiobookStore.update_meta(
                book_id,
                phase_progress={"page_done": n, "page_total": page_count},
            )
            cls._emit(
                book_id, "page_done", phase="extracting", page=n, total=page_count
            )

        await AudiobookStore.update_meta(book_id, page_count=page_count)
        cls._emit(book_id, "phase_finished", phase="extracting")

    # ---------- phase: section detection ----------

    @classmethod
    async def _phase_section(
        cls, book_id: str, api_key: str, meta: dict[str, Any]
    ) -> None:
        await AudiobookStore.update_meta(book_id, status="sectioning")
        cls._emit(book_id, "phase_started", phase="sectioning")

        file_ext = meta.get("file_ext", "pdf")
        page_count = int(meta.get("page_count") or 0)
        loop = asyncio.get_running_loop()

        # Path A: try the PDF's own outline first (no API call needed).
        # For non-PDF files there is no outline; skip straight to Gemini.
        if file_ext == "pdf":
            source_path = AudiobookStore.source_file_path(book_id, file_ext)
            outline = await loop.run_in_executor(
                cls._executor, PDFExtractor.read_outline, source_path
            )
        else:
            outline = None

        sections: list[dict] = []
        if outline:
            # Convert flat outline (title, start_page) to contiguous sections.
            sorted_outline = sorted(outline, key=lambda x: x["start_page"])
            for i, entry in enumerate(sorted_outline):
                end_page = (
                    sorted_outline[i + 1]["start_page"] - 1
                    if i + 1 < len(sorted_outline)
                    else page_count
                )
                sections.append(
                    {
                        "title": entry["title"],
                        "start_page": entry["start_page"],
                        "end_page": max(entry["start_page"], end_page),
                    }
                )
            if sections and sections[0]["start_page"] > 1:
                sections.insert(
                    0,
                    {
                        "title": "Front Matter",
                        "start_page": 1,
                        "end_page": sections[0]["start_page"] - 1,
                    },
                )
        elif bool(meta.get("uses_gemini_cleanup", True)):
            # Path B: ask Gemini.
            cleaned_pages: list[str] = []
            for n in range(1, page_count + 1):
                p = AudiobookStore.page_clean_path(book_id, n)
                if not os.path.exists(p):
                    cleaned_pages.append("")
                    continue
                with open(p, encoding="utf-8") as f:
                    cleaned_pages.append(f.read())
            try:
                sections = await asyncio.wait_for(
                    GeminiCleaner.detect_sections(api_key, cleaned_pages),
                    timeout=120.0,
                )
            except TimeoutError:
                log.warning("audiobook.sections_timeout", extra={"book_id": book_id})
                sections = []
            except GeminiAuthError:
                raise
            except Exception as e:
                log.warning(
                    "audiobook.sections_failed",
                    extra={"book_id": book_id, "error": str(e)},
                )
                sections = []

        if not sections:
            sections = [
                {
                    "title": meta.get("title") or "Audiobook",
                    "start_page": 1,
                    "end_page": page_count,
                }
            ]

        # start_time gets filled in concat phase. Persist now so UI can show titles
        # even before audio is finalized.
        await AudiobookStore.update_meta(
            book_id,
            sections=[{**s, "start_time": 0.0} for s in sections],
        )
        cls._emit(book_id, "phase_finished", phase="sectioning")

    # ---------- phase: clean ----------

    @classmethod
    async def _phase_clean(cls, book_id: str, api_key: str) -> None:
        await AudiobookStore.update_meta(book_id, status="cleaning")
        cls._emit(book_id, "phase_started", phase="cleaning")

        meta = AudiobookStore.read_meta(book_id) or {}
        file_ext = meta.get("file_ext", "pdf")
        is_pdf = file_ext == "pdf"
        uses_gemini_cleanup = bool(meta.get("uses_gemini_cleanup", True))
        page_count = int(meta.get("page_count") or 0)
        failed: list[int] = list(meta.get("failed_pages") or [])

        # Pages still needing cleaning (skip already-done for resume).
        pending = [
            n
            for n in range(1, page_count + 1)
            if not os.path.exists(AudiobookStore.page_clean_path(book_id, n))
        ]
        # Pages already done are still progress — emit instantly so UI catches up.
        done_count = page_count - len(pending)

        sem = asyncio.Semaphore(cls._CLEAN_PARALLELISM)
        # Lock around shared state (failed list, done counter, meta writes).
        state_lock = asyncio.Lock()
        progress = {"done": done_count}

        async def clean_one(n: int) -> None:
            async with sem:
                # Honor /speak preemption (every page acquires after Gemini network call too)
                async with interactive_tts_lock:
                    pass
                cls._check_cancel(book_id)

                raw_path = AudiobookStore.page_raw_path(book_id, n)
                if not os.path.exists(raw_path):
                    return
                with open(raw_path, encoding="utf-8") as f:
                    raw_text = f.read()

                try:
                    if not uses_gemini_cleanup:
                        # The local-first default: normal extracted text is
                        # narrated as-is. Image-only pages remain blank until
                        # the user explicitly enables Gemini OCR for the book.
                        cleaned = raw_text or "-"
                    elif is_pdf and len(raw_text.strip()) < _OCR_TEXT_THRESHOLD:
                        # Image page (PDF only) — render and OCR+clean via Gemini vision.
                        source_path = AudiobookStore.source_file_path(book_id, file_ext)
                        image_bytes = await asyncio.get_running_loop().run_in_executor(
                            cls._executor,
                            PDFExtractor.render_page_image,
                            source_path,
                            n,
                        )
                        try:
                            cleaned = await asyncio.wait_for(
                                GeminiCleaner.ocr_page(api_key, image_bytes),
                                timeout=90.0,
                            )
                        except TimeoutError:
                            log.warning(
                                "audiobook.ocr_timeout",
                                extra={"book_id": book_id, "page": n},
                            )
                            cleaned = raw_text or "-"
                    else:
                        try:
                            cleaned = await asyncio.wait_for(
                                GeminiCleaner.clean_page(api_key, raw_text),
                                timeout=90.0,
                            )
                        except TimeoutError:
                            log.warning(
                                "audiobook.clean_timeout",
                                extra={"book_id": book_id, "page": n},
                            )
                            cleaned = raw_text or "-"
                except GeminiAuthError:
                    raise
                except Exception as e:
                    log.warning(
                        "audiobook.clean_failed",
                        extra={"book_id": book_id, "page": n, "error": str(e)},
                    )
                    async with state_lock:
                        failed.append(n)
                        await AudiobookStore.update_meta(book_id, failed_pages=failed)
                    cls._emit(
                        book_id, "page_failed", phase="cleaning", page=n, error=str(e)
                    )
                    cleaned = raw_text or "-"

                out = AudiobookStore.page_clean_path(book_id, n)
                tmp = out + ".tmp"
                with open(tmp, "w", encoding="utf-8") as f:
                    f.write(cleaned)
                os.replace(tmp, out)

                async with state_lock:
                    progress["done"] += 1
                    await AudiobookStore.update_meta(
                        book_id,
                        phase_progress={
                            "page_done": progress["done"],
                            "page_total": page_count,
                        },
                    )
                cls._emit(
                    book_id,
                    "page_done",
                    phase="cleaning",
                    page=n,
                    total=page_count,
                )

        try:
            await asyncio.gather(*(clean_one(n) for n in pending))
        except GeminiAuthError:
            raise

        cls._emit(book_id, "phase_finished", phase="cleaning")

    # ---------- phase: tts ----------

    @classmethod
    async def _phase_tts(cls, book_id: str, meta: dict[str, Any]) -> None:
        await AudiobookStore.update_meta(book_id, status="tts")
        cls._emit(book_id, "phase_started", phase="tts")

        page_count = int(meta.get("page_count") or 0)
        voice = meta.get("voice") or "af_bella"
        speed = float(meta.get("speed") or 1.0)
        failed: list[int] = list(
            (AudiobookStore.read_meta(book_id) or {}).get("failed_pages") or []
        )

        await EngineManager.ensure_loaded()

        for n in range(1, page_count + 1):
            cls._check_cancel(book_id)
            # Wait for any interactive /speak to finish before grabbing the engine.
            async with interactive_tts_lock:
                pass

            out_path = AudiobookStore.page_audio_path(book_id, n)
            if os.path.exists(out_path):
                cls._emit(book_id, "page_done", phase="tts", page=n, total=page_count)
                continue

            clean_path = AudiobookStore.page_clean_path(book_id, n)
            if not os.path.exists(clean_path):
                # Skip pages with no cleaned text.
                cls._write_silence_wav(out_path, 0.5)
                continue
            with open(clean_path, encoding="utf-8") as f:
                text = f.read().strip() or "-"

            # P3: blank-page marker is silence, never spoken aloud as "dash".
            # GeminiCleaner returns the literal "-" string for empty pages.
            if text == "-" or text.startswith("[blank") and text.endswith("]"):
                cls._write_silence_wav(out_path, 0.3)
            else:
                try:
                    samples = await cls._generate_full_page(text, voice, speed)
                    cls._write_wav_from_samples(out_path, samples)
                except Exception as e:
                    log.warning(
                        "audiobook.tts_failed",
                        extra={"book_id": book_id, "page": n, "error": str(e)},
                    )
                    failed.append(n)
                    await AudiobookStore.update_meta(book_id, failed_pages=failed)
                    cls._emit(book_id, "page_failed", phase="tts", page=n, error=str(e))
                    cls._write_silence_wav(out_path, 0.5)

            EngineManager.touch()
            await AudiobookStore.update_meta(
                book_id,
                phase_progress={"page_done": n, "page_total": page_count},
            )
            cls._emit(book_id, "page_done", phase="tts", page=n, total=page_count)

        cls._emit(book_id, "phase_finished", phase="tts")

    @classmethod
    async def _generate_full_page(
        cls, text: str, voice: str, speed: float
    ) -> np.ndarray:
        """Drain the EngineManager.generate async generator into one float32 array."""
        chunks: list[np.ndarray] = []
        async for chunk in EngineManager.generate(text, voice, speed):
            chunks.append(chunk)
        if not chunks:
            return np.zeros(int(0.3 * SAMPLE_RATE), dtype=np.float32)
        return np.concatenate(chunks)

    # ---------- phase: concat ----------

    @classmethod
    async def _phase_concat(cls, book_id: str, meta: dict[str, Any]) -> dict[str, Any]:
        await AudiobookStore.update_meta(book_id, status="concatenating")
        cls._emit(book_id, "phase_started", phase="concatenating")

        page_count = int(meta.get("page_count") or 0)
        out_path = AudiobookStore.audio_path(book_id)
        tmp_path = out_path + ".tmp"

        # Compute total PCM bytes + page→time map by scanning per-page WAV sizes.
        page_bytes: list[int] = []
        for n in range(1, page_count + 1):
            p = AudiobookStore.page_audio_path(book_id, n)
            if not os.path.exists(p):
                page_bytes.append(0)
                continue
            sz = os.path.getsize(p) - WAV_HEADER_SIZE
            page_bytes.append(max(0, sz))

        total_pcm_bytes = sum(page_bytes)
        page_to_time: dict[str, float] = {}
        cumulative = 0
        for n, sz in enumerate(page_bytes, start=1):
            page_to_time[str(n)] = cumulative / (SAMPLE_RATE * BYTES_PER_SAMPLE)
            cumulative += sz
        total_seconds = total_pcm_bytes / (SAMPLE_RATE * BYTES_PER_SAMPLE)

        # Write final WAV: header + concatenated PCM bodies.
        with open(tmp_path, "wb") as out:
            out.write(_wav_header(total_pcm_bytes))
            for n in range(1, page_count + 1):
                p = AudiobookStore.page_audio_path(book_id, n)
                if not os.path.exists(p):
                    continue
                with open(p, "rb") as f:
                    f.seek(WAV_HEADER_SIZE)
                    while True:
                        buf = f.read(1 << 20)
                        if not buf:
                            break
                        out.write(buf)
        os.replace(tmp_path, out_path)

        # Update each section's start_time from page_to_time.
        existing_sections = list(meta.get("sections") or [])
        if not existing_sections:
            existing_sections = [
                {
                    "title": meta.get("title", "Audiobook"),
                    "start_page": 1,
                    "end_page": page_count,
                }
            ]
        timed_sections: list[dict[str, Any]] = []
        for s in existing_sections:
            sp = int(s.get("start_page", 1))
            timed_sections.append(
                {
                    "title": s.get("title", "Section"),
                    "start_page": sp,
                    "end_page": int(s.get("end_page", sp)),
                    "start_time": page_to_time.get(str(sp), 0.0),
                }
            )

        await AudiobookStore.update_meta(
            book_id,
            page_to_time=page_to_time,
            total_audio_seconds=total_seconds,
            sections=timed_sections,
        )

        # Write transcript.json (sections + page_to_time + per-page text).
        try:
            page_texts: dict[str, str] = {}
            for n in range(1, page_count + 1):
                cp = AudiobookStore.page_clean_path(book_id, n)
                if os.path.exists(cp):
                    with open(cp, encoding="utf-8") as f:
                        page_texts[str(n)] = f.read()
            transcript = {
                "book_id": book_id,
                "sections": timed_sections,
                "page_to_time": page_to_time,
                "total_audio_seconds": total_seconds,
                "pages": page_texts,
            }
            tpath = AudiobookStore.transcript_path(book_id)
            tmp = tpath + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(transcript, f, ensure_ascii=False)
            os.replace(tmp, tpath)
        except Exception as e:
            log.warning(
                "audiobook.transcript_write_failed",
                extra={"book_id": book_id, "error": str(e)},
            )

        # Build actual stats.
        words_actual = 0
        chars_actual = 0
        for n in range(1, page_count + 1):
            cp = AudiobookStore.page_clean_path(book_id, n)
            if os.path.exists(cp):
                with open(cp, encoding="utf-8") as f:
                    text = f.read()
                    words_actual += len(text.split())
                    chars_actual += len(text)

        created_at = meta.get("created_at", _now_iso())
        try:
            t_created = calendar.timegm(time.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ"))
            processing_seconds = max(0.0, time.time() - t_created)
        except Exception:
            processing_seconds = 0.0

        # tokens_used: input tokens (one Gemini call per page sent the raw text)
        # plus output tokens (the cleaned text we have on disk now). Strict-preserve
        # means input ≈ output length; we approximate input from cleaned chars too
        # since raw and cleaned char counts are close after stripping headers.
        tokens_used = GeminiCleaner.estimate_tokens(chars_actual) * 2  # input + output
        # P10: derive cost from actual char count rather than the (potentially
        # missing) estimated.cost_usd in meta, so resumed books still get a
        # correct cost in the completion modal.
        cost_actual = GeminiCleaner.estimate_cost_usd(chars_actual)
        actual = {
            "pages": page_count,
            "words": words_actual,
            "audio_seconds": total_seconds,
            "processing_seconds": processing_seconds,
            "sections": len(timed_sections),
            "tokens_used": tokens_used,
            "cost_usd": cost_actual,
        }
        cls._emit(book_id, "phase_finished", phase="concatenating")
        return actual

    # ---------- WAV helpers ----------

    @staticmethod
    def _write_wav_from_samples(path: str, samples: np.ndarray) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        clipped = np.clip(samples, -1.0, 1.0)
        pcm = (clipped * 32767).astype(np.int16).tobytes()
        with wave.open(tmp, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm)
        os.replace(tmp, path)

    @staticmethod
    def _write_silence_wav(path: str, duration_sec: float) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        n_samples = int(duration_sec * SAMPLE_RATE)
        pcm = (np.zeros(n_samples, dtype=np.int16)).tobytes()
        tmp = path + ".tmp"
        with wave.open(tmp, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(pcm)
        os.replace(tmp, path)

    # ---------- estimation (called from upload endpoint) ----------

    @classmethod
    def estimate(
        cls,
        page_count: int,
        sample_words: int,
        sample_chars: int,
        speed: float = 1.0,
    ) -> dict[str, Any]:
        word_count = sample_words * page_count
        # Kokoro ~ 165 wpm = 2.75 wps at speed=1
        audio_seconds = word_count / max(0.01, 2.75 * speed)
        tts_seconds = audio_seconds / 3.5
        clean_seconds = page_count * 1.2
        extract_seconds = page_count * 0.05
        processing_seconds = (
            extract_seconds + clean_seconds + tts_seconds + page_count * 0.02
        )
        cost_usd = GeminiCleaner.estimate_cost_usd(sample_chars * page_count)
        return {
            "pages": page_count,
            "words": word_count,
            "audio_seconds": audio_seconds,
            "processing_seconds": processing_seconds,
            "cost_usd": cost_usd,
        }


def _wav_header(pcm_data_size: int) -> bytes:
    """Build a complete 44-byte WAV header for the given PCM body size."""
    header = bytearray(44)
    riff_size = 36 + pcm_data_size
    struct.pack_into("<4sI4s", header, 0, b"RIFF", riff_size, b"WAVE")
    struct.pack_into(
        "<4sIHHIIHH",
        header,
        12,
        b"fmt ",
        16,
        1,
        1,
        SAMPLE_RATE,
        SAMPLE_RATE * 2,
        2,
        16,
    )
    struct.pack_into("<4sI", header, 36, b"data", pcm_data_size)
    return bytes(header)
