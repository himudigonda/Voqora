from __future__ import annotations

import os
import shutil
import tempfile
from collections.abc import AsyncIterator, Callable, Iterator
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.api import article as article_api
from app.api.article import ARTICLE_ERROR_STATUS, MAX_ARTICLE_HTML_BYTES
from app.main import app
from app.services.article_errors import ArticleFailure
from app.services.audiobook_store import AudiobookStore
from app.services.text_extractor import TextExtractor
from app.services.web_fetcher import MAX_CONCURRENT_FETCHES, WebFetcher, web_fetcher

FIXTURES = Path(__file__).parent / "fixtures" / "articles"
NEWS = (FIXTURES / "news.html").read_bytes()
PROSE = (
    "This sentence carries enough ordinary words to count as real article prose, "
    "with commas, clauses, and a steady rhythm that a reader would expect. "
)

Handler = Callable[[httpx.Request], httpx.Response]


@pytest.fixture(autouse=True)
def isolated_audiobooks_dir(monkeypatch) -> Iterator[str]:
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


@pytest.fixture(autouse=True)
def clear_overrides() -> Iterator[None]:
    yield
    app.dependency_overrides.pop(web_fetcher, None)


async def _chunks(body: bytes) -> AsyncIterator[bytes]:
    yield body


def _respond(
    body: bytes, content_type: str = "text/html; charset=utf-8", status: int = 200
) -> httpx.Response:
    return httpx.Response(
        status, headers={"content-type": content_type}, content=_chunks(body)
    )


def _serve(handler: Handler, table: dict[str, list[str]] | None = None) -> list:
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    async def resolve(host: str, port: int) -> list[str]:
        return (table or {}).get(host, ["93.184.216.34"])

    app.dependency_overrides[web_fetcher] = lambda: WebFetcher(
        transport=httpx.MockTransport(record), resolver=resolve
    )
    return seen


def _forbid_network() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        raise AssertionError("no network access expected")

    _serve(handler)


def _client() -> TestClient:
    return TestClient(app)


def _staged_leftovers(root: str) -> list[str]:
    return [name for name in os.listdir(root) if name.startswith(".upload-")]


def test_every_failure_code_has_an_http_status() -> None:
    assert set(ARTICLE_ERROR_STATUS) == set(ArticleFailure)


