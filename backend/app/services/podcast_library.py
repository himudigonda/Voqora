import os
import uuid
from dataclasses import dataclass
from typing import Any

from pydantic import ValidationError

from app.core.logging import get_logger
from app.services.audiobook_store import AudiobookStore
from app.services.pdf_extractor import PDFExtractor
from app.services.podcast_script import (
    PODCAST_KIND,
    STORED_SCRIPT_CONTEXT,
    PodcastScript,
)
from app.services.text_extractor import TextExtractor
from app.services.voices import voice_with_fallback

log = get_logger(__name__)

_WORDS_PER_SECOND = 2.75


@dataclass(frozen=True)
class TurnPlan:
    speaker_id: str
    speaker: str
    voice: str
    pause_after_seconds: float


def _write_text_atomic(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{uuid.uuid4().hex}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def estimated_audio_seconds(script: PodcastScript) -> float:
    return script.word_count() / _WORDS_PER_SECOND + script.pause_seconds()


def transcript_text(script: PodcastScript) -> str:
    return "\n\n".join(
        f"{script.speaker(turn.speaker_id).name}: {turn.text}" for turn in script.turns
    )


def is_podcast(meta: dict[str, Any] | None) -> bool:
    return bool(meta) and meta.get("kind") == PODCAST_KIND


def speaker_summary(script: PodcastScript) -> list[dict[str, str]]:
    return [speaker.model_dump() for speaker in script.speakers]


def save_script(book_id: str, script: PodcastScript) -> None:
    _write_text_atomic(
        AudiobookStore.script_path(book_id),
        script.model_dump_json(),
    )


def load_script(book_id: str) -> PodcastScript | None:
    try:
        with open(AudiobookStore.script_path(book_id), encoding="utf-8") as f:
            return PodcastScript.model_validate_json(
                f.read(), context=STORED_SCRIPT_CONTEXT
            )
    except FileNotFoundError:
        return None
    except (OSError, ValueError, ValidationError):
        log.warning(
            "podcast.script_unreadable",
            extra={"book_id": book_id, "failure_code": "podcast_script_unreadable"},
        )
        return None


def require_script(book_id: str) -> PodcastScript:
    script = load_script(book_id)
    if script is None:
        raise FileNotFoundError("podcast script is missing")
    return script


def materialize_turn_pages(book_id: str) -> int:
    script = require_script(book_id)
    written = 0
    for n, turn in enumerate(script.turns, start=1):
        for path in (
            AudiobookStore.page_raw_path(book_id, n),
            AudiobookStore.page_clean_path(book_id, n),
        ):
            if not os.path.exists(path):
                _write_text_atomic(path, turn.text)
                written += 1
    return written


def turn_plan(book_id: str) -> list[TurnPlan]:
    script = require_script(book_id)
    return [
        TurnPlan(
            speaker_id=turn.speaker_id,
            speaker=script.speaker(turn.speaker_id).name,
            voice=voice_with_fallback(script.speaker(turn.speaker_id).voice, None).id,
            pause_after_seconds=turn.pause_after_seconds,
        )
        for turn in script.turns
    ]


def speaker_labels(book_id: str) -> dict[str, dict[str, str]]:
    script = load_script(book_id)
    if script is None:
        return {}
    return {
        str(n): {
            "speaker_id": turn.speaker_id,
            "speaker": script.speaker(turn.speaker_id).name,
        }
        for n, turn in enumerate(script.turns, start=1)
    }


def create_item(script: PodcastScript, title: str) -> str:
    book_id = AudiobookStore.create_book(title)
    try:
        save_script(book_id, script)
        _write_text_atomic(
            AudiobookStore.source_file_path(book_id, "txt"),
            f"{title}\n\n{transcript_text(script)}",
        )
        materialize_turn_pages(book_id)
        AudiobookStore.write_meta(book_id, initial_meta(book_id, script, title))
    except Exception:
        AudiobookStore.delete_book(book_id)
        raise
    return book_id


def initial_meta(book_id: str, script: PodcastScript, title: str) -> dict[str, Any]:
    audio_seconds = estimated_audio_seconds(script)
    meta = AudiobookStore.initial_meta(
        book_id=book_id,
        title=title,
        page_count=len(script.turns),
        engine="kokoro",
        voice=script.speakers[0].voice,
        speed=1.0,
        estimated={
            "pages": len(script.turns),
            "words": script.word_count(),
            "audio_seconds": audio_seconds,
            "processing_seconds": audio_seconds / 3.5,
            "cost_usd": 0.0,
            "max_cost_usd": 0.0,
        },
    )
    meta.update(
        kind=PODCAST_KIND,
        file_ext="txt",
        is_image_only=False,
        speakers=speaker_summary(script),
        turn_count=len(script.turns),
        sections=[{**s, "start_time": 0.0} for s in script.sections()],
        sections_source="script",
    )
    return meta


def _read_page(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def _extracted_pages(book_id: str, page_count: int) -> list[str]:
    pages: list[str] = []
    for n in range(1, page_count + 1):
        text = _read_page(AudiobookStore.page_clean_path(book_id, n))
        if not text or text == "-":
            text = _read_page(AudiobookStore.page_raw_path(book_id, n))
        if text and text != "-":
            pages.append(text)
    return pages


def _source_pages(meta: dict[str, Any]) -> list[str]:
    ext = str(meta.get("file_ext") or "pdf")
    path = AudiobookStore.source_file_path(str(meta["book_id"]), ext)
    if ext == "pdf":
        return PDFExtractor.read_page_texts(path)
    return [TextExtractor.read_text(path)]


def book_source_text(book_id: str, max_chars: int) -> tuple[str, bool]:
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise FileNotFoundError("book not found")
    pages = _extracted_pages(book_id, int(meta.get("page_count") or 0))
    if not pages:
        pages = _source_pages(meta)
    text = "\n\n".join(page.strip() for page in pages if page.strip())
    return text[:max_chars], len(text) > max_chars
