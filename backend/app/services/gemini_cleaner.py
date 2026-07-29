"""GeminiCleaner — text-cleaning and OCR via Gemini 2.5 Flash (google.genai SDK).

The user's API key is sent per-request (X-Gemini-Api-Key header from Swift).
Never persisted on disk.
"""

import asyncio
import json
import re

from google import genai
from google.genai import types

from app.core.logging import get_logger

log = get_logger(__name__)

# Pricing constants (Gemini 2.5 Flash, May 2026). Update if rates change.
# https://ai.google.dev/gemini-api/docs/pricing
INPUT_USD_PER_M_TOKENS = 0.15  # $0.15/M tokens (<=200k ctx)
OUTPUT_USD_PER_M_TOKENS = 0.60  # $0.60/M tokens (<=200k ctx)

MODEL_NAME = "gemini-2.5-flash"

GEMINI_CLEAN_SYSTEM_PROMPT = """\
You are a strict text-cleaning assistant preparing PDF page text for
text-to-speech narration. Your output will be read aloud verbatim.

ABSOLUTE RULES:
1. Preserve every meaningful word from the source. Do not summarize, paraphrase,
   shorten, or omit content.
2. Remove only: page numbers, running headers/footers that repeat across pages,
   hyphenation artifacts at line breaks (e.g., "exam-\\nple" -> "example"), and
   isolated stray characters from PDF extraction noise.
3. Reflow text into natural paragraphs. Join broken lines that belong to the
   same sentence.
4. For tables: prefix the first row with "The following is a table." and
   convert each row into a sentence describing its cells in reading order.
   End the table with "End of table.".
5. For figures/captions: keep the caption text as a sentence; replace figure
   image references with "Figure caption:".
6. For equations: read them aloud naturally (e.g., "x squared plus y squared
   equals z squared"). Preserve all variables and operators.
7. For bullet lists: convert to "First, ... Second, ..." or read in order with
   periods.
8. Output ONLY the cleaned narration text. No preamble, no commentary, no
   markdown, no JSON. Plain prose only.

If the input page is empty or contains no readable content, output the single
character "-".
"""

OCR_AND_CLEAN_PROMPT = """\
You are a combined OCR and text-cleaning assistant preparing a scanned PDF page
for text-to-speech narration. Your output will be read aloud verbatim.

STEP 1 — OCR: Extract all visible text from the provided page image exactly as
it appears. Include all words, numbers, punctuation, and sentence structure.

STEP 2 — CLEAN: Apply these rules to the extracted text:
1. Preserve every meaningful word. Do not summarize, paraphrase, or omit content.
2. Remove only: page numbers, running headers/footers, hyphenation artifacts
   (e.g., "exam-\\nple" -> "example"), and PDF extraction noise.
3. Reflow into natural paragraphs; join broken lines belonging to the same sentence.
4. Tables: prefix first row with "The following is a table." Convert each row to
   a sentence. End with "End of table.".
5. Equations: read aloud naturally (e.g., "x squared plus y squared equals z squared").
6. Bullet lists: convert to "First, ... Second, ..." with periods.

Output ONLY the cleaned narration text. No preamble, no commentary, no markdown.
If the page is blank or unreadable, output the single character "-".
"""


class GeminiAuthError(Exception):
    """Invalid API key."""


class GeminiRateLimitError(Exception):
    """Gemini returned 429 after retries exhausted."""


class GeminiBadResponseError(Exception):
    """Gemini returned an unexpected response."""


