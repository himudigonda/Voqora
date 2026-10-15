import base64
import ipaddress
import re
from dataclasses import dataclass
from typing import Any, Literal
from urllib.parse import urlparse

import httpx

from app.core.logging import get_logger

log = get_logger(__name__)

Dialect = Literal["gemini", "openai", "anthropic"]


@dataclass(frozen=True)
class ModelPrice:
    input_usd_per_m: float
    output_usd_per_m: float
    long_context_tokens: int | None = None
    long_input_usd_per_m: float | None = None
    long_output_usd_per_m: float | None = None

    def cost(self, input_tokens: int, output_tokens: int) -> float:
        input_rate, output_rate = self.input_usd_per_m, self.output_usd_per_m
        if (
            self.long_context_tokens is not None
            and input_tokens > self.long_context_tokens
        ):
            input_rate = self.long_input_usd_per_m or input_rate
            output_rate = self.long_output_usd_per_m or output_rate
        return (max(0, input_tokens) / 1_000_000) * input_rate + (
            max(0, output_tokens) / 1_000_000
        ) * output_rate


FREE = ModelPrice(0.0, 0.0)
UNLISTED_MODEL_PRICE = ModelPrice(3.0, 15.0)


@dataclass(frozen=True)
class ProviderSpec:
    id: str
    name: str
    dialect: Dialect
    base_url: str
    default_model: str
    requires_key: bool = True
    local: bool = False
    vision_models: frozenset[str] = frozenset()
    text_only_models: frozenset[str] = frozenset()
    prices: tuple[tuple[str, ModelPrice], ...] = ()
    lists_models: bool = True
    extra_headers: tuple[tuple[str, str], ...] = ()
    completion_tokens_field: str = "max_tokens"
    sends_temperature: bool = True

    def price(self, model: str) -> ModelPrice:
        if self.local:
            return FREE
        return dict(self.prices).get(model, UNLISTED_MODEL_PRICE)

    def is_priced(self, model: str) -> bool:
        return self.local or model in dict(self.prices)

    def supports_vision(self, model: str) -> bool | None:
        if model in self.vision_models:
            return True
        if model in self.text_only_models:
            return False
        return None


PROVIDERS: dict[str, ProviderSpec] = {
    spec.id: spec
    for spec in (
        ProviderSpec(
            id="openai",
            name="OpenAI",
            dialect="openai",
            base_url="https://api.openai.com/v1",
            default_model="gpt-6-luna",
            vision_models=frozenset({"gpt-6-luna"}),
            prices=(("gpt-6-luna", ModelPrice(0.10, 0.50)),),
            completion_tokens_field="max_completion_tokens",
            sends_temperature=False,
        ),
        ProviderSpec(
            id="anthropic",
            name="Anthropic",
            dialect="anthropic",
            base_url="https://api.anthropic.com/v1",
            default_model="claude-haiku-5-5",
            vision_models=frozenset({"claude-haiku-5-5", "claude-sonnet-5-5"}),
            prices=(
                (
                    "claude-haiku-5-5",
                    ModelPrice(0.10, 0.50, 100_000, 0.50, 2.50),
                ),
                ("claude-sonnet-5-5", ModelPrice(2.0, 10.0)),
            ),
        ),
        ProviderSpec(
            id="xai",
            name="xAI",
            dialect="openai",
            base_url="https://api.x.ai/v1",
            default_model="grok-4.20-0309-non-reasoning",
            vision_models=frozenset({"grok-4.20-0309-non-reasoning"}),
            prices=(
                (
                    "grok-4.20-0309-non-reasoning",
                    ModelPrice(1.25, 2.50, 200_000, 2.50, 5.00),
                ),
            ),
            completion_tokens_field="max_completion_tokens",
        ),
        ProviderSpec(
            id="groq",
            name="Groq",
            dialect="openai",
            base_url="https://api.groq.com/openai/v1",
            default_model="openai/gpt-oss-120b",
            vision_models=frozenset({"qwen/qwen3.8-27b"}),
            text_only_models=frozenset({"openai/gpt-oss-120b", "openai/gpt-oss-20b"}),
            prices=(
                ("openai/gpt-oss-120b", ModelPrice(0.15, 0.60)),
                ("openai/gpt-oss-20b", ModelPrice(0.075, 0.30)),
            ),
        ),
        ProviderSpec(
            id="cerebras",
            name="Cerebras",
            dialect="openai",
            base_url="https://api.cerebras.ai/v1",
            default_model="gpt-oss-120b",
            text_only_models=frozenset({"gpt-oss-120b"}),
        ),
        ProviderSpec(
            id="google",
            name="Google",
            dialect="gemini",
            base_url="",
            default_model="gemini-3.8-flash",
            vision_models=frozenset({"gemini-3.8-flash"}),
            lists_models=False,
        ),
        ProviderSpec(
            id="openrouter",
            name="OpenRouter",
            dialect="openai",
            base_url="https://openrouter.ai/api/v1",
            default_model="google/gemini-2.5-flash-lite",
            vision_models=frozenset({"google/gemini-2.5-flash-lite"}),
            lists_models=False,
            extra_headers=(
                ("HTTP-Referer", "https://github.com/himudigonda/Voqora"),
                ("X-OpenRouter-Title", "Voqora"),
            ),
        ),
        ProviderSpec(
            id="ollama",
            name="Ollama",
            dialect="openai",
            base_url="http://localhost:11434/v1",
            default_model="",
            requires_key=False,
            local=True,
        ),
        ProviderSpec(
            id="lmstudio",
            name="LM Studio",
            dialect="openai",
            base_url="http://localhost:1234/v1",
            default_model="",
            requires_key=False,
            local=True,
        ),
        ProviderSpec(
            id="custom",
            name="Custom Provider",
            dialect="openai",
            base_url="",
            default_model="",
            requires_key=False,
        ),
    )
}

