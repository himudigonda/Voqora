from __future__ import annotations

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.mcp import router as mcp_router
from app.api.middleware import CorrelationMiddleware
from app.api.openai_compat import router as openai_router
from app.api.public_errors import http_exception_handler, validation_exception_handler
from app.api.public_middleware import (
    BearerAuthMiddleware,
    BodyLimitMiddleware,
    ExtensionOriginMiddleware,
    RateLimitMiddleware,
)
from app.core.config import settings
from app.services.rate_limit import TokenBucket


def create_public_app(api_key: str) -> FastAPI:
    app = FastAPI(
        title="Voqora Local API",
        version=settings.VERSION,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)
    app.add_exception_handler(RequestValidationError, validation_exception_handler)
    app.include_router(openai_router)
    app.include_router(mcp_router)
    app.add_middleware(BodyLimitMiddleware, max_bytes=settings.LOCAL_API_MAX_BODY_BYTES)
    app.add_middleware(CorrelationMiddleware)
    app.add_middleware(
        RateLimitMiddleware,
        bucket=TokenBucket(
            settings.LOCAL_API_RATE_LIMIT_BURST,
            settings.LOCAL_API_RATE_LIMIT_PER_SECOND,
        ),
    )
    app.add_middleware(BearerAuthMiddleware, api_key=api_key)
    app.add_middleware(ExtensionOriginMiddleware)
    return app
