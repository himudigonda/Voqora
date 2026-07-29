"""Audiobook HTTP surface — upload, lifecycle, range-served audio, SSE events.

Split out of the former `endpoints.py` monolith in HARD-031.
"""

import asyncio
import json
import os
import re
from typing import Any

from fastapi import (
    APIRouter,
    File,
    Form,
    Header,
    HTTPException,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.engine_manager import EngineManager
from app.services.gemini_cleaner import GeminiCleaner
from app.services.pdf_extractor import PDFExtractor
from app.services.text_extractor import TextExtractor

router = APIRouter()
log = get_logger(__name__)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class AudiobookEstimate(BaseModel):
    book_id: str
    title: str
    page_count: int
    word_count_estimate: int
    estimated_processing_seconds: float
    estimated_audio_seconds: float
    estimated_cost_usd: float
    estimated_token_count: int
    is_image_only: bool
    cost_warning: bool


class VerifyKeyRequest(BaseModel):
    api_key: str


# Configurable cost-cap threshold; warn (don't block) above this estimated USD.
COST_WARNING_THRESHOLD_USD = 1.00

# File types accepted at upload.
_ALLOWED_EXTENSIONS = {"pdf", "txt", "docx", "md"}

# Per-page OCR character estimate used when sample chars are unavailable.
_OCR_CHARS_PER_PAGE = 1500  # ~250 words × 6 chars/word

# book_id is always a uuid4.hex string (32 lowercase hex chars). Reject
# anything else upfront — a malformed id never touches AudiobookStore which
# would naively pass it to os.path.join, allowing path traversal in theory.
_BOOK_ID_RE = re.compile(r"^[0-9a-f]{32}$")


def _validate_book_id(book_id: str) -> None:
    if not _BOOK_ID_RE.fullmatch(book_id):
        raise HTTPException(status_code=400, detail="Invalid book_id.")


# ---------------------------------------------------------------------------
# Background tasks
# ---------------------------------------------------------------------------

# Hold every spawned bg task so it isn't GC'd before the event loop runs it.
# asyncio.create_task() returns a Task whose only strong reference is the
# scheduler's queue — pulled out as soon as the task yields. A naive
# `asyncio.create_task(...)` with no stored ref can be cancelled mid-flight
# if the GC fires at the wrong moment. See HARD-031.
_bg_tasks: set[asyncio.Task] = set()


def _spawn_bg(coro) -> asyncio.Task:
    task = asyncio.create_task(coro)
    _bg_tasks.add(task)
    task.add_done_callback(_bg_tasks.discard)
    return task


async def _render_cover_task(book_id: str, is_pdf: bool) -> None:
    """Render cover off the request path. Updates meta status on completion."""
    loop = asyncio.get_running_loop()
    try:
        if is_pdf:
            await loop.run_in_executor(None, PDFExtractor.render_cover, book_id)
        else:
            await loop.run_in_executor(None, TextExtractor.render_cover, book_id)
        await AudiobookStore.update_meta(book_id, cover_status="ready")
    except Exception as e:
        log.warning(
            "audiobook.cover_render_failed", extra={"book_id": book_id, "error": str(e)}
        )
        await AudiobookStore.update_meta(book_id, cover_status="failed")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/audiobook", response_model=AudiobookEstimate)
async def upload_audiobook(
    file: UploadFile = File(...),
    voice: str | None = Form(default=None),
    speed: float | None = Form(default=None),
    engine: str | None = Form(default=None),
):
    """Save the uploaded file, extract estimate, return book_id + stats. No processing yet.

    Accepts PDF, TXT, DOCX, and MD files. Optional `voice`, `speed`, `engine`
    form fields snapshot the user's current selection for this book.
    """
    filename = file.filename or "Untitled"
    file_ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if file_ext not in _ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail="Only PDF, TXT, DOCX, and MD files are supported.",
        )

    # Stream-read with a hard size cap. `await file.read()` is unbounded and
    # would OOM the backend on a 1 GB upload. See HARD-017.
    max_bytes = settings.MAX_AUDIOBOOK_UPLOAD_MB * 1024 * 1024
    parts: list[bytes] = []
    total = 0
    while True:
        chunk = await file.read(1 << 20)  # 1 MiB
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(
                status_code=413,
                detail=f"File exceeds {settings.MAX_AUDIOBOOK_UPLOAD_MB} MB limit.",
            )
        parts.append(chunk)
    content = b"".join(parts)
    if not content:
        raise HTTPException(status_code=400, detail="The uploaded file is empty.")
    if file_ext == "pdf" and len(content) < 100:
        raise HTTPException(
            status_code=400, detail="The uploaded file is too small to be a valid PDF."
        )
    title = filename

    book_id = AudiobookStore.create_book(title)
    # Wrap everything after book creation so any unexpected failure cleans up
    # the directory and never leaves an orphan row in the DB.
    try:
        AudiobookStore.save_source(book_id, content, file_ext)

        source_path = AudiobookStore.source_file_path(book_id, file_ext)
        loop = asyncio.get_running_loop()

        is_pdf = file_ext == "pdf"

        try:
            if is_pdf:
                page_count = await loop.run_in_executor(
                    None, PDFExtractor.page_count, source_path
                )
                is_image_only = await loop.run_in_executor(
                    None, PDFExtractor.is_image_only, source_path
                )
            else:
                page_count = await loop.run_in_executor(
                    None, TextExtractor.page_count, source_path
                )
                is_image_only = False
        except Exception as e:
            raise HTTPException(
                status_code=400, detail=f"Could not read file: {e}"
            ) from e

        # P9: reject zero-page / zero-content files early.
        if page_count == 0:
            raise HTTPException(
                status_code=400,
                detail="This file has no extractable content. Try a different file.",
            )

        # D9: TextExtractor.split_pages always returns at least one page —
        # whitespace-only TXT/MD content produces a single page whose text is
        # "", so page_count alone reads as 1 (not 0) and slips past the check
        # above. Confirm that lone page actually has content before accepting
        # the upload. PDFs are exempt: a 0-char PDF page is a real page (an
        # image-only scan, handled by the is_image_only estimate path above),
        # not this TXT/MD-specific synthetic-pagination edge case.
        if not is_pdf and page_count == 1:
            only_page_text = await loop.run_in_executor(
                None, TextExtractor.read_text, source_path
            )
            only_pages = await loop.run_in_executor(
                None, TextExtractor.split_pages, only_page_text
            )
            if not only_pages or not only_pages[0].strip():
                raise HTTPException(
                    status_code=400,
                    detail="This file has no extractable content. Try a different file.",
                )

        # Image-only PDFs → substitute per-page estimate; text files always have text.
        if is_image_only:
            sample_words = 250
            sample_chars = _OCR_CHARS_PER_PAGE
        elif is_pdf:
            sample_words = await loop.run_in_executor(
                None, PDFExtractor.sample_word_count, source_path
            )
            sample_chars = await loop.run_in_executor(
                None, PDFExtractor.sample_char_count, source_path
            )
        else:
            sample_words = await loop.run_in_executor(
                None, TextExtractor.sample_word_count, source_path
            )
            sample_chars = await loop.run_in_executor(
                None, TextExtractor.sample_char_count, source_path
            )

        book_speed = float(speed) if speed is not None else 1.0
        # estimate() now includes token_count, so no post-patch needed.
        estimate = AudiobookService.estimate(
            page_count=page_count,
            sample_words=sample_words,
            sample_chars=sample_chars,
            speed=book_speed,
        )

        # HARD-072: hard cap on estimated Gemini cost. Reject at upload time
        # so the user can't accidentally start a multi-dollar job.
        if estimate["cost_usd"] > settings.MAX_GEMINI_COST_USD_PER_BOOK:
            raise HTTPException(
                status_code=413,
                detail=(
                    f"Estimated Gemini cost ${estimate['cost_usd']:.2f} exceeds "
                    f"the ${settings.MAX_GEMINI_COST_USD_PER_BOOK:.2f} per-book cap. "
                    "Split the document into smaller files or raise the cap "
                    "in settings."
                ),
            )

        state = EngineManager.state()
        book_engine = engine or state.get("engine", "kokoro")
        default_voice = (
            state.get("voices", ["af_bella"])[0] if state.get("voices") else "af_bella"
        )
        book_voice = voice or default_voice

        meta = AudiobookStore.initial_meta(
            book_id=book_id,
            title=title,
            page_count=page_count,
            engine=book_engine,
            voice=book_voice,
            speed=book_speed,
            estimated=estimate,
        )
        meta["file_ext"] = file_ext
        # D6: persisted so _phase_clean can distinguish a genuinely blank
        # page (safe to silence for free) from a scanned/image-only page
        # that also extracts to "" but still deserves a real OCR attempt —
        # see audiobook_service.py's _phase_clean for the consuming logic.
        meta["is_image_only"] = is_image_only
        AudiobookStore.write_meta(book_id, meta)

        # Render cover off the request path. Pulled out of an inline closure
        # in the previous monolithic endpoints.py — see HARD-031.
        _spawn_bg(_render_cover_task(book_id, is_pdf))

        return AudiobookEstimate(
            book_id=book_id,
            title=title,
            page_count=page_count,
            estimated_token_count=estimate["token_count"],
            cost_warning=estimate["cost_usd"] >= COST_WARNING_THRESHOLD_USD,
            word_count_estimate=estimate["words"],
            estimated_processing_seconds=estimate["processing_seconds"],
            estimated_audio_seconds=estimate["audio_seconds"],
            estimated_cost_usd=estimate["cost_usd"],
            is_image_only=is_image_only,
        )

    except HTTPException:
        AudiobookStore.delete_book(book_id)
        raise
    except Exception as e:
        AudiobookStore.delete_book(book_id)
        raise HTTPException(status_code=500, detail=f"Upload failed: {e}") from e


