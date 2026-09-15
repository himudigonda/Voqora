"""Shared backend-test transport setup.

Lives at the backend/ root (not backend/tests/) so it applies to every test
root — backend/tests/ and backend/benchmarks/ alike, including a `pytest
benchmarks/`-only invocation that never collects backend/tests/.

The release backend correctly rejects clients that omit its per-launch IPC
token. Existing route tests use Starlette's TestClient, so install the same
test-only token on every client unless a test deliberately supplies a value.
"""

import os

from fastapi.testclient import TestClient

TEST_IPC_TOKEN = "voqora-test-ipc-token"
os.environ.setdefault("VOQORA_IPC_TOKEN", TEST_IPC_TOKEN)

_original_init = TestClient.__init__


def _authenticated_init(self, app, *args, headers=None, **kwargs):
    merged_headers = {"X-Voqora-IPC-Token": TEST_IPC_TOKEN}
    if headers:
        merged_headers.update(headers)
    _original_init(self, app, *args, headers=merged_headers, **kwargs)


TestClient.__init__ = _authenticated_init
