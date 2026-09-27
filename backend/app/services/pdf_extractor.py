"""PDFExtractor — pdfium text extraction plus pdfplumber cover render and page geometry.

All file-system writes are atomic (tmp+rename). All operations are sync;
callers wrap in run_in_executor when invoked from async code.
"""

import io
import os
import re
from collections.abc import Iterable

import pdfplumber
import pypdfium2 as pdfium
from PIL import Image

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audiobook_store import AudiobookStore

log = get_logger(__name__)


class PDFExtractor:
    # Heuristic: if total extracted text across the PDF is shorter than this,
    # it's almost certainly a scanned/image-only PDF.
    _IMAGE_ONLY_CHAR_THRESHOLD = 100

    @classmethod
    def page_count(cls, pdf_path: str) -> int:
        with pdfplumber.open(pdf_path) as pdf:
            # OCR uses 200 DPI below. Reject oversized page geometry before a
            # background cover/OCR render can allocate an unbounded bitmap.
            for page in pdf.pages:
                pixels = int(page.width * 200 / 72) * int(page.height * 200 / 72)
                if pixels > settings.MAX_PDF_RASTER_PIXELS:
                    raise ValueError(
                        "This PDF has a page that is too large to render safely."
                    )
            return len(pdf.pages)

    @classmethod
    def is_image_only(cls, pdf_path: str) -> bool:
        """Return True if no extractable text. Sample first 5 pages for speed."""
        texts = cls.read_page_texts(pdf_path, indices=range(5))
        total_chars = sum(len(text) for text in texts)
        return total_chars < cls._IMAGE_ONLY_CHAR_THRESHOLD

    @classmethod
    def sample_word_count(cls, pdf_path: str) -> int:
        """Average word count across pages 1, mid, last for accurate estimation."""
        samples = cls._sample_texts(pdf_path)
        return sum(len(t.split()) for t in samples) // len(samples) if samples else 0

    @classmethod
    def sample_char_count(cls, pdf_path: str) -> int:
        """Average char count across pages 1, mid, last (for token estimation)."""
        samples = cls._sample_texts(pdf_path)
        return sum(len(t) for t in samples) // len(samples) if samples else 0

    @classmethod
    def _sample_texts(cls, pdf_path: str) -> list[str]:
        doc = pdfium.PdfDocument(pdf_path)
        try:
            n = len(doc)
        finally:
            doc.close()
        return (
            cls.read_page_texts(pdf_path, indices=sorted({0, n // 2, n - 1}))
            if n
            else []
        )

    @classmethod
    def read_page_texts(
        cls, pdf_path: str, indices: Iterable[int] | None = None
    ) -> list[str]:
        """Text of the requested pages (all by default) in content order, with
        pdfium's line-end hyphen markers resolved against their vocabulary."""
        doc = pdfium.PdfDocument(pdf_path)
        try:
            wanted = (
                range(len(doc))
                if indices is None
                else [i for i in indices if 0 <= i < len(doc)]
            )
            raw: list[str] = []
            for index in wanted:
                textpage = doc[index].get_textpage()
                try:
                    raw.append(textpage.get_text_range())
                finally:
                    textpage.close()
        finally:
            doc.close()
        return resolve_line_hyphens(
            [text.replace("\r\n", "\n").replace("\r", "\n") for text in raw]
        )

    # ---------- extraction ----------

    @classmethod
    def extract_one(cls, book_id: str, page_num: int) -> None:
        """Write page_num's raw text (1-indexed).

        On first call for a book, extracts and writes ALL pages from one
        PDF open so subsequent calls for pages 2..N find their files and
        skip I/O entirely — opening/parsing the PDF's structure once
        instead of once per page. _phase_extract calls this sequentially
        for n=1..page_count, so page 1's call always fires first and
        front-loads the rest. Mirrors TextExtractor.extract_one's
        already-established pattern for the non-PDF path.
        """
        out = AudiobookStore.page_raw_path(book_id, page_num)
        if os.path.exists(out):
            return
        pdf_path = AudiobookStore.pdf_path(book_id)
        for i, text in enumerate(cls.read_page_texts(pdf_path), start=1):
            p = AudiobookStore.page_raw_path(book_id, i)
            if not os.path.exists(p):
                cls._atomic_write(p, text)

    # ---------- cover ----------

    @classmethod
    def read_outline(cls, pdf_path: str) -> list[dict] | None:
        """Return a flat list of section dicts from the PDF outline if present.

        Each entry: {"title": str, "start_page": int}. Returns None if the PDF
        has no outline (so the caller falls back to LLM-based section detection).
        """
        try:
            import pypdfium2 as pdfium

            doc = pdfium.PdfDocument(pdf_path)
            try:
                # Walk top-level bookmarks (outline). Children are flattened.
                outline = list(doc.get_toc())
                if not outline:
                    return None
                page_count = len(doc)
                sections: list[dict] = []
                for entry in outline:
                    title = (entry.title or "").strip()
                    if not title:
                        continue
                    page_idx = entry.page_index
                    if page_idx is None or page_idx < 0 or page_idx >= page_count:
                        continue
                    sections.append({"title": title, "start_page": page_idx + 1})
                return sections or None
            finally:
                doc.close()
        except Exception:
            log.warning(
                "pdf.outline_read_failed",
                extra={"failure_code": "pdf_outline_read_failed"},
                exc_info=True,
            )
            return None

    @classmethod
    def render_cover(cls, book_id: str, max_width: int = 600) -> None:
        """Render page 1 as a JPEG to cover.jpg. Skip if exists."""
        out = AudiobookStore.cover_path(book_id)
        if os.path.exists(out):
            return
        pdf_path = AudiobookStore.pdf_path(book_id)
        with pdfplumber.open(pdf_path) as pdf:
            if len(pdf.pages) == 0:
                return
            # resolution=120 → ~1000px wide page; we resize to max_width.
            pil_img = pdf.pages[0].to_image(resolution=120).original

        if pil_img.width > max_width:
            ratio = max_width / pil_img.width
            new_h = int(pil_img.height * ratio)
            pil_img = pil_img.resize((max_width, new_h), Image.Resampling.LANCZOS)

        # Convert RGBA→RGB if needed for JPEG.
        if pil_img.mode != "RGB":
            pil_img = pil_img.convert("RGB")

        buf = io.BytesIO()
        pil_img.save(buf, format="JPEG", quality=85, optimize=True)
        cls._atomic_write_bytes(out, buf.getvalue())

    @classmethod
    def render_page_image(
        cls, pdf_path: str, page_num: int, resolution: int = 200
    ) -> bytes:
        """Render a single page (1-indexed) to JPEG bytes for Gemini OCR."""
        with pdfplumber.open(pdf_path) as pdf:
            page = pdf.pages[page_num - 1]
            pixels = int(page.width * resolution / 72) * int(
                page.height * resolution / 72
            )
            if pixels > settings.MAX_PDF_RASTER_PIXELS:
                raise ValueError("This PDF page is too large to render safely.")
            pil_img = page.to_image(resolution=resolution).original
        if pil_img.mode != "RGB":
            pil_img = pil_img.convert("RGB")
        buf = io.BytesIO()
        pil_img.save(buf, format="JPEG", quality=85)
        return buf.getvalue()

    # ---------- atomic helpers ----------

    @staticmethod
    def _atomic_write(path: str, text: str) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)

    @staticmethod
    def _atomic_write_bytes(path: str, data: bytes) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)


_SOFT_HYPHEN = "\ufffe"
_HYPHENATED = re.compile(r"(\w+)\ufffe\s*(\w+)")
_WORD = re.compile(r"\w+")


def resolve_line_hyphens(pages: list[str]) -> list[str]:
    vocabulary = {
        word.lower()
        for page in pages
        for word in _WORD.findall(page.replace(_SOFT_HYPHEN, " "))
    }

    def join(match: re.Match[str]) -> str:
        head, tail = match.group(1), match.group(2)
        merged = head + tail
        return merged if merged.lower() in vocabulary else f"{head}-{tail}"

    return [_HYPHENATED.sub(join, page).replace(_SOFT_HYPHEN, "-") for page in pages]


_NUMERIC_TOKEN = re.compile(
    r"[(\[]?[-+±×~]?\d[\d.,:%×x/]*[KMBkmb%]?[)\]]?[.,;]?|[(\[][A-Za-z0-9]{1,2}[)\]]"
)
_PAGE_NUMBER = re.compile(r"\d{1,4}")
_CITATION = re.compile(r"\[[\d,\s–-]+\]")
_REFERENCE_ENTRY = re.compile(r"\[\d{1,3}\]\s+\S")
_REFERENCES_HEADING = re.compile(
    r"(\d+(\.\d+)*\.?\s+)?(references|bibliography|works cited)", re.IGNORECASE
)
_ARXIV_STAMP = re.compile(r"arXiv:\d{4}\.\d{4,5}", re.IGNORECASE)
_NUMBERED_HEADING = re.compile(
    r"(\d+(\.\d+)*\.?|[A-Z]\.\d*|[IVX]+\.)\s+[A-Z][^.!?;]{1,80}"
)
_NAMED_HEADING = re.compile(
    r"(abstract|introduction|background|related work|conclusions?|discussion|"
    r"acknowledg(e)?ments|appendix|summary|methods?|results)",
    re.IGNORECASE,
)
_SHORT_LINE_RATIO = 0.7
_SENTENCE_TERMINAL = (".", "!", "?", ":", ";")
_CLOSERS = "\"'\u201d\u2019)]"
_MIN_TABLE_ROWS = 3
_MIN_WORD_LIST_ROWS = 6
_MAX_TABLE_HEADER_ROWS = 3


def _numeric_share(line: str) -> float:
    tokens = _CITATION.sub(" ", line).split()
    if not tokens:
        return 0.0
    return sum(1 for token in tokens if _NUMERIC_TOKEN.fullmatch(token)) / len(tokens)


def _is_table_row(line: str) -> bool:
    tokens = line.split()
    if not tokens:
        return False
    numeric = _numeric_share(line)
    if _ends_sentence(line):
        return numeric >= 0.5
    ends_in_number = len(tokens) <= 12 and bool(_NUMERIC_TOKEN.fullmatch(tokens[-1]))
    return numeric >= 0.3 or ends_in_number or len(tokens) <= 3


def _drop_runs(lines: list[str], matches, minimum: int, header_rows: int) -> list[str]:
    keep = [True] * len(lines)
    i = 0
    while i < len(lines):
        if not matches(lines[i]):
            i += 1
            continue
        end = i
        while end < len(lines) and matches(lines[end]):
            end += 1
        if end - i >= minimum:
            start = i
            numeric_rows = sum(1 for line in lines[i:end] if _numeric_share(line) > 0)
            while (
                numeric_rows * 2 >= end - i
                and start > 0
                and i - start < header_rows
                and not _ends_sentence(lines[start - 1])
                and len(lines[start - 1].split()) < 10
            ):
                start -= 1
            for j in range(start, end):
                keep[j] = False
        i = end
    return [line for line, kept in zip(lines, keep, strict=True) if kept]


def strip_layout_noise(text: str) -> str:
    lines = [line.strip() for line in text.splitlines()]
    lines = [
        line
        for line in lines
        if line and not _PAGE_NUMBER.fullmatch(line) and not _ARXIV_STAMP.search(line)
    ]
    reference_starts = [
        i for i, line in enumerate(lines) if _REFERENCE_ENTRY.match(line)
    ]
    if len(reference_starts) >= 3:
        cut = reference_starts[0]
        if cut > 0 and _REFERENCES_HEADING.fullmatch(lines[cut - 1]):
            cut -= 1
        lines = lines[:cut]
    lines = _drop_runs(lines, _is_figure_token, _MIN_WORD_LIST_ROWS, 0)
    lines = _drop_runs(lines, _is_table_row, _MIN_TABLE_ROWS, _MAX_TABLE_HEADER_ROWS)
    lines = [line for line in lines if not _is_numeric_line(line)]
    return "\n".join(_mark_structure(lines))


def _is_heading(line: str) -> bool:
    if _ends_sentence(line) or len(line.split()) > 10:
        return False
    return bool(_NUMBERED_HEADING.fullmatch(line) or _NAMED_HEADING.fullmatch(line))


def _mark_structure(lines: list[str]) -> list[str]:
    if not lines:
        return lines
    lengths = sorted(len(line) for line in lines)
    typical = lengths[int(len(lengths) * 0.8)]
    out: list[str] = []
    for line in lines:
        if _is_heading(line):
            if out and out[-1]:
                out.append("")
            out.extend([line, ""])
            continue
        out.append(line)
        if (
            line.rstrip(_CLOSERS).endswith((".", "!", "?"))
            and len(line) < typical * _SHORT_LINE_RATIO
        ):
            out.append("")
    while out and not out[-1]:
        out.pop()
    return out


def _ends_sentence(line: str) -> bool:
    return line.rstrip(_CLOSERS).endswith(_SENTENCE_TERMINAL)


def _is_figure_token(line: str) -> bool:
    if not any(character.isalnum() for character in line):
        return True
    if _NAMED_HEADING.fullmatch(line):
        return False
    return len(line.split()) <= 2 and not line.rstrip(_CLOSERS).endswith(
        (".", "!", "?", ",")
    )


def _is_numeric_line(line: str) -> bool:
    tokens = line.split()
    return len(tokens) >= 3 and _numeric_share(line) >= 0.5
