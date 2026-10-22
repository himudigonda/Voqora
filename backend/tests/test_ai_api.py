from __future__ import annotations

import asyncio
import json
import logging
import shutil
import tempfile

import httpx
import pytest
from ai_fakes import OPENAI_HEADERS, Call, FakeLLM, install, make_book, reply
from fastapi.testclient import TestClient

from app.api import ai as ai_api
from app.api.ai import RequestGate, provider_failure, run_until_disconnect
from app.main import app
from app.services import ai_documents, ai_reader
from app.services.audiobook_store import AudiobookStore
from app.services.llm_providers import (
    LLMAuthError,
    LLMBadResponseError,
    LLMBillingError,
    LLMCapacityError,
    LLMConfigError,
    LLMCredential,
    LLMIncompleteError,
    LLMModelNotFoundError,
    LLMRateLimitError,
    LLMRequestRejectedError,
    LLMUnreachableError,
)

SECRET = OPENAI_HEADERS["X-Voqora-LLM-Key"]


@pytest.fixture(autouse=True)
def isolated_library(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_ai_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


@pytest.fixture(autouse=True)
def fresh_gate(monkeypatch):
    monkeypatch.setattr(
        ai_api,
        "_gate",
        RequestGate(max_active=3, max_per_window=30, window_s=60.0),
    )
    monkeypatch.setattr(ai_reader, "_RETRY_DELAY_S", 0.0)


@pytest.fixture
def client():
    return TestClient(app)


def _summary_llm(monkeypatch) -> FakeLLM:
    return install(
        monkeypatch, FakeLLM(lambda _c, _n: reply({"summary": "A summary."}))
    )


def test_summarize_text_returns_summary_tokens_and_cost(client, monkeypatch):
    fake = _summary_llm(monkeypatch)
    response = client.post(
        "/ai/summarize",
        json={"text": "Some text to summarize.", "length": "short"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["summary"] == "A summary."
    assert body["chunks"] == 1
    assert body["tokens"] == 120
    assert body["tokens_estimated"] is False
    assert body["cost_usd"] > 0
    assert body["provider"] == "openai"
    assert body["model"] == "gpt-6-luna"
    assert len(fake.calls) == 1


def test_summarize_a_book_reads_clean_pages_with_section_titles(client, monkeypatch):
    fake = _summary_llm(monkeypatch)
    book_id = make_book(
        ["Page one text.", "-", "Page three text."],
        sections=[{"title": "Opening", "start_page": 1, "end_page": 3}],
    )
    response = client.post(
        "/ai/summarize", json={"book_id": book_id}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 200
    user = fake.calls[0].user
    assert "Opening\n\nPage one text.\n\nPage three text." in user


def test_book_falls_back_to_raw_pages(client, monkeypatch):
    fake = _summary_llm(monkeypatch)
    book_id = make_book(["Raw only."], clean=False)
    response = client.post(
        "/ai/summarize", json={"book_id": book_id}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 200
    assert "Raw only." in fake.calls[0].user


def test_missing_book_is_404(client, monkeypatch):
    _summary_llm(monkeypatch)
    response = client.post(
        "/ai/summarize", json={"book_id": "a" * 32}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 404
    assert response.json() == {"detail": "Book not found.", "code": "book_not_found"}


def test_book_without_text_is_409(client, monkeypatch):
    fake = _summary_llm(monkeypatch)
    book_id = make_book(["-", "   "])
    response = client.post(
        "/ai/flashcards", json={"book_id": book_id}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 409
    assert response.json()["code"] == "book_text_unavailable"
    assert fake.calls == []


def test_book_over_the_text_limit_is_413(client, monkeypatch):
    _summary_llm(monkeypatch)
    monkeypatch.setattr(ai_documents, "MAX_BOOK_TEXT_CHARS", 10)
    book_id = make_book(["0123456789", "more"])
    response = client.post(
        "/ai/summarize", json={"book_id": book_id}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 413
    assert response.json()["code"] == "book_too_long"


def test_long_book_summary_exceeding_the_cost_cap_is_413(client, monkeypatch):
    fake = _summary_llm(monkeypatch)
    monkeypatch.setattr(ai_api.settings, "MAX_AI_REQUEST_COST_USD", 0.0000001)
    response = client.post(
        "/ai/summarize", json={"text": "word " * 2_000}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 413
    assert response.json()["code"] == "ai_budget_exceeded"
    assert fake.calls == []


@pytest.mark.parametrize(
    ("path", "payload"),
    [
        ("/ai/summarize", {}),
        ("/ai/summarize", {"text": "a", "book_id": "a" * 32}),
        ("/ai/summarize", {"text": "   "}),
        ("/ai/summarize", {"text": "x", "length": "huge"}),
        ("/ai/summarize", {"text": "x", "language": "klingon"}),
        ("/ai/summarize", {"text": "x" * 200_001}),
        ("/ai/summarize", {"book_id": "../../etc/passwd"}),
        ("/ai/summarize", {"book_id": "A" * 32}),
        ("/ai/translate", {"text": "x" * 20_001, "target_language": "es"}),
        ("/ai/translate", {"text": "hello", "target_language": "de"}),
        ("/ai/translate", {"text": "", "target_language": "es"}),
        ("/ai/translate", {"text": "hello"}),
        ("/ai/tidy", {"text": "x" * 20_001}),
        ("/ai/tidy", {"text": "   "}),
        ("/ai/tidy", {}),
        ("/ai/ask", {"book_id": "a" * 32, "question": "q" * 1_001}),
        ("/ai/ask", {"book_id": "a" * 32, "question": "  "}),
        ("/ai/ask", {"question": "Why?"}),
        (
            "/ai/ask",
            {
                "book_id": "a" * 32,
                "question": "Why?",
                "history": [{"role": "user", "content": "hi"}] * 11,
            },
        ),
        (
            "/ai/ask",
            {
                "book_id": "a" * 32,
                "question": "Why?",
                "history": [{"role": "system", "content": "hi"}],
            },
        ),
        (
            "/ai/ask",
            {
                "book_id": "a" * 32,
                "question": "Why?",
                "history": [{"role": "user", "content": "h" * 4_001}],
            },
        ),
        ("/ai/quiz", {"text": "x", "count": 2}),
        ("/ai/quiz", {"text": "x", "count": 21}),
        ("/ai/quiz", {"text": "x", "difficulty": "brutal"}),
        ("/ai/flashcards", {"text": "x", "count": 4}),
        ("/ai/flashcards", {"text": "x", "count": 41}),
    ],
)
def test_request_validation(client, monkeypatch, path, payload):
    fake = _summary_llm(monkeypatch)
    response = client.post(path, json=payload, headers=OPENAI_HEADERS)
    assert response.status_code == 422
    assert fake.calls == []


@pytest.mark.parametrize(
    ("headers", "detail"),
    [
        ({}, "Choose an AI provider in Settings to use AI tools."),
        ({"X-Voqora-LLM-Provider": "openai"}, "Missing API key for OpenAI."),
        (
            {"X-Voqora-LLM-Provider": "custom", "X-Voqora-LLM-Model": "m"},
            "Enter a server URL for Custom Provider.",
        ),
    ],
)
def test_unusable_provider_config_is_400(client, monkeypatch, headers, detail):
    fake = _summary_llm(monkeypatch)
    response = client.post("/ai/summarize", json={"text": "x"}, headers=headers)
    assert response.status_code == 400
    assert response.json() == {"detail": detail, "code": "ai_provider_required"}
    assert fake.calls == []


def test_unknown_provider_uses_the_shared_header_check(client):
    response = client.post(
        "/ai/summarize",
        json={"text": "x"},
        headers={"X-Voqora-LLM-Provider": "nope"},
    )
    assert response.status_code == 400
    assert response.json()["detail"] == "Unknown AI provider."


def test_routes_still_require_the_ipc_token(monkeypatch):
    fake = _summary_llm(monkeypatch)
    response = TestClient(app, headers={"X-Voqora-IPC-Token": "wrong"}).post(
        "/ai/summarize", json={"text": "x"}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 401
    assert fake.calls == []


def test_translate_round_trip(client, monkeypatch):
    def handler(call: Call, _n: int) -> str:
        source = json.loads(call.user.split("\n", 1)[1].rsplit("\n", 1)[0])
        return reply(
            {
                "paragraphs": [f"[{p}]" for p in source],
                "detected_source_language": "en",
            }
        )

    install(monkeypatch, FakeLLM(handler))
    response = client.post(
        "/ai/translate",
        json={"text": "One.\n\nTwo.", "target_language": "hi"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "[One.]\n\n[Two.]"
    assert body["detected_source_language"] == "en"


def test_tidy_returns_cleaned_text_and_usage(client, monkeypatch):
    fake = install(
        monkeypatch,
        FakeLLM(lambda _c, _n: reply({"text": "Hello, world. This is a test."})),
    )
    response = client.post(
        "/ai/tidy",
        json={"text": "um hello world uh this is a test"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "Hello, world. This is a test."
    assert body["provider"] == "openai"
    assert body["tokens"] == 120
    assert len(fake.calls) == 1
    assert fake.calls[0].json_output is True
    assert "um hello world uh this is a test" in fake.calls[0].user
    assert "DICTATION" in fake.calls[0].user


def test_tidy_rejects_a_reply_that_adds_text(client, monkeypatch):
    fake = install(monkeypatch, FakeLLM(lambda _c, _n: reply({"text": "word " * 200})))
    response = client.post(
        "/ai/tidy", json={"text": "hello there"}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 502
    assert response.json()["code"] == "ai_invalid_output"
    assert len(fake.calls) == 2


def test_tidy_rejects_a_reply_that_drops_half_the_sentences(client, monkeypatch):
    sentences = [
        "We reviewed the budget today.",
        "Marketing asked for more time.",
        "Engineering confirmed the release date.",
        "Finance wants a revised forecast.",
        "Support will answer migration questions.",
        "We meet again on Thursday.",
    ]
    fake = install(
        monkeypatch,
        FakeLLM(lambda _c, _n: reply({"text": " ".join(sentences[:3])})),
    )
    response = client.post(
        "/ai/tidy", json={"text": " ".join(sentences)}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 502
    assert response.json()["code"] == "ai_invalid_output"
    assert len(fake.calls) == 2


def test_tidy_accepts_a_reply_that_only_removes_fillers(client, monkeypatch):
    fake = install(
        monkeypatch,
        FakeLLM(lambda _c, _n: reply({"text": "We shipped the release on Friday."})),
    )
    response = client.post(
        "/ai/tidy",
        json={"text": "um we shipped the release uh you know on Friday"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 200
    assert response.json()["text"] == "We shipped the release on Friday."
    assert len(fake.calls) == 1


def test_tidy_accepts_a_shorter_reply_for_a_four_word_dictation(client, monkeypatch):
    fake = install(
        monkeypatch,
        FakeLLM(lambda _c, _n: reply({"text": "Hello friend."})),
    )
    response = client.post(
        "/ai/tidy", json={"text": "hello there my friend"}, headers=OPENAI_HEADERS
    )
    assert response.status_code == 200
    assert response.json()["text"] == "Hello friend."
    assert len(fake.calls) == 1


def test_tidy_requires_a_provider(client, monkeypatch):
    fake = install(monkeypatch, FakeLLM(lambda _c, _n: reply({"text": "x"})))
    response = client.post("/ai/tidy", json={"text": "hello"})
    assert response.status_code == 400
    assert fake.calls == []


def test_ask_returns_citations_with_page_and_section(client, monkeypatch):
    install(
        monkeypatch,
        FakeLLM(
            lambda _c, _n: reply(
                {
                    "answer": "In a lighthouse.",
                    "citations": [{"passage": 1, "quote": "lived in a lighthouse"}],
                }
            )
        ),
    )
    book_id = make_book(
        ["Intro text about nothing.", "Mara lived in a lighthouse by the sea."],
        sections=[
            {"title": "Front", "start_page": 1, "end_page": 1},
            {"title": "Mara", "start_page": 2, "end_page": 2},
        ],
    )
    response = client.post(
        "/ai/ask",
        json={
            "book_id": book_id,
            "question": "Where did Mara live?",
            "history": [{"role": "user", "content": "Who is Mara?"}],
        },
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["found"] is True
    assert body["citations"] == [
        {
            "section_title": "Mara",
            "page": 2,
            "passage_index": 1,
            "quote": "lived in a lighthouse",
        }
    ]


def test_quiz_and_flashcards_round_trip(client, monkeypatch):
    questions = [
        {
            "question": f"Q{i}?",
            "choices": ["a", "b", "c", "d"],
            "answer_index": 2,
            "explanation": "See text.",
        }
        for i in range(3)
    ]
    cards = [{"front": f"F{i}", "back": "B"} for i in range(5)]

    def handler(call: Call, _n: int) -> str:
        if "flashcards" in call.system:
            return reply({"cards": cards})
        return reply({"questions": questions})

    install(monkeypatch, FakeLLM(handler))
    quiz = client.post(
        "/ai/quiz",
        json={"text": "Study me.", "count": 3, "difficulty": "easy"},
        headers=OPENAI_HEADERS,
    )
    assert quiz.status_code == 200
    assert quiz.json()["questions"] == questions
    flash = client.post(
        "/ai/flashcards", json={"text": "Study me.", "count": 5}, headers=OPENAI_HEADERS
    )
    assert flash.status_code == 200
    assert flash.json()["cards"] == cards


def test_invalid_model_output_after_repair_is_a_clean_502(client, monkeypatch):
    install(monkeypatch, FakeLLM(lambda _c, _n: f"garbage with {SECRET}"))
    response = client.post("/ai/summarize", json={"text": "x"}, headers=OPENAI_HEADERS)
    assert response.status_code == 502
    body = response.json()
    assert body["code"] == "ai_invalid_output"
    assert "garbage" not in body["detail"]
    assert SECRET not in response.text


_LEAKY = f"raw provider body with key {SECRET}"


@pytest.mark.parametrize(
    ("error", "status", "code"),
    [
        (LLMAuthError(_LEAKY, status=401, detail=_LEAKY), 502, "llm_auth_failed"),
        (LLMBillingError(_LEAKY), 502, "llm_billing_failed"),
        (LLMModelNotFoundError(_LEAKY), 502, "llm_model_not_found"),
        (LLMUnreachableError(_LEAKY), 502, "llm_unreachable"),
        (LLMConfigError(_LEAKY), 400, "llm_config_failed"),
        (LLMRateLimitError(_LEAKY), 503, "llm_busy"),
        (LLMCapacityError(_LEAKY), 503, "llm_busy"),
        (LLMIncompleteError(_LEAKY), 502, "llm_incomplete"),
        (LLMRequestRejectedError(_LEAKY), 502, "llm_rejected"),
        (LLMBadResponseError(_LEAKY), 502, "llm_failed"),
    ],
)
def test_provider_errors_map_to_stable_messages(
    client, monkeypatch, error, status, code
):
    install(monkeypatch, FakeLLM(lambda _c, _n: error))
    response = client.post(
        "/ai/translate",
        json={"text": "hello", "target_language": "es"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == status
    body = response.json()
    assert body["code"] == code
    assert "OpenAI" in body["detail"]
    assert SECRET not in response.text
    assert "raw provider body" not in response.text


def test_model_name_in_errors_is_bounded():
    credential = LLMCredential("openai", api_key="k", model="m" * 500)
    _, _, message = provider_failure(LLMModelNotFoundError("x"), credential)
    assert len(message) < 200


def test_concurrent_requests_beyond_the_limit_are_429():
    gate = RequestGate(max_active=1, max_per_window=10, window_s=60.0)
    with gate.admit() as first:
        assert first is None
        with gate.admit() as second:
            assert second == "ai_busy"
    with gate.admit() as third:
        assert third is None


def test_rate_window_limits_and_recovers():
    now = [0.0]
    gate = RequestGate(
        max_active=5, max_per_window=2, window_s=60.0, clock=lambda: now[0]
    )
    for _ in range(2):
        with gate.admit() as rejection:
            assert rejection is None
    with gate.admit() as rejection:
        assert rejection == "ai_rate_limited"
    now[0] = 61.0
    with gate.admit() as rejection:
        assert rejection is None


def test_gate_rejection_is_reported_with_a_code(client, monkeypatch):
    fake = _summary_llm(monkeypatch)
    monkeypatch.setattr(
        ai_api, "_gate", RequestGate(max_active=0, max_per_window=1, window_s=60.0)
    )
    response = client.post("/ai/summarize", json={"text": "x"}, headers=OPENAI_HEADERS)
    assert response.status_code == 429
    assert response.json()["code"] == "ai_busy"
    assert fake.calls == []


def test_gate_slot_is_released_after_a_failure(client, monkeypatch):
    install(monkeypatch, FakeLLM(lambda _c, _n: LLMAuthError("no")))
    monkeypatch.setattr(
        ai_api, "_gate", RequestGate(max_active=1, max_per_window=10, window_s=60.0)
    )
    for _ in range(3):
        response = client.post(
            "/ai/summarize", json={"text": "x"}, headers=OPENAI_HEADERS
        )
        assert response.status_code == 502


def test_slow_provider_times_out_with_504(client, monkeypatch):
    install(
        monkeypatch,
        FakeLLM(lambda _c, _n: reply({"summary": "late"}), delay_s=5.0),
    )
    monkeypatch.setattr(ai_api, "_TOOL_TIMEOUT_S", 0.05)
    response = client.post(
        "/ai/translate",
        json={"text": "hello", "target_language": "es"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 504
    assert response.json()["code"] == "ai_timeout"


class _DisconnectingRequest:
    def __init__(self, after: int) -> None:
        self.after = after
        self.polls = 0

    async def receive(self) -> dict[str, str]:
        self.polls += 1
        if self.polls > self.after:
            return {"type": "http.disconnect"}
        return {"type": "http.request"}


class _ConnectedRequest:
    def __init__(self) -> None:
        self.cancelled = False

    async def receive(self) -> dict[str, str]:
        try:
            await asyncio.sleep(3600)
        except asyncio.CancelledError:
            self.cancelled = True
            raise
        return {"type": "http.disconnect"}


@pytest.mark.asyncio
async def test_client_disconnect_cancels_the_work(monkeypatch):
    monkeypatch.setattr(ai_api, "_DISCONNECT_POLL_S", 0.01)
    cancelled = asyncio.Event()

    async def work() -> str:
        try:
            await asyncio.sleep(10)
        except asyncio.CancelledError:
            cancelled.set()
            raise
        return "done"

    with pytest.raises(ai_api._ClientDisconnected):
        await run_until_disconnect(_DisconnectingRequest(after=2), work(), 5.0)
    assert cancelled.is_set()


@pytest.mark.asyncio
async def test_finished_work_wins_and_stops_listening_for_disconnects():
    async def work() -> str:
        await asyncio.sleep(0.01)
        return "done"

    request = _ConnectedRequest()
    result = await asyncio.wait_for(run_until_disconnect(request, work(), 5.0), 2.0)
    assert result == "done"
    assert request.cancelled


@pytest.mark.asyncio
async def test_work_errors_propagate_from_the_runner():
    async def work() -> str:
        raise LLMAuthError("no")

    with pytest.raises(LLMAuthError):
        await run_until_disconnect(_ConnectedRequest(), work(), 5.0)


@pytest.mark.asyncio
async def test_disconnect_returns_499_and_stops_provider_calls(monkeypatch):
    monkeypatch.setattr(ai_api, "_DISCONNECT_POLL_S", 0.01)
    fake = install(
        monkeypatch, FakeLLM(lambda _c, _n: reply({"summary": "x"}), delay_s=5.0)
    )
    session = ai_reader.AISession(
        LLMCredential("openai", api_key="sk-test-123456"),
        max_tokens=10_000,
        max_cost_usd=1.0,
        concurrency=2,
    )

    async def work(s):
        return await ai_reader.summarize(s, "text", "short", None)

    response = await ai_api._execute(
        "summarize", _DisconnectingRequest(after=1), session, work, 5.0
    )
    assert response.status_code == 499
    assert fake.active == 0
    assert len(fake.calls) == 1


@pytest.mark.asyncio
async def test_disconnect_is_seen_through_the_full_middleware_stack(monkeypatch):
    monkeypatch.setattr(ai_api.settings, "IPC_TOKEN", "ipc-test-token")
    fake = install(
        monkeypatch,
        FakeLLM(lambda _c, _n: reply({"paragraphs": ["hola"]}), delay_s=30.0),
    )
    body = json.dumps({"text": "hello", "target_language": "es"}).encode()
    headers = {
        "x-voqora-ipc-token": "ipc-test-token",
        "content-type": "application/json",
        "content-length": str(len(body)),
        **{key.lower(): value for key, value in OPENAI_HEADERS.items()},
    }
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": "/ai/translate",
        "raw_path": b"/ai/translate",
        "query_string": b"",
        "root_path": "",
        "headers": [(k.encode(), v.encode()) for k, v in headers.items()],
        "client": ("127.0.0.1", 50000),
        "server": ("127.0.0.1", 8000),
    }
    disconnected = asyncio.Event()
    sent: list[dict] = []
    messages = [{"type": "http.request", "body": body, "more_body": False}]

    async def receive() -> dict:
        if messages:
            return messages.pop(0)
        await disconnected.wait()
        return {"type": "http.disconnect"}

    async def send(message: dict) -> None:
        sent.append(message)

    served = asyncio.ensure_future(app(scope, receive, send))
    while not fake.calls:
        await asyncio.sleep(0.01)
    disconnected.set()
    await asyncio.wait_for(served, 5.0)
    assert fake.active == 0
    starts = [m for m in sent if m["type"] == "http.response.start"]
    assert [m["status"] for m in starts] in ([], [499])


def test_logs_never_contain_document_text_or_the_key(client, monkeypatch, caplog):
    marker = "PRIVATE-DOCUMENT-MARKER"
    install(
        monkeypatch,
        FakeLLM(lambda _c, n: "bad" if n == 1 else reply({"summary": marker})),
    )
    with caplog.at_level(logging.DEBUG):
        response = client.post(
            "/ai/summarize",
            json={"text": f"{marker} body"},
            headers=OPENAI_HEADERS,
        )
    assert response.status_code == 200
    assert any(r.getMessage() == "ai.tool_done" for r in caplog.records)
    for record in caplog.records:
        dumped = json.dumps(record.__dict__, default=str)
        assert marker not in dumped
        assert SECRET not in dumped


def test_end_to_end_through_a_fake_openai_transport(client, monkeypatch):
    seen: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {"content": reply({"summary": "Via HTTP."})},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {"prompt_tokens": 30, "completion_tokens": 5},
            },
        )

    real_client = httpx.AsyncClient

    def client_with_transport(**kwargs):
        kwargs["transport"] = httpx.MockTransport(handle)
        return real_client(**kwargs)

    monkeypatch.setattr(
        "app.services.llm_providers.httpx.AsyncClient", client_with_transport
    )
    response = client.post(
        "/ai/summarize",
        json={"text": "Hello world.", "length": "medium"},
        headers={**OPENAI_HEADERS, "X-Voqora-LLM-Model": "gpt-6-luna"},
    )
    assert response.status_code == 200
    assert response.json()["summary"] == "Via HTTP."
    assert response.json()["tokens"] == 35
    assert seen[0].url == "https://api.openai.com/v1/chat/completions"
    assert seen[0].headers["authorization"] == f"Bearer {SECRET}"
    sent = json.loads(seen[0].content)
    assert sent["messages"][0]["role"] == "system"
    assert "Hello world." in sent["messages"][1]["content"]
    assert "Hello world." not in sent["messages"][0]["content"]


def test_end_to_end_provider_401_does_not_leak_the_body(client, monkeypatch):
    def handle(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            401, json={"error": {"message": f"Incorrect API key {SECRET}"}}
        )

    real_client = httpx.AsyncClient
    monkeypatch.setattr(
        "app.services.llm_providers.httpx.AsyncClient",
        lambda **kw: real_client(**{**kw, "transport": httpx.MockTransport(handle)}),
    )
    response = client.post(
        "/ai/translate",
        json={"text": "hello", "target_language": "es"},
        headers=OPENAI_HEADERS,
    )
    assert response.status_code == 502
    assert response.json()["code"] == "llm_auth_failed"
    assert "Incorrect API key" not in response.text
    assert SECRET not in response.text


def test_existing_routes_are_unchanged(client):
    assert client.get("/health").status_code == 200
    assert client.get("/audiobook").status_code == 200
