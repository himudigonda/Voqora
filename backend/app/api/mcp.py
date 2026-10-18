from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

from app.services.mcp_server import (
    INVALID_REQUEST,
    PARSE_ERROR,
    SUPPORTED_PROTOCOL_VERSIONS,
    McpServer,
    build_tools,
    error_message,
)
from app.services.speech_relay import speech_relay

router = APIRouter()
mcp_server = McpServer(build_tools(speech_relay))

_ACCEPTED_MEDIA_TYPES = ("application/json", "application/*", "*/*")
_UNPARSEABLE = object()


@router.post("/mcp")
async def mcp_endpoint(request: Request) -> Response:
    """MCP over Streamable HTTP: one JSON-RPC 2.0 message in, a JSON reply out."""
    if not _accepts_json(request.headers.get("accept")):
        return _rpc_error(406, INVALID_REQUEST, "Accept must include application/json.")
    version = request.headers.get("mcp-protocol-version")
    if version is not None and version not in SUPPORTED_PROTOCOL_VERSIONS:
        return _rpc_error(400, INVALID_REQUEST, "Unsupported MCP-Protocol-Version.")
    message = _parse(await request.body())
    if message is _UNPARSEABLE:
        return _rpc_error(400, PARSE_ERROR, "Parse error.")
    if isinstance(message, list):
        return _rpc_error(400, INVALID_REQUEST, "Batch requests are not supported.")
    reply = mcp_server.handle(message)
    if reply is None:
        return Response(status_code=202)
    status = 400 if reply["id"] is None else 200
    return JSONResponse(reply, status_code=status)


@router.api_route("/mcp", methods=["GET", "DELETE"])
def mcp_unsupported_method() -> Response:
    """Voqora does not open server-sent streams or sessions on /mcp."""
    return _rpc_error(405, INVALID_REQUEST, "Method not allowed.", {"Allow": "POST"})


def _accepts_json(accept: str | None) -> bool:
    if not accept:
        return True
    media_types = [part.split(";")[0].strip().lower() for part in accept.split(",")]
    return any(media in _ACCEPTED_MEDIA_TYPES for media in media_types)


def _parse(body: bytes) -> Any:
    try:
        return json.loads(body)
    except (ValueError, RecursionError):
        return _UNPARSEABLE


def _rpc_error(
    status_code: int,
    code: int,
    message: str,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(
        error_message(None, code, message), status_code=status_code, headers=headers
    )
