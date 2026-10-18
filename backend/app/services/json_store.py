"""Small atomic JSON document persistence for user preferences."""

from __future__ import annotations

import json
import os
import tempfile
from collections.abc import Callable
from typing import Any

from app.core.logging import get_logger

log = get_logger(__name__)

_MAX_DOCUMENT_BYTES = 4 * 1024 * 1024


class JsonDocument:
    def __init__(self, path_provider: Callable[[], str], name: str) -> None:
        self._path_provider = path_provider
        self._name = name

    @property
    def path(self) -> str:
        return self._path_provider()

    def load(self) -> dict[str, Any]:
        path = self.path
        try:
            if os.path.getsize(path) > _MAX_DOCUMENT_BYTES:
                raise ValueError("document too large")
            with open(path, encoding="utf-8") as handle:
                payload = json.load(handle)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            log.warning(
                "json_store.load_failed",
                extra={"store": self._name, "failure_code": "store_load_failed"},
                exc_info=True,
            )
            return {}
        if not isinstance(payload, dict):
            log.warning(
                "json_store.load_failed",
                extra={"store": self._name, "failure_code": "store_shape_invalid"},
            )
            return {}
        return payload

    def save(self, payload: dict[str, Any]) -> None:
        path = self.path
        directory = os.path.dirname(path)
        os.makedirs(directory, exist_ok=True)
        descriptor, tmp_path = tempfile.mkstemp(
            prefix=f".{os.path.basename(path)}.", suffix=".tmp", dir=directory
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp_path, path)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except FileNotFoundError:
                pass
            raise
