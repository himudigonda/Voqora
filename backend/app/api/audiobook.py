"""Audiobook HTTP surface — upload, lifecycle, range-served audio, SSE events.

Split out of the former `endpoints.py` monolith in HARD-031.
"""

import asyncio
import hashlib
import json
import math
import os
import re
import tempfile
from typing import Any, NamedTuple

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    Header,
    HTTPException,
    Query,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from app.api.article import article_error_response, run_reader
from app.core.config import settings
from app.core.logging import get_logger
from app.services.article_errors import ArticleError
from app.services.article_reader import audiobook_source
from app.services.audiobook_service import WAV_HEADER_SIZE, AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.engine_manager import EngineManager
from app.services.import_limits import (
    ImportLimitError,
    ensure_storage_capacity,
    estimated_pcm_bytes,
    validate_docx_archive,
    validate_epub_archive,
    validate_magic,
)
from app.services.llm_cleaner import LLMCleaner
from app.services.llm_providers import PROVIDERS, LLMCredential, api_key_problem
from app.services.pdf_extractor import PDFExtractor
from app.services.pronunciation import pronunciations
from app.services.text_extractor import TextExtractor
from app.services.transcript_export import with_word_timings
from app.services.tts import MAX_PAUSE_SCALE, MIN_PAUSE_SCALE
from app.services.url_guard import MAX_URL_CHARS
from app.services.voices import resolve_voice
from app.services.web_fetcher import WebFetcher, web_fetcher

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
    maximum_cost_usd: float
    estimated_token_count: int
    is_image_only: bool
    cost_warning: bool
    llm_provider: str | None = None
    llm_model: str | None = None
    pricing_known: bool = True
    reads_images: bool | None = True
    # Set when this exact file content already exists as another book.
    # Uploads were previously silently duplicated with no dedupe check at
    # all — this flags it so the client can warn instead of proceeding
    # silently, without blocking a deliberate re-import (e.g. narrating the
    # same document with a different voice).
    duplicate_of_book_id: str | None = None
    duplicate_of_title: str | None = None
    author: str | None = None


class VerifyProviderRequest(BaseModel):
    provider: str
    api_key: str = ""
    model: str = ""
    base_url: str = ""


def _provider_credential(
    provider: str | None, api_key: str | None, model: str | None, base_url: str | None
) -> LLMCredential | None:
    if not provider:
        return None
    if provider not in PROVIDERS:
        raise HTTPException(status_code=400, detail="Unknown AI provider.")
    key_problem = api_key_problem(api_key or "")
    if key_problem:
        raise HTTPException(status_code=400, detail=key_problem)
    return LLMCredential(provider, api_key or "", model or "", base_url or "")


def _pricing_credential(
    provider: str | None, model: str | None, base_url: str | None
) -> LLMCredential | None:
    credential = _provider_credential(provider, None, model, base_url)
    if credential is not None and base_url and credential.server_url_problem():
        return _provider_credential(provider, None, model, None)
    return credential


def llm_credential(
    provider: str | None = Header(default=None, alias="X-Voqora-LLM-Provider"),
    api_key: str | None = Header(default=None, alias="X-Voqora-LLM-Key"),
    model: str | None = Header(default=None, alias="X-Voqora-LLM-Model"),
    base_url: str | None = Header(default=None, alias="X-Voqora-LLM-Base-URL"),
) -> LLMCredential | None:
    return _provider_credential(provider, api_key, model, base_url)


def _require_credential(credential: LLMCredential | None) -> LLMCredential:
    if credential is None:
        raise HTTPException(
            status_code=400,
            detail="Choose an AI provider in Settings to clean up this audiobook.",
        )
    problem = credential.problem()
    if problem:
        raise HTTPException(status_code=400, detail=problem)
    return credential


class AudiobookURLRequest(BaseModel):
    url: str = Field(min_length=1, max_length=MAX_URL_CHARS)
    voice: str | None = Field(default=None, max_length=64)
    speed: float | None = None
    engine: str | None = Field(default=None, max_length=32)
    pause_scale: float | None = None
    llm_provider: str | None = Field(default=None, max_length=32)
    llm_model: str | None = Field(default=None, max_length=200)
    llm_base_url: str | None = Field(default=None, max_length=MAX_URL_CHARS)


class CostApprovalRequest(BaseModel):
    approve: bool
    new_cap_usd: float | None = None


