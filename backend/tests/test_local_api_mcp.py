"""MCP over Streamable HTTP: handshake, negotiation, tools, JSON-RPC errors."""

from __future__ import annotations

import json
from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.api.public_app import create_public_app
from app.core.config import settings
from app.services.mcp_server import (
    INTERNAL_ERROR,
    INVALID_PARAMS,
    INVALID_REQUEST,
    LATEST_PROTOCOL_VERSION,
    METHOD_NOT_FOUND,
    PARSE_ERROR,
    SUPPORTED_PROTOCOL_VERSIONS,
    McpServer,
    McpSession,
    McpSessions,
    McpTool,
    NoArguments,
)
from app.services.speech_relay import speech_relay

API_KEY = "test-local-api-key-0123456789abcdef"
HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Accept": "application/json, text/event-stream",
}


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_public_app(API_KEY), headers=HEADERS)


@pytest.fixture(autouse=True)
def clean_relay() -> Iterator[None]:
    speech_relay.close_all()
    yield
    speech_relay.close_all()


def _rpc(client: TestClient, method: str, params: dict | None = None, rid=1):
    message = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params is not None:
        message["params"] = params
    return client.post("/mcp", json=message)


def _call(client: TestClient, name: str, arguments: dict | None = None) -> dict:
    params: dict = {"name": name}
    if arguments is not None:
        params["arguments"] = arguments
    response = _rpc(client, "tools/call", params)
    assert response.status_code == 200
    return response.json()["result"]


def test_initialize_echoes_supported_version(client: TestClient) -> None:
    for version in SUPPORTED_PROTOCOL_VERSIONS:
        response = _rpc(
            client,
            "initialize",
            {
                "protocolVersion": version,
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1"},
            },
        )
        assert response.status_code == 200
        body = response.json()
        assert body["jsonrpc"] == "2.0"
        assert body["id"] == 1
        result = body["result"]
        assert result["protocolVersion"] == version
        assert result["capabilities"] == {"tools": {"listChanged": False}}
        assert result["serverInfo"]["name"] == "voqora"
        assert result["serverInfo"]["version"] == settings.VERSION
        assert result["instructions"]


def test_initialize_offers_latest_for_unknown_version(client: TestClient) -> None:
    response = _rpc(client, "initialize", {"protocolVersion": "1999-01-01"})
    assert response.json()["result"]["protocolVersion"] == LATEST_PROTOCOL_VERSION


def test_initialize_requires_protocol_version(client: TestClient) -> None:
    response = _rpc(client, "initialize", {})
    assert response.json()["error"]["code"] == INVALID_PARAMS


def test_initialized_notification_is_accepted(client: TestClient) -> None:
    response = client.post(
        "/mcp", json={"jsonrpc": "2.0", "method": "notifications/initialized"}
    )
    assert response.status_code == 202
    assert response.content == b""


def test_client_response_is_accepted(client: TestClient) -> None:
    response = client.post("/mcp", json={"jsonrpc": "2.0", "id": 9, "result": {}})
    assert response.status_code == 202


def test_ping(client: TestClient) -> None:
    body = _rpc(client, "ping", rid="abc").json()
    assert body == {"jsonrpc": "2.0", "id": "abc", "result": {}}


def test_tools_list_declares_schemas(client: TestClient) -> None:
    tools = _rpc(client, "tools/list").json()["result"]["tools"]
    by_name = {tool["name"]: tool for tool in tools}
    assert set(by_name) == {"speak", "stop", "list_voices"}
    speak = by_name["speak"]["inputSchema"]
    assert speak["type"] == "object"
    assert speak["required"] == ["text"]
    assert speak["additionalProperties"] is False
    assert speak["properties"]["text"]["maxLength"] == 50_000
    assert speak["properties"]["text"]["minLength"] == 1
    assert "voice" in speak["properties"]
    for name in ("stop", "list_voices"):
        schema = by_name[name]["inputSchema"]
        assert schema["type"] == "object"
        assert schema["additionalProperties"] is False
        assert schema.get("properties", {}) == {}
    assert by_name["list_voices"]["annotations"]["readOnlyHint"] is True
    for tool in tools:
        assert tool["description"]
        assert tool["title"]


def test_speak_tool_without_app_is_tool_error(client: TestClient) -> None:
    result = _call(client, "speak", {"text": "Hello"})
    assert result["isError"] is True
    assert "not listening" in result["content"][0]["text"]