MAX_API_KEY_CHARS = 512
USER_URL_PROVIDERS = frozenset({"custom", "ollama", "lmstudio"})


def _host_address(host: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        return ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return None


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    address = _host_address(host)
    return address is not None and address.is_loopback


def api_key_problem(api_key: str) -> str | None:
    if len(api_key) > MAX_API_KEY_CHARS:
        return "The API key is too long."
    if not (api_key.isascii() and api_key.isprintable()):
        return "The API key contains characters that aren't allowed."
    return None


@dataclass(frozen=True)
class LLMCredential:
    provider: str
    api_key: str = ""
    model: str = ""
    base_url: str = ""

    @classmethod
    def gemini(cls, api_key: str) -> "LLMCredential":
        return cls(provider="google", api_key=api_key)

    @property
    def spec(self) -> ProviderSpec:
        return PROVIDERS[self.provider]

    @property
    def resolved_model(self) -> str:
        return self.model.strip() or self.spec.default_model

    @property
    def resolved_base_url(self) -> str:
        supplied = self.base_url.strip()
        if supplied and self.provider in USER_URL_PROVIDERS:
            return supplied.rstrip("/")
        return self.spec.base_url.rstrip("/")

    @property
    def name(self) -> str:
        return self.spec.name

    @property
    def is_gemini(self) -> bool:
        return self.spec.dialect == "gemini"

    @property
    def runs_on_this_network(self) -> bool:
        if self.spec.local:
            return True
        if self.provider != "custom":
            return False
        host = urlparse(self.resolved_base_url).hostname or ""
        if host == "localhost" or host.endswith(".local"):
            return True
        address = _host_address(host)
        if address is None or address.is_link_local:
            return False
        return address.is_loopback or address.is_private

    @property
    def price(self) -> ModelPrice:
        if self.runs_on_this_network:
            return FREE
        return self.spec.price(self.resolved_model)

    @property
    def is_priced(self) -> bool:
        return self.runs_on_this_network or self.spec.is_priced(self.resolved_model)

    def problem(self, *, require_model: bool = True) -> str | None:
        if self.provider not in PROVIDERS:
            return "Unknown AI provider."
        key_problem = api_key_problem(self.api_key)
        if key_problem:
            return key_problem
        if self.spec.requires_key and not self.api_key.strip():
            return f"Missing API key for {self.name}."
        if require_model and not self.resolved_model:
            return f"Choose a model for {self.name}."
        if not self.is_gemini:
            return self.server_url_problem()
        return None

    def server_url_problem(self) -> str | None:
        parsed = urlparse(self.resolved_base_url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            return f"Enter a server URL for {self.name}."
        if parsed.username is not None or parsed.password is not None:
            return "Put the credential in API Key, not the address."
        address = _host_address(parsed.hostname)
        if address is not None and address.is_link_local:
            return f"{self.name} can't use a link-local address."
        if (
            parsed.scheme == "http"
            and self.api_key.strip()
            and not _is_loopback(parsed.hostname)
        ):
            return (
                f"{self.name} needs an https:// address when an API key is set, "
                "unless the server is on this computer."
            )
        if (
            self.provider == "custom"
            and parsed.scheme == "http"
            and not self.runs_on_this_network
        ):
            return (
                f"{self.name} needs an https:// address unless the server "
                "is on this computer or your local network."
            )
        return None

    @property
    def display_base_url(self) -> str:
        parsed = urlparse(self.resolved_base_url)
        host = parsed.hostname or ""
        if ":" in host:
            host = f"[{host}]"
        try:
            port = parsed.port
        except ValueError:
            port = None
        origin = f"{parsed.scheme}://{host}" if parsed.scheme and host else ""
        return f"{origin}:{port}" if origin and port else origin

    def __repr__(self) -> str:
        return (
            f"LLMCredential(provider={self.provider!r}, "
            f"model={self.resolved_model!r}, key={'set' if self.api_key else 'unset'})"
        )


class LLMError(Exception):
    retryable = True

    def __init__(self, message: str, *, status: int | None = None, detail: str = ""):
        super().__init__(message)
        self.user_message = message
        self.status = status
        self.detail = detail


class LLMConfigError(LLMError):
    code = "llm_config_failed"
    retryable = False


class LLMAuthError(LLMConfigError):
    code = "llm_auth_failed"


class LLMBillingError(LLMConfigError):
    code = "llm_billing_failed"


class LLMUnreachableError(LLMConfigError):
    code = "llm_unreachable"


class LLMRateLimitError(LLMError):
    pass


class LLMBadResponseError(LLMError):
    pass


class LLMRequestRejectedError(LLMBadResponseError):
    retryable = False


class LLMModelNotFoundError(LLMConfigError, LLMRequestRejectedError):
    code = "llm_model_not_found"


class LLMModelListUnavailableError(LLMError):
    pass


class LLMIncompleteError(LLMError):
    retryable = False


class LLMCapacityError(LLMError):
    pass


@dataclass(frozen=True)
class Completion:
    text: str
    input_tokens: int | None
    output_tokens: int | None


_REMOTE_TIMEOUT = httpx.Timeout(180.0, connect=15.0)
_LOCAL_TIMEOUT = httpx.Timeout(600.0, connect=5.0)
_VERIFY_TIMEOUT = httpx.Timeout(20.0, connect=8.0)
_MIN_SECRET_CHARS = 6
_USER_DETAIL_CHARS = 160
_LOG_DETAIL_CHARS = 200
_MODEL_LIST_PAGE_LIMIT = 1000
_MODEL_LIST_MAX_PAGES = 10
_COMPLETE_FINISH_REASONS = frozenset(
    {"", "stop", "end_turn", "eos", "eos_token", "stop_sequence"}
)
_KEY_PATTERN = re.compile(
    r"(?<![A-Za-z0-9])(?:sk-or-|sk-ant-|sk-|xai-|gsk_|csk-|AIza)[A-Za-z0-9_\-]{6,}"
    r"|(?i:bearer)\s+[A-Za-z0-9._\-]{8,}"
    r"|(?i:(?<=[?&]key=))[^&\s\"']+"
)
_BILLING_CODES = frozenset(
    {"insufficient_quota", "billing_not_active", "insufficient_credits"}
)
_BILLING_PHRASES = ("credit balance", "insufficient credit", "insufficient funds")
_LIST_UNAVAILABLE_STATUSES = frozenset({404, 405, 501})


def redact(text: str, *secrets: str) -> str:
    for secret in secrets:
        if len(secret.strip()) < _MIN_SECRET_CHARS:
            continue
        variants = {
            secret,
            secret.strip(),
            repr(secret)[1:-1],
            repr(secret.strip())[1:-1],
        }
        for variant in sorted(variants, key=len, reverse=True):
            text = text.replace(variant, "[redacted]")
    return _KEY_PATTERN.sub("[redacted]", text)


def short_text(text: str, limit: int, *secrets: str) -> str:
    flat = " ".join(redact(text, *secrets).split())
    flat = "".join(ch for ch in flat if ch.isprintable())
    return flat if len(flat) <= limit else flat[: limit - 1].rstrip() + "…"


def _error_body(response: httpx.Response) -> tuple[str, str]:
    try:
        body = response.json()
    except ValueError:
        text = response.text.strip()
        return ("" if text.startswith("<") else text), ""
    error = body.get("error", body) if isinstance(body, dict) else body
    if isinstance(error, str):
        return error, ""
    if isinstance(error, dict):
        message = error.get("message") or error.get("detail") or ""
        code = error.get("code") or error.get("type") or ""
        return str(message), str(code).lower()
    return "", ""


def log_failure(
    event: str,
    credential: LLMCredential,
    error: BaseException,
    *,
    status: int | None = None,
    detail: str = "",
) -> None:
    cause = error.__cause__ or error
    if isinstance(error, LLMError):
        status = error.status if status is None else status
        detail = detail or error.detail or error.user_message
    else:
        code = getattr(error, "code", None)
        status = code if status is None and isinstance(code, int) else status
        detail = detail or str(getattr(error, "message", None) or "")
    log.warning(
        event,
        extra={
            "provider": credential.provider,
            "model": credential.resolved_model,
            "error_type": type(error).__name__,
            "cause_type": type(cause).__name__,
            "http_status": status,
            "provider_message": short_text(
                detail or str(error), _LOG_DETAIL_CHARS, credential.api_key
            ),
        },
    )


def _headers(credential: LLMCredential) -> dict[str, str]:
    spec = credential.spec
    headers = {"content-type": "application/json", **dict(spec.extra_headers)}
    key = credential.api_key.strip()
    if spec.dialect == "anthropic":
        headers["x-api-key"] = key
        headers["anthropic-version"] = "2023-06-01"
    elif key:
        headers["authorization"] = f"Bearer {key}"
    return headers


def _with_detail(message: str, detail: str) -> str:
    return f"{message} ({detail})" if detail else message


def _raise_for_status(credential: LLMCredential, response: httpx.Response) -> None:
    status = response.status_code
    if status < 300:
        return
    name = credential.name
    model = credential.resolved_model
    message, code = _error_body(response)
    detail = short_text(message, _USER_DETAIL_CHARS, credential.api_key)
    facts = {"status": status, "detail": message}
    if status < 400:
        raise LLMBadResponseError(
            f"{name} redirected the request, and Voqora does not follow redirects.",
            **facts,
        )
    billing = (
        status == 402
        or code in _BILLING_CODES
        or any(phrase in message.lower() for phrase in _BILLING_PHRASES)
    )
    if billing:
        raise LLMBillingError(
            _with_detail(
                f"{name} reports no remaining credit or quota for this account."
                " Add credit or check your plan.",
                detail,
            ),
            **facts,
        )
    if status == 401:
        raise LLMAuthError(
            _with_detail(
                f"{name} rejected the API key. Update it in Settings.", detail
            ),
            **facts,
        )
    if status == 403:
        raise LLMAuthError(
            _with_detail(
                f"{name} denied this key access to {model}."
                " Check the key's permissions or choose another model.",
                detail,
            ),
            **facts,
        )
    if status == 404:
        where = (
            "Check the server URL and model name."
            if credential.provider == "custom"
            else "Choose another model."
        )
        raise LLMModelNotFoundError(
            _with_detail(f"{name} has no model named {model}. {where}", detail),
            **facts,
        )
    if status in (408, 409, 425, 429) or status >= 500:
        raise LLMRateLimitError(
            _with_detail(f"{name} is busy or rate limited ({status}).", detail),
            **facts,
        )
    raise LLMRequestRejectedError(
        _with_detail(f"{name} rejected the request ({status}).", detail), **facts
    )


def _unreachable(credential: LLMCredential) -> LLMUnreachableError:
    if credential.spec.local:
        return LLMUnreachableError(
            f"Voqora could not reach {credential.name}. Make sure it is running."
        )
    return LLMUnreachableError(
        f"Voqora could not reach {credential.name} at {credential.display_base_url}."
    )


def _require_usable_server(credential: LLMCredential) -> None:
    if credential.is_gemini:
        return
    problem = credential.server_url_problem()
    if problem:
        raise LLMConfigError(problem)


def _openai_body(
    credential: LLMCredential,
    system: str,
    text: str | None,
    image_jpeg: bytes | None,
    max_output_tokens: int,
) -> dict[str, Any]:
    spec = credential.spec
    if image_jpeg is not None:
        encoded = base64.b64encode(image_jpeg).decode("ascii")
        user: Any = [
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{encoded}"},
            }
        ]
    else:
        user = text or ""
    body: dict[str, Any] = {
        "model": credential.resolved_model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        spec.completion_tokens_field: max_output_tokens,
        "stream": False,
    }
    if spec.sends_temperature:
        body["temperature"] = 0.1
    return body


def _anthropic_body(
    credential: LLMCredential,
    system: str,
    text: str | None,
    image_jpeg: bytes | None,
    max_output_tokens: int,
) -> dict[str, Any]:
    if image_jpeg is not None:
        content: Any = [
            {
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64.b64encode(image_jpeg).decode("ascii"),
                },
            }
        ]
    else:
        content = text or ""
    return {
        "model": credential.resolved_model,
        "system": system,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_output_tokens,
        "temperature": 0.1,
    }


