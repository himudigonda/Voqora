from __future__ import annotations

import json
import uuid
from collections import OrderedDict
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from app.core.config import settings
from app.core.logging import get_logger
from app.services.public_voices import (
    MAX_VOICE_ID_CHARS,
    OPENAI_VOICE_ALIASES,
    require_voice,
    voice_list,
)
from app.services.speech_relay import (
    RELAY_BUSY_MESSAGE,
    RELAY_UNAVAILABLE_MESSAGE,
    RelayBusyError,
    RelayUnavailableError,
    SpeechRelay,
    client_name,
)
from app.services.speech_stream import MAX_SPEECH_CHARS, speakable_text

log = get_logger("voqora.mcp")

SUPPORTED_PROTOCOL_VERSIONS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0]

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

_MAX_ERROR_DETAILS = 5
MAX_SESSIONS = 64
_VALUE_ERROR_PREFIX = "Value error, "
_INSTRUCTIONS = (
    "Voqora speaks text aloud on this Mac with on-device voices. "
    "Use speak for text the user should hear, stop to silence it, and "
    "list_voices to pick a voice id."
)


class JsonRpcError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class SpeakArguments(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str = Field(
        min_length=1,
        max_length=MAX_SPEECH_CHARS,
        description="Text to speak aloud on this Mac.",
    )
    voice: str | None = Field(
        default=None,
        min_length=1,
        max_length=MAX_VOICE_ID_CHARS,
        description="Voice id from list_voices, or an OpenAI voice name. "
        "Omit to use the voice chosen in Voqora.",
    )

    @field_validator("text")
    @classmethod
    def require_meaningful_text(cls, value: str) -> str:
        return speakable_text(value)

    @field_validator("voice")
    @classmethod
    def require_known_voice(cls, value: str | None) -> str | None:
        return None if value is None else require_voice(value)


class NoArguments(BaseModel):
    model_config = ConfigDict(extra="forbid")


@dataclass
class McpSession:
    id: str | None = None
    client: str | None = None


class McpSessions:
    """Remembers which client opened each session, for the newest sessions."""

    def __init__(self, limit: int) -> None:
        self._limit = limit
        self._clients: OrderedDict[str, str | None] = OrderedDict()

    def lookup(self, session_id: str | None) -> McpSession:
        if session_id is None or session_id not in self._clients:
            return McpSession()
        self._clients.move_to_end(session_id)
        return McpSession(session_id, self._clients[session_id])

    def start(self, session: McpSession, client: str | None) -> None:
        session_id = uuid.uuid4().hex
        self._clients[session_id] = client
        while len(self._clients) > self._limit:
            self._clients.popitem(last=False)
        session.id = session_id
        session.client = client


@dataclass(frozen=True)
class McpTool:
    name: str
    title: str
    description: str
    arguments: type[BaseModel]
    handler: Callable[[Any, str | None], str]
    annotations: Mapping[str, bool] = field(default_factory=dict)

    def descriptor(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "title": self.title,
            "description": self.description,
            "inputSchema": _input_schema(self.arguments),
            "annotations": {"title": self.title, **self.annotations},
        }


def _input_schema(model: type[BaseModel]) -> dict[str, Any]:
    schema = model.model_json_schema()
    schema.pop("title", None)
    for prop in schema.get("properties", {}).values():
        prop.pop("title", None)
    return schema


def build_tools(relay: SpeechRelay) -> list[McpTool]:
    def speak(args: SpeakArguments, client: str | None) -> str:
        relay.speak(args.text, args.voice, client)
        return "Queued for speech on this Mac."

    def stop(_args: NoArguments, _client: str | None) -> str:
        relay.stop()
        return "Stopped speech on this Mac."

    def list_voices(_args: NoArguments, _client: str | None) -> str:
        return json.dumps({"voices": voice_list(), "aliases": OPENAI_VOICE_ALIASES})

    local_effect = {"destructiveHint": False, "openWorldHint": False}
    return [
        McpTool(
            "speak",
            "Speak text",
            "Speak text aloud on this Mac through the Voqora app.",
            SpeakArguments,
            speak,
            {**local_effect, "readOnlyHint": False, "idempotentHint": False},
        ),
        McpTool(
            "stop",
            "Stop speaking",
            "Stop speech on this Mac and drop anything still queued.",
            NoArguments,
            stop,
            {**local_effect, "readOnlyHint": False, "idempotentHint": True},
        ),
        McpTool(
            "list_voices",
            "List voices",
            "List the voices Voqora can speak with, and OpenAI voice names it maps.",
            NoArguments,
            list_voices,
            {**local_effect, "readOnlyHint": True, "idempotentHint": True},
        ),
    ]


class McpServer:
    def __init__(self, tools: Sequence[McpTool]) -> None:
        self._tools = {tool.name: tool for tool in tools}
        self.sessions = McpSessions(MAX_SESSIONS)
        self._methods: dict[
            str, Callable[[dict[str, Any], McpSession], dict[str, Any]]
        ] = {
            "initialize": self._initialize,
            "ping": lambda _params, _session: {},
            "tools/list": self._list_tools,
            "tools/call": self._call_tool,
        }

    def handle(
        self, message: Any, session: McpSession | None = None
    ) -> dict[str, Any] | None:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            return error_message(None, INVALID_REQUEST, "Invalid JSON-RPC message.")
        if "method" not in message:
            return None if _is_client_response(message) else _invalid_request()
        if not isinstance(message["method"], str):
            return _invalid_request()
        if "id" not in message:
            return None
        return self._handle_request(message, session or McpSession())

    def _handle_request(
        self, message: dict[str, Any], session: McpSession
    ) -> dict[str, Any]:
        request_id = message["id"]
        if not _is_valid_id(request_id):
            return error_message(None, INVALID_REQUEST, "Invalid request id.")
        params = message.get("params") or {}
        if not isinstance(params, dict):
            return error_message(
                request_id, INVALID_PARAMS, "params must be an object."
            )
        try:
            result = self._dispatch(message["method"], params, session)
        except JsonRpcError as exc:
            return error_message(request_id, exc.code, exc.message)
        except Exception:
            log.error(
                "mcp.request_failed",
                extra={"failure_code": "mcp_internal_error"},
                exc_info=True,
            )
            return error_message(request_id, INTERNAL_ERROR, "Internal error.")
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    def _dispatch(
        self, method: str, params: dict[str, Any], session: McpSession
    ) -> dict[str, Any]:
        handler = self._methods.get(method)
        if handler is None:
            raise JsonRpcError(METHOD_NOT_FOUND, "Method not found.")
        return handler(params, session)

    def _initialize(
        self, params: dict[str, Any], session: McpSession
    ) -> dict[str, Any]:
        requested = params.get("protocolVersion")
        if not isinstance(requested, str):
            raise JsonRpcError(INVALID_PARAMS, "protocolVersion is required.")
        client_info = params.get("clientInfo")
        name = client_info.get("name") if isinstance(client_info, dict) else None
        self.sessions.start(session, client_name(name))
        return {
            "protocolVersion": negotiate_protocol_version(requested),
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {
                "name": "voqora",
                "title": "Voqora",
                "version": settings.VERSION,
            },
            "instructions": _INSTRUCTIONS,
        }

    def _list_tools(
        self, _params: dict[str, Any], _session: McpSession
    ) -> dict[str, Any]:
        return {"tools": [tool.descriptor() for tool in self._tools.values()]}

    def _call_tool(self, params: dict[str, Any], session: McpSession) -> dict[str, Any]:
        name = params.get("name")
        tool = self._tools.get(name) if isinstance(name, str) else None
        if tool is None:
            raise JsonRpcError(INVALID_PARAMS, "Unknown tool.")
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, dict):
            raise JsonRpcError(INVALID_PARAMS, "arguments must be an object.")
        try:
            parsed = tool.arguments.model_validate(arguments)
        except ValidationError as exc:
            return tool_result(f"Invalid arguments: {_describe(exc)}", is_error=True)
        return _run_tool(tool, parsed, session.client)