_PENDING_STATUSES = frozenset(
    {
        "queued",
        "extracting",
        "cleaning",
        "sectioning",
        "tts",
        "concatenating",
        "needs_key",
    }
)


def _pending_audio_bytes(*, exclude: str | None) -> int:
    pending = 0
    for meta in AudiobookStore.list_books():
        if (
            meta.get("book_id") == exclude
            or meta.get("status") not in _PENDING_STATUSES
        ):
            continue
        seconds = float((meta.get("estimated") or {}).get("audio_seconds") or 0)
        pending += estimated_pcm_bytes(seconds) * 2
    return pending


# Configurable cost-cap threshold; warn (don't block) above this estimated USD.
COST_WARNING_THRESHOLD_USD = 1.00
_MAX_APPROVED_CAP_USD = 10_000.0

# File types accepted at upload.
_ALLOWED_EXTENSIONS = {"pdf", "txt", "docx", "md", "epub", "html", "htm"}

# Per-page OCR character estimate used when sample chars are unavailable.
_OCR_CHARS_PER_PAGE = 1500  # ~250 words × 6 chars/word

# book_id is always a uuid4.hex string (32 lowercase hex chars). Reject
# anything else upfront — a malformed id never touches AudiobookStore which
# would naively pass it to os.path.join, allowing path traversal in theory.
_BOOK_ID_RE = re.compile(r"^[0-9a-f]{32}$")

# Audiobook synthesis ultimately reaches the same Kokoro engine as /speak.
# Keep its persisted snapshot within that public API's contract. A typo in
# voice or an invalid speed must fail at upload time, rather than producing a
# book full of fallback silence much later in the background pipeline.
_MIN_TTS_SPEED = 0.5
_MAX_TTS_SPEED = 2.0


def _validate_book_id(book_id: str) -> None:
    if not _BOOK_ID_RE.fullmatch(book_id):
        raise HTTPException(status_code=400, detail="Invalid book_id.")


def _forget_book_pronunciations(book_id: str | None) -> None:
    try:
        if book_id is None:
            pronunciations.delete_orphaned_scopes(
                lambda scope: AudiobookStore.read_meta(scope) is not None
            )
        else:
            pronunciations.delete_scope(book_id)
    except OSError:
        log.warning(
            "audiobook.pronunciation_cleanup_failed",
            extra={"book_id": book_id, "failure_code": "pronunciation_cleanup_failed"},
            exc_info=True,
        )


def _validated_pause_scale(pause_scale: float | None) -> float:
    scale = 1.0 if pause_scale is None else float(pause_scale)
    if not math.isfinite(scale) or not MIN_PAUSE_SCALE <= scale <= MAX_PAUSE_SCALE:
        raise HTTPException(
            status_code=422,
            detail=(
                f"Pause length must be between {MIN_PAUSE_SCALE} and "
                f"{MAX_PAUSE_SCALE}."
            ),
        )
    return scale


def _validated_synthesis_settings(
    voice: str | None, speed: float | None, engine: str | None
) -> tuple[str, float, str, str]:
    book_voice = voice or EngineManager.default_voice()
    spec = resolve_voice(book_voice)
    if spec is None:
        raise HTTPException(status_code=422, detail="Unknown narration voice.")

    book_speed = 1.0 if speed is None else float(speed)
    if (
        not math.isfinite(book_speed)
        or not _MIN_TTS_SPEED <= book_speed <= _MAX_TTS_SPEED
    ):
        raise HTTPException(
            status_code=422,
            detail=(
                f"Narration speed must be between {_MIN_TTS_SPEED} and "
                f"{_MAX_TTS_SPEED}."
            ),
        )

    book_engine = engine or EngineManager.state().get("engine", "kokoro")
    if book_engine != "kokoro":
        raise HTTPException(status_code=422, detail="Unknown narration engine.")
    return book_voice, book_speed, book_engine, spec.fallback_voice


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
    except Exception:
        log.warning(
            "audiobook.cover_render_failed",
            extra={"book_id": book_id, "failure_code": "cover_render_failed"},
            exc_info=True,
        )
        await AudiobookStore.update_meta(book_id, cover_status="failed")


class _StagedSource(NamedTuple):
    path: str
    file_ext: str
    title: str
    total: int
    content_hash: str
    # Who wrote it, when the source says so outside the file itself (a web
    # article's byline). Metadata the file declares (EPUB, HTML) wins.
    author: str | None = None