def _int_or_none(value: Any) -> int | None:
    return value if isinstance(value, int) and value >= 0 else None


def _finished(reason: Any) -> bool:
    return reason is None or str(reason).strip().lower() in _COMPLETE_FINISH_REASONS


def _parse_openai(credential: LLMCredential, payload: Any) -> Completion:
    try:
        choice = payload["choices"][0]
        message = choice.get("message") or {}
        content = message.get("content")
    except (KeyError, IndexError, TypeError, AttributeError) as e:
        raise LLMBadResponseError(
            f"{credential.name} returned an unexpected response."
        ) from e
    if isinstance(content, list):
        content = "".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    finish = choice.get("finish_reason")
    if not _finished(finish):
        raise LLMIncompleteError(f"{credential.name} stopped early: {finish}")
    usage = payload.get("usage") or {}
    return Completion(
        text=(content or "").strip(),
        input_tokens=_int_or_none(usage.get("prompt_tokens")),
        output_tokens=_int_or_none(usage.get("completion_tokens")),
    )


def _parse_anthropic(credential: LLMCredential, payload: Any) -> Completion:
    try:
        blocks = payload["content"]
        text = "".join(
            block.get("text", "")
            for block in blocks
            if isinstance(block, dict) and block.get("type") == "text"
        )
    except (KeyError, TypeError) as e:
        raise LLMBadResponseError(
            f"{credential.name} returned an unexpected response."
        ) from e
    stop_reason = payload.get("stop_reason")
    if not _finished(stop_reason):
        raise LLMIncompleteError(f"{credential.name} stopped early: {stop_reason}")
    usage = payload.get("usage") or {}
    return Completion(
        text=text.strip(),
        input_tokens=_int_or_none(usage.get("input_tokens")),
        output_tokens=_int_or_none(usage.get("output_tokens")),
    )