def _run_tool(
    tool: McpTool, arguments: BaseModel, client: str | None
) -> dict[str, Any]:
    try:
        text = tool.handler(arguments, client)
    except RelayUnavailableError:
        return tool_result(RELAY_UNAVAILABLE_MESSAGE, is_error=True)
    except RelayBusyError:
        return tool_result(RELAY_BUSY_MESSAGE, is_error=True)
    log.info("mcp.tool_called", extra={"tool": tool.name})
    return tool_result(text)


def negotiate_protocol_version(requested: str) -> str:
    if requested in SUPPORTED_PROTOCOL_VERSIONS:
        return requested
    return LATEST_PROTOCOL_VERSION


def tool_result(text: str, *, is_error: bool = False) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def error_message(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


def _invalid_request() -> dict[str, Any]:
    return error_message(None, INVALID_REQUEST, "Invalid JSON-RPC request.")


def _is_client_response(message: dict[str, Any]) -> bool:
    return "id" in message and ("result" in message or "error" in message)


def _is_valid_id(value: Any) -> bool:
    return isinstance(value, str) or (
        isinstance(value, int) and not isinstance(value, bool)
    )


def _describe(exc: ValidationError) -> str:
    details = []
    for error in exc.errors(include_input=False)[:_MAX_ERROR_DETAILS]:
        loc = ".".join(str(part) for part in error["loc"]) or "arguments"
        message = str(error["msg"]).removeprefix(_VALUE_ERROR_PREFIX)
        details.append(f"{loc}: {message}")
    return "; ".join(details)
