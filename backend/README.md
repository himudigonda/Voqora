# Voqora local speech engine

This is the FastAPI service bundled inside the Voqora Mac app. It owns local
speech synthesis, progressive audio streaming, and PDF-to-audiobook work. It is
not a hosted Voqora API.

## Responsibilities

- Serve the local health, prewarm, speech, and audiobook endpoints.
- Load Kokoro ONNX and its voice data on the Mac.
- Stream generated audio back to the native client.
- Extract and persist audiobook work so long documents can resume.
- Use Gemini only for the optional PDF cleanup and OCR flow.

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
