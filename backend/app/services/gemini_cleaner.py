"""GeminiCleaner — text-cleaning and OCR via Gemini 3.8 Flash (google.genai SDK).

The user's API key is sent per-request (X-Gemini-Api-Key header from Swift).
Never persisted on disk.
"""

import asyncio
import json
import re
from dataclasses import dataclass
from typing import Any

from google import genai
from google.genai import types

from app.core.logging import get_logger

log = get_logger(__name__)

# Pricing constants (Gemini 3.8 Flash, Sept 2026). Update if rates change.
# Standard is $0.75/M input, $3.75/M output through 2026-12-31 (rises to
# $1.50 / $7.50 on 2027-01-01 — revisit these constants before then).
# Halved from standard rates since all calls below run on the Flex service
# tier (50% discount). https://ai.google.dev/gemini-api/docs/pricing
# https://ai.google.dev/gemini-api/docs/flex-inference
INPUT_USD_PER_M_TOKENS = 0.375  # $0.75/M standard, Flex = 50%
OUTPUT_USD_PER_M_TOKENS = 1.875  # $3.75/M standard, Flex = 50%
STANDARD_INPUT_USD_PER_M_TOKENS = 0.75
STANDARD_OUTPUT_USD_PER_M_TOKENS = 3.75
PRICING_VERSION = "gemini-3.8-flash-2026-09"

# Cost reservations deliberately use bounded response sizes. Besides keeping a
# malformed page from consuming an unbounded amount of a user's API budget,
# this makes the reservation a real upper bound rather than a hopeful
# character-count estimate. 8k tokens is ample for one extracted page; the
# section operation only returns compact JSON and needs considerably less.
_CLEAN_MAX_OUTPUT_TOKENS = 8_192
_SECTION_MAX_OUTPUT_TOKENS = 4_096


@dataclass(frozen=True)
class GeminiUsage:
    """Provider usage returned with a successful generation.

    The SDK has changed the concrete response model across releases, so this
    deliberately stores only the stable numeric fields Voqora needs for its
    local cost receipt. ``None`` means the provider did not return usage; the
    caller must retain its conservative reservation in that case.
    """

    input_tokens: int | None
    output_tokens: int | None
    tier: str


class GeneratedText(str):
    """A string-compatible Gemini response with optional usage attached."""

    usage: GeminiUsage | None

    def __new__(cls, value: str, usage: GeminiUsage | None = None):
        obj = super().__new__(cls, value)
        obj.usage = usage
        return obj


class GeneratedSections(list[dict]):
    """List-compatible section result carrying successful call receipts."""

    usage: tuple[GeminiUsage, ...]

    def __init__(self, values: list[dict], usage: list[GeminiUsage]):
        super().__init__(values)
        self.usage = tuple(usage)


# gemini-2.5-flash was sunset for new users (404: "no longer available to new
# users") as of Sept 2026 — migrated to gemini-3.8-flash.
MODEL_NAME = "gemini-3.8-flash"

# Flex service tier: 50% cheaper than standard, best-effort/sheddable capacity
# (minutes-scale latency, can 503 under load). We retry only within Flex; a
# Standard-tier request needs explicit per-book user approval before dispatch.
# The long client timeout is only used for Flex calls, to tolerate queuing.
# https://ai.google.dev/gemini-api/docs/flex-inference
FLEX_HTTP_OPTIONS = types.HttpOptions(timeout=900_000)  # 15 min, per Google's guidance