async def complete(
    credential: LLMCredential,
    *,
    system: str,
    text: str | None = None,
    image_jpeg: bytes | None = None,
    max_output_tokens: int,
    transport: httpx.AsyncBaseTransport | None = None,
) -> Completion:
    try:
        return await _complete(
            credential,
            system=system,
            text=text,
            image_jpeg=image_jpeg,
            max_output_tokens=max_output_tokens,
            transport=transport,
        )
    except LLMError as e:
        log_failure("llm.provider_call_failed", credential, e)
        raise


async def _complete(
    credential: LLMCredential,
    *,
    system: str,
    text: str | None,
    image_jpeg: bytes | None,
    max_output_tokens: int,
    transport: httpx.AsyncBaseTransport | None,
) -> Completion:
    _require_usable_server(credential)
    spec = credential.spec
    if spec.dialect == "anthropic":
        url = f"{credential.resolved_base_url}/messages"
        body = _anthropic_body(credential, system, text, image_jpeg, max_output_tokens)
    else:
        url = f"{credential.resolved_base_url}/chat/completions"
        body = _openai_body(credential, system, text, image_jpeg, max_output_tokens)
    timeout = _LOCAL_TIMEOUT if spec.local else _REMOTE_TIMEOUT
    try:
        async with httpx.AsyncClient(
            timeout=timeout, transport=transport, follow_redirects=False
        ) as client:
            response = await client.post(url, headers=_headers(credential), json=body)
    except httpx.UnsupportedProtocol as e:
        raise _unreachable(credential) from e
    except httpx.ConnectError as e:
        if credential.runs_on_this_network or credential.provider == "custom":
            raise _unreachable(credential) from e
        raise LLMRateLimitError(f"{credential.name} could not be reached.") from e
    except httpx.TimeoutException as e:
        raise LLMRateLimitError(f"{credential.name} timed out.") from e
    except httpx.HTTPError as e:
        raise LLMBadResponseError(f"{credential.name} request failed.") from e
    _raise_for_status(credential, response)
    try:
        payload = response.json()
    except ValueError as e:
        raise LLMBadResponseError(
            f"{credential.name} returned an unexpected response."
        ) from e
    if spec.dialect == "anthropic":
        return _parse_anthropic(credential, payload)
    return _parse_openai(credential, payload)


