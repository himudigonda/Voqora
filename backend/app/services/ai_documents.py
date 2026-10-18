import os
from dataclasses import dataclass
from typing import Any

from app.core.config import settings
from app.services.ai_errors import AIToolError
from app.services.audiobook_store import AudiobookStore

MAX_BOOK_TEXT_CHARS = 4_000_000
_EMPTY_PAGE_MARKER = "-"


@dataclass(frozen=True)
class BookPage:
    page: int
    section_title: str
    text: str


@dataclass(frozen=True)
class BookText:
    book_id: str
    title: str
    pages: tuple[BookPage, ...]

    def joined(self) -> str:
        blocks: list[str] = []
        current_section = ""
        for page in self.pages:
            if page.section_title and page.section_title != current_section:
                blocks.append(page.section_title)
                current_section = page.section_title
            blocks.append(page.text)
        return "\n\n".join(blocks)


def _section_lookup(sections: Any) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    for section in sections if isinstance(sections, list) else []:
        if not isinstance(section, dict):
            continue
        try:
            start = int(section.get("start_page"))
            end = int(section.get("end_page", start))
        except (TypeError, ValueError):
            continue
        title = str(section.get("title") or "").strip()
        if title:
            spans.append((start, end, title))
    return spans


def _section_for(page: int, spans: list[tuple[int, int, str]]) -> str:
    for start, end, title in spans:
        if start <= page <= end:
            return title
    return ""


def _read_page(book_id: str, page: int) -> str:
    for path in (
        AudiobookStore.page_clean_path(book_id, page),
        AudiobookStore.page_raw_path(book_id, page),
    ):
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read(MAX_BOOK_TEXT_CHARS + 1).strip()
        except FileNotFoundError:
            continue
        return "" if text == _EMPTY_PAGE_MARKER else text
    return ""


def _require_inside_library(book_id: str) -> None:
    root = os.path.realpath(AudiobookStore.root_dir())
    book_dir = os.path.realpath(AudiobookStore.book_dir(book_id))
    if os.path.dirname(book_dir) != root:
        raise AIToolError("Book not found.", status=404, code="book_not_found")


def load_book_text(book_id: str) -> BookText:
    _require_inside_library(book_id)
    meta = AudiobookStore.read_meta(book_id)
    if meta is None:
        raise AIToolError("Book not found.", status=404, code="book_not_found")
    page_count = min(int(meta.get("page_count") or 0), settings.MAX_AUDIOBOOK_PAGES)
    spans = _section_lookup(meta.get("sections"))
    pages: list[BookPage] = []
    total = 0
    for number in range(1, page_count + 1):
        text = _read_page(book_id, number)
        if not text:
            continue
        total += len(text)
        if total > MAX_BOOK_TEXT_CHARS:
            raise AIToolError(
                "This book is too long for AI tools.",
                status=413,
                code="book_too_long",
            )
        pages.append(BookPage(number, _section_for(number, spans), text))
    if not pages:
        raise AIToolError(
            "This book's text isn't ready yet. Try again after it finishes importing.",
            status=409,
            code="book_text_unavailable",
        )
    return BookText(book_id, str(meta.get("title") or ""), tuple(pages))