class _Synthesis(NamedTuple):
    voice: str
    speed: float
    engine: str
    voice_fallback: str
    pause_scale: float


def _validated_synthesis(
    voice: str | None,
    speed: float | None,
    engine: str | None,
    pause_scale: float | None,
) -> _Synthesis:
    return _Synthesis(
        *_validated_synthesis_settings(voice, speed, engine),
        _validated_pause_scale(pause_scale),
    )


def _new_staging_file(file_ext: str) -> tuple[int, str]:
    return tempfile.mkstemp(
        prefix=".upload-", suffix=f".{file_ext}", dir=AudiobookStore.root_dir()
    )


def _discard_staged(staged_path: str | None) -> None:
    if not staged_path:
        return
    try:
        os.unlink(staged_path)
    except FileNotFoundError:
        pass


async def _stage_upload(file: UploadFile, file_ext: str) -> tuple[str, int, str]:
    # Stream straight to a private staging file. Keeping chunks in a list and
    # joining them later made a nominal 100 MB document occupy multiple large
    # process allocations while the speech model was also resident.
    max_bytes = settings.MAX_AUDIOBOOK_UPLOAD_MB * 1024 * 1024
    total = 0
    digest = hashlib.sha256()
    descriptor, staged_path = _new_staging_file(file_ext)
    try:
        with os.fdopen(descriptor, "wb") as staged:
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
                digest.update(chunk)
                staged.write(chunk)
            staged.flush()
            os.fsync(staged.fileno())
    except BaseException:
        _discard_staged(staged_path)
        raise
    return staged_path, total, digest.hexdigest()


def _stage_bytes(content: bytes, file_ext: str) -> str:
    descriptor, staged_path = _new_staging_file(file_ext)
    try:
        with os.fdopen(descriptor, "wb") as staged:
            staged.write(content)
            staged.flush()
            os.fsync(staged.fileno())
    except BaseException:
        _discard_staged(staged_path)
        raise
    return staged_path


