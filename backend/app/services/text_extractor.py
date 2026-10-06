"""TextExtractor — TXT / DOCX / Markdown → audiobook page pipeline.

Mirrors the PDFExtractor interface so audiobook_service.py can route to
either class based on meta["file_ext"] without branching everywhere.

All file-system writes are atomic (tmp+rename). All methods are sync;
callers wrap in run_in_executor when called from async code.
"""

import io
import os
import re

from PIL import Image, ImageDraw, ImageFont

from app.services.audiobook_store import AudiobookStore
from app.services.text_normalizer import strip_markdown_for_narration

# Target words per synthetic page. 400 words ≈ 2-3 minutes of audio.
_WORDS_PER_PAGE = 400


class TextExtractor:
    # ---------- text reading ----------

    # Validation is extension-only elsewhere (upload accepts any .txt/.md by
    # name, no content sniffing) — a binary file renamed to .txt decoded
    # silently under errors="replace" and sailed through every downstream
    # check (page_count > 0, etc.) straight into a "successfully completed"
    # audiobook narrating replacement-character noise. A real UTF-8 text
    # file essentially never contains U+FFFD; a binary file force-decoded
    # this way is overwhelmingly replacement characters. This threshold
    # catches that case without false-positiving on a real document that
    # happens to contain a handful of genuinely unencodable characters.
    _MAX_REPLACEMENT_CHAR_RATIO = 0.05

    @classmethod
    def read_text(cls, source_path: str) -> str:
        """Return the full plain-text content of a TXT, MD, or DOCX file."""
        ext = os.path.splitext(source_path)[1].lower()
        if ext == ".docx":
            return cls._read_docx_text(source_path)
        with open(source_path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        if text:
            replacement_ratio = text.count("�") / len(text)
            if replacement_ratio > cls._MAX_REPLACEMENT_CHAR_RATIO:
                raise ValueError(
                    "This file doesn't look like readable text — it may be a "
                    "binary or corrupted file with a .txt/.md extension."
                )
        return text

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

    # A fenced code block may legitimately contain blank lines, which the
    # paragraph splitter would otherwise treat as block boundaries -- cutting
    # the fence in half across two pages. Each page is then cleaned
    # independently with no fence state carried between them, so page one's
    # unterminated fence swallowed the rest of that page and page two's
    # orphaned closing fence was misread as a new *opening* fence that
    # swallowed all the prose after it. Both losses were silent: no error, no
    # log, no failed_pages entry.
    _FENCE_RE = re.compile(r"^ {0,3}(?:```|~~~)")

    @classmethod
    def _split_blocks(cls, text: str) -> list[str]:
        """Split on blank lines, but never inside a fenced code block."""
        lines = text.split("\n")
        blocks: list[str] = []
        current: list[str] = []
        in_fence = False
        fence_at = -1
        for i, line in enumerate(lines):
            if cls._FENCE_RE.match(line):
                in_fence = not in_fence
                fence_at = i
                current.append(line)
                continue
            if not line.strip() and not in_fence:
                if current:
                    blocks.append("\n".join(current))
                    current = []
                continue
            current.append(line)
        if in_fence:
            return cls._split_blocks(
                "\n".join(lines[:fence_at] + lines[fence_at + 1 :])
            )
        if current:
            blocks.append("\n".join(current))
        return blocks

    _SENTENCE_END_RE = re.compile(r"(?<=[.!?])\s+")

    @classmethod
    def _chunk_oversized(cls, para: str) -> list[str]:
        """Break a paragraph longer than a page at line, then sentence, then
        word boundaries so no single page outgrows _WORDS_PER_PAGE."""
        units: list[str] = []
        for line in para.split("\n"):
            if len(line.split()) <= _WORDS_PER_PAGE:
                units.append(line)
                continue
            for sentence in cls._SENTENCE_END_RE.split(line):
                words = sentence.split()
                for start in range(0, len(words), _WORDS_PER_PAGE):
                    units.append(" ".join(words[start : start + _WORDS_PER_PAGE]))

        chunks: list[str] = []
        current: list[str] = []
        current_words = 0
        for unit in units:
            wc = len(unit.split())
            if current_words + wc > _WORDS_PER_PAGE and current:
                chunks.append("\n".join(current))
                current, current_words = [], 0
            current.append(unit)
            current_words += wc
        if current:
            chunks.append("\n".join(current))
        return chunks

    @classmethod
    def split_pages(cls, text: str) -> list[str]:
        """Split text into ~_WORDS_PER_PAGE-word pages at paragraph boundaries."""
        # Normalise line endings, then split on blank lines (fence-aware).
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        raw_paras = cls._split_blocks(text)
        paragraphs: list[str] = []
        for para in (p.strip() for p in raw_paras):
            if not para:
                continue
            if len(para.split()) > _WORDS_PER_PAGE and not cls._FENCE_RE.match(para):
                paragraphs.extend(c for c in cls._chunk_oversized(para) if c.strip())
            else:
                paragraphs.append(para)

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
                # The captured heading is raw Markdown -- "# **Chapter _One_**"
                # yielded a section title of literally "**Chapter _One_**" in
                # the Sections tab. Titles are displayed text, so they get the
                # same treatment as narrated text.
                title = strip_markdown_for_narration(m.group(1)).strip()
                if title:
                    starts.append((i, title))
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
        """Render the first page as a cover, matching how PDF covers look. Skip if already exists."""
        out = AudiobookStore.cover_path(book_id)
        if os.path.exists(out):
            return

        meta = AudiobookStore.read_meta(book_id) or {}
        ext = (meta.get("file_ext") or "txt").lstrip(".")
        title = (meta.get("title") or "").strip()
        if title.lower().endswith(f".{ext.lower()}"):
            title = title[: -len(ext) - 1]
        title = title or "Untitled"
        source_path = AudiobookStore.source_file_path(book_id, ext)
        try:
            body = strip_markdown_for_narration(cls.read_text(source_path)[:4000])
        except Exception:
            body = ""

        width, height, margin = 600, 840, 56
        img = Image.new("RGB", (width, height), color=(250, 248, 244))
        draw = ImageDraw.Draw(img)
        title_font = cls._cover_font(40)
        body_font = cls._cover_font(18)
        label_font = cls._cover_font(15)

        y = margin + 8
        for line in cls._wrap(draw, title, title_font, width - 2 * margin)[:4]:
            draw.text((margin, y), line, font=title_font, fill=(28, 24, 22))
            y += 50
        y += 14
        draw.rectangle([margin, y, margin + 64, y + 4], fill=(204, 120, 92))
        y += 32

        for paragraph in body.split("\n"):
            paragraph = paragraph.strip()
            if not paragraph or paragraph == title:
                continue
            for line in cls._wrap(draw, paragraph, body_font, width - 2 * margin):
                if y > height - margin - 60:
                    break
                draw.text((margin, y), line, font=body_font, fill=(110, 104, 98))
                y += 27
            y += 12
            if y > height - margin - 60:
                break

        label = f".{ext.upper()}"
        label_width = draw.textlength(label, font=label_font)
        draw.text(
            (width - margin - label_width, height - margin - 10),
            label,
            font=label_font,
            fill=(160, 152, 144),
        )

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=88, optimize=True)
        cls._atomic_write_bytes(out, buf.getvalue())

    @staticmethod
    def _cover_font(size: int) -> ImageFont.ImageFont | ImageFont.FreeTypeFont:
        try:
            return ImageFont.load_default(size=size)
        except Exception:
            return ImageFont.load_default()

    @staticmethod
    def _wrap(draw: ImageDraw.ImageDraw, text: str, font, max_width: int) -> list[str]:
        lines: list[str] = []
        current = ""
        for word in text.split():
            candidate = f"{current} {word}".strip()
            if current and draw.textlength(candidate, font=font) > max_width:
                lines.append(current)
                current = word
            else:
                current = candidate
        if current:
            lines.append(current)
        return lines

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