_NON_TEXT_MODEL_MARKERS = (
    "embed",
    "whisper",
    "tts",
    "audio",
    "realtime",
    "transcribe",
    "dall-e",
    "image",
    "moderation",
    "search",
    "guard",
)


def chat_models(ids: list[str]) -> list[str]:
    return sorted(
        {
            model
            for model in ids
            if model and not any(m in model.lower() for m in _NON_TEXT_MODEL_MARKERS)
        }
    )


def model_is_listed(model: str, ids: list[str]) -> bool:
    wanted = model.strip()
    listed = {item.strip() for item in ids}
    return wanted in listed or f"{wanted}:latest" in listed


async def list_models(
    credential: LLMCredential,
    transport: httpx.AsyncBaseTransport | None = None,
) -> list[str]:
    return chat_models(await list_model_ids(credential, transport))


async def list_model_ids(
    credential: LLMCredential,
    transport: httpx.AsyncBaseTransport | None = None,
) -> list[str]:
    try:
        return await _list_model_ids(credential, transport)
    except LLMModelListUnavailableError as e:
        log_failure("llm.model_list_unavailable", credential, e)
        raise
    except LLMError as e:
        log_failure("llm.provider_call_failed", credential, e)
        raise


async def _get(
    credential: LLMCredential,
    url: str,
    params: dict[str, Any],
    transport: httpx.AsyncBaseTransport | None,
) -> httpx.Response:
    try:
        async with httpx.AsyncClient(
            timeout=_VERIFY_TIMEOUT, transport=transport, follow_redirects=False
        ) as client:
            return await client.get(url, headers=_headers(credential), params=params)
    except (httpx.ConnectError, httpx.UnsupportedProtocol) as e:
        raise _unreachable(credential) from e
    except httpx.TimeoutException as e:
        raise LLMUnreachableError(f"{credential.name} did not respond in time.") from e
    except httpx.HTTPError as e:
        raise LLMBadResponseError(f"{credential.name} request failed.") from e


