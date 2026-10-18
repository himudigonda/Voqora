from __future__ import annotations

from typing import Any

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

_ERROR_TYPES: dict[int, str] = {
    400: "invalid_request_error",
    401: "authentication_error",
    403: "permission_error",
    404: "not_found_error",
    405: "invalid_request_error",
    413: "invalid_request_error",
    422: "invalid_request_error",
    429: "rate_limit_error",
    503: "service_unavailable_error",
}

_VALUE_ERROR_PREFIX = "Value error, "


def error_response(
    status_code: int,
    message: str,
    *,
    param: str | None = None,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    body = {
        "error": {
            "message": message,
            "type": _ERROR_TYPES.get(status_code, "server_error"),
            "param": param,
            "code": None,
        }
    }
    return JSONResponse(body, status_code=status_code, headers=headers)


async def http_exception_handler(_request: Request, exc: HTTPException) -> JSONResponse:
    message = exc.detail if isinstance(exc.detail, str) else "Request failed."
    return error_response(exc.status_code, message, headers=exc.headers)


async def validation_exception_handler(
    _request: Request, exc: RequestValidationError
) -> JSONResponse:
    errors = exc.errors()
    if not errors:
        return error_response(400, "Invalid request body.")
    first = errors[0]
    loc = [str(part) for part in first.get("loc", ()) if part != "body"]
    param = ".".join(loc) or None
    return error_response(400, _describe(first, param), param=param)


def _describe(error: dict[str, Any], param: str | None) -> str:
    message = str(error.get("msg", "Invalid value."))
    if error.get("type") == "value_error":
        return message.removeprefix(_VALUE_ERROR_PREFIX)
    return f"{param}: {message}" if param else message
