import asyncio
import json
import re
from dataclasses import dataclass
from typing import Any

import httpx
from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from app.core.logging import get_logger
from app.services import llm_providers
from app.services.llm_providers import (
    PROVIDERS,
    LLMAuthError,
    LLMBadResponseError,
    LLMBillingError,
    LLMCapacityError,
    LLMCredential,
    LLMError,
    LLMIncompleteError,
    LLMModelListUnavailableError,
    LLMModelNotFoundError,
    LLMRateLimitError,
    LLMRequestRejectedError,
    log_failure,
    model_is_listed,
    short_text,
)

log = get_logger(__name__)

# Gemini 3.8 Flash Standard is $0.75/$3.75 per M tokens through 2026-12-31 (then $1.50/$7.50); Flex is 50% of Standard.
INPUT_USD_PER_M_TOKENS = 0.375
OUTPUT_USD_PER_M_TOKENS = 1.875
STANDARD_INPUT_USD_PER_M_TOKENS = 0.75
STANDARD_OUTPUT_USD_PER_M_TOKENS = 3.75
PRICING_VERSION = "llm-providers-2026-10"

_CLEAN_MAX_OUTPUT_TOKENS = 8_192
_SECTION_MAX_OUTPUT_TOKENS = 4_096


@dataclass(frozen=True)
class LLMUsage:
    input_tokens: int | None
    output_tokens: int | None
    tier: str
    provider: str = "google"
    model: str = ""


@dataclass(frozen=True)
class VerifyResult:
    ok: bool
    models: list[str]
    error: str | None = None


class GeneratedText(str):
    usage: LLMUsage | None

    def __new__(cls, value: str, usage: LLMUsage | None = None):
        obj = super().__new__(cls, value)
        obj.usage = usage
        return obj


class GeneratedSections(list[dict]):
    usage: tuple[LLMUsage, ...]

    def __init__(self, values: list[dict], usage: list[LLMUsage]):
        super().__init__(values)
        self.usage = tuple(usage)


MODEL_NAME = "gemini-3.8-flash"

FLEX_HTTP_OPTIONS = types.HttpOptions(timeout=900_000)
STANDARD_HTTP_OPTIONS = types.HttpOptions(timeout=180_000)

