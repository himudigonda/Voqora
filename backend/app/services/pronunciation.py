"""User pronunciation dictionary applied to text right before phonemization."""

from __future__ import annotations

import re
import threading
import unicodedata
import uuid
from collections import OrderedDict
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from typing import Any

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audiobook_store import _now_iso
from app.services.json_store import JsonDocument

log = get_logger(__name__)

SCOPE_GLOBAL = "global"
MAX_ENTRIES = 500
MAX_MATCH_CHARS = 100
MAX_REPLACEMENT_CHARS = 200
MAX_SPOKEN_CHARS = 20_000

_BOOK_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_ENTRY_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_SCHEMA_VERSION = 1
_MAX_CACHED_RULES = 32


class PronunciationLimitError(Exception):
    pass


class PronunciationNotFoundError(Exception):
    pass


class DuplicatePronunciationError(Exception):
    pass


@dataclass(frozen=True)
class PronunciationEntry:
    id: str
    match: str
    replacement: str
    case_sensitive: bool
    whole_word: bool
    scope: str
    created_at: str
    updated_at: str

    def identity(self) -> tuple[str, str, bool, bool]:
        key = self.match if self.case_sensitive else self.match.casefold()
        return (self.scope, key, self.case_sensitive, self.whole_word)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "match": self.match,
            "replacement": self.replacement,
            "case_sensitive": self.case_sensitive,
            "whole_word": self.whole_word,
            "scope": self.scope,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


def is_entry_id(value: str) -> bool:
    return bool(_ENTRY_ID_RE.fullmatch(value))


def is_book_scope(scope: str) -> bool:
    return bool(_BOOK_ID_RE.fullmatch(scope))


def validate_scope(scope: str) -> str:
    if scope != SCOPE_GLOBAL and not is_book_scope(scope):
        raise ValueError("scope must be 'global' or a book id")
    return scope


def _validate_text(value: str, *, label: str, minimum: int, maximum: int) -> str:
    cleaned = unicodedata.normalize("NFC", value).strip()
    if not minimum <= len(cleaned) <= maximum:
        raise ValueError(f"{label} must be {minimum} to {maximum} characters")
    if any(unicodedata.category(ch) in {"Cc", "Cf", "Zl", "Zp"} for ch in cleaned):
        raise ValueError(f"{label} must not contain control characters")
    return cleaned


def validate_match(value: str) -> str:
    return _validate_text(value, label="match", minimum=1, maximum=MAX_MATCH_CHARS)


def validate_replacement(value: str) -> str:
    return _validate_text(
        value, label="replacement", minimum=0, maximum=MAX_REPLACEMENT_CHARS
    )


def _entry_pattern(entry: PronunciationEntry) -> str:
    body = re.escape(entry.match)
    if entry.whole_word:
        body = rf"(?<!\w){body}(?!\w)"
    if not entry.case_sensitive:
        body = f"(?i:{body})"
    return f"({body})"


class _RulePass:
    def __init__(self, entries: Sequence[PronunciationEntry]) -> None:
        ordered = sorted(entries, key=lambda entry: -len(entry.match))
        self._replacements = tuple(entry.replacement for entry in ordered)
        self._pattern = (
            re.compile("|".join(_entry_pattern(entry) for entry in ordered))
            if ordered
            else None
        )

    def apply(self, text: str) -> tuple[str, int]:
        if self._pattern is None:
            return text, 0
        return self._pattern.subn(self._replace, text)

    def _replace(self, match: re.Match[str]) -> str:
        return self._replacements[(match.lastindex or 1) - 1]


class PronunciationRules:
    def __init__(
        self, version: int, passes: Sequence[Sequence[PronunciationEntry]]
    ) -> None:
        self.version = version
        self._passes = tuple(_RulePass(entries) for entries in passes if entries)

    @property
    def is_empty(self) -> bool:
        return not self._passes

    def apply(self, text: str) -> str:
        return self.apply_counted(text)[0]

    def apply_counted(self, text: str) -> tuple[str, int]:
        if not self._passes:
            return text, 0
        spoken = unicodedata.normalize("NFC", text)
        total = 0
        for rule_pass in self._passes:
            spoken, count = rule_pass.apply(spoken)
            total += count
            if len(spoken) > MAX_SPOKEN_CHARS:
                log.warning(
                    "pronunciation.expansion_capped",
                    extra={
                        "segment_chars": len(text),
                        "failure_code": "pronunciation_expansion_capped",
                    },
                )
                return text, 0
        return spoken, total


EMPTY_RULES = PronunciationRules(0, ())


def _entry_from_record(record: Any) -> PronunciationEntry:
    if not isinstance(record, dict):
        raise ValueError("record must be an object")
    entry_id = str(record.get("id", ""))
    if not is_entry_id(entry_id):
        raise ValueError("invalid entry id")
    case_sensitive = record.get("case_sensitive", False)
    whole_word = record.get("whole_word", True)
    if not isinstance(case_sensitive, bool) or not isinstance(whole_word, bool):
        raise ValueError("flags must be booleans")
    return PronunciationEntry(
        id=entry_id,
        match=validate_match(str(record.get("match", ""))),
        replacement=validate_replacement(str(record.get("replacement", ""))),
        case_sensitive=case_sensitive,
        whole_word=whole_word,
        scope=validate_scope(str(record.get("scope", ""))),
        created_at=str(record.get("created_at", "")),
        updated_at=str(record.get("updated_at", "")),
    )


@dataclass(frozen=True)
class _State:
    version: int
    entries: dict[str, PronunciationEntry]