class GeminiCleaner:
    _MAX_RETRIES = 3
    _BACKOFF_BASE = 2.0  # 2s, 4s, 8s

    # ---------- retry helper (DRY for clean_page + ocr_page) ----------

    @classmethod
    async def _with_retry(cls, label: str, coro_factory):
        """Run `coro_factory()` up to _MAX_RETRIES times with exponential backoff.

        - GeminiAuthError → re-raised immediately (won't recover on retry).
        - GeminiRateLimitError / GeminiBadResponseError / generic Exception
          → sleep _BACKOFF_BASE * 2^attempt and retry.
        - All attempts exhausted → re-raise the last seen exception, or a
          GeminiBadResponseError with `label` if none was captured.

        See HARD-034 — extracted from duplicated loops in clean_page/ocr_page.
        """
        last_exc: Exception | None = None
        for attempt in range(cls._MAX_RETRIES):
            try:
                return await coro_factory()
            except GeminiAuthError:
                raise
            except (GeminiRateLimitError, GeminiBadResponseError) as e:
                last_exc = e
            except Exception as e:
                last_exc = e
            if attempt < cls._MAX_RETRIES - 1:
                await asyncio.sleep(cls._BACKOFF_BASE * (2**attempt))
        raise last_exc or GeminiBadResponseError(f"{label}: unknown error")

    # ---------- error classification ----------

    @staticmethod
    def _reraise_typed(e: Exception) -> None:
        msg = str(e).lower()
        # Model-not-found / 404 → transient bad-response, NOT an auth error.
        # Check this first so "invalid model" doesn't fall into the auth bucket.
        if any(k in msg for k in ("not found", "404", "model", "does not exist")):
            raise GeminiBadResponseError(str(e)) from e
        # True auth failures: bad key, wrong project, permission denied.
        if any(
            k in msg
            for k in (
                "api_key",
                "api key",
                "permission denied",
                "unauthorized",
                "401",
                "credentials",
                "invalid api key",
                "api key not valid",
            )
        ):
            raise GeminiAuthError(str(e)) from e
        if any(k in msg for k in ("429", "rate limit", "quota", "resource_exhausted")):
            raise GeminiRateLimitError(str(e)) from e
        raise GeminiBadResponseError(str(e)) from e

    # ---------- text cleaning ----------

    @classmethod
    async def clean_page(cls, api_key: str, raw_text: str) -> str:
        """Strict-clean a single page. Retries on transient errors."""
        if not raw_text.strip():
            return "-"
        return await cls._with_retry(
            "clean_page", lambda: cls._async_clean(api_key, raw_text)
        )

    @classmethod
    async def _async_clean(cls, api_key: str, raw_text: str) -> str:
        client = genai.Client(api_key=api_key)
        config = types.GenerateContentConfig(
            system_instruction=GEMINI_CLEAN_SYSTEM_PROMPT,
            temperature=0.1,
        )
        try:
            resp = await client.aio.models.generate_content(
                model=MODEL_NAME,
                config=config,
                contents=raw_text,
            )
        except Exception as e:
            cls._reraise_typed(e)
        text = (resp.text or "").strip()
        return text if text else "-"

    # ---------- OCR (image pages) ----------

    @classmethod
    async def ocr_page(cls, api_key: str, image_bytes: bytes) -> str:
        """OCR + clean a scanned page image via Gemini vision. Retries on transient errors."""
        return await cls._with_retry(
            "ocr_page", lambda: cls._async_ocr(api_key, image_bytes)
        )

    @classmethod
    async def _async_ocr(cls, api_key: str, image_bytes: bytes) -> str:
        client = genai.Client(api_key=api_key)
        config = types.GenerateContentConfig(temperature=0.1)
        image_part = types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg")
        try:
            resp = await client.aio.models.generate_content(
                model=MODEL_NAME,
                config=config,
                contents=[image_part, OCR_AND_CLEAN_PROMPT],
            )
        except Exception as e:
            cls._reraise_typed(e)
        text = (resp.text or "").strip()
        return text if text else "-"

    # ---------- cost / token estimation ----------

    @staticmethod
    def estimate_tokens(char_count: int) -> int:
        """Rough heuristic: ~4 chars per token for English."""
        return max(1, char_count // 4)

    @classmethod
    def estimate_cost_usd(cls, total_chars: int) -> float:
        """Strict-preserve: output ≈ input length, so use same token count for both."""
        tok = cls.estimate_tokens(total_chars)
        input_usd = (tok / 1_000_000) * INPUT_USD_PER_M_TOKENS
        output_usd = (tok / 1_000_000) * OUTPUT_USD_PER_M_TOKENS
        return input_usd + output_usd

    # ---------- section detection (Phase 2) ----------

    SECTION_PROMPT = (
        "Below are the cleaned pages of a document, one per `=== PAGE N ===` "
        "header. Identify the chapter or section boundaries.\n"
        "Output ONLY a JSON object of the form: "
        '{"sections":[{"title":"...","start_page":N,"end_page":M},...]}\n'
        "Rules:\n"
        "- Cover every page; sections must be contiguous and non-overlapping.\n"
        "- Use the headings the document itself uses (e.g., 'Chapter 3: Habits').\n"
        "- Prefer 4-20 sections per document. Combine very short subsections.\n"
        "- Do not invent content. Use only what is in the text."
    )

    _SECTION_CHUNK_CHARS = 500_000
    _SECTION_CHUNK_PAGE_OVERLAP = 5

    @classmethod
    async def detect_sections(cls, api_key: str, pages: list[str]) -> list[dict]:
        """Identify sections from a list of cleaned pages.

        `pages` is 1-indexed (pages[0] is page 1). Returns a list of
        {"title": str, "start_page": int, "end_page": int} sorted by start_page,
        contiguous and non-overlapping. Returns [] on total failure.
        """
        if not pages:
            return []

        chunks: list[tuple[int, str]] = []
        cur_pages: list[str] = []
        cur_chars = 0
        cur_start = 1
        for i, p in enumerate(pages, start=1):
            block = f"=== PAGE {i} ===\n{p}\n"
            if cur_chars + len(block) > cls._SECTION_CHUNK_CHARS and cur_pages:
                chunks.append((cur_start, "".join(cur_pages)))
                tail = cur_pages[-cls._SECTION_CHUNK_PAGE_OVERLAP :]
                cur_pages = list(tail)
                cur_start = i - len(tail)
                cur_chars = sum(len(t) for t in cur_pages)
            cur_pages.append(block)
            cur_chars += len(block)
        if cur_pages:
            chunks.append((cur_start, "".join(cur_pages)))

        all_sections: list[dict] = []
        for first_page, text in chunks:
            try:
                resp_text = await cls._async_section_call(api_key, text)
                parsed = cls._parse_sections_json(resp_text, max_page=len(pages))
                parsed = [s for s in parsed if s["start_page"] >= first_page]
                all_sections.extend(parsed)
            except Exception as e:
                log.warning(
                    "gemini.section_chunk_failed",
                    extra={"first_page": first_page, "error": str(e)},
                )
                continue

        return cls._stitch_sections(all_sections, page_count=len(pages))

    @classmethod
    async def _async_section_call(cls, api_key: str, joined_text: str) -> str:
        client = genai.Client(api_key=api_key)
        config = types.GenerateContentConfig(
            system_instruction=cls.SECTION_PROMPT,
            temperature=0.1,
            response_mime_type="application/json",
        )
        try:
            resp = await client.aio.models.generate_content(
                model=MODEL_NAME,
                config=config,
                contents=joined_text,
            )
        except Exception as e:
            cls._reraise_typed(e)
        return resp.text or ""

    @staticmethod
    def _parse_sections_json(raw: str, max_page: int) -> list[dict]:
        """Parse Gemini's JSON output into a clean list. Tolerant to markdown fences."""
        s = raw.strip()
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
        try:
            obj = json.loads(s)
        except json.JSONDecodeError:
            return []
        items = obj.get("sections") if isinstance(obj, dict) else None
        if not isinstance(items, list):
            return []
        out: list[dict] = []
        for it in items:
            if not isinstance(it, dict):
                continue
            title = (it.get("title") or "").strip()
            try:
                sp = int(it.get("start_page"))
                ep = int(it.get("end_page"))
            except (TypeError, ValueError):
                continue
            if not title or sp < 1 or ep < sp or sp > max_page:
                continue
            ep = min(ep, max_page)
            out.append({"title": title, "start_page": sp, "end_page": ep})
        return out

    @staticmethod
    def _stitch_sections(sections: list[dict], page_count: int) -> list[dict]:
        """Merge overlapping/duplicate sections from chunked results into one
        contiguous, non-overlapping list covering [1..page_count]."""
        if not sections:
            return []

        seen: set[tuple] = set()
        unique: list[dict] = []
        for s in sorted(sections, key=lambda x: (x["start_page"], x["end_page"])):
            key = (s["title"].lower().strip(), s["start_page"])
            if key in seen:
                continue
            seen.add(key)
            unique.append(s)

        cleaned: list[dict] = []
        for s in unique:
            if cleaned and s["start_page"] <= cleaned[-1]["start_page"]:
                continue
            cleaned.append(s)
        for i, s in enumerate(cleaned):
            if i + 1 < len(cleaned):
                s["end_page"] = max(s["start_page"], cleaned[i + 1]["start_page"] - 1)
            else:
                s["end_page"] = page_count

        if cleaned and cleaned[0]["start_page"] > 1:
            cleaned.insert(
                0,
                {
                    "title": "Front Matter",
                    "start_page": 1,
                    "end_page": cleaned[0]["start_page"] - 1,
                },
            )
        return cleaned

    @classmethod
    async def verify_key(cls, api_key: str) -> bool:
        """Lightweight key check: lists available models (no generation, zero tokens consumed).

        Uses the models.list API instead of a generation call so no quota is used
        and latency is minimal.

        Returns True only when the listing call succeeds. ANY failure — a genuinely
        invalid key OR a transport error (offline, DNS, timeout, transient 5xx) —
        returns False, because we can't confirm validity. The SDK raises raw
        google.genai exceptions here (not our typed GeminiAuthError, which only
        comes from _reraise_typed on the generation path), so there's nothing finer
        to branch on. Caller treats False as "not verified," not "definitely bad."
        """
        try:
            client = genai.Client(api_key=api_key)
            await client.aio.models.list(config={"page_size": 1})
            return True
        except Exception:
            return False
