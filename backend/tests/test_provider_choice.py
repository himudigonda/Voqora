from __future__ import annotations

import asyncio
import os
import shutil
import tempfile
from unittest.mock import AsyncMock

import httpx
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services import audiobook_service as service_module
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.llm_cleaner import LLMCleaner, LLMUsage
from app.services.llm_cleaner import types as gemini_types
from app.services.llm_providers import (
    LLMAuthError,
    LLMCredential,
    LLMModelNotFoundError,
    LLMRateLimitError,
)


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="ss_audiobooks_test_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def _make_book(status: str = "failed", pages: int = 1, **extra) -> str:
    bid = AudiobookStore.create_book("Doc.txt")
    meta = AudiobookStore.initial_meta(
        bid, "Doc.txt", pages, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta.update(status=status, **extra)
    AudiobookStore.write_meta(bid, meta)
    return bid


def _write_raw(bid: str, n: int, text: str) -> None:
    path = AudiobookStore.page_raw_path(bid, n)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _stub_enqueue(monkeypatch) -> list:
    enqueued: list = []

    async def fake_enqueue(book_id, credential):
        enqueued.append((book_id, credential))

    monkeypatch.setattr(
        AudiobookService,
        "enqueue",
        classmethod(lambda cls, b, c: fake_enqueue(b, c)),
    )
    return enqueued


@pytest.mark.asyncio
async def test_enqueue_records_the_provider_actually_used_and_clears_the_error(
    monkeypatch,
):
    bid = _make_book(
        "failed",
        error="old",
        error_code="llm_auth_failed",
        llm_provider="google",
        llm_model="gemini-3.8-flash",
    )
    monkeypatch.setattr(AudiobookService, "initialize", classmethod(lambda cls: None))
    monkeypatch.setattr(AudiobookService, "_queue", asyncio.Queue())

    await AudiobookService.enqueue(
        bid, LLMCredential("openai", api_key="sk-test", model="gpt-6-luna")
    )

    meta = AudiobookStore.read_meta(bid)
    assert meta["status"] == "queued"
    assert meta["error"] is None and meta["error_code"] is None
    assert meta["llm_provider"] == "openai"
    assert meta["llm_model"] == "gpt-6-luna"
    AudiobookService._scheduled_book_ids.discard(bid)
    AudiobookService._job_keys.pop(bid, None)


@pytest.mark.asyncio
async def test_enqueue_without_a_credential_leaves_the_recorded_provider(monkeypatch):
    bid = _make_book("tts", llm_provider="groq", llm_model="m")
    monkeypatch.setattr(AudiobookService, "initialize", classmethod(lambda cls: None))
    monkeypatch.setattr(AudiobookService, "_queue", asyncio.Queue())

    await AudiobookService.enqueue(bid, None)

    meta = AudiobookStore.read_meta(bid)
    assert meta["llm_provider"] == "groq" and meta["llm_model"] == "m"
    AudiobookService._scheduled_book_ids.discard(bid)
    AudiobookService._job_keys.pop(bid, None)


@pytest.mark.asyncio
async def test_retry_with_a_new_provider_updates_meta(monkeypatch):
    bid = _make_book(
        "failed",
        uses_gemini_cleanup=True,
        error_code="llm_billing_failed",
        llm_provider="google",
        llm_model="gemini-3.8-flash",
    )
    monkeypatch.setattr(AudiobookService, "initialize", classmethod(lambda cls: None))
    monkeypatch.setattr(AudiobookService, "_queue", asyncio.Queue())

    await AudiobookService.retry_failed(
        bid, LLMCredential("anthropic", api_key="k", model="claude-x")
    )

    meta = AudiobookStore.read_meta(bid)
    assert meta["llm_provider"] == "anthropic"
    assert meta["llm_model"] == "claude-x"
    assert meta["error_code"] is None
    assert meta["uses_gemini_cleanup"] is True
    AudiobookService._scheduled_book_ids.discard(bid)
    AudiobookService._job_keys.pop(bid, None)


@pytest.mark.asyncio
async def test_retry_without_cleanup_drops_the_provider_and_finishes_locally(
    monkeypatch,
):
    bid = _make_book(
        "failed",
        pages=2,
        uses_gemini_cleanup=True,
        failed_pages=[1],
        page_status={"1": "cleaning_failed"},
        error_code="llm_auth_failed",
        llm_provider="google",
        llm_model="gemini-3.8-flash",
        gemini_tier="standard",
    )
    _write_raw(bid, 1, "# Heading\n\nSome **bold** words.")
    _write_raw(bid, 2, "Second page.")
    with open(AudiobookStore.page_clean_path(bid, 2), "w") as f:
        f.write("Second page.")
    enqueued = _stub_enqueue(monkeypatch)

    count = await AudiobookService.retry_failed(
        bid, LLMCredential.gemini("k"), cleanup=False
    )

    assert count == 1
    assert enqueued == [(bid, None)]
    meta = AudiobookStore.read_meta(bid)
    assert meta["uses_gemini_cleanup"] is False
    assert meta["llm_provider"] is None and meta["llm_model"] is None
    assert meta["error_code"] is None
    assert meta["gemini_tier"] == "flex"

    clean_page = AsyncMock(side_effect=AssertionError("no AI when cleanup is off"))
    monkeypatch.setattr(LLMCleaner, "clean_page", clean_page)
    _write_raw(bid, 1, "# Heading\n\nSome **bold** words.")
    monkeypatch.setattr(AudiobookService, "_executor", None)
    AudiobookService.initialize()
    await AudiobookService._phase_clean(bid, None)

    clean_page.assert_not_called()
    with open(AudiobookStore.page_clean_path(bid, 1), encoding="utf-8") as f:
        local = f.read()
    assert "Heading" in local and "#" not in local and "**" not in local


def _retry_client(monkeypatch, *, uses_cleanup: bool):
    retry = AsyncMock(return_value=1)
    monkeypatch.setattr(AudiobookService, "retry_failed", retry)
    bid = _make_book("failed", uses_gemini_cleanup=uses_cleanup)
    return TestClient(app), bid, retry


def test_retry_endpoint_cleanup_false_header_skips_the_credential_requirement(
    monkeypatch,
):
    client, bid, retry = _retry_client(monkeypatch, uses_cleanup=True)

    response = client.post(
        f"/audiobook/{bid}/retry", headers={"X-Voqora-LLM-Cleanup": "false"}
    )

    assert response.status_code == 200
    retry.assert_awaited_once_with(bid, None, cleanup=False)


def test_retry_endpoint_still_requires_a_provider_by_default(monkeypatch):
    client, bid, retry = _retry_client(monkeypatch, uses_cleanup=True)

    response = client.post(f"/audiobook/{bid}/retry")

    assert response.status_code == 400
    retry.assert_not_called()


def test_retry_endpoint_passes_the_chosen_provider_through(monkeypatch):
    client, bid, retry = _retry_client(monkeypatch, uses_cleanup=True)

    response = client.post(
        f"/audiobook/{bid}/retry",
        headers={
            "X-Voqora-LLM-Provider": "openai",
            "X-Voqora-LLM-Key": "sk-test",
            "X-Voqora-LLM-Model": "gpt-6-luna",
            "X-Voqora-LLM-Cleanup": "true",
        },
    )

    assert response.status_code == 200
    (_, credential), kwargs = retry.await_args
    assert credential.provider == "openai" and kwargs == {"cleanup": True}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("error", "code"),
    [
        (LLMAuthError("bad key"), "llm_auth_failed"),
        (LLMModelNotFoundError("no model"), "llm_model_not_found"),
    ],
)
async def test_failed_book_exposes_error_code_provider_and_model(
    monkeypatch, error, code
):
    bid = _make_book("queued", llm_provider="google", llm_model="gemini-3.8-flash")
    monkeypatch.setattr(AudiobookService, "_phase_extract", AsyncMock())
    monkeypatch.setattr(AudiobookService, "_phase_clean", AsyncMock(side_effect=error))
    events: list[dict] = []
    original = AudiobookService._emit

    def capture(cls, book_id, event_type, **data):
        events.append({"type": event_type, **data})
        return original(book_id, event_type, **data)

    monkeypatch.setattr(AudiobookService, "_emit", classmethod(capture))

    await AudiobookService._run_pipeline(bid)

    client = TestClient(app)
    single = client.get(f"/audiobook/{bid}").json()
    listed = next(b for b in client.get("/audiobook").json() if b["book_id"] == bid)
    for payload in (single, listed):
        assert payload["status"] == "failed"
        assert payload["error_code"] == code
        assert payload["llm_provider"] == "google"
        assert payload["llm_model"] == "gemini-3.8-flash"
    failed = next(e for e in events if e["type"] == "failed")
    assert failed["error_code"] == code