def test_speak_tool_queues_for_app(client: TestClient) -> None:
    queue = speech_relay.subscribe()
    result = _call(client, "speak", {"text": "Hello **there**", "voice": "nova"})
    assert result["isError"] is False
    event = queue.get_nowait()
    assert event["type"] == "speak"
    assert event["text"] == "Hello there"
    assert event["voice"] == "af_bella"


def test_speak_tool_forwards_the_mode(client: TestClient) -> None:
    queue = speech_relay.subscribe()
    _call(client, "speak", {"text": "one"})
    _call(client, "speak", {"text": "two", "mode": "queue"})
    assert queue.get_nowait()["mode"] == "replace"
    assert queue.get_nowait()["mode"] == "queue"


def _initialize(client: TestClient, info: object) -> str:
    response = _rpc(
        client,
        "initialize",
        {"protocolVersion": LATEST_PROTOCOL_VERSION, "clientInfo": info},
    )
    assert response.status_code == 200
    return response.headers["mcp-session-id"]


def _speak_in(client: TestClient, session_id: str | None) -> dict:
    headers = {} if session_id is None else {"Mcp-Session-Id": session_id}
    message = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": "speak", "arguments": {"text": "Hi"}},
    }
    response = client.post("/mcp", json=message, headers=headers)
    assert response.json()["result"]["isError"] is False
    assert "mcp-session-id" not in response.headers
    return response.json()


def test_speak_tool_names_the_client_of_its_session(client: TestClient) -> None:
    queue = speech_relay.subscribe()
    session_id = _initialize(client, {"name": " Claude\nDesktop ", "version": "1"})
    _speak_in(client, session_id)
    assert queue.get_nowait()["client"] == "Claude Desktop"


@pytest.mark.parametrize("session_id", [None, "unknown-session"])
def test_speak_tool_without_a_known_session_has_no_client(
    client: TestClient, session_id: str | None
) -> None:
    queue = speech_relay.subscribe()
    _initialize(client, {"name": "Cursor", "version": "1"})
    _speak_in(client, session_id)
    assert queue.get_nowait()["client"] is None


def test_initialize_without_a_client_name_opens_an_anonymous_session(
    client: TestClient,
) -> None:
    queue = speech_relay.subscribe()
    _speak_in(client, _initialize(client, "not an object"))
    assert queue.get_nowait()["client"] is None


def test_sessions_forget_the_oldest_clients_beyond_the_limit() -> None:
    sessions = McpSessions(2)
    started = [McpSession() for _ in range(3)]
    for index, session in enumerate(started):
        sessions.start(session, f"client {index}")
    assert sessions.lookup(started[0].id) == McpSession()
    assert sessions.lookup(started[2].id) == McpSession(started[2].id, "client 2")
    assert len({session.id for session in started}) == 3


def test_speak_tool_reports_busy_queue(client: TestClient) -> None:
    speech_relay.subscribe()
    for _ in range(settings.SPEECH_RELAY_QUEUE_SIZE):
        assert _call(client, "speak", {"text": "x"})["isError"] is False
    result = _call(client, "speak", {"text": "x"})
    assert result["isError"] is True
    assert "queued" in result["content"][0]["text"]


@pytest.mark.parametrize(
    "arguments,fragment",
    [
        ({}, "text"),
        ({"text": ""}, "text"),
        ({"text": "   "}, "blank"),
        ({"text": "a" * 50_001}, "text"),
        ({"text": "hi", "voice": "nope"}, "Unknown voice"),
        ({"text": "hi", "extra": 1}, "extra"),
        ({"text": "hi", "mode": "later"}, "mode"),
        ({"text": 5}, "text"),
    ],
)
def test_speak_tool_validates_arguments(
    client: TestClient, arguments: dict, fragment: str
) -> None:
    speech_relay.subscribe()
    result = _call(client, "speak", arguments)
    assert result["isError"] is True
    assert result["content"][0]["text"].startswith("Invalid arguments:")
    assert fragment in result["content"][0]["text"]


def test_speak_tool_error_does_not_echo_input(client: TestClient) -> None:
    result = _call(client, "speak", {"text": 12345678})
    assert "12345678" not in result["content"][0]["text"]


def test_stop_tool(client: TestClient) -> None:
    queue = speech_relay.subscribe()
    _call(client, "speak", {"text": "one"})
    result = _call(client, "stop", {})
    assert result["isError"] is False
    assert queue.get_nowait()["type"] == "stop"
    assert queue.empty()


def test_stop_tool_without_app_is_tool_error(client: TestClient) -> None:
    assert _call(client, "stop")["isError"] is True