@router.post("/audiobook/{book_id}/start")
async def start_audiobook(
    book_id: str,
    x_gemini_api_key: str | None = Header(default=None, alias="X-Gemini-Api-Key"),
    x_gemini_consent: str | None = Header(default=None, alias="X-Gemini-Consent"),
):
    _validate_book_id(book_id)
    if not x_gemini_api_key:
        raise HTTPException(status_code=400, detail="Missing X-Gemini-Api-Key header.")
    if (x_gemini_consent or "").strip().lower() != "true":
        raise HTTPException(
            status_code=400, detail="Missing or false X-Gemini-Consent header."
        )
    if AudiobookStore.read_meta(book_id) is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    if AudiobookService.is_processing(book_id):
        raise HTTPException(status_code=409, detail="Book is already processing.")
    await AudiobookService.enqueue(book_id, x_gemini_api_key)
    return {"status": "queued", "book_id": book_id}


@router.get("/audiobook/{book_id}/events")
async def audiobook_events(book_id: str):
    _validate_book_id(book_id)
    if AudiobookStore.read_meta(book_id) is None:
        raise HTTPException(status_code=404, detail="Book not found.")

    async def stream():
        q = AudiobookService.subscribe(book_id)
        try:
            # Emit current status immediately so the client doesn't need to poll first.
            meta = AudiobookStore.read_meta(book_id) or {}
            yield f"data: {json.dumps({'type': 'snapshot', **meta})}\n\n"
            # If the book already reached a terminal state before this subscriber
            # arrived, return immediately instead of waiting forever.
            if meta.get("status") in {"done", "failed", "cancelled", "ready"}:
                return
            while True:
                try:
                    event = await asyncio.wait_for(q.get(), timeout=15.0)
                except TimeoutError:
                    yield ": keep-alive\n\n"
                    continue
                yield f"data: {json.dumps(event)}\n\n"
                if event.get("type") in {"done", "failed", "cancelled"}:
                    break
        finally:
            AudiobookService.unsubscribe(book_id, q)

    return StreamingResponse(stream(), media_type="text/event-stream")