GEMINI_CLEAN_SYSTEM_PROMPT = """\
You are preparing document text — from a PDF, Markdown, or plain-text source —
to be narrated aloud as an audiobook, and to be read on screen as the listener
follows along. Your output serves both, so it must sound like a script and look
like one.

Your output is read aloud VERBATIM. Every character you leave in it is spoken.
A stray "#" becomes "hash", a "*" becomes "asterisk", a "|" becomes "pipe".
Leaving formatting syntax in the output is the single worst thing you can do.

CONTENT — preserve everything that carries meaning:
1. Keep every meaningful word. Never summarize, paraphrase, shorten, or omit.
2. Remove only: page numbers, running headers and footers that repeat across
   pages, hyphenation artifacts at line breaks ("exam-\nple" -> "example"), and
   isolated stray characters from PDF extraction noise.
3. Never invent a transition, heading, or sentence that is not in the source.

FORMATTING — remove the syntax, speak the content:
4. Headings ("#", "##", ...): drop the hashes. Keep the heading text as its own
   short line, with a blank line above and below it.
5. Bold and italic ("**text**", "*text*", "__text__", "_text_"): drop the
   markers, keep the words. Strikethrough ("~~text~~"): drop the markers.
6. Links ("[label](url)"): speak only "label", drop the URL. A bare URL on its
   own: drop it — a narrator does not read out a web address.
7. Inline code and fenced code blocks: drop the backticks. Read short code as
   plain words. For a long block, say "The following is a code snippet." and
   then its content.
8. Blockquotes ("> text"): drop the ">" and speak the text normally.
9. Horizontal rules ("---", "***"), YAML front matter, and HTML tags: drop
   entirely — never speak them.
10. Do not use Markdown in your OWN output either. No "**", no "#", no "-"
    bullets, no pipe tables, no backticks. Plain prose only.

STRUCTURE — this is what makes it read like a script instead of a text dump:
11. Separate every block — every paragraph, heading, list, and table — from its
    neighbours with exactly one blank line. Never put two blocks back to back on
    adjacent lines.
12. Reflow prose into natural paragraphs. Join lines broken mid-sentence by the
    source's line wrapping, so a paragraph is one continuous run with no
    internal line breaks.
13. Lists: convert to spoken sentences, ONE PER LINE, each on its own line:
        First, the first item.
        Second, the second item.
        Third, the third item.
    Do not run them together into a single paragraph — a reader following along
    needs to see them as separate items.
14. Tables: ONE ROW PER LINE. Open with "The following is a table." on its own
    line, then one line per row naming each cell by its column, then
    "End of table." on its own line:
        The following is a table.
        Tier is Starter, Price is 99 dollars.
        Tier is Pro, Price is 299 dollars.
        End of table.
15. Equations: read naturally ("x squared plus y squared equals z squared").
    Preserve every variable and operator.
16. Figures: keep the caption as a sentence, introduced by "Figure caption:".

Output ONLY the narration text. No preamble, no commentary, no explanation of
what you did.

If the input page is empty or contains no readable content, output the single
character "-".
"""

OCR_AND_CLEAN_PROMPT = """\
You are reading a scanned page image and preparing its text to be narrated
aloud as an audiobook, and to be read on screen as the listener follows along.

STEP 1 — OCR: Extract all visible text from the page image exactly as it
appears, including all words, numbers, punctuation, and sentence structure.

STEP 2 — CLEAN: Your output is read aloud VERBATIM. Every character you leave in
it is spoken — a stray "#" becomes "hash", a "*" becomes "asterisk". Apply these
rules to the text you extracted:

1. Keep every meaningful word. Never summarize, paraphrase, or omit.
2. Remove only: page numbers, running headers and footers, hyphenation
   artifacts ("exam-\nple" -> "example"), and OCR noise.
3. If the page shows Markdown or other formatting syntax, drop the syntax and
   keep the content: no "#", "**", "*", backticks, ">", "|", or "---" in your
   output. Do not use Markdown in your own output either.
4. Reflow prose into natural paragraphs — join lines the page's own wrapping
   broke mid-sentence, so a paragraph has no internal line breaks.
5. Separate every block — paragraph, heading, list, table — from its neighbours
   with exactly one blank line. Never put two back to back on adjacent lines.
6. Lists: convert to spoken sentences, ONE PER LINE:
       First, the first item.
       Second, the second item.
7. Tables: ONE ROW PER LINE, opened by "The following is a table." and closed by
   "End of table.", each on its own line, naming each cell by its column:
       The following is a table.
       Tier is Starter, Price is 99 dollars.
       End of table.
8. Equations: read naturally ("x squared plus y squared equals z squared").

Output ONLY the narration text. No preamble, no commentary.
If the page is blank or unreadable, output the single character "-".
"""


class GeminiAuthError(Exception):
    """Invalid API key."""


class GeminiRateLimitError(Exception):
    """Gemini returned 429 after retries exhausted."""


class GeminiBadResponseError(Exception):
    """Gemini returned an unexpected response."""


class GeminiCapacityError(Exception):
    """Flex tier at capacity (503/UNAVAILABLE) — recoverable by falling back to Standard."""