def test_list_voices_tool(client: TestClient) -> None:
    result = _call(client, "list_voices")
    payload = json.loads(result["content"][0]["text"])
    assert any(voice["id"] == "af_bella" for voice in payload["voices"])
    assert payload["aliases"]["alloy"]


def test_unknown_tool_is_invalid_params(client: TestClient) -> None:
    body = _rpc(client, "tools/call", {"name": "rm_rf"}).json()
    assert body["error"]["code"] == INVALID_PARAMS


@pytest.mark.parametrize("params", [{"name": ["speak"]}, {}, {"name": None}])
def test_malformed_tool_name_is_invalid_params(client: TestClient, params) -> None:
    body = _rpc(client, "tools/call", params).json()
    assert body["error"]["code"] == INVALID_PARAMS


def test_non_object_arguments_are_invalid_params(client: TestClient) -> None:
    body = _rpc(client, "tools/call", {"name": "speak", "arguments": ["x"]}).json()
    assert body["error"]["code"] == INVALID_PARAMS


def test_unknown_method(client: TestClient) -> None:
    body = _rpc(client, "resources/list").json()
    assert body["error"]["code"] == METHOD_NOT_FOUND
    assert body["id"] == 1


def test_non_object_params(client: TestClient) -> None:
    response = client.post(
        "/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "ping", "params": [1]}
    )
    assert response.json()["error"]["code"] == INVALID_PARAMS


@pytest.mark.parametrize("body", [b"{nope", b"", b"\xff\xfe"])
def test_parse_error(client: TestClient, body: bytes) -> None:
    response = client.post("/mcp", content=body)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == PARSE_ERROR
    assert response.json()["id"] is None


def test_deeply_nested_json_is_parse_error(client: TestClient) -> None:
    response = client.post("/mcp", content=b"[" * 100_000 + b"]" * 100_000)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == PARSE_ERROR


@pytest.mark.parametrize(
    "message",
    [
        [{"jsonrpc": "2.0", "id": 1, "method": "ping"}],
        {"jsonrpc": "1.0", "id": 1, "method": "ping"},
        {"id": 1, "method": "ping"},
        {"jsonrpc": "2.0", "id": 1, "method": 5},
        {"jsonrpc": "2.0", "id": True, "method": "ping"},
        {"jsonrpc": "2.0", "id": 1.5, "method": "ping"},
        {"jsonrpc": "2.0", "id": None, "method": "ping"},
        {"jsonrpc": "2.0"},
        "ping",
        None,
    ],
)
def test_invalid_requests(client: TestClient, message) -> None:
    response = client.post("/mcp", content=json.dumps(message).encode())
    assert response.status_code == 400
    assert response.json()["error"]["code"] == INVALID_REQUEST


def test_unsupported_protocol_header_is_400(client: TestClient) -> None:
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"MCP-Protocol-Version": "2000-01-01"},
    )
    assert response.status_code == 400


def test_supported_protocol_header_is_accepted(client: TestClient) -> None:
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"MCP-Protocol-Version": "2025-06-18"},
    )
    assert response.status_code == 200


def test_accept_without_json_is_406(client: TestClient) -> None:
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"Accept": "text/event-stream"},
    )
    assert response.status_code == 406


@pytest.mark.parametrize("accept", ["*/*", "application/json;q=0.9", ""])
def test_lenient_accept_headers(client: TestClient, accept: str) -> None:
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"Accept": accept},
    )
    assert response.status_code == 200


@pytest.mark.parametrize("method", ["GET", "DELETE"])
def test_get_and_delete_are_not_allowed(client: TestClient, method: str) -> None:
    response = client.request(method, "/mcp")
    assert response.status_code == 405
    assert response.headers["allow"] == "POST"


def test_mcp_requires_bearer_key() -> None:
    client = TestClient(create_public_app(API_KEY))
    response = client.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "ping"})
    assert response.status_code == 401


def test_mcp_rejects_web_origin(client: TestClient) -> None:
    response = client.post(
        "/mcp",
        json={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        headers={"Origin": "https://evil.example.com"},
    )
    assert response.status_code == 403


def test_unexpected_tool_exception_is_internal_error() -> None:
    def explode(_args: NoArguments, _client: str | None) -> str:
        raise RuntimeError("secret detail")

    server = McpServer([McpTool("boom", "Boom", "Explodes.", NoArguments, explode)])
    reply = server.handle(
        {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "boom"}}
    )
    assert reply["error"] == {"code": INTERNAL_ERROR, "message": "Internal error."}