@router.get("/audiobook")
def list_audiobooks() -> list[dict[str, Any]]:
    return AudiobookStore.list_books()


@router.get("/audiobook/{book_id}")
def get_audiobook(book_id: str):
    _validate_book_id(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    return meta


@router.get("/audiobook/{book_id}/audio")
def get_audiobook_audio(
    book_id: str,
    range_header: str | None = Header(default=None, alias="Range"),
):
    """Stream audio.wav with HTTP Range support for AVAudioPlayer seeking."""
    _validate_book_id(book_id)
    path = AudiobookStore.audio_path(book_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Audio not ready.")

    file_size = os.path.getsize(path)
    # A valid WAV is at least a 44-byte header. A smaller file means concat hasn't
    # produced real audio yet (or the file is corrupt) — return 404 rather than
    # streaming an empty/garbage body with a 200.
    if file_size < 44:
        raise HTTPException(status_code=404, detail="Audio not ready.")
    if not range_header:
        return FileResponse(
            path,
            media_type="audio/wav",
            filename=f"{book_id}.wav",
            headers={"Accept-Ranges": "bytes", "Content-Length": str(file_size)},
        )

    # Parse `Range: bytes=START-END` (END optional) or `bytes=-N` (suffix form).
    try:
        units, _, rng = range_header.partition("=")
        if units.strip().lower() != "bytes":
            raise ValueError
        start_s, _, end_s = rng.partition("-")
        if not start_s and end_s:
            # Suffix range: bytes=-N means last N bytes
            suffix_len = int(end_s)
            start = max(0, file_size - suffix_len)
            end = file_size - 1
        elif start_s:
            start = int(start_s)
            end = int(end_s) if end_s else file_size - 1
        else:
            start = 0
            end = file_size - 1
        if start < 0 or end >= file_size or start > end:
            raise ValueError
    except ValueError:
        return Response(
            status_code=416, headers={"Content-Range": f"bytes */{file_size}"}
        )

    chunk_size = 1 << 16  # 64 KB per yield

    def iter_range():
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                buf = f.read(min(chunk_size, remaining))
                if not buf:
                    break
                remaining -= len(buf)
                yield buf

    return StreamingResponse(
        iter_range(),
        status_code=206,
        media_type="audio/wav",
        headers={
            "Accept-Ranges": "bytes",
            "Content-Range": f"bytes {start}-{end}/{file_size}",
            "Content-Length": str(end - start + 1),
        },
    )


@router.get("/audiobook/{book_id}/transcript")
def get_audiobook_transcript(book_id: str):
    """Return the per-page transcript + section timing map (for live highlighting)."""
    _validate_book_id(book_id)
    path = AudiobookStore.transcript_path(book_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Transcript not ready.")
    return FileResponse(path, media_type="application/json")


@router.post("/audiobook/{book_id}/cancel")
def cancel_audiobook(book_id: str):
    _validate_book_id(book_id)
    if AudiobookStore.read_meta(book_id) is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    AudiobookService.cancel(book_id)
    return {"status": "cancelling", "book_id": book_id}


@router.post("/audiobook/{book_id}/retry")
async def retry_audiobook(
    book_id: str,
    x_gemini_api_key: str | None = Header(default=None, alias="X-Gemini-Api-Key"),
):
    """Re-process failed pages (or the whole book if state is `failed`)."""
    _validate_book_id(book_id)
    if AudiobookStore.read_meta(book_id) is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    if not x_gemini_api_key:
        raise HTTPException(status_code=400, detail="Missing X-Gemini-Api-Key header.")
    # D4: mirrors /delete's existing is_processing() guard — without it, a
    # double-clicked Retry (or an SSE-reconnect re-POST) could double-enqueue
    # a second concurrent pipeline run on a book that's already processing.
    if AudiobookService.is_processing(book_id):
        raise HTTPException(status_code=409, detail="Book is already processing.")
    count = await AudiobookService.retry_failed(book_id, x_gemini_api_key)
    return {"status": "queued", "retried_pages": count, "book_id": book_id}


@router.get("/audiobook/{book_id}/cover")
def get_audiobook_cover(book_id: str):
    _validate_book_id(book_id)
    path = AudiobookStore.cover_path(book_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Cover not yet rendered.")
    return FileResponse(path, media_type="image/jpeg")


@router.delete("/audiobook/{book_id}")
async def delete_audiobook(book_id: str):
    """Coordinated delete: cancels any in-flight pipeline at its next page
    boundary, then removes the book directory. Prevents the rmtree-mid-write
    crash (C8)."""
    _validate_book_id(book_id)
    ok = await AudiobookService.request_delete(book_id)
    if not ok:
        raise HTTPException(status_code=404, detail="Book not found.")
    return {"status": "deleted", "book_id": book_id}


@router.post("/audiobook/verify_key")
async def verify_key(req: VerifyKeyRequest):
    """Lightweight Gemini key verification (called from PreferencesView)."""
    ok = await GeminiCleaner.verify_key(req.api_key)
    return {"verified": ok}
