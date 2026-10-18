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

Every route requires the per-launch `X-Voqora-IPC-Token` header and listens
only on loopback.

- `POST /audiobook` (multipart `file`, optional `voice`, `speed`, `engine`,
  `llm_provider`, `llm_model`, `llm_base_url`) stores a document and returns
  its estimate. Accepted types: `.pdf`, `.epub`, `.txt`, `.docx`, `.md`,
  `.html`, and `.htm`. For EPUB the returned `title` is the book's own title
  (the file name when it has none) and `author` is its author, or `null`.
  Rejections are `400` with a `detail` the app can show as is, for example a
  DRM-protected EPUB, an unsafe or oversized archive, or a damaged package.
- EPUB chapters come from the EPUB 3 navigation document or the EPUB 2 NCX,
  falling back to `h1` and `h2` headings. HTML chapters come from `h1` and
  `h2`. The EPUB cover image becomes the book cover served by
  `GET /audiobook/{book_id}/cover`.
- `GET /audiobook` and `GET /audiobook/{book_id}` include `author` when the
  document declares one.

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