async def _import_staged(
    source: _StagedSource,
    synthesis: _Synthesis,
    pricing_credential: LLMCredential | None,
    *,
    extra_meta: dict[str, Any] | None = None,
) -> AudiobookEstimate:
    book_voice, book_speed, book_engine = (
        synthesis.voice,
        synthesis.speed,
        synthesis.engine,
    )
    staged_path, file_ext, title = source.path, source.file_ext, source.title
    total, content_hash = source.total, source.content_hash
    book_id: str | None = None
    try:
        if total == 0:
            raise HTTPException(status_code=400, detail="The uploaded file is empty.")
        if file_ext == "pdf" and total < 100:
            raise HTTPException(
                status_code=400,
                detail="The uploaded file is too small to be a valid PDF.",
            )
        validate_magic(staged_path, file_ext)
        if file_ext == "docx":
            validate_docx_archive(staged_path)
        if file_ext == "epub":
            validate_epub_archive(staged_path)

        duplicate = next(
            (
                b
                for b in AudiobookStore.list_books()
                if b.get("source_sha256") == content_hash
            ),
            None,
        )

        book_id = AudiobookStore.create_book(title)
        source_path = AudiobookStore.adopt_staged_source(book_id, staged_path, file_ext)
        # Wrap everything after book creation so any unexpected failure cleans up
        # the directory and never leaves an orphan row in the DB.
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
        except ImportLimitError:
            raise
        except Exception as exc:
            # Not curated: the raw exception can be a library-internal
            # message (parser jargon, occasionally an internal path
            # fragment) with no useful action for the user. Log it for
            # diagnostics; the client only ever needs to know what to do.
            log.warning(
                "audiobook.upload_could_not_read_file",
                extra={"book_id": book_id, "failure_code": "source_read_failed"},
            )
            raise HTTPException(
                status_code=400,
                detail="Could not read this file. It may be corrupted or in an unsupported format.",
            ) from exc

        # P9: reject zero-page / zero-content files early.
        if page_count == 0:
            raise HTTPException(
                status_code=400,
                detail="This file has no extractable content. Try a different file.",
            )
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
        declared_title, author = (
            (None, None)
            if is_pdf
            else await loop.run_in_executor(
                None, TextExtractor.read_metadata, source_path
            )
        )
        author = author or source.author
        if declared_title and file_ext == "epub":
            title = declared_title
        if page_count > settings.MAX_AUDIOBOOK_PAGES:
            raise HTTPException(
                status_code=413,
                detail=(
                    f"This document has more than {settings.MAX_AUDIOBOOK_PAGES:,} pages. "
                    "Split it into smaller books before importing."
                ),
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

        estimate = AudiobookService.estimate(
            page_count=page_count,
            sample_words=sample_words,
            sample_chars=sample_chars,
            speed=book_speed,
            credential=pricing_credential,
        )
        estimate["cleanup_chars"] = sample_chars * page_count
        estimate["token_count"] = LLMCleaner.estimate_tokens(estimate["cleanup_chars"])
        estimate["max_cost_usd"] = LLMCleaner.estimate_max_cost_usd(
            estimate["cleanup_chars"], pricing_credential
        )
        estimate["pricing_version"] = LLMCleaner.PRICING_VERSION
        if estimate["audio_seconds"] > settings.MAX_AUDIOBOOK_DURATION_SECONDS:
            raise HTTPException(
                status_code=413,
                detail="This book would exceed Voqora's 24-hour narration limit.",
            )
        try:
            ensure_storage_capacity(
                total,
                estimate["audio_seconds"],
                library_root=AudiobookStore.root_dir(),
                reserved_bytes=_pending_audio_bytes(exclude=book_id),
            )
        except ImportLimitError as exc:
            raise HTTPException(status_code=413, detail=str(exc)) from exc

        # This is a transparent *optional* AI cleanup estimate. The cap is
        # enforced only if the user explicitly enables cleanup at /start;
        # local narration must never reject a document for a cloud cost it
        # will not incur.

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
        meta["is_image_only"] = is_image_only
        meta["source_sha256"] = content_hash
        if author:
            meta["author"] = author
        meta["voice_fallback"] = synthesis.voice_fallback
        meta["pause_scale"] = synthesis.pause_scale
        meta.update(extra_meta or {})
        AudiobookStore.write_meta(book_id, meta)

        # Render cover off the request path. Pulled out of an inline closure
        # in the previous monolithic endpoints.py — see HARD-031.
        _spawn_bg(_render_cover_task(book_id, is_pdf))

        return AudiobookEstimate(
            book_id=book_id,
            title=title,
            page_count=page_count,
            estimated_token_count=estimate["token_count"],
            cost_warning=estimate["max_cost_usd"] >= COST_WARNING_THRESHOLD_USD,
            word_count_estimate=estimate["words"],
            estimated_processing_seconds=estimate["processing_seconds"],
            estimated_audio_seconds=estimate["audio_seconds"],
            estimated_cost_usd=estimate["cost_usd"],
            maximum_cost_usd=estimate["max_cost_usd"],
            is_image_only=is_image_only,
            llm_provider=pricing_credential.provider if pricing_credential else None,
            llm_model=(
                pricing_credential.resolved_model if pricing_credential else None
            ),
            pricing_known=LLMCleaner.is_priced(pricing_credential),
            reads_images=(
                pricing_credential.spec.supports_vision(
                    pricing_credential.resolved_model
                )
                if pricing_credential is not None
                else True
            ),
            duplicate_of_book_id=duplicate.get("book_id") if duplicate else None,
            duplicate_of_title=duplicate.get("title") if duplicate else None,
            author=author,
        )

    except ImportLimitError as exc:
        if book_id is not None:
            AudiobookStore.delete_book(book_id)
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except HTTPException:
        if book_id is not None:
            AudiobookStore.delete_book(book_id)
        raise
    except Exception:
        if book_id is not None:
            AudiobookStore.delete_book(book_id)
        raise


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/audiobook", response_model=AudiobookEstimate)
async def upload_audiobook(
    file: UploadFile = File(...),
    voice: str | None = Form(default=None),
    speed: float | None = Form(default=None),
    engine: str | None = Form(default=None),
    pause_scale: float | None = Form(default=None),
    llm_provider: str | None = Form(default=None),
    llm_model: str | None = Form(default=None),
    llm_base_url: str | None = Form(default=None),
):
    """Save the uploaded file, extract estimate, return book_id + stats. No processing yet.

    Accepts PDF, EPUB, TXT, DOCX, MD, and HTML files. Optional `voice` (a built-in
    voice or blend id), `speed`, `engine` and `pause_scale` form fields snapshot the
    user's current selection for this book.
    """
    filename = file.filename or "Untitled"
    file_ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if file_ext not in _ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail="Only PDF, EPUB, TXT, DOCX, MD, and HTML files are supported.",
        )

    # Validate before allocating a book directory or buffering a potentially
    # large upload. These fields are persisted settings, not client hints.
    synthesis = _validated_synthesis(voice, speed, engine, pause_scale)
    pricing_credential = _pricing_credential(llm_provider, llm_model, llm_base_url)

    staged_path: str | None = None
    try:
        staged_path, total, content_hash = await _stage_upload(file, file_ext)
        return await _import_staged(
            _StagedSource(staged_path, file_ext, filename, total, content_hash),
            synthesis,
            pricing_credential,
        )
    except HTTPException:
        raise
    except Exception as exc:
        log.warning("audiobook.upload_failed", extra={"failure_code": "upload_failed"})
        raise HTTPException(
            status_code=500, detail="Upload failed. Please try again."
        ) from exc
    finally:
        _discard_staged(staged_path)


