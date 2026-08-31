"""TextExtractor — TXT / DOCX / Markdown → audiobook page pipeline.

Mirrors the PDFExtractor interface so audiobook_service.py can route to
either class based on meta["file_ext"] without branching everywhere.

All file-system writes are atomic (tmp+rename). All methods are sync;
callers wrap in run_in_executor when called from async code.
"""

import io
import os
import re

from PIL import Image, ImageDraw

from app.services.audiobook_store import AudiobookStore

# Target words per synthetic page. 400 words ≈ 2-3 minutes of audio.
_WORDS_PER_PAGE = 400


class TextExtractor:
    # ---------- text reading ----------

    @classmethod
    def read_text(cls, source_path: str) -> str:
        """Return the full plain-text content of a TXT, MD, or DOCX file."""
        ext = os.path.splitext(source_path)[1].lower()
        if ext == ".docx":
            return cls._read_docx_text(source_path)
        with open(source_path, encoding="utf-8", errors="replace") as f:
            return f.read()

    @classmethod
    def _read_docx_text(cls, source_path: str) -> str:
        """Read a DOCX in document order, including table content.

        `doc.paragraphs` alone omits table cell text entirely — tables live
        in the separate `doc.tables` collection, unordered relative to
        paragraphs — so a document with a table would silently lose that
        content. Walking `doc.element.body`'s raw XML children in order is
        the standard python-docx way to interleave both. Table rows are
        rendered pipe-delimited so the downstream cleaning pipeline
        (Gemini's table rule, or the local Markdown normalizer) recognizes
        them as tabular content instead of just losing the structure.
        """
        from docx import Document  # python-docx
        from docx.oxml.ns import qn
        from docx.table import Table
        from docx.text.paragraph import Paragraph

        doc = Document(source_path)
        blocks: list[str] = []
        for child in doc.element.body.iterchildren():
            if child.tag == qn("w:p"):
                text = Paragraph(child, doc).text
                if text.strip():
                    blocks.append(text)
            elif child.tag == qn("w:tbl"):
                table = Table(child, doc)
                rows = [
                    "| " + " | ".join(c.text.strip() for c in row.cells) + " |"
                    for row in table.rows
                    if any(c.text.strip() for c in row.cells)
                ]
                if rows:
                    blocks.append("\n".join(rows))
        return "\n\n".join(blocks)

    @classmethod
    def split_pages(cls, text: str) -> list[str]:
        """Split text into ~_WORDS_PER_PAGE-word pages at paragraph boundaries."""
        # Normalise line endings, then split on blank lines.
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        raw_paras = re.split(r"\n{2,}", text)
        paragraphs = [p.strip() for p in raw_paras if p.strip()]

        pages: list[str] = []
        current: list[str] = []
        current_words = 0

        for para in paragraphs:
            wc = len(para.split())
            if current_words + wc > _WORDS_PER_PAGE and current:
                pages.append("\n\n".join(current))
                current = [para]
                current_words = wc
            else:
                current.append(para)
                current_words += wc

        if current:
            pages.append("\n\n".join(current))

        return pages if pages else [""]

    # ---------- PDFExtractor-compatible interface ----------

    @classmethod
    def page_count(cls, source_path: str) -> int:
        text = cls.read_text(source_path)
        return len(cls.split_pages(text))

    @classmethod
    def is_image_only(cls, source_path: str) -> bool:
        return False

    @classmethod
    def sample_word_count(cls, source_path: str) -> int:
        text = cls.read_text(source_path)
        pages = cls.split_pages(text)
        n = len(pages)
        if n == 0:
            return 0
        indices = sorted({0, n // 2, n - 1})
        samples = [len(pages[i].split()) for i in indices]
        return sum(samples) // len(samples)

    @classmethod
    def sample_char_count(cls, source_path: str) -> int:
        text = cls.read_text(source_path)
        pages = cls.split_pages(text)
        n = len(pages)
        if n == 0:
            return 0
        indices = sorted({0, n // 2, n - 1})
        samples = [len(pages[i]) for i in indices]
        return sum(samples) // len(samples)

    @classmethod
    def extract_one(cls, book_id: str, page_num: int) -> None:
        """Write page_num (1-indexed) to pages/{n:03d}.txt.

        On first call for a book, splits and writes ALL pages at once so
        subsequent calls for pages 2..N find their files and skip I/O.
        """
        out = AudiobookStore.page_raw_path(book_id, page_num)
        if os.path.exists(out):
            return

        meta = AudiobookStore.read_meta(book_id) or {}
        file_ext = meta.get("file_ext", "txt")
        source_path = AudiobookStore.source_file_path(book_id, file_ext)

        text = cls.read_text(source_path)
        pages = cls.split_pages(text)

        for i, page_text in enumerate(pages, start=1):
            p = AudiobookStore.page_raw_path(book_id, i)
            if not os.path.exists(p):
                cls._atomic_write(p, page_text)

    @classmethod
    def read_outline(cls, source_path: str):
        """Text files have no native outline; always fall through to Gemini."""
        return

    # ---------- local (no-LLM) section detection ----------

    _HEADING_RE = re.compile(r"^ {0,3}#{1,6}\s+(.+)$", re.MULTILINE)

    @classmethod
    def detect_markdown_sections(cls, source_path: str, page_count: int) -> list[dict]:
        """Chapter detection for a Markdown source with no LLM call.

        Only meaningful for .md sources, which have real '#'..'######'
        structural headings to key off of — plain TXT/DOCX have no
        comparable local signal, so those still fall back to one section
        (the caller only calls this for file_ext == "md"). Page-granularity,
        not exact offsets: keyed off the same _WORDS_PER_PAGE split used at
        extraction time, so a heading is attributed to whichever synthetic
        page it landed on. Returns [] if no headings are found, so the
        caller falls back to its existing single-section default.
        """
        text = cls.read_text(source_path)
        pages = cls.split_pages(text)
        if not pages:
            return []

        starts: list[tuple[int, str]] = []
        for i, page_text in enumerate(pages, start=1):
            m = cls._HEADING_RE.search(page_text)
            if m:
                starts.append((i, m.group(1).strip()))
        if not starts:
            return []

        sections: list[dict] = []
        for idx, (start_page, title) in enumerate(starts):
            end_page = starts[idx + 1][0] - 1 if idx + 1 < len(starts) else page_count
            sections.append(
                {
                    "title": title,
                    "start_page": start_page,
                    "end_page": max(start_page, end_page),
                }
            )
        if sections[0]["start_page"] > 1:
            sections.insert(
                0,
                {
                    "title": "Front Matter",
                    "start_page": 1,
                    "end_page": sections[0]["start_page"] - 1,
                },
            )
        return sections

    # ---------- cover ----------

    @classmethod
    def render_cover(cls, book_id: str) -> None:
        """Generate a minimal placeholder cover JPEG. Skip if already exists."""
        out = AudiobookStore.cover_path(book_id)
        if os.path.exists(out):
            return

        meta = AudiobookStore.read_meta(book_id) or {}
        file_ext = (meta.get("file_ext") or "txt").upper()

        img = Image.new("RGB", (600, 840), color=(18, 26, 38))
        draw = ImageDraw.Draw(img)

        # Cyan accent bar
        draw.rectangle([0, 0, 600, 10], fill=(0, 210, 230))

        # File-type badge (bottom-right)
        badge_text = f".{file_ext}"
        badge_x, badge_y = 470, 760
        draw.rectangle(
            [badge_x - 10, badge_y - 6, badge_x + 100, badge_y + 26], fill=(0, 180, 200)
        )
        draw.text((badge_x, badge_y), badge_text, fill=(255, 255, 255))

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85, optimize=True)
        cls._atomic_write_bytes(out, buf.getvalue())

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
