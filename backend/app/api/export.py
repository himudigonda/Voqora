"""Export HTTP surface: subtitles, chapter markers, and MP3 audio."""

import asyncio
import os
import tempfile
import threading
import unicodedata
from collections.abc import Callable
from typing import Any
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Query, Request, Response
from fastapi.responses import StreamingResponse

from app.api.audiobook import _PENDING_STATUSES, _load_transcript, _validate_book_id
from app.api.middleware import WAV_CONVERT_PATH
from app.core.config import settings
from app.core.logging import get_logger
from app.services.audiobook_service import WAV_HEADER_SIZE, AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.mp3_encoder import (
    DEFAULT_MP3_BITRATE_KBPS,
    MP3_BITRATES_KBPS,
    Mp3InputError,
    Mp3UnavailableError,
    encode_wav_to_mp3,
    has_wav_header,
)
from app.services.transcript_export import (
    Cue,
    build_cues,
    chapter_markers,
    format_srt,
    format_vtt,
    transcript_lines,
)

router = APIRouter()
log = get_logger(__name__)

_GENERATING_STATUSES = _PENDING_STATUSES | {"needs_cost_approval"}
_SOURCE_EXTENSIONS = (".pdf", ".txt", ".docx", ".md")
_FILENAME_PUNCTUATION = frozenset(" -_.,()")
_MAX_FILENAME_CHARS = 100
_WAV_CONTENT_TYPES = frozenset(
    {"audio/wav", "audio/x-wav", "audio/wave", "application/octet-stream"}
)
_STREAM_CHUNK_BYTES = 1 << 16
_mp3_slot = threading.BoundedSemaphore(1)

_BITRATE_QUERY = Query(
    default=DEFAULT_MP3_BITRATE_KBPS,
    ge=MP3_BITRATES_KBPS[0],
    le=MP3_BITRATES_KBPS[-1],
    description="Constant MP3 bitrate in kbps.",
)


def _require_bitrate(bitrate: int) -> None:
    if bitrate not in MP3_BITRATES_KBPS:
        allowed = ", ".join(str(value) for value in MP3_BITRATES_KBPS)
        raise HTTPException(
            status_code=422, detail=f"MP3 bitrate must be one of {allowed} kbps."
        )