class GeminiCleaner:
    # Expose the recorded pricing receipt through the service API so job
    # metadata remains self-describing without duplicating a magic string.
    PRICING_VERSION = PRICING_VERSION
    _MAX_RETRIES = 4
    _BACKOFF_BASE = 2.0  # 2s, 4s, 8s, 16s
    # ---------- retry helper (DRY for clean_page + ocr_page) ----------

    @classmethod
    async def _with_retry(
        cls,
        label: str,
        coro_factory,
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ):
        """Run `coro_factory(tier)` up to _MAX_RETRIES times with exponential backoff.

        Starts on `start_tier` (Flex by default) and never changes tier. A
        Standard request has a different cost envelope and is only created by
        an explicit, separately-approved job transition.

        - GeminiAuthError → re-raised immediately (won't recover on retry).
        - GeminiCapacityError / GeminiRateLimitError / GeminiBadResponseError /
          generic Exception → sleep _BACKOFF_BASE * 2^attempt and retry.
        - All attempts exhausted → re-raise the last seen exception, or a
          GeminiBadResponseError with `label` if none was captured.

        See HARD-034 — extracted from duplicated loops in clean_page/ocr_page.
        """
        last_exc: Exception | None = None
        tier = start_tier
        for attempt in range(cls._MAX_RETRIES):
            try:
                return await coro_factory(tier)
            except GeminiAuthError:
                raise
            except GeminiCapacityError as e:
                last_exc = e
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
        code = getattr(e, "code", None)
        # Flex capacity/sheddable failures (503/UNAVAILABLE) — checked first
        # since they're an unambiguous, specific signal (unlike the broad
        # "model" keyword below). The job owner can safely present an
        # explicit Standard-tier approval after retries are exhausted.
        if code == 503 or any(
            k in msg for k in ("503", "unavailable", "overloaded", "capacity")
        ):
            raise GeminiCapacityError(
                "Gemini capacity is temporarily unavailable."
            ) from e
        # Ordered most-specific-first. "model" (checked last, below) is far too
        # broad to lead with: Gemini's quota and permission-denied bodies
        # routinely name the model -- quota dimensions embed
        # {"model": "gemini-3.8-flash"}, and access errors read "... for model
        # X". With the broad check first, a genuine bad key was classified
        # GeminiBadResponseError, so _with_retry burned all four attempts
        # instead of failing fast, the caller never saw GeminiAuthError, and
        # the user was never told to fix their key -- the book just degraded
        # to locally-cleaned narration on every page.
        #
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
            raise GeminiAuthError("Gemini rejected the configured credential.") from e
        if any(k in msg for k in ("429", "rate limit", "quota", "resource_exhausted")):
            raise GeminiRateLimitError("Gemini rate limit reached.") from e
        # Model-not-found / 404 → transient bad-response, NOT an auth error.
        if any(k in msg for k in ("not found", "404", "model", "does not exist")):
            raise GeminiBadResponseError(
                "Gemini returned an unsupported response."
            ) from e
        raise GeminiBadResponseError("Gemini request failed.") from e

    # ---------- text cleaning ----------

    @classmethod
    async def clean_page(
        cls,
        api_key: str,
        raw_text: str,
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        """Strict-clean a single page. Retries on transient errors."""
        if not raw_text.strip():
            return "-"
        return await cls._with_retry(
            "clean_page",
            lambda tier: cls._async_clean(api_key, raw_text, tier),
            start_tier=start_tier,
        )

    @classmethod
    async def _async_clean(
        cls,
        api_key: str,
        raw_text: str,
        tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        http_options = FLEX_HTTP_OPTIONS if tier == types.ServiceTier.FLEX else None
        client = genai.Client(api_key=api_key, http_options=http_options)
        config = types.GenerateContentConfig(
            system_instruction=GEMINI_CLEAN_SYSTEM_PROMPT,
            temperature=0.1,
            max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
            service_tier=tier,
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
        return GeneratedText(
            text if text else "-", cls._usage_from_response(resp, tier)
        )

    # ---------- OCR (image pages) ----------

    @classmethod
    async def ocr_page(
        cls,
        api_key: str,
        image_bytes: bytes,
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        """OCR + clean a scanned page image via Gemini vision. Retries on transient errors."""
        return await cls._with_retry(
            "ocr_page",
            lambda tier: cls._async_ocr(api_key, image_bytes, tier),
            start_tier=start_tier,
        )

    @classmethod
    async def _async_ocr(
        cls,
        api_key: str,
        image_bytes: bytes,
        tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        http_options = FLEX_HTTP_OPTIONS if tier == types.ServiceTier.FLEX else None
        client = genai.Client(api_key=api_key, http_options=http_options)
        # Passed as system_instruction, mirroring _async_clean. It used to ride
        # along as an ordinary content part next to the image, which weights it
        # like user input rather than an instruction.
        config = types.GenerateContentConfig(
            system_instruction=OCR_AND_CLEAN_PROMPT,
            temperature=0.1,
            max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
            service_tier=tier,
        )
        image_part = types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg")
        try:
            resp = await client.aio.models.generate_content(
                model=MODEL_NAME,
                config=config,
                contents=[image_part],
            )
        except Exception as e:
            cls._reraise_typed(e)
        text = (resp.text or "").strip()
        return GeneratedText(
            text if text else "-", cls._usage_from_response(resp, tier)
        )

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

    @classmethod
    def estimate_max_cost_usd(cls, total_chars: int) -> float:
        """Conservative Standard-tier envelope for preflight disclosure."""
        input_tokens = cls.estimate_tokens(total_chars)
        output_tokens = max(input_tokens * 2, 1)
        return (input_tokens / 1_000_000) * STANDARD_INPUT_USD_PER_M_TOKENS + (
            output_tokens / 1_000_000
        ) * STANDARD_OUTPUT_USD_PER_M_TOKENS

    @staticmethod
    def _tier_name(tier: "types.ServiceTier") -> str:
        return "standard" if tier == types.ServiceTier.STANDARD else "flex"

    @classmethod
    def cost_for_tokens(
        cls, input_tokens: int, output_tokens: int, *, tier: str
    ) -> float:
        """Calculate a price using the versioned rate receipt above."""
        if tier == "standard":
            input_rate = STANDARD_INPUT_USD_PER_M_TOKENS
            output_rate = STANDARD_OUTPUT_USD_PER_M_TOKENS
        else:
            input_rate = INPUT_USD_PER_M_TOKENS
            output_rate = OUTPUT_USD_PER_M_TOKENS
        return (max(0, input_tokens) / 1_000_000) * input_rate + (
            max(0, output_tokens) / 1_000_000
        ) * output_rate

    @classmethod
    def reserve_cost_usd(
        cls,
        input_chars: int,
        *,
        tier: str,
        max_output_tokens: int,
        prompt_tokens: int = 0,
        extra_input_tokens: int = 0,
    ) -> float:
        """Conservative, bounded envelope used *before* dispatching a call."""
        return cls.cost_for_tokens(
            cls.estimate_tokens(input_chars) + prompt_tokens + extra_input_tokens,
            max_output_tokens,
            tier=tier,
        )

    @classmethod
    def clean_reservation_cost_usd(
        cls, input_chars: int, *, tier: str, image_input: bool = False
    ) -> float:
        # The largest accepted raster is 16 MP. Reserve 16k input tokens for
        # vision pages; it is intentionally above normal image-token use so a
        # page can never be dispatched on an optimistic OCR estimate.
        return cls.reserve_cost_usd(
            input_chars,
            tier=tier,
            max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
            prompt_tokens=2_000,
            extra_input_tokens=16_384 if image_input else 0,
        )

    @classmethod
    def section_reservation_cost_usd(
        cls, input_chars: int, chunk_count: int, *, tier: str
    ) -> float:
        # Every chunk includes the instruction and has its own bounded JSON
        # response. Overlap is already present in input_chars supplied by the
        # caller, which builds the same chunks as detect_sections.
        return cls.reserve_cost_usd(
            input_chars,
            tier=tier,
            max_output_tokens=_SECTION_MAX_OUTPUT_TOKENS * max(1, chunk_count),
            prompt_tokens=700 * max(1, chunk_count),
        )

    @classmethod
    def _usage_from_response(
        cls, response: Any, tier: "types.ServiceTier"
    ) -> GeminiUsage | None:
        """Extract a small, SDK-version-tolerant provider usage receipt."""
        usage = getattr(response, "usage_metadata", None)
        if usage is None:
            return None

        def integer(name: str) -> int | None:
            value = getattr(usage, name, None)
            return value if isinstance(value, int) and value >= 0 else None

        input_tokens = integer("prompt_token_count")
        candidate_tokens = integer("candidates_token_count")
        thought_tokens = integer("thoughts_token_count")
        total_tokens = integer("total_token_count")
        output_tokens = None
        if candidate_tokens is not None or thought_tokens is not None:
            output_tokens = (candidate_tokens or 0) + (thought_tokens or 0)
        elif total_tokens is not None and input_tokens is not None:
            output_tokens = max(0, total_tokens - input_tokens)
        if input_tokens is None or output_tokens is None:
            return None
        return GeminiUsage(input_tokens, output_tokens, cls._tier_name(tier))

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
    def _section_chunks(cls, pages: list[str]) -> list[tuple[int, str]]:
        """Build the exact bounded requests used by section detection."""
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
        return chunks

    @classmethod
    def section_reservation_envelope(cls, pages: list[str]) -> tuple[int, int]:
        """Return actual chunked input size/count before any request is sent."""
        chunks = cls._section_chunks(pages)
        return sum(len(text) for _, text in chunks), len(chunks)

    @classmethod
    async def detect_sections(
        cls,
        api_key: str,
        pages: list[str],
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> list[dict]:
        """Identify sections from a list of cleaned pages.

        `pages` is 1-indexed (pages[0] is page 1). Returns a list of
        {"title": str, "start_page": int, "end_page": int} sorted by start_page,
        contiguous and non-overlapping. Returns [] on total failure.
        """
        if not pages:
            return []

        chunks = cls._section_chunks(pages)

        all_sections: list[dict] = []
        receipts: list[GeminiUsage] = []
        for first_page, text in chunks:
            try:
                resp_text = await cls._with_retry(
                    "detect_sections",
                    lambda tier, text=text: cls._async_section_call(
                        api_key, text, tier
                    ),
                    start_tier=start_tier,
                )
                receipt = getattr(resp_text, "usage", None)
                if receipt is not None:
                    receipts.append(receipt)
                parsed = cls._parse_sections_json(resp_text, max_page=len(pages))
                parsed = [s for s in parsed if s["start_page"] >= first_page]
                all_sections.extend(parsed)
            except GeminiCapacityError:
                # A capacity transition is a product decision with a different
                # price tier; never convert it into an invisible fallback.
                raise
            except Exception:
                log.warning(
                    "gemini.section_chunk_failed",
                    extra={
                        "first_page": first_page,
                        "failure_code": "section_chunk_failed",
                    },
                    exc_info=True,
                )
                continue

        return GeneratedSections(
            cls._stitch_sections(all_sections, page_count=len(pages)), receipts
        )

    @classmethod
    async def _async_section_call(
        cls,
        api_key: str,
        joined_text: str,
        tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        http_options = FLEX_HTTP_OPTIONS if tier == types.ServiceTier.FLEX else None
        client = genai.Client(api_key=api_key, http_options=http_options)
        config = types.GenerateContentConfig(
            system_instruction=cls.SECTION_PROMPT,
            temperature=0.1,
            response_mime_type="application/json",
            max_output_tokens=_SECTION_MAX_OUTPUT_TOKENS,
            service_tier=tier,
        )
        try:
            resp = await client.aio.models.generate_content(
                model=MODEL_NAME,
                config=config,
                contents=joined_text,
            )
        except Exception as e:
            cls._reraise_typed(e)
        return GeneratedText(resp.text or "", cls._usage_from_response(resp, tier))

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

    # Standard-tier calls get no HttpOptions (see _async_clean: http_options
    # is only set for Flex), which the genai SDK treats as an *unbounded*
    # httpx timeout, not a sane default — a request can hang forever on a
    # dropped-packet/offline network instead of failing fast. Every other
    # Standard-tier caller (clean_page/ocr_page/detect_sections during a
    # cost-approved run) is already bounded by an outer asyncio.wait_for in
    # AudiobookService; this endpoint had no such wrapper, so a user checking
    # their API key with no network could hang the request indefinitely.
    _VERIFY_KEY_TIMEOUT_S = 20.0

    @classmethod
    async def verify_key(cls, api_key: str) -> bool:
        """Lightweight key check: tiny generation. Returns True if key works.

        Forced onto the Standard tier rather than Flex — key verification is
        a user-facing, latency-sensitive check and must not be subject to
        Flex's minutes-scale best-effort queuing. Bounded by an explicit
        overall timeout (see `_VERIFY_KEY_TIMEOUT_S`) so a network outage
        fails fast instead of hanging the request forever.
        """
        try:
            await asyncio.wait_for(
                cls._with_retry(
                    "verify_key",
                    lambda tier: cls._async_clean(api_key, "Say 'ok'.", tier),
                    start_tier=types.ServiceTier.STANDARD,
                ),
                timeout=cls._VERIFY_KEY_TIMEOUT_S,
            )
            return True
        except GeminiAuthError:
            return False
        except Exception:
            return False
