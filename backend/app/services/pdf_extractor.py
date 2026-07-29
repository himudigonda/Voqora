"""PDFExtractor — pdfplumber wrapper for text extraction, cover render, image-only detection.

All file-system writes are atomic (tmp+rename). All operations are sync;
callers wrap in run_in_executor when invoked from async code.
"""

import io
import os

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
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
