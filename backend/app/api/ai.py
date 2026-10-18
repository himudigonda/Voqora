"""AI reading tools: summarize, translate, ask, quiz, and flashcards.

Every route uses the provider, model, key, and base URL from the same
`X-Voqora-LLM-*` request headers as audiobook cleanup. Nothing is stored.
"""

import asyncio
import time
from collections import deque
from collections.abc import Awaitable, Callable, Iterator
from contextlib import contextmanager
from typing import Any, TypeVar

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field, field_validator, model_validator

from app.api.audiobook import llm_credential
from app.core.config import settings
from app.core.logging import get_logger
from app.services import ai_reader
from app.services.ai_documents import load_book_text
from app.services.ai_errors import AIToolError
from app.services.ai_reader import (
    AISession,
    AnswerResult,
    Difficulty,
    FlashcardsResult,
    HistoryTurn,
    QuizResult,
    Role,
    SummaryLength,
    SummaryResult,
    TranslationResult,
)
from app.services.llm_providers import (
    LLMAuthError,
    LLMBillingError,
    LLMCapacityError,
    LLMConfigError,
    LLMCredential,
    LLMError,
    LLMIncompleteError,
    LLMModelNotFoundError,
    LLMRateLimitError,
    LLMRequestRejectedError,
    LLMUnreachableError,
    short_text,
)

router = APIRouter(prefix="/ai")
log = get_logger(__name__)

T = TypeVar("T")

MAX_SOURCE_TEXT_CHARS = 200_000
MAX_TRANSLATE_CHARS = 20_000
MAX_QUESTION_CHARS = 1_000
MAX_HISTORY_TURNS = 10
MAX_HISTORY_TURN_CHARS = 4_000
_BOOK_ID_PATTERN = r"^[0-9a-f]{32}$"
_LANGUAGE_CODES = frozenset(ai_reader.LANGUAGE_NAMES)
_SUMMARY_CONCURRENCY = 4
_TOOL_CONCURRENCY = 2
_SUMMARY_TIMEOUT_S = 600.0
_TOOL_TIMEOUT_S = 300.0
_DISCONNECT_POLL_S = 0.5
_MAX_ACTIVE_REQUESTS = 3
_MAX_REQUESTS_PER_WINDOW = 30
_RATE_WINDOW_S = 60.0


def _require_language(value: str | None) -> str | None:
    if value is not None and value not in _LANGUAGE_CODES:
        raise ValueError(f"unsupported language: {value}")
    return value


def _require_meaningful(value: str | None) -> str | None:
    if value is not None and not value.strip():
        raise ValueError("must not be blank")
    return value


class _SourceRequest(BaseModel):
    text: str | None = Field(default=None, max_length=MAX_SOURCE_TEXT_CHARS)
    book_id: str | None = Field(default=None, pattern=_BOOK_ID_PATTERN)

    @field_validator("text")
    @classmethod
    def require_meaningful_text(cls, value: str | None) -> str | None:
        return _require_meaningful(value)

    @model_validator(mode="after")
    def require_one_source(self) -> "_SourceRequest":
        if (self.text is None) == (self.book_id is None):
            raise ValueError("provide exactly one of text or book_id")
        return self


class SummarizeRequest(_SourceRequest):
    length: SummaryLength = "medium"
    language: str | None = None

    @field_validator("language")
    @classmethod
    def require_known_language(cls, value: str | None) -> str | None:
        return _require_language(value)


class TranslateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TRANSLATE_CHARS)
    target_language: str

    @field_validator("text")
    @classmethod
    def require_meaningful_text(cls, value: str) -> str:
        return _require_meaningful(value)

    @field_validator("target_language")
    @classmethod
    def require_known_language(cls, value: str) -> str:
        return _require_language(value)


class HistoryTurnRequest(BaseModel):
    role: Role
    content: str = Field(min_length=1, max_length=MAX_HISTORY_TURN_CHARS)

    @field_validator("content")
    @classmethod
    def require_meaningful_content(cls, value: str) -> str:
        return _require_meaningful(value).strip()


class AskRequest(BaseModel):
    book_id: str = Field(pattern=_BOOK_ID_PATTERN)
    question: str = Field(min_length=1, max_length=MAX_QUESTION_CHARS)
    history: list[HistoryTurnRequest] = Field(
        default_factory=list, max_length=MAX_HISTORY_TURNS
    )

    @field_validator("question")
    @classmethod
    def require_meaningful_question(cls, value: str) -> str:
        return _require_meaningful(value).strip()


