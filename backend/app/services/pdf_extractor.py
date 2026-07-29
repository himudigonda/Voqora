"""PDFExtractor — pdfplumber wrapper for text extraction, cover render, image-only detection.

All file-system writes are atomic (tmp+rename). All operations are sync;
callers wrap in run_in_executor when invoked from async code.
"""

import io
import os
import uuid

import pdfplumber
from PIL import Image

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
            return len(pdf.pages)

    @classmethod
    def is_image_only(cls, pdf_path: str) -> bool:
        """Return True if no extractable text. Sample first 5 pages for speed."""
        total_chars = 0
        with pdfplumber.open(pdf_path) as pdf:
            sample = pdf.pages[: min(5, len(pdf.pages))]
            for page in sample:
                text = page.extract_text() or ""
                total_chars += len(text)
                if total_chars >= cls._IMAGE_ONLY_CHAR_THRESHOLD:
                    return False
        return total_chars < cls._IMAGE_ONLY_CHAR_THRESHOLD

    @classmethod
    def sample_word_count(cls, pdf_path: str) -> int:
        """Average word count across pages 1, mid, last for accurate estimation."""
        with pdfplumber.open(pdf_path) as pdf:
            n = len(pdf.pages)
            if n == 0:
                return 0
            indices = sorted({0, n // 2, n - 1})
            samples: list[int] = []
            for i in indices:
                text = pdf.pages[i].extract_text() or ""
                samples.append(len(text.split()))
            return sum(samples) // len(samples)

    @classmethod
    def sample_char_count(cls, pdf_path: str) -> int:
        """Average char count across pages 1, mid, last (for token estimation)."""
        with pdfplumber.open(pdf_path) as pdf:
            n = len(pdf.pages)
            if n == 0:
                return 0
            indices = sorted({0, n // 2, n - 1})
            samples: list[int] = []
            for i in indices:
                text = pdf.pages[i].extract_text() or ""
                samples.append(len(text))
            return sum(samples) // len(samples)

    # ---------- extraction ----------

    @classmethod
    def extract_one(cls, book_id: str, page_num: int) -> None:
        """Extract a single page (1-indexed). Used by callers that emit progress."""
        pdf_path = AudiobookStore.pdf_path(book_id)
        out = AudiobookStore.page_raw_path(book_id, page_num)
        if os.path.exists(out):
            return
        with pdfplumber.open(pdf_path) as pdf:
            page = pdf.pages[page_num - 1]
            text = page.extract_text() or ""
        cls._atomic_write(out, text)

    @classmethod
    def extract_batch(cls, book_id: str, page_numbers: list[int]) -> None:
        """Extract multiple pages in a single PDF open — O(1) opens vs. O(N).

        Opens the source PDF once and writes raw text files for all specified
        pages. Skips pages whose output file already exists (safe for resume).
        Called from _phase_extract before the per-page loop so the loop can
        focus on cancel/preemption/dedup without repeated PDF open overhead.
        """
        if not page_numbers:
            return
        pdf_path = AudiobookStore.pdf_path(book_id)
        with pdfplumber.open(pdf_path) as pdf:
            for n in page_numbers:
                out = AudiobookStore.page_raw_path(book_id, n)
                if os.path.exists(out):
                    continue
                try:
                    text = pdf.pages[n - 1].extract_text() or ""
                except Exception:
                    text = ""
                cls._atomic_write(out, text)

    # ---------- cover ----------

    @classmethod
    def read_outline(cls, pdf_path: str) -> list[dict] | None:
        """Return a flat list of section dicts from the PDF outline if present.

        Each entry: {"title": str, "start_page": int, "level": int}. `level` is
        the bookmark's zero-based nesting depth (Part/Chapter/Sub-heading),
        captured so hierarchy isn't silently discarded even though the current
        caller flattens it into one contiguous section list. Returns None if
        the PDF has no outline (so the caller falls back to DOCX/MD/LLM-based
        section detection).

        NOTE: pypdfium2's `PdfBookmark` exposes title/destination via methods
        (`get_title()`, `get_dest().get_index()`), not plain attributes —
        `.title`/`.page_index` do not exist on that class and raise
        AttributeError, which a past version of this method silently mistook
        for "no outline" via the blanket except below. Confirmed against the
        installed pypdfium2 by introspecting `dir(pdfium.PdfBookmark)`.
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
                    title = (entry.get_title() or "").strip()
                    if not title:
                        continue
                    dest = entry.get_dest()
                    page_idx = dest.get_index() if dest is not None else None
                    if page_idx is None or page_idx < 0 or page_idx >= page_count:
                        continue
                    sections.append(
                        {
                            "title": title,
                            "start_page": page_idx + 1,
                            "level": entry.level,
                        }
                    )
                return sections or None
            finally:
                doc.close()
        except Exception as e:
            log.warning(
                "pdf.outline_read_failed", extra={"path": pdf_path, "error": str(e)}
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
        """D7: the tmp suffix is unique per call (not a fixed `path + ".tmp"`).

        Two independent call sites can render the same book's cover.jpg —
        api/audiobook.py's upload-time background task and
        _phase_extract's own render — both idempotency-gated by an
        `if os.path.exists(out): return` check with a TOCTOU window. A fixed
        shared tmp path let concurrent writers interleave writes into the
        same inode (or race each other's os.replace) and corrupt cover.jpg.
        With a unique tmp path per call, concurrent writers never touch the
        same file before either os.replace()s — which is itself atomic — so
        the loser's replace simply overwrites the winner's with an equally
        complete, valid image; never a half-written mix of both.
        """
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{uuid.uuid4().hex}.tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
