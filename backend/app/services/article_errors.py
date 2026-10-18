"""Typed, user-safe failures for reading web articles."""

from __future__ import annotations

from enum import StrEnum


class ArticleFailure(StrEnum):
    INVALID_URL = "invalid_url"
    BLOCKED_ADDRESS = "blocked_address"
    UNREACHABLE = "unreachable"
    TIMEOUT = "timeout"
    TOO_MANY_REDIRECTS = "too_many_redirects"
    HTTP_ERROR = "http_error"
    NOT_FOUND = "not_found"
    PAYWALLED = "paywalled"
    UNSUPPORTED_TYPE = "unsupported_type"
    PDF_DOCUMENT = "pdf_document"
    TOO_LARGE = "too_large"
    NO_READABLE_CONTENT = "no_readable_content"
    BUSY = "busy"


class ArticleError(Exception):
    """A rejection whose message is safe to show the user verbatim."""

    def __init__(self, code: ArticleFailure, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