def test_extract_returns_readable_article() -> None:
    seen = _serve(lambda _r: _respond(NEWS))
    response = _client().post(
        "/article/extract", json={"url": "https://coastalherald.example/bridge"}
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["url"] == "https://coastalherald.example/bridge"
    assert body["title"] == "Harbour bridge reopens after two years of repairs"
    assert body["byline"] == "Priya Natarajan"
    assert body["site_name"] == "The Coastal Herald"
    assert body["language"] == "en-gb"
    assert body["word_count"] == len(body["text"].split())
    assert body["markdown"].startswith("# Harbour bridge")
    assert "COOKIE_TEXT" not in body["text"]
    assert seen[0].headers["host"] == "coastalherald.example"


def test_extract_reports_final_url_after_redirect() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/short":
            return httpx.Response(301, headers={"location": "/long/story"})
        return _respond(NEWS)

    _serve(handler)
    response = _client().post(
        "/article/extract", json={"url": "https://a.example/short"}
    )
    assert response.json()["url"] == "https://a.example/long/story"


def test_extract_plain_text_page() -> None:
    _serve(lambda _r: _respond((PROSE * 3).encode(), "text/plain"))
    response = _client().post(
        "/article/extract", json={"url": "https://a.example/notes.txt"}
    )
    assert response.status_code == 200
    assert response.json()["title"] == "notes"


@pytest.mark.parametrize(
    ("url", "handler", "status", "code"),
    [
        ("http://127.0.0.1:8080/", None, 403, "blocked_address"),
        ("http://[::ffff:192.168.0.1]/", None, 403, "blocked_address"),
        ("https://intranet.example/", None, 403, "blocked_address"),
        ("ftp://a.example/", None, 422, "invalid_url"),
        ("https://user:pw@a.example/", None, 422, "invalid_url"),
        (
            "https://a.example/",
            lambda _r: httpx.Response(402),
            422,
            "paywalled",
        ),
        ("https://a.example/", lambda _r: httpx.Response(404), 502, "not_found"),
        ("https://a.example/", lambda _r: httpx.Response(500), 502, "http_error"),
        (
            "https://a.example/",
            lambda _r: _respond(b"\x89PNG", "image/png"),
            415,
            "unsupported_type",
        ),
        (
            "https://a.example/",
            lambda _r: _respond(b"%PDF-1.4 body", "application/pdf"),
            415,
            "pdf_document",
        ),
        (
            "https://a.example/",
            lambda _r: httpx.Response(
                200,
                headers={"content-type": "text/html", "content-length": "99999999"},
                content=_chunks(b""),
            ),
            413,
            "too_large",
        ),
        (
            "https://a.example/",
            lambda _r: _respond(b"<html><body><nav>Home</nav></body></html>"),
            422,
            "no_readable_content",
        ),
        (
            "https://a.example/",
            lambda _r: _respond((FIXTURES / "paywall.html").read_bytes()),
            422,
            "paywalled",
        ),
    ],
)
def test_extract_errors_have_status_code_and_safe_detail(
    url: str, handler: Handler | None, status: int, code: str
) -> None:
    def refuse(_request: httpx.Request) -> httpx.Response:
        raise AssertionError("blocked or invalid URLs must not be fetched")

    _serve(handler or refuse, {"intranet.example": ["10.1.2.3"]})
    response = _client().post("/article/extract", json={"url": url})

    assert response.status_code == status, response.text
    body = response.json()
    assert body["code"] == code
    assert isinstance(body["detail"], str) and body["detail"]
    assert "Traceback" not in body["detail"]


def test_extract_timeout_is_504() -> None:
    def handler(_request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow upstream at 10.0.0.1")

    _serve(handler)
    response = _client().post("/article/extract", json={"url": "https://a.example/"})
    assert response.status_code == 504
    assert response.json()["code"] == "timeout"
    assert "10.0.0.1" not in response.text


def test_extract_busy_is_429(monkeypatch) -> None:
    _forbid_network()
    monkeypatch.setattr(WebFetcher, "_active", MAX_CONCURRENT_FETCHES)
    response = _client().post("/article/extract", json={"url": "https://a.example/"})
    assert response.status_code == 429
    assert response.json()["code"] == "busy"


@pytest.mark.parametrize(
    "payload",
    [{}, {"url": ""}, {"url": "https://a.example/" + "a" * 2100}, {"url": 5}],
)
def test_extract_request_validation(payload: dict) -> None:
    _forbid_network()
    assert _client().post("/article/extract", json=payload).status_code == 422


def test_extractor_crash_returns_curated_error(monkeypatch) -> None:
    def explode(*_args):
        raise RuntimeError("/Users/someone/secret/path")

    monkeypatch.setattr("app.services.article_reader.extract_html", explode)
    _serve(lambda _r: _respond(NEWS))
    response = _client().post("/article/extract", json={"url": "https://a.example/"})
    assert response.status_code == 422
    assert response.json()["code"] == "no_readable_content"
    assert "secret" not in response.text


def test_extract_html_needs_no_network() -> None:
    _forbid_network()
    response = _client().post(
        "/article/extract-html",
        json={"url": "https://coastalherald.example/bridge#x", "html": NEWS.decode()},
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["url"] == "https://coastalherald.example/bridge"
    assert body["site_name"] == "The Coastal Herald"
    assert body["title"].startswith("Harbour bridge")


def test_extract_html_uses_url_for_site_name() -> None:
    html = f"<html><body><p>{PROSE * 3}</p></body></html>"
    response = _client().post(
        "/article/extract-html",
        json={"url": "https://www.blog.example/p", "html": html},
    )
    assert response.json()["site_name"] == "blog.example"


def test_extract_html_allows_private_page_urls_because_nothing_is_fetched() -> None:
    html = f"<html><body><p>{PROSE * 3}</p></body></html>"
    response = _client().post(
        "/article/extract-html",
        json={"url": "http://intranet.local/wiki", "html": html},
    )
    assert response.status_code == 200


def test_extract_html_rejects_bad_url_with_code() -> None:
    response = _client().post(
        "/article/extract-html", json={"url": "javascript:alert(1)", "html": "<p>x</p>"}
    )
    assert response.status_code == 422
    assert response.json()["code"] == "invalid_url"


def test_extract_html_rejects_more_than_five_megabytes() -> None:
    multibyte = "é" * (MAX_ARTICLE_HTML_BYTES // 2 + 10)
    response = _client().post(
        "/article/extract-html", json={"url": "https://a.example/", "html": multibyte}
    )
    assert response.status_code == 413
    assert response.json()["code"] == "too_large"


@pytest.mark.parametrize(
    "payload",
    [
        {"url": "https://a.example/"},
        {"html": "<p>x</p>"},
        {"url": "https://a.example/", "html": ""},
        {"url": "https://a.example/", "html": "x" * (MAX_ARTICLE_HTML_BYTES + 1)},
    ],
)
def test_extract_html_request_validation(payload: dict) -> None:
    assert _client().post("/article/extract-html", json=payload).status_code == 422


def test_extract_html_empty_content_is_422() -> None:
    response = _client().post(
        "/article/extract-html",
        json={"url": "https://a.example/", "html": "<html><body></body></html>"},
    )
    assert response.status_code == 422
    assert response.json()["code"] == "no_readable_content"


def test_article_routes_keep_the_ipc_token_gate() -> None:
    unauthenticated = TestClient(app, headers={"X-Voqora-IPC-Token": "wrong"})
    for path in ("/article/extract", "/article/extract-html", "/audiobook/url"):
        assert unauthenticated.post(path, json={}).status_code == 401
    browser = TestClient(app, headers={"Origin": "https://evil.example"})
    assert browser.post("/article/extract", json={}).status_code == 403


def test_module_exposes_router() -> None:
    assert any(route.path == "/article/extract" for route in article_api.router.routes)


# ---------- /audiobook/url ----------


def test_audiobook_from_article_uses_markdown_path(isolated_audiobooks_dir) -> None:
    _serve(lambda _r: _respond(NEWS))
    response = _client().post(
        "/audiobook/url",
        json={
            "url": "https://coastalherald.example/bridge",
            "voice": "bf_emma",
            "speed": 1.25,
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["title"] == "Harbour bridge reopens after two years of repairs"
    assert body["page_count"] >= 1
    assert body["word_count_estimate"] > 0
    assert body["is_image_only"] is False
    assert body["duplicate_of_book_id"] is None
    meta = AudiobookStore.read_meta(body["book_id"])
    assert meta["file_ext"] == "md"
    assert meta["source_url"] == "https://coastalherald.example/bridge"
    assert meta["voice"] == "bf_emma"
    assert meta["speed"] == 1.25
    source = AudiobookStore.source_file_path(body["book_id"], "md")
    with open(source, encoding="utf-8") as file:
        assert file.read().startswith("# Harbour bridge reopens")
    outline = TextExtractor.read_outline(source)
    assert [heading["title"] for heading in outline][-1] == "A long road to reopening"
    assert _staged_leftovers(isolated_audiobooks_dir) == []


def test_same_article_twice_is_flagged_as_duplicate() -> None:
    _serve(lambda _r: _respond(NEWS))
    first = _client().post("/audiobook/url", json={"url": "https://a.example/b"})
    second = _client().post("/audiobook/url", json={"url": "https://a.example/b"})
    assert second.json()["duplicate_of_book_id"] == first.json()["book_id"]


def test_audiobook_from_plain_text_link() -> None:
    _serve(lambda _r: _respond((PROSE * 4).encode(), "text/plain"))
    response = _client().post(
        "/audiobook/url", json={"url": "https://a.example/field-notes.txt"}
    )
    assert response.status_code == 200, response.text
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["file_ext"] == "txt"
    assert meta["title"] == "field notes"


def test_audiobook_from_pdf_link_routes_to_pdf_path(monkeypatch) -> None:
    from app.services import pdf_extractor as pe

    monkeypatch.setattr(pe.PDFExtractor, "page_count", classmethod(lambda c, p: 2))
    monkeypatch.setattr(
        pe.PDFExtractor, "is_image_only", classmethod(lambda c, p: False)
    )
    monkeypatch.setattr(
        pe.PDFExtractor, "sample_word_count", classmethod(lambda c, p: 100)
    )
    monkeypatch.setattr(
        pe.PDFExtractor, "sample_char_count", classmethod(lambda c, p: 500)
    )
    monkeypatch.setattr(pe.PDFExtractor, "render_cover", classmethod(lambda c, b: None))
    pdf = b"%PDF-1.4\n" + b"x" * 200
    _serve(lambda _r: _respond(pdf, "application/pdf"))

    response = _client().post(
        "/audiobook/url", json={"url": "https://a.example/papers/Annual%20Report.pdf"}
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["title"] == "Annual Report"
    assert body["page_count"] == 2
    assert body["word_count_estimate"] == 200
    meta = AudiobookStore.read_meta(body["book_id"])
    assert meta["file_ext"] == "pdf"
    with open(AudiobookStore.source_file_path(body["book_id"], "pdf"), "rb") as file:
        assert file.read() == pdf


def test_tiny_pdf_link_is_rejected_like_an_upload() -> None:
    _serve(lambda _r: _respond(b"%PDF-1.4", "application/pdf"))
    response = _client().post("/audiobook/url", json={"url": "https://a.example/x.pdf"})
    assert response.status_code == 400
    assert AudiobookStore.list_books() == []


@pytest.mark.parametrize(
    ("url", "status", "code"),
    [
        ("http://localhost/", 403, "blocked_address"),
        ("http://169.254.169.254/latest/meta-data/", 403, "blocked_address"),
        ("mailto:someone@example.com", 422, "invalid_url"),
    ],
)
def test_audiobook_url_failures_create_no_book(
    url: str, status: int, code: str, isolated_audiobooks_dir
) -> None:
    _serve(lambda _r: _respond(NEWS), {"localhost": ["127.0.0.1"]})
    response = _client().post("/audiobook/url", json={"url": url})
    assert response.status_code == status
    assert response.json()["code"] == code
    assert AudiobookStore.list_books() == []
    assert _staged_leftovers(isolated_audiobooks_dir) == []


def test_audiobook_url_unreadable_article_creates_no_book() -> None:
    _serve(lambda _r: _respond(b"<html><body><p>Too short.</p></body></html>"))
    response = _client().post("/audiobook/url", json={"url": "https://a.example/"})
    assert response.status_code == 422
    assert response.json()["code"] == "no_readable_content"
    assert AudiobookStore.list_books() == []


@pytest.mark.parametrize(
    "payload",
    [
        {"url": "https://a.example/", "voice": "nobody"},
        {"url": "https://a.example/", "speed": 9.0},
        {"url": "https://a.example/", "speed": 0.1},
        {"url": "https://a.example/", "engine": "other"},
        {"url": "https://a.example/", "voice": "v" * 65},
        {"url": "https://a.example/", "llm_model": "m" * 201},
        {"url": "https://a.example/" + "a" * 2100},
        {"voice": "af_bella"},
    ],
)
def test_audiobook_url_validates_settings_before_fetching(payload: dict) -> None:
    _forbid_network()
    response = _client().post("/audiobook/url", json=payload)
    assert response.status_code == 422
    assert AudiobookStore.list_books() == []


def test_audiobook_url_rejects_unknown_provider_before_fetching() -> None:
    _forbid_network()
    response = _client().post(
        "/audiobook/url", json={"url": "https://a.example/", "llm_provider": "nope"}
    )
    assert response.status_code == 400


def test_audiobook_url_reports_provider_pricing() -> None:
    _serve(lambda _r: _respond(NEWS))
    response = _client().post(
        "/audiobook/url", json={"url": "https://a.example/", "llm_provider": "openai"}
    )
    assert response.status_code == 200, response.text
    assert response.json()["llm_provider"] == "openai"


def test_audiobook_url_staging_failure_is_curated(
    monkeypatch, isolated_audiobooks_dir
) -> None:
    def fail(*_args):
        raise OSError("disk full at /Users/someone")

    monkeypatch.setattr("app.api.audiobook._stage_bytes", fail)
    _serve(lambda _r: _respond(NEWS))
    response = _client().post("/audiobook/url", json={"url": "https://a.example/"})
    assert response.status_code == 500
    assert response.json()["detail"] == "Couldn't add this page. Please try again."
    assert AudiobookStore.list_books() == []


def test_audiobook_url_unexpected_import_failure_cleans_up(
    monkeypatch, isolated_audiobooks_dir
) -> None:
    def explode(*_args, **_kwargs):
        raise RuntimeError("estimate exploded")

    monkeypatch.setattr("app.api.audiobook.AudiobookService.estimate", explode)
    _serve(lambda _r: _respond(NEWS))
    response = _client().post("/audiobook/url", json={"url": "https://a.example/"})
    assert response.status_code == 500
    assert "exploded" not in response.text
    assert AudiobookStore.list_books() == []
    assert [
        name
        for name in os.listdir(isolated_audiobooks_dir)
        if not name.startswith("audiobooks.db")
    ] == []


def test_upload_unexpected_failure_still_returns_curated_500(monkeypatch) -> None:
    def explode(*_args, **_kwargs):
        raise RuntimeError("estimate exploded")

    monkeypatch.setattr("app.api.audiobook.AudiobookService.estimate", explode)
    response = _client().post(
        "/audiobook", files={"file": ("note.txt", (PROSE * 3).encode(), "text/plain")}
    )
    assert response.status_code == 500
    assert response.json()["detail"] == "Upload failed. Please try again."
    assert AudiobookStore.list_books() == []


def test_upload_staging_failure_returns_curated_500(monkeypatch) -> None:
    def fail(*_args):
        raise OSError("no space")

    monkeypatch.setattr("app.api.audiobook._new_staging_file", fail)
    response = _client().post(
        "/audiobook", files={"file": ("note.txt", b"hello there", "text/plain")}
    )
    assert response.status_code == 500
    assert response.json()["detail"] == "Upload failed. Please try again."
