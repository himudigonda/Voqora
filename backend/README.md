# Voqora local speech engine

This is the FastAPI service bundled inside the Voqora Mac app. It owns local
speech synthesis, progressive audio streaming, and document-to-audiobook work. It is
not a hosted Voqora API.

## Responsibilities

- Serve the local health, prewarm, speech, and audiobook endpoints.
- Load Kokoro ONNX and its voice data on the Mac.
- Stream generated audio back to the native client.
- Extract and persist audiobook work so long documents can resume.
- Serve the language and voice catalog (28 voices in eight languages) and pick
  the espeak-ng language from the voice.
- Use an AI provider only for optional document cleanup and scanned-page OCR.
  The provider and key come from the request headers and are never stored.

## API

### Private app channel

Every route below needs the per-launch `X-Voqora-IPC-Token` header and is
refused when an `Origin` header is present.

- `GET /health`, `GET /engine`, `POST /prewarm`, `POST /speak`, and the
  `/audiobook` routes serve the native app.
- `GET /integrations/local-api` returns `{enabled, port, running}`, plus
  `error` and `error_code` when the local API could not start or stopped. The
  key is never returned.
- `POST /integrations/local-api` takes `{enabled, port, api_key}`. `port` is
  1024 to 65535 and `api_key` is 32 to 128 characters of `A-Z a-z 0-9 . _ ~ + /
  = -`; both are required when `enabled` is true. The call starts, restarts, or
  stops the local API and returns the same shape as the GET. A port that is
  taken returns 409 with `error_code` `port_in_use`. Other codes are
  `permission_denied`, `bind_failed`, `start_failed`, `start_timeout`, and
  `stopped`.
- `GET /integrations/events` is a server-sent event stream. It sends
  `{"type": "ready"}` first, then `{"type": "speak", "id", "text", "voice"}`
  and `{"type": "stop", "id"}` commands from the local API for the app to play,
  with a `: keep-alive` comment every 15 seconds. `voice` is null when the
  caller left it to the app.

### Local API (opt-in)

A second server that the app starts on `127.0.0.1` only, on the port the user
picks. It shares the speech engine and the interactive speech lock with
`/speak`. The key and port live in the app; this service never stores them.

Every request needs `Authorization: Bearer <api_key>`. Requests with an
`Origin` header are refused unless the origin is a `chrome-extension://`,
`moz-extension://`, or `safari-web-extension://` extension, and those still
need the key. CORS preflight is answered only for those origins. Bodies are
capped at 1 MiB, and each key gets a token bucket of 60 requests that refills
at 2 per second (429 with `Retry-After` when empty). Errors use the OpenAI
shape `{"error": {"message", "type", "param", "code"}}`.

- `GET /v1/models` lists `kokoro`, `tts-1`, and `tts-1-hd`. All three use
  Kokoro.
- `GET /v1/voices` returns `{object, data, aliases}`. `data` holds built-in
  voices `{id, name, gender, language, type: "builtin"}` and custom voices
  `{id, name, type: "custom"}`. `aliases` maps OpenAI voice names to Kokoro
  voices: alloy to af_heart, echo to am_michael, fable to bm_fable, onyx to
  am_adam, nova to af_bella, shimmer to af_nicole.
- `POST /v1/audio/speech` takes `{model, input, voice, response_format?,
  speed?}`. `input` is up to 50,000 characters. `response_format` is `wav`
  (default), `pcm` (raw 24 kHz mono 16-bit little-endian), or `flac`; anything
  else is a 400 naming the supported formats. `speed` is 0.25 to 4.0 and is
  clamped to the engine's 0.5 to 2.0. WAV and PCM stream as they are made;
  FLAC is sent once encoding finishes.
- `POST /v1/voqora/speak` takes `{text, voice?}` and asks the app to speak it
  on this Mac. `POST /v1/voqora/stop` stops speech and drops queued commands.
  Both return 202 `{status: "queued", id}`, 503 when the app is not
  subscribed to `/integrations/events`, and 429 when 16 commands are queued.
- `POST /mcp` is a Model Context Protocol server over Streamable HTTP with
  JSON responses. It supports protocol versions 2025-11-25, 2025-06-18,
  2025-03-26, and 2024-11-05, and the methods `initialize`,
  `notifications/initialized`, `ping`, `tools/list`, and `tools/call`. Tools
  are `speak(text, voice?)`, `stop()`, and `list_voices()`. `GET` and
  `DELETE` return 405.

## Local development

From the repository root:

```bash
make setup
cd backend
uv run pytest -q
```

To run the service directly during backend work, use a throwaway token and an
explicit development listener. The production app does **not** use this fixed
development port: it supplies an inherited ephemeral loopback listener and a
new token on every launch.

```bash
cd backend
VOQORA_IPC_TOKEN="$(openssl rand -base64 32)" \
  uv run uvicorn app.main:app --host 127.0.0.1 --port 10101
```

For a benchmark against that explicit development process, provide both values
instead of relying on a fixed endpoint:

```bash
VOQORA_BACKEND_URL=http://127.0.0.1:10101 \
VOQORA_IPC_TOKEN="...same throwaway token..." \
  python3 ../scripts/benchmark_stream.py
```

The bundled app starts this service itself. Do not expose it on a public
interface for normal Voqora use.

## Tests

```bash
make test          # fast backend suite only
make verify        # lint + fast backend suite
```

The model and voice artifacts are downloaded by the packaging path and ignored
by Git. See the [architecture guide](../docs/architecture.md) for how the
native app launches the bundled service.
