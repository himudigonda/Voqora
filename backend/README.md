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

Every request needs the per-launch `X-Voqora-IPC-Token` header. AI provider
settings travel in the `X-Voqora-LLM-Provider`, `X-Voqora-LLM-Key`,
`X-Voqora-LLM-Model` and `X-Voqora-LLM-Base-URL` headers and are never stored.

- `GET /health`, `GET /engine`, `POST /prewarm`, `POST /speak`: speech.
- `POST /audiobook` uploads a document; `POST /audiobook/{id}/start`,
  `/cancel` and `/retry` control processing; `GET /audiobook/{id}/events`
  streams progress as server-sent events; `GET /audiobook/{id}/audio`,
  `/transcript` and `/cover` serve the result. `GET /audiobook` lists the
  Library. Every item has a `kind`: `book` or `podcast`.
- `POST /podcast/script` writes a podcast script with the chosen AI provider.
  The body names a source (`{"text": ...}` or `{"book_id": ...}`), a style
  (`deep_dive`, `brief`, `debate` or `lecture`), 2 to 30 minutes, a language
  and one or two hosts (`lecture` takes one host, `debate` takes two). Long
  sources are condensed into notes first. The source is passed to the model
  as delimited data, and the reply must be JSON that passes validation, with
  one repair attempt.
- `POST /podcast/render` takes `{"script": ..., "title": ...}`, creates a
  `podcast` Library item and narrates it turn by turn in each speaker's voice.
  Scripts have 1 to 4 speakers and up to 600 turns of up to 2,000 characters,
  each with a pause of 0 to 3 seconds. Progress, cancel, retry, resume,
  audio and transcript use the audiobook routes above, where a page is a
  turn and each transcript line carries `speaker_id` and `speaker`.
- `GET /podcast/{id}/script` returns the script a podcast was made from.

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