def _exportable_meta(book_id: str) -> dict[str, Any]:
    _validate_book_id(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise HTTPException(status_code=404, detail="Book not found.")
    if meta.get("status") in _GENERATING_STATUSES:
        raise HTTPException(
            status_code=409, detail="This audiobook is still being generated."
        )
    return meta


def book_title(title: Any, fallback: str) -> str:
    base = unicodedata.normalize("NFC", str(title or "")).strip()
    if base.lower().endswith(_SOURCE_EXTENSIONS):
        base = base.rsplit(".", 1)[0]
    return " ".join(base.split()) or fallback


def export_filename(title: Any, extension: str, fallback: str) -> str:
    stem = _filename_safe(book_title(title, fallback))[:_MAX_FILENAME_CHARS]
    return f"{stem.strip(' ._') or fallback}.{extension}"


def content_disposition(filename: str) -> str:
    stem, _, extension = filename.rpartition(".")
    ascii_stem = _filename_safe(
        unicodedata.normalize("NFKD", stem).encode("ascii", "ignore").decode("ascii")
    ).strip(" ._")
    return (
        f'attachment; filename="{ascii_stem or "export"}.{extension}"; '
        f"filename*=UTF-8''{quote(filename)}"
    )


def _filename_safe(text: str) -> str:
    cleaned = "".join(
        char if char.isalnum() or char in _FILENAME_PUNCTUATION else "_"
        for char in text
    )
    return " ".join(cleaned.split())


def _subtitle_response(
    book_id: str,
    render: Callable[[list[Cue]], str],
    extension: str,
    media_type: str,
) -> Response:
    meta = _exportable_meta(book_id)
    transcript = _load_transcript(book_id)
    body = render(build_cues(transcript_lines(transcript)))
    filename = export_filename(meta.get("title"), extension, "audiobook")
    return Response(
        content=body.encode("utf-8"),
        media_type=media_type,
        headers={"Content-Disposition": content_disposition(filename)},
    )


@router.get("/audiobook/{book_id}/export/srt")
def export_audiobook_srt(book_id: str):
    """Sentence-timed SubRip subtitles for a finished audiobook."""
    return _subtitle_response(
        book_id, format_srt, "srt", "application/x-subrip; charset=utf-8"
    )


@router.get("/audiobook/{book_id}/export/vtt")
def export_audiobook_vtt(book_id: str):
    """Sentence-timed WebVTT subtitles for a finished audiobook."""
    return _subtitle_response(book_id, format_vtt, "vtt", "text/vtt; charset=utf-8")


@router.get("/audiobook/{book_id}/chapters")
def get_audiobook_chapters(book_id: str):
    """Chapter markers aligned to audio.wav, for M4B chapter tracks."""
    meta = _exportable_meta(book_id)
    transcript = _load_transcript(book_id)
    total = float(transcript.get("total_audio_seconds") or 0.0)
    return {
        "book_id": book_id,
        "total_audio_seconds": round(total, 3),
        "chapters": chapter_markers(
            transcript, book_title(meta.get("title"), "Audiobook")
        ),
    }


@router.get("/audiobook/{book_id}/export/mp3")
async def export_audiobook_mp3(book_id: str, bitrate: int = _BITRATE_QUERY):
    """Encode a finished audiobook's audio.wav to a constant-bitrate MP3."""
    _require_bitrate(bitrate)
    meta = _exportable_meta(book_id)
    source = AudiobookStore.audio_path(book_id)
    if not os.path.exists(source) or os.path.getsize(source) < WAV_HEADER_SIZE:
        raise HTTPException(status_code=404, detail="Audio not ready.")
    try:
        encoded = await _encode_mp3(source, bitrate)
    except Mp3InputError as exc:
        log.warning(
            "export.book_audio_unreadable",
            extra={"book_id": book_id, "failure_code": "book_audio_unreadable"},
        )
        raise HTTPException(
            status_code=500, detail="This audiobook's audio could not be exported."
        ) from exc
    return _mp3_response(
        encoded, export_filename(meta.get("title"), "mp3", "audiobook")
    )


@router.post(WAV_CONVERT_PATH)
async def convert_wav_to_mp3(
    request: Request,
    bitrate: int = _BITRATE_QUERY,
    name: str | None = Query(default=None, max_length=120),
):
    """Convert one uploaded WAV clip (raw request body) to MP3."""
    _require_bitrate(bitrate)
    content_type = (request.headers.get("content-type") or "").split(";")[0]
    if content_type.strip().lower() not in _WAV_CONTENT_TYPES:
        raise HTTPException(status_code=415, detail="Send the clip as audio/wav.")
    staged = await _stage_wav_upload(request)
    try:
        encoded = await _encode_mp3(staged, bitrate)
    except Mp3InputError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    finally:
        AudiobookService._remove_quietly(staged)
    return _mp3_response(encoded, export_filename(name, "mp3", "clip"))


async def _stage_wav_upload(request: Request) -> str:
    limit = settings.MAX_WAV_CONVERT_MB * 1024 * 1024
    descriptor, path = tempfile.mkstemp(
        prefix="upload-", suffix=".wav.tmp", dir=AudiobookStore.exports_dir()
    )
    total = 0
    prefix = b""
    try:
        with os.fdopen(descriptor, "wb") as staged:
            async for chunk in request.stream():
                total += len(chunk)
                if total > limit:
                    raise HTTPException(
                        status_code=413,
                        detail=f"File exceeds {settings.MAX_WAV_CONVERT_MB} MB limit.",
                    )
                if len(prefix) < 12:
                    prefix += chunk[: 12 - len(prefix)]
                staged.write(chunk)
        if total == 0:
            raise HTTPException(status_code=400, detail="The uploaded file is empty.")
        if not has_wav_header(prefix):
            raise HTTPException(
                status_code=400, detail="This file is not a valid WAV file."
            )
        return path
    except BaseException:
        AudiobookService._remove_quietly(path)
        raise


async def _encode_mp3(source: str, bitrate: int) -> str:
    if not _mp3_slot.acquire(blocking=False):
        raise HTTPException(
            status_code=429,
            detail="Another MP3 export is in progress. Try again shortly.",
            headers={"Retry-After": "5"},
        )
    cancel = threading.Event()
    try:
        future = asyncio.get_running_loop().run_in_executor(
            None, _encode_to_temp, source, bitrate, cancel
        )
    except BaseException:
        _mp3_slot.release()
        raise
    future.add_done_callback(lambda _: _mp3_slot.release())
    try:
        return await asyncio.shield(future)
    except asyncio.CancelledError:
        cancel.set()
        future.add_done_callback(_discard_encoded)
        raise
    except (Mp3InputError, HTTPException):
        raise
    except Mp3UnavailableError as exc:
        log.error(
            "export.mp3_unavailable",
            extra={"failure_code": "mp3_encoder_unavailable"},
        )
        raise HTTPException(
            status_code=503, detail="MP3 export is not available in this build."
        ) from exc
    except Exception as exc:
        log.error(
            "export.mp3_encode_failed",
            extra={"failure_code": "mp3_encode_failed", "bitrate_kbps": bitrate},
            exc_info=True,
        )
        raise HTTPException(status_code=500, detail="MP3 export failed.") from exc


def _encode_to_temp(source: str, bitrate: int, cancel: threading.Event) -> str:
    descriptor, path = tempfile.mkstemp(
        prefix="export-", suffix=".mp3.tmp", dir=AudiobookStore.exports_dir()
    )
    os.close(descriptor)
    try:
        encode_wav_to_mp3(source, path, bitrate, cancel)
    except BaseException:
        AudiobookService._remove_quietly(path)
        raise
    return path


def _discard_encoded(future: "asyncio.Future[str]") -> None:
    if not future.cancelled() and future.exception() is None:
        AudiobookService._remove_quietly(future.result())


def _mp3_response(path: str, filename: str) -> StreamingResponse:
    try:
        handle = open(path, "rb")
    except OSError as exc:
        log.error(
            "export.mp3_open_failed",
            extra={"failure_code": "mp3_open_failed"},
            exc_info=True,
        )
        raise HTTPException(status_code=500, detail="MP3 export failed.") from exc
    finally:
        AudiobookService._remove_quietly(path)
    size = os.fstat(handle.fileno()).st_size

    def iterate():
        with handle:
            while chunk := handle.read(_STREAM_CHUNK_BYTES):
                yield chunk

    return StreamingResponse(
        iterate(),
        media_type="audio/mpeg",
        headers={
            "Content-Length": str(size),
            "Content-Disposition": content_disposition(filename),
        },
    )