def _page_ids(credential: LLMCredential, response: httpx.Response) -> dict[str, Any]:
    try:
        body = response.json()
        data = body.get("data")
        if not isinstance(data, list):
            raise ValueError("no data list")
        ids = [str(item.get("id", "")) for item in data if isinstance(item, dict)]
    except (ValueError, AttributeError) as e:
        raise LLMModelListUnavailableError(
            f"{credential.name} did not return a model list.",
            status=response.status_code,
        ) from e
    return {
        "ids": ids,
        "has_more": body.get("has_more") is True,
        "last_id": body.get("last_id"),
    }


async def _list_model_ids(
    credential: LLMCredential, transport: httpx.AsyncBaseTransport | None
) -> list[str]:
    _require_usable_server(credential)
    spec = credential.spec
    if spec.id == "openrouter":
        url = f"{credential.resolved_base_url}/key"
    else:
        url = f"{credential.resolved_base_url}/models"
    paged = spec.dialect == "anthropic"
    params: dict[str, Any] = {"limit": _MODEL_LIST_PAGE_LIMIT} if paged else {}
    ids: list[str] = []
    for _ in range(_MODEL_LIST_MAX_PAGES):
        response = await _get(credential, url, params, transport)
        if response.status_code in _LIST_UNAVAILABLE_STATUSES:
            raise LLMModelListUnavailableError(
                f"{credential.name} does not list its models.",
                status=response.status_code,
            )
        _raise_for_status(credential, response)
        if not spec.lists_models:
            return []
        page = _page_ids(credential, response)
        ids.extend(page["ids"])
        if not (paged and page["has_more"] and page["last_id"]):
            break
        params = {**params, "after_id": page["last_id"]}
    return ids
