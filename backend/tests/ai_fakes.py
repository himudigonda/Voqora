from __future__ import annotations

import asyncio
import json
import os
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from app.services.audiobook_store import AudiobookStore
from app.services.llm_cleaner import GeneratedText, LLMCleaner, LLMUsage

OPENAI_HEADERS = {
    "X-Voqora-LLM-Provider": "openai",
    "X-Voqora-LLM-Key": "sk-test-secret-key-123456",
}


@dataclass
class Call:
    system: str
    user: str
    max_output_tokens: int
    json_output: bool


Reply = str | BaseException | GeneratedText
Handler = Callable[[Call, int], Reply]


class FakeLLM:
    def __init__(
        self,
        handler: Handler,
        *,
        delay_s: float = 0.0,
        usage: tuple[int, int] | None = (100, 20),
    ) -> None:
        self.handler = handler
        self.delay_s = delay_s
        self.usage = usage
        self.calls: list[Call] = []
        self.active = 0
        self.peak = 0

    async def __call__(
        self,
        credential: Any,
        system: str,
        text: str,
        *,
        max_output_tokens: int,
        json_output: bool = False,
    ) -> GeneratedText:
        call = Call(system, text, max_output_tokens, json_output)
        self.calls.append(call)
        self.active += 1
        self.peak = max(self.peak, self.active)
        try:
            await asyncio.sleep(self.delay_s)
            reply = self.handler(call, len(self.calls))
        finally:
            self.active -= 1
        if isinstance(reply, BaseException):
            raise reply
        if isinstance(reply, GeneratedText):
            return reply
        usage = (
            LLMUsage(
                self.usage[0],
                self.usage[1],
                "standard",
                credential.provider,
                credential.resolved_model,
            )
            if self.usage
            else None
        )
        return GeneratedText(reply, usage)


def install(monkeypatch: Any, fake: FakeLLM) -> FakeLLM:
    monkeypatch.setattr(LLMCleaner, "generate", staticmethod(fake))
    return fake


def reply(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def make_book(
    pages: list[str],
    *,
    sections: list[dict[str, Any]] | None = None,
    clean: bool = True,
    title: str = "Book.txt",
) -> str:
    book_id = AudiobookStore.create_book(title)
    meta = AudiobookStore.initial_meta(
        book_id, title, len(pages), "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
    )
    meta["sections"] = sections or []
    AudiobookStore.write_meta(book_id, meta)
    for number, text in enumerate(pages, start=1):
        path = (
            AudiobookStore.page_clean_path(book_id, number)
            if clean
            else AudiobookStore.page_raw_path(book_id, number)
        )
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    return book_id