@router.post("/audiobook/url", response_model=AudiobookEstimate)
async def create_audiobook_from_url(
    body: AudiobookURLRequest, fetcher: WebFetcher = Depends(web_fetcher)
):
    """Fetch a web article or PDF link and add it to Library like an upload.

    Articles are stored as Markdown so their headings become sections.
    """
    synthesis = _validated_synthesis(
        body.voice, body.speed, body.engine, body.pause_scale
    )
    pricing_credential = _pricing_credential(
        body.llm_provider, body.llm_model, body.llm_base_url
    )
    try:
        page = await fetcher.fetch(body.url)
        source = await run_reader(audiobook_source, page)
    except ArticleError as error:
        return article_error_response(error)
    if len(source.content) > settings.MAX_AUDIOBOOK_UPLOAD_MB * 1024 * 1024:
        raise HTTPException(
            status_code=413,
            detail=f"File exceeds {settings.MAX_AUDIOBOOK_UPLOAD_MB} MB limit.",
        )

    staged_path: str | None = None
    try:
        staged_path = await asyncio.get_running_loop().run_in_executor(
            None, _stage_bytes, source.content, source.file_ext
        )
        return await _import_staged(
            _StagedSource(
                staged_path,
                source.file_ext,
                source.title,
                len(source.content),
                hashlib.sha256(source.content).hexdigest(),
                source.author,
            ),
            synthesis,
            pricing_credential,
            extra_meta={"source_url": page.url},
        )
    except HTTPException:
        raise
    except Exception as exc:
        log.warning(
            "audiobook.url_import_failed",
            extra={"failure_code": "url_import_failed"},
        )
        raise HTTPException(
            status_code=500, detail="Couldn't add this page. Please try again."
        ) from exc
    finally:
        _discard_staged(staged_path)