@pytest.mark.asyncio
async def test_local_custom_server_reconciles_to_zero_and_never_hits_the_cap():
    bid = _make_book("cleaning")
    await AudiobookStore.update_meta(bid, budget=AudiobookService._new_budget(5.0))
    local = LLMCredential(
        "custom", model="my-model", base_url="http://localhost:1234/v1"
    )
    remote = LLMCredential(
        "custom", model="my-model", base_url="https://api.example.com/v1"
    )
    usage = LLMUsage(2_000_000, 500_000, "flex", "custom", "my-model")

    for _ in range(20):
        receipt = await AudiobookService._reserve_llm_operation(
            bid, operation="clean_page", reserved_usd=0.0
        )
        assert receipt is not None
        await AudiobookService._reconcile_llm_operation(bid, receipt, usage, local)

    budget = AudiobookStore.read_meta(bid)["budget"]
    assert budget["actual_usd"] == 0.0
    assert budget["available_usd"] == pytest.approx(5.0)

    receipt = await AudiobookService._reserve_llm_operation(
        bid, operation="clean_page", reserved_usd=0.0
    )
    await AudiobookService._reconcile_llm_operation(bid, receipt, usage, remote)
    assert AudiobookStore.read_meta(bid)["budget"]["actual_usd"] > 0.0