CLEAN_SYSTEM_PROMPT = """\
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


class LLMCleaner:
    PRICING_VERSION = PRICING_VERSION
    _MAX_RETRIES = 4
    _BACKOFF_BASE = 2.0

    @classmethod
    async def _with_retry(
        cls,
        label: str,
        coro_factory,
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ):
        last_exc: Exception | None = None
        tier = start_tier
        for attempt in range(cls._MAX_RETRIES):
            try:
                return await coro_factory(tier)
            except LLMError as e:
                if not e.retryable:
                    raise
                last_exc = e
            except Exception as e:
                last_exc = e
            if attempt < cls._MAX_RETRIES - 1:
                await asyncio.sleep(cls._BACKOFF_BASE * (2**attempt))
        raise last_exc or LLMBadResponseError(f"{label}: unknown error")

    @staticmethod
    def _reraise_typed(e: Exception, credential: LLMCredential | None = None) -> None:
        credential = credential or LLMCredential.gemini("")
        typed = LLMCleaner._classify_gemini_error(e, credential)
        log_failure("llm.provider_call_failed", credential, typed)
        raise typed from e

    @staticmethod
    def _classify_gemini_error(e: Exception, credential: LLMCredential) -> LLMError:
        if isinstance(e, genai_errors.APIError):
            return LLMCleaner._classify_gemini_api_error(e, credential)
        name = credential.name
        if isinstance(e, (TimeoutError, httpx.TimeoutException)):
            return LLMRateLimitError(f"{name} didn't answer in time. Try again.")
        if isinstance(e, httpx.HTTPError):
            return LLMRateLimitError(f"Voqora could not reach {name}.")
        msg = str(e).lower()
        if getattr(e, "code", None) == 503 or any(
            k in msg for k in ("503", "unavailable", "overloaded", "capacity")
        ):
            return LLMCapacityError("Gemini capacity is temporarily unavailable.")
        if any(
            k in msg
            for k in (
                "api_key",
                "api key",
                "permission denied",
                "unauthorized",
                "401",
                "credentials",
            )
        ):
            return LLMAuthError("Gemini rejected the configured credential.")
        if any(k in msg for k in ("429", "rate limit", "quota", "resource_exhausted")):
            return LLMRateLimitError("Gemini rate limit reached.")
        if any(k in msg for k in ("not found", "404", "does not exist")):
            return LLMBadResponseError("Gemini returned an unsupported response.")
        return LLMBadResponseError("Gemini request failed.")

    @staticmethod
    def _classify_gemini_api_error(
        e: genai_errors.APIError, credential: LLMCredential
    ) -> LLMError:
        name, model = credential.name, credential.resolved_model
        code = e.code if isinstance(e.code, int) else None
        status = str(e.status or "").upper()
        message = str(e.message or "")
        blob = f"{message} {getattr(e, 'details', '')}".lower()
        detail = short_text(message, 160, credential.api_key)
        facts = {"status": code, "detail": message or status}
        suffix = f" ({detail})" if detail else ""
        if code == 401 or "api_key_invalid" in blob or "api key not valid" in blob:
            return LLMAuthError(
                f"{name} rejected the API key. Update it in Settings.{suffix}", **facts
            )
        if code == 403 or status == "PERMISSION_DENIED":
            return LLMAuthError(
                f"{name} denied this key access to {model}."
                f" Check the key's permissions or choose another model.{suffix}",
                **facts,
            )
        if code == 404 or status == "NOT_FOUND":
            return LLMModelNotFoundError(
                f"{name} has no model named {model} for this key.", **facts
            )
        if code == 429 or status == "RESOURCE_EXHAUSTED":
            return LLMCleaner._classify_gemini_quota(credential, blob, facts)
        if code == 503 or status == "UNAVAILABLE":
            return LLMCapacityError(
                f"{name} is busy right now. Try again shortly.", **facts
            )
        if code == 408 or status == "DEADLINE_EXCEEDED":
            return LLMRateLimitError(
                f"{name} didn't answer in time. Try again.", **facts
            )
        if code is not None and code >= 500:
            return LLMRateLimitError(
                f"{name} had a server problem ({code}). Try again shortly.", **facts
            )
        if code is not None and 400 <= code < 500:
            return LLMRequestRejectedError(
                (
                    f"{name} rejected the request: {detail}"
                    if detail
                    else f"{name} rejected the request ({code})."
                ),
                **facts,
            )
        return LLMBadResponseError(f"{name} request failed.{suffix}", **facts)

    @staticmethod
    def _classify_gemini_quota(
        credential: LLMCredential, blob: str, facts: dict[str, Any]
    ) -> LLMError:
        name, model = credential.name, credential.resolved_model
        compact = blob.replace(" ", "").replace("_", "")
        if re.search(r"limit\W{1,4}0\b", blob):
            return LLMBillingError(
                f"{name}'s free tier has no quota for {model}."
                " Enable billing for this key or choose another model.",
                **facts,
            )
        if "perday" in compact or any(
            marker in compact
            for marker in (
                "enablebilling",
                "billingisnot",
                "billingdisabled",
                "billingaccount",
            )
        ):
            return LLMBillingError(
                f"{name}'s quota for {model} is used up or not enabled for this key.",
                **facts,
            )
        return LLMRateLimitError(
            f"{name} is rate limiting this key. Try again in a moment.", **facts
        )

    @classmethod
    async def clean_page(
        cls,
        credential: LLMCredential,
        raw_text: str,
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        if not raw_text.strip():
            return "-"
        return await cls._with_retry(
            "clean_page",
            lambda tier: cls._async_clean(credential, raw_text, tier),
            start_tier=start_tier,
        )

    @classmethod
    async def _async_clean(
        cls,
        credential: LLMCredential,
        raw_text: str,
        tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        if not credential.is_gemini:
            return await cls._async_complete(
                credential,
                CLEAN_SYSTEM_PROMPT,
                text=raw_text,
                max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
                empty="-",
            )
        http_options = (
            FLEX_HTTP_OPTIONS
            if tier == types.ServiceTier.FLEX
            else STANDARD_HTTP_OPTIONS
        )
        client = genai.Client(api_key=credential.api_key, http_options=http_options)
        config = types.GenerateContentConfig(
            system_instruction=CLEAN_SYSTEM_PROMPT,
            temperature=0.1,
            max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
            service_tier=tier,
        )
        try:
            resp = await client.aio.models.generate_content(
                model=credential.resolved_model,
                config=config,
                contents=raw_text,
            )
        except Exception as e:
            cls._reraise_typed(e, credential)
        cls._require_complete(resp)
        text = (resp.text or "").strip()
        return GeneratedText(
            text if text else "-", cls._usage_from_response(resp, tier, credential)
        )

    @staticmethod
    def _require_complete(resp: Any) -> None:
        candidates = getattr(resp, "candidates", None) or []
        reason = getattr(candidates[0], "finish_reason", None) if candidates else None
        if reason is not None and reason != types.FinishReason.STOP:
            raise LLMIncompleteError(
                f"Gemini stopped early: {getattr(reason, 'name', reason)}"
            )

    @classmethod
    async def ocr_page(
        cls,
        credential: LLMCredential,
        image_bytes: bytes,
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        return await cls._with_retry(
            "ocr_page",
            lambda tier: cls._async_ocr(credential, image_bytes, tier),
            start_tier=start_tier,
        )

    @classmethod
    async def _async_ocr(
        cls,
        credential: LLMCredential,
        image_bytes: bytes,
        tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        if not credential.is_gemini:
            return await cls._async_complete(
                credential,
                OCR_AND_CLEAN_PROMPT,
                image_jpeg=image_bytes,
                max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
                empty="-",
            )
        http_options = (
            FLEX_HTTP_OPTIONS
            if tier == types.ServiceTier.FLEX
            else STANDARD_HTTP_OPTIONS
        )
        client = genai.Client(api_key=credential.api_key, http_options=http_options)
        config = types.GenerateContentConfig(
            system_instruction=OCR_AND_CLEAN_PROMPT,
            temperature=0.1,
            max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
            service_tier=tier,
        )
        image_part = types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg")
        try:
            resp = await client.aio.models.generate_content(
                model=credential.resolved_model,
                config=config,
                contents=[image_part],
            )
        except Exception as e:
            cls._reraise_typed(e, credential)
        cls._require_complete(resp)
        text = (resp.text or "").strip()
        return GeneratedText(
            text if text else "-", cls._usage_from_response(resp, tier, credential)
        )

    @staticmethod
    def estimate_tokens(char_count: int) -> int:
        return max(1, char_count // 4)

    @staticmethod
    def price_for(
        provider: str = "google", model: str = "", *, tier: str = "flex"
    ) -> llm_providers.ModelPrice:
        if provider == "google":
            if model not in ("", MODEL_NAME):
                return llm_providers.UNLISTED_MODEL_PRICE
            if tier == "standard":
                return llm_providers.ModelPrice(
                    STANDARD_INPUT_USD_PER_M_TOKENS, STANDARD_OUTPUT_USD_PER_M_TOKENS
                )
            return llm_providers.ModelPrice(
                INPUT_USD_PER_M_TOKENS, OUTPUT_USD_PER_M_TOKENS
            )
        return PROVIDERS[provider].price(model)

    @classmethod
    def _credential_price(
        cls, credential: LLMCredential | None, tier: str
    ) -> llm_providers.ModelPrice:
        if credential is None:
            return cls.price_for(tier=tier)
        if credential.is_gemini:
            return cls.price_for("google", credential.resolved_model, tier=tier)
        return credential.price

    @staticmethod
    def is_priced(credential: LLMCredential | None) -> bool:
        if credential is None:
            return True
        if credential.is_gemini:
            return credential.resolved_model == MODEL_NAME
        return credential.is_priced

    @classmethod
    def estimate_cost_usd(
        cls, total_chars: int, credential: LLMCredential | None = None
    ) -> float:
        tok = cls.estimate_tokens(total_chars)
        return cls._credential_price(credential, "flex").cost(tok, tok)

    @classmethod
    def estimate_max_cost_usd(
        cls, total_chars: int, credential: LLMCredential | None = None
    ) -> float:
        input_tokens = cls.estimate_tokens(total_chars)
        return cls._credential_price(credential, "standard").cost(
            input_tokens, max(input_tokens * 2, 1)
        )

    @staticmethod
    def _tier_name(tier: "types.ServiceTier") -> str:
        return "standard" if tier == types.ServiceTier.STANDARD else "flex"

    @classmethod
    def cost_for_tokens(
        cls,
        input_tokens: int,
        output_tokens: int,
        *,
        tier: str,
        provider: str = "google",
        model: str = "",
        credential: LLMCredential | None = None,
    ) -> float:
        if credential is not None:
            return cls._credential_price(credential, tier).cost(
                input_tokens, output_tokens
            )
        return cls.price_for(provider, model, tier=tier).cost(
            input_tokens, output_tokens
        )

    @classmethod
    def reserve_cost_usd(
        cls,
        input_chars: int,
        *,
        tier: str,
        max_output_tokens: int,
        prompt_tokens: int = 0,
        extra_input_tokens: int = 0,
        credential: LLMCredential | None = None,
    ) -> float:
        return cls._credential_price(credential, tier).cost(
            cls.estimate_tokens(input_chars) + prompt_tokens + extra_input_tokens,
            max_output_tokens,
        )

    @classmethod
    def clean_reservation_cost_usd(
        cls,
        input_chars: int,
        *,
        tier: str,
        image_input: bool = False,
        credential: LLMCredential | None = None,
    ) -> float:
        return cls.reserve_cost_usd(
            input_chars,
            tier=tier,
            max_output_tokens=_CLEAN_MAX_OUTPUT_TOKENS,
            prompt_tokens=2_000,
            extra_input_tokens=16_384 if image_input else 0,
            credential=credential,
        )

    @classmethod
    def section_reservation_cost_usd(
        cls,
        input_chars: int,
        chunk_count: int,
        *,
        tier: str,
        credential: LLMCredential | None = None,
    ) -> float:
        chunks = max(1, chunk_count)
        return chunks * cls.reserve_cost_usd(
            -(-input_chars // chunks),
            tier=tier,
            max_output_tokens=_SECTION_MAX_OUTPUT_TOKENS,
            prompt_tokens=700,
            credential=credential,
        )

    @classmethod
    async def _async_complete(
        cls,
        credential: LLMCredential,
        system: str,
        *,
        text: str | None = None,
        image_jpeg: bytes | None = None,
        max_output_tokens: int,
        empty: str = "",
    ) -> GeneratedText:
        completion = await llm_providers.complete(
            credential,
            system=system,
            text=text,
            image_jpeg=image_jpeg,
            max_output_tokens=max_output_tokens,
        )
        if not completion.text and (image_jpeg is not None or (text or "").strip()):
            raise LLMBadResponseError(f"{credential.name} returned no text.")
        usage = None
        if completion.input_tokens is not None and completion.output_tokens is not None:
            usage = LLMUsage(
                completion.input_tokens,
                completion.output_tokens,
                "standard",
                credential.provider,
                credential.resolved_model,
            )
        return GeneratedText(completion.text or empty, usage)

    @classmethod
    async def complete_text(
        cls,
        credential: LLMCredential,
        system: str,
        text: str,
        *,
        max_output_tokens: int,
        json_output: bool = False,
    ) -> GeneratedText:
        return await cls._with_retry(
            "complete_text",
            lambda tier: cls._async_text(
                credential, system, text, max_output_tokens, json_output, tier
            ),
            start_tier=types.ServiceTier.STANDARD,
        )

    @classmethod
    async def _async_text(
        cls,
        credential: LLMCredential,
        system: str,
        text: str,
        max_output_tokens: int,
        json_output: bool,
        tier: "types.ServiceTier",
    ) -> GeneratedText:
        if not credential.is_gemini:
            return await cls._async_complete(
                credential, system, text=text, max_output_tokens=max_output_tokens
            )
        client = genai.Client(
            api_key=credential.api_key, http_options=STANDARD_HTTP_OPTIONS
        )
        config = types.GenerateContentConfig(
            system_instruction=system,
            temperature=0.7,
            max_output_tokens=max_output_tokens,
            response_mime_type="application/json" if json_output else None,
            service_tier=tier,
        )
        try:
            resp = await client.aio.models.generate_content(
                model=credential.resolved_model, config=config, contents=text
            )
        except Exception as e:
            cls._reraise_typed(e, credential)
        cls._require_complete(resp)
        return GeneratedText(
            (resp.text or "").strip(), cls._usage_from_response(resp, tier, credential)
        )

    @classmethod
    def _usage_from_response(
        cls,
        response: Any,
        tier: "types.ServiceTier",
        credential: LLMCredential | None = None,
    ) -> LLMUsage | None:
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
        return LLMUsage(
            input_tokens,
            output_tokens,
            cls._tier_name(tier),
            "google",
            credential.resolved_model if credential else MODEL_NAME,
        )

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
        chunks = cls._section_chunks(pages)
        return sum(len(text) for _, text in chunks), len(chunks)

    @classmethod
    async def detect_sections(
        cls,
        credential: LLMCredential,
        pages: list[str],
        start_tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> list[dict]:
        if not pages:
            return []

        chunks = cls._section_chunks(pages)

        all_sections: list[dict] = []
        receipts: list[LLMUsage] = []
        for first_page, text in chunks:
            try:
                resp_text = await cls._with_retry(
                    "detect_sections",
                    lambda tier, text=text: cls._async_section_call(
                        credential, text, tier
                    ),
                    start_tier=start_tier,
                )
                receipt = getattr(resp_text, "usage", None)
                if receipt is not None:
                    receipts.append(receipt)
                parsed = cls._parse_sections_json(resp_text, max_page=len(pages))
                parsed = [s for s in parsed if s["start_page"] >= first_page]
                all_sections.extend(parsed)
            except LLMCapacityError:
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
        credential: LLMCredential,
        joined_text: str,
        tier: "types.ServiceTier" = types.ServiceTier.FLEX,
    ) -> str:
        if not credential.is_gemini:
            return await cls._async_complete(
                credential,
                cls.SECTION_PROMPT,
                text=joined_text,
                max_output_tokens=_SECTION_MAX_OUTPUT_TOKENS,
            )
        http_options = (
            FLEX_HTTP_OPTIONS
            if tier == types.ServiceTier.FLEX
            else STANDARD_HTTP_OPTIONS
        )
        client = genai.Client(api_key=credential.api_key, http_options=http_options)
        config = types.GenerateContentConfig(
            system_instruction=cls.SECTION_PROMPT,
            temperature=0.1,
            response_mime_type="application/json",
            max_output_tokens=_SECTION_MAX_OUTPUT_TOKENS,
            service_tier=tier,
        )
        try:
            resp = await client.aio.models.generate_content(
                model=credential.resolved_model,
                config=config,
                contents=joined_text,
            )
        except Exception as e:
            cls._reraise_typed(e, credential)
        return GeneratedText(
            resp.text or "", cls._usage_from_response(resp, tier, credential)
        )

    @staticmethod
    def _parse_sections_json(raw: str, max_page: int) -> list[dict]:
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

    _VERIFY_KEY_TIMEOUT_S = 20.0
    _PROBE_MAX_OUTPUT_TOKENS = 32

    @classmethod
    async def verify(cls, credential: LLMCredential | None) -> VerifyResult:
        if credential is None:
            return VerifyResult(False, [], "Choose an AI provider.")
        problem = credential.problem(require_model=False)
        if problem:
            return VerifyResult(False, [], problem)
        try:
            return await asyncio.wait_for(
                cls._verify(credential), timeout=cls._VERIFY_KEY_TIMEOUT_S
            )
        except TimeoutError as e:
            message = f"{credential.name} didn't answer in time. Try again."
            log_failure("llm.verify_failed", credential, e, detail="verify timed out")
            return VerifyResult(False, [], message)
        except LLMError as e:
            log_failure("llm.verify_failed", credential, e)
            return VerifyResult(False, [], e.user_message)
        except Exception as e:
            log_failure("llm.verify_failed", credential, e)
            return VerifyResult(
                False, [], f"Voqora could not verify {credential.name}. Try again."
            )

    @classmethod
    async def _verify(cls, credential: LLMCredential) -> VerifyResult:
        if credential.is_gemini:
            await cls._probe_gemini(credential)
            return VerifyResult(True, [])
        ids: list[str] = []
        try:
            ids = await llm_providers.list_model_ids(credential)
        except LLMModelListUnavailableError:
            pass
        models = llm_providers.chat_models(ids)
        model = credential.resolved_model
        if not model:
            return VerifyResult(False, models, f"Choose a model for {credential.name}.")
        if ids and model_is_listed(model, ids):
            return VerifyResult(True, models)
        try:
            await cls._probe_model(credential)
        except LLMIncompleteError:
            return VerifyResult(True, models)
        except LLMModelNotFoundError:
            hint = " Choose one from the list." if models else ""
            return VerifyResult(
                False, models, f"{credential.name} has no model named {model}.{hint}"
            )
        except LLMError as e:
            log_failure("llm.verify_failed", credential, e)
            return VerifyResult(False, models, e.user_message)
        return VerifyResult(True, models)

    @classmethod
    async def _probe_gemini(cls, credential: LLMCredential) -> None:
        try:
            await cls._async_clean(credential, "Say 'ok'.", types.ServiceTier.STANDARD)
        except LLMIncompleteError:
            return

    @classmethod
    async def _probe_model(cls, credential: LLMCredential) -> None:
        await llm_providers.complete(
            credential,
            system="Reply with the single word ok.",
            text="ok",
            max_output_tokens=cls._PROBE_MAX_OUTPUT_TOKENS,
        )