@router.post("/audiobook/{book_id}/start")
async def start_audiobook(
    book_id: str,
    credential: LLMCredential | None = Depends(llm_credential),
    x_voqora_llm_cleanup: str | None = Header(
        default=None, alias="X-Voqora-LLM-Cleanup"
    ),
):
    _validate_book_id(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    uses_llm_cleanup = (x_voqora_llm_cleanup or "").lower() == "true"
    if uses_llm_cleanup:
        credential = _require_credential(credential)
    estimated = meta.get("estimated") or {}
    if "cleanup_chars" in estimated and credential is not None:
        estimated_cost = LLMCleaner.estimate_max_cost_usd(
            int(estimated["cleanup_chars"]), credential
        )
    else:
        estimated_cost = float(
            estimated.get("max_cost_usd") or estimated.get("cost_usd") or 0
        )
    if uses_llm_cleanup and estimated_cost > settings.MAX_GEMINI_COST_USD_PER_BOOK:
        raise HTTPException(
            status_code=413,
            detail=(
                f"The conservative {credential.name} cost envelope "
                f"${estimated_cost:.2f} exceeds the "
                f"${settings.MAX_GEMINI_COST_USD_PER_BOOK:.2f} per-book cap."
            ),
        )
    accepted = await AudiobookService.start(
        book_id,
        credential if uses_llm_cleanup else None,
        uses_llm_cleanup=uses_llm_cleanup,
    )
    if not accepted:
        raise HTTPException(
            status_code=409, detail="This audiobook is already processing."
        )
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


@router.delete("/audiobook")
async def delete_all_audiobooks():
    """Remove every local book, source document, transcript, and audio file."""
    deleted = await AudiobookService.request_delete_all()
    _forget_book_pronunciations(None)
    return {"status": "deleted", "deleted_books": deleted}


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
    if file_size < WAV_HEADER_SIZE:
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


def _load_transcript(book_id: str) -> dict[str, Any]:
    AudiobookService.backfill_transcript_lines(book_id)
    try:
        transcript = AudiobookStore.read_transcript(book_id)
    except (OSError, ValueError):
        log.warning(
            "audiobook.transcript_read_failed",
            extra={"book_id": book_id, "failure_code": "transcript_read_failed"},
            exc_info=True,
        )
        raise HTTPException(
            status_code=500, detail="The transcript could not be read."
        ) from None
    if transcript is None:
        raise HTTPException(status_code=404, detail="Transcript not ready.")
    return transcript


@router.get("/audiobook/{book_id}/transcript")
def get_audiobook_transcript(book_id: str, words: bool = Query(default=False)):
    """Return the per-page transcript + section timing map (for live highlighting).

    `words=true` adds an estimated `words` list to every timed line.
    """
    _validate_book_id(book_id)
    if words:
        return JSONResponse(with_word_timings(_load_transcript(book_id)))
    path = AudiobookStore.transcript_path(book_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Transcript not ready.")
    AudiobookService.backfill_transcript_lines(book_id)
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
    credential: LLMCredential | None = Depends(llm_credential),
    x_voqora_llm_cleanup: str | None = Header(
        default=None, alias="X-Voqora-LLM-Cleanup"
    ),
):
    """Re-process failed pages (or the whole book if state is `failed`)."""
    _validate_book_id(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    if AudiobookService.is_processing(book_id):
        raise HTTPException(status_code=409, detail="Book is already processing.")
    cleanup = (x_voqora_llm_cleanup or "").strip().lower() != "false"
    if cleanup and bool(meta.get("uses_gemini_cleanup", True)):
        credential = _require_credential(credential)
    count = await AudiobookService.retry_failed(book_id, credential, cleanup=cleanup)
    return {"status": "queued", "retried_pages": count, "book_id": book_id}


@router.post("/audiobook/{book_id}/cost-approval")
async def resolve_cost_approval(
    book_id: str,
    body: CostApprovalRequest,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Explicitly approve a higher Standard-tier ceiling or finish locally."""
    _validate_book_id(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    if meta.get("status") != "needs_cost_approval":
        raise HTTPException(
            status_code=409, detail="This book is not awaiting cost approval."
        )
    if body.approve:
        credential = _require_credential(credential)
        if not credential.is_gemini:
            raise HTTPException(
                status_code=400,
                detail="Standard-tier approval applies only to Google Gemini.",
            )
    if body.new_cap_usd is not None and not (
        math.isfinite(body.new_cap_usd)
        and 0 <= body.new_cap_usd <= _MAX_APPROVED_CAP_USD
    ):
        raise HTTPException(status_code=422, detail="The approved cap is not valid.")
    try:
        accepted = await AudiobookService.resolve_cost_approval(
            book_id,
            credential if body.approve else None,
            approve=body.approve,
            new_cap_usd=body.new_cap_usd,
        )
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    if not accepted:
        raise HTTPException(status_code=404, detail="Book not found.")
    return {
        "status": "queued",
        "book_id": book_id,
        "tier": "standard" if body.approve else "local",
    }


@router.get("/audiobook/{book_id}/cover")
def get_audiobook_cover(book_id: str):
    _validate_book_id(book_id)
    path = AudiobookStore.cover_path(book_id)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Cover not yet rendered.")
    meta = AudiobookStore.read_meta(book_id) or {}
    if meta.get("file_ext", "pdf") != "pdf" and not TextExtractor.cover_is_current(
        path
    ):
        try:
            TextExtractor.render_cover(book_id)
        except Exception:
            log.warning(
                "audiobook.cover_upgrade_failed",
                extra={"book_id": book_id, "failure_code": "cover_upgrade_failed"},
                exc_info=True,
            )
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
    _forget_book_pronunciations(book_id)
    return {"status": "deleted", "book_id": book_id}


@router.post("/llm/verify")
async def verify_provider(req: VerifyProviderRequest):
    credential = _provider_credential(
        req.provider.strip(), req.api_key, req.model, req.base_url
    )
    if credential is None:
        raise HTTPException(status_code=400, detail="Choose an AI provider.")
    result = await LLMCleaner.verify(credential)
    return {"verified": result.ok, "models": result.models, "error": result.error}