@pytest.mark.asyncio
async def test_clean_phase_on_a_local_custom_server_is_never_cost_capped(
    monkeypatch,
):
    bid = _make_book("cleaning", pages=3, uses_gemini_cleanup=True)
    await AudiobookStore.update_meta(bid, budget=AudiobookService._new_budget(5.0))
    for n in (1, 2, 3):
        _write_raw(bid, n, f"Page {n} text. " * 30)
    usage = LLMUsage(3_000_000, 1_000_000, "flex", "custom", "my-model")

    async def fake_clean(credential, raw_text, **_):
        from app.services.llm_cleaner import GeneratedText

        return GeneratedText("cleaned text", usage)

    monkeypatch.setattr(LLMCleaner, "clean_page", fake_clean)
    AudiobookService.initialize()

    await AudiobookService._phase_clean(
        bid,
        LLMCredential("custom", model="my-model", base_url="http://localhost:1234/v1"),
    )

    meta = AudiobookStore.read_meta(bid)
    assert meta["failed_pages"] == []
    assert meta["budget"]["actual_usd"] == 0.0


def _upload(client: TestClient, **data):
    return client.post(
        "/audiobook",
        files={"file": ("Doc.txt", ("word " * 4000).encode(), "text/plain")},
        data=data,
    )


def test_upload_estimate_prices_a_local_custom_server_as_free():
    client = TestClient(app)
    local = _upload(
        client,
        llm_provider="custom",
        llm_model="my-model",
        llm_base_url="http://localhost:1234/v1",
    )
    lan = _upload(
        client,
        llm_provider="custom",
        llm_model="my-model",
        llm_base_url="http://192.168.1.20:8080/v1",
    )
    remote = _upload(
        client,
        llm_provider="custom",
        llm_model="my-model",
        llm_base_url="https://api.example.com/v1",
    )
    if any(r.status_code != 200 for r in (local, lan, remote)):
        pytest.skip("upload needs a loaded TTS engine in this environment")
    for free in (local.json(), lan.json()):
        assert free["estimated_cost_usd"] == 0 and free["maximum_cost_usd"] == 0
        assert free["llm_provider"] == "custom"
    assert remote.json()["maximum_cost_usd"] > 0


def test_upload_estimate_ignores_an_invalid_base_url_instead_of_failing():
    client = TestClient(app)
    invalid = _upload(
        client,
        llm_provider="custom",
        llm_model="my-model",
        llm_base_url="http://169.254.169.254/v1",
    )
    plain = _upload(client, llm_provider="custom", llm_model="my-model")
    if invalid.status_code != 200 or plain.status_code != 200:
        pytest.skip("upload needs a loaded TTS engine in this environment")
    assert invalid.json()["maximum_cost_usd"] == plain.json()["maximum_cost_usd"]


class _TimeoutModels:
    def __init__(self):
        self.calls = 0

    async def generate_content(self, **_):
        self.calls += 1
        raise httpx.ReadTimeout("slow")


@pytest.mark.asyncio
async def test_standard_tier_gemini_calls_are_bounded_and_timeouts_retry(
    monkeypatch,
):
    from types import SimpleNamespace

    models = _TimeoutModels()
    captured: list = []

    def fake_client(**kwargs):
        captured.append(kwargs.get("http_options"))
        return SimpleNamespace(aio=SimpleNamespace(models=models))

    monkeypatch.setattr("app.services.llm_cleaner.genai.Client", fake_client)
    monkeypatch.setattr("app.services.llm_cleaner.asyncio.sleep", AsyncMock())

    with pytest.raises(LLMRateLimitError):
        await LLMCleaner.clean_page(
            LLMCredential.gemini("k"),
            "text",
            start_tier=gemini_types.ServiceTier.STANDARD,
        )

    assert models.calls == LLMCleaner._MAX_RETRIES
    assert all(options is not None for options in captured)
    assert all(options.timeout == 180_000 for options in captured)


def test_flex_gemini_calls_keep_the_long_flex_timeout():
    from app.services.llm_cleaner import FLEX_HTTP_OPTIONS, STANDARD_HTTP_OPTIONS

    assert FLEX_HTTP_OPTIONS.timeout == 900_000
    assert STANDARD_HTTP_OPTIONS.timeout == 180_000
    assert service_module._GEMINI_PAGE_TIMEOUT_S == 900.0