class QuizRequest(_SourceRequest):
    count: int = Field(default=5, ge=3, le=20)
    difficulty: Difficulty = "medium"


class FlashcardsRequest(_SourceRequest):
    count: int = Field(default=10, ge=5, le=40)


class RequestGate:
    def __init__(
        self,
        *,
        max_active: int,
        max_per_window: int,
        window_s: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._max_active = max_active
        self._max_per_window = max_per_window
        self._window_s = window_s
        self._clock = clock
        self._active = 0
        self._recent: deque[float] = deque()

    def _rejection(self) -> str | None:
        now = self._clock()
        while self._recent and now - self._recent[0] >= self._window_s:
            self._recent.popleft()
        if self._active >= self._max_active:
            return "ai_busy"
        if len(self._recent) >= self._max_per_window:
            return "ai_rate_limited"
        self._recent.append(now)
        self._active += 1
        return None

    @contextmanager
    def admit(self) -> Iterator[str | None]:
        rejection = self._rejection()
        try:
            yield rejection
        finally:
            if rejection is None:
                self._active -= 1


_gate = RequestGate(
    max_active=_MAX_ACTIVE_REQUESTS,
    max_per_window=_MAX_REQUESTS_PER_WINDOW,
    window_s=_RATE_WINDOW_S,
)

_GATE_MESSAGES = {
    "ai_busy": "Voqora is already working on other AI requests. Try again shortly.",
    "ai_rate_limited": "Too many AI requests in the last minute. Try again shortly.",
}


class _ClientDisconnected(Exception):
    pass


class _ToolTimedOut(Exception):
    pass


async def _wait_for_disconnect(request: Request) -> None:
    while (await request.receive())["type"] != "http.disconnect":
        await asyncio.sleep(_DISCONNECT_POLL_S)


async def run_until_disconnect(
    request: Request, work: Awaitable[T], timeout_s: float
) -> T:
    task = asyncio.ensure_future(work)
    watcher = asyncio.ensure_future(_wait_for_disconnect(request))
    try:
        done, _ = await asyncio.wait(
            {task, watcher}, timeout=timeout_s, return_when=asyncio.FIRST_COMPLETED
        )
        if task in done:
            return task.result()
        if watcher in done:
            raise _ClientDisconnected()
        raise _ToolTimedOut()
    finally:
        for pending in (task, watcher):
            pending.cancel()
        await asyncio.gather(task, watcher, return_exceptions=True)


def _error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse({"detail": message, "code": code}, status_code=status)


def provider_failure(
    error: LLMError, credential: LLMCredential
) -> tuple[int, str, str]:
    name = credential.name
    model = short_text(credential.resolved_model, 80, credential.api_key)
    if isinstance(error, LLMModelNotFoundError):
        return (
            502,
            "llm_model_not_found",
            f"{name} has no model named {model}. Choose another model in Settings.",
        )
    if isinstance(error, LLMBillingError):
        return (
            502,
            "llm_billing_failed",
            f"{name} reports no remaining credit or quota for this account.",
        )
    if isinstance(error, LLMAuthError):
        return (
            502,
            "llm_auth_failed",
            f"{name} rejected the API key or denied access to {model}."
            " Check the provider in Settings.",
        )
    if isinstance(error, LLMUnreachableError):
        return 502, "llm_unreachable", f"Voqora could not reach {name}."
    if isinstance(error, LLMConfigError):
        return 400, "llm_config_failed", f"Check the {name} settings."
    if isinstance(error, (LLMRateLimitError, LLMCapacityError)):
        return (
            503,
            "llm_busy",
            f"{name} is busy or rate limiting this key. Try again shortly.",
        )
    if isinstance(error, LLMIncompleteError):
        return (
            502,
            "llm_incomplete",
            f"{name} stopped before finishing. Try a shorter text or another model.",
        )
    if isinstance(error, LLMRequestRejectedError):
        return 502, "llm_rejected", f"{name} rejected the request."
    return (
        502,
        "llm_failed",
        f"{name} returned an answer Voqora could not read. Try again.",
    )


def _usable_credential(credential: LLMCredential | None) -> LLMCredential | str:
    if credential is None:
        return "Choose an AI provider in Settings to use AI tools."
    return credential.problem() or credential


async def _run_tool(
    tool: str,
    request: Request,
    credential: LLMCredential | None,
    work: Callable[[AISession], Awaitable[Any]],
    *,
    timeout_s: float | None = None,
    concurrency: int = _TOOL_CONCURRENCY,
) -> Any:
    usable = _usable_credential(credential)
    if isinstance(usable, str):
        return _error(400, "ai_provider_required", usable)
    with _gate.admit() as rejection:
        if rejection is not None:
            log.info("ai.request_rejected", extra={"tool": tool, "reason": rejection})
            return _error(429, rejection, _GATE_MESSAGES[rejection])
        session = AISession(
            usable,
            max_tokens=settings.MAX_AI_REQUEST_TOKENS,
            max_cost_usd=settings.MAX_AI_REQUEST_COST_USD,
            concurrency=concurrency,
        )
        return await _execute(
            tool, request, session, work, timeout_s or _TOOL_TIMEOUT_S
        )


async def _execute(
    tool: str,
    request: Request,
    session: AISession,
    work: Callable[[AISession], Awaitable[Any]],
    timeout_s: float,
) -> Any:
    started = time.perf_counter()
    facts: dict[str, Any] = {
        "tool": tool,
        "provider": session.credential.provider,
        "model": session.credential.resolved_model,
    }
    try:
        result = await run_until_disconnect(request, work(session), timeout_s)
    except _ClientDisconnected:
        log.info("ai.client_disconnected", extra={**facts, "calls": session.calls})
        return Response(status_code=499)
    except _ToolTimedOut:
        log.warning("ai.tool_failed", extra={**facts, "failure_code": "ai_timeout"})
        return _error(504, "ai_timeout", "The AI request took too long. Try again.")
    except AIToolError as e:
        log.warning("ai.tool_failed", extra={**facts, "failure_code": e.code})
        return _error(e.status, e.code, e.user_message)
    except LLMError as e:
        status, code, message = provider_failure(e, session.credential)
        log.warning(
            "ai.tool_failed",
            extra={**facts, "failure_code": code, "error_type": type(e).__name__},
        )
        return _error(status, code, message)
    log.info(
        "ai.tool_done",
        extra={
            **facts,
            "calls": session.calls,
            "tokens": session.budget.input_tokens + session.budget.output_tokens,
            "duration_ms": round((time.perf_counter() - started) * 1000, 1),
        },
    )
    return result


async def _source_text(body: _SourceRequest) -> str:
    if body.text is not None:
        return body.text
    book = await asyncio.to_thread(load_book_text, body.book_id)
    return book.joined()


@router.post("/summarize", response_model=SummaryResult)
async def summarize(
    body: SummarizeRequest,
    request: Request,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Summarize pasted text or a library book, map-reducing long books."""

    async def work(session: AISession) -> SummaryResult:
        text = await _source_text(body)
        return await ai_reader.summarize(session, text, body.length, body.language)

    return await _run_tool(
        "summarize",
        request,
        credential,
        work,
        timeout_s=_SUMMARY_TIMEOUT_S,
        concurrency=_SUMMARY_CONCURRENCY,
    )


@router.post("/translate", response_model=TranslationResult)
async def translate(
    body: TranslateRequest,
    request: Request,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Translate text into one of the app's languages, keeping paragraphs."""

    async def work(session: AISession) -> TranslationResult:
        return await ai_reader.translate(session, body.text, body.target_language)

    return await _run_tool("translate", request, credential, work)


@router.post("/ask", response_model=AnswerResult)
async def ask(
    body: AskRequest,
    request: Request,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Answer a question about a library book from its best-matching passages."""
    history = [HistoryTurn(turn.role, turn.content) for turn in body.history]

    async def work(session: AISession) -> AnswerResult:
        book = await asyncio.to_thread(load_book_text, body.book_id)
        return await ai_reader.ask(session, book, body.question, history)

    return await _run_tool("ask", request, credential, work)


@router.post("/quiz", response_model=QuizResult)
async def quiz(
    body: QuizRequest,
    request: Request,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Write multiple-choice questions about pasted text or a library book."""

    async def work(session: AISession) -> QuizResult:
        text = await _source_text(body)
        return await ai_reader.quiz(session, text, body.count, body.difficulty)

    return await _run_tool("quiz", request, credential, work)


@router.post("/flashcards", response_model=FlashcardsResult)
async def flashcards(
    body: FlashcardsRequest,
    request: Request,
    credential: LLMCredential | None = Depends(llm_credential),
):
    """Write study flashcards about pasted text or a library book."""

    async def work(session: AISession) -> FlashcardsResult:
        text = await _source_text(body)
        return await ai_reader.flashcards(session, text, body.count)

    return await _run_tool("flashcards", request, credential, work)