class PronunciationStore:
    def __init__(self, path_provider: Callable[[], str]) -> None:
        self._document = JsonDocument(path_provider, "pronunciations")
        self._lock = threading.RLock()
        self._state: _State | None = None
        self._rules: OrderedDict[tuple[int, str | None], PronunciationRules] = (
            OrderedDict()
        )

    def reset(self) -> None:
        with self._lock:
            self._state = None
            self._rules.clear()

    @property
    def version(self) -> int:
        with self._lock:
            return self._loaded().version

    def list(self, scope: str | None = None) -> list[PronunciationEntry]:
        with self._lock:
            entries = self._loaded().entries.values()
            return [e for e in entries if scope is None or e.scope == scope]

    def get(self, entry_id: str) -> PronunciationEntry | None:
        with self._lock:
            return self._loaded().entries.get(entry_id)

    def create(
        self,
        *,
        match: str,
        replacement: str,
        case_sensitive: bool,
        whole_word: bool,
        scope: str,
    ) -> PronunciationEntry:
        now = _now_iso()
        entry = PronunciationEntry(
            id=uuid.uuid4().hex,
            match=validate_match(match),
            replacement=validate_replacement(replacement),
            case_sensitive=case_sensitive,
            whole_word=whole_word,
            scope=validate_scope(scope),
            created_at=now,
            updated_at=now,
        )
        with self._lock:
            state = self._loaded()
            if len(state.entries) >= MAX_ENTRIES:
                raise PronunciationLimitError(
                    f"You can save up to {MAX_ENTRIES} pronunciations."
                )
            self._ensure_unique(state, entry)
            self._commit(state, {**state.entries, entry.id: entry})
            return entry

    def update(
        self,
        entry_id: str,
        *,
        match: str,
        replacement: str,
        case_sensitive: bool,
        whole_word: bool,
        scope: str,
    ) -> PronunciationEntry:
        validated = {
            "match": validate_match(match),
            "replacement": validate_replacement(replacement),
            "case_sensitive": case_sensitive,
            "whole_word": whole_word,
            "scope": validate_scope(scope),
        }
        with self._lock:
            state = self._loaded()
            current = state.entries.get(entry_id)
            if current is None:
                raise PronunciationNotFoundError(entry_id)
            entry = replace(current, **validated, updated_at=_now_iso())
            self._ensure_unique(state, entry)
            self._commit(state, {**state.entries, entry.id: entry})
            return entry

    def delete(self, entry_id: str) -> bool:
        with self._lock:
            state = self._loaded()
            if entry_id not in state.entries:
                return False
            self._commit(
                state, {k: v for k, v in state.entries.items() if k != entry_id}
            )
            return True

    def delete_scope(self, scope: str) -> int:
        return self._delete_where(lambda entry: entry.scope == scope)

    def delete_book_scopes(self) -> int:
        return self._delete_where(lambda entry: entry.scope != SCOPE_GLOBAL)

    def rules_for(self, book_id: str | None = None) -> PronunciationRules:
        with self._lock:
            state = self._loaded()
            key = (state.version, book_id)
            cached = self._rules.get(key)
            if cached is not None:
                self._rules.move_to_end(key)
                return cached
            global_entries = [
                e for e in state.entries.values() if e.scope == SCOPE_GLOBAL
            ]
            book_entries = (
                [e for e in state.entries.values() if e.scope == book_id]
                if book_id is not None and is_book_scope(book_id)
                else []
            )
            rules = PronunciationRules(state.version, (global_entries, book_entries))
            self._rules[key] = rules
            while len(self._rules) > _MAX_CACHED_RULES:
                self._rules.popitem(last=False)
            return rules

    def _delete_where(self, predicate: Callable[[PronunciationEntry], bool]) -> int:
        with self._lock:
            state = self._loaded()
            kept = {k: v for k, v in state.entries.items() if not predicate(v)}
            removed = len(state.entries) - len(kept)
            if removed:
                self._commit(state, kept)
            return removed

    @staticmethod
    def _ensure_unique(state: _State, entry: PronunciationEntry) -> None:
        identity = entry.identity()
        if any(
            other.id != entry.id and other.identity() == identity
            for other in state.entries.values()
        ):
            raise DuplicatePronunciationError(
                "A pronunciation for this text already exists in this scope."
            )

    def _loaded(self) -> _State:
        if self._state is None:
            self._state = self._read()
        return self._state

    def _read(self) -> _State:
        payload = self._document.load()
        entries: dict[str, PronunciationEntry] = {}
        skipped = 0
        for record in payload.get("entries") or []:
            try:
                entry = _entry_from_record(record)
            except (TypeError, ValueError):
                skipped += 1
                continue
            if entry.id in entries or len(entries) >= MAX_ENTRIES:
                skipped += 1
                continue
            entries[entry.id] = entry
        if skipped:
            log.warning(
                "pronunciation.records_skipped",
                extra={
                    "skipped": skipped,
                    "failure_code": "pronunciation_record_invalid",
                },
            )
        version = payload.get("version", 0)
        if not isinstance(version, int) or version < 0:
            version = 0
        return _State(version=version, entries=entries)

    def _commit(self, state: _State, entries: dict[str, PronunciationEntry]) -> None:
        version = state.version + 1
        self._document.save(
            {
                "schema": _SCHEMA_VERSION,
                "version": version,
                "entries": [entry.to_dict() for entry in entries.values()],
            }
        )
        self._state = _State(version=version, entries=entries)


pronunciations = PronunciationStore(lambda: settings.PRONUNCIATIONS_PATH)
