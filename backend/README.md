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

Every request needs the per-launch `X-Voqora-IPC-Token` header. Errors use
FastAPI's `{"detail": ...}` body; 422 means a field failed validation.

Speech and voices:

- `POST /speak` takes `text`, `voice`, `speed`, `volume`, `lang` and an
  optional `pause_scale` (0.5 to 2.0, default 1.0) that lengthens or shortens
  the pause after each phrase and paragraph. It streams `audio/wav`.
- `POST /prewarm` takes the same `voice`, `speed` and `pause_scale`. Use the
  values you will send to `/speak`, or the warm-up is not reused.
- `GET /engine` also returns `blends`, the saved voice blends. `voices` still
  lists only the 28 built-in voices.
- Anywhere a voice id is accepted (`/speak`, `/prewarm`, audiobook upload), a
  blend id (`blend:<uuid4>`) works too. An unknown or deleted blend is a 422.

Voice blends mix 2 to 4 built-in voices, each weighted 0.05 to 1. Weights are
normalized so they add up to 1, and the style vectors are summed with those
weights. A blend speaks in the language of its first voice. Up to 50 blends
are kept in `voice_blends.json` in the app data folder.

- `GET /voices/blends` returns `{"blends": [...], "max_blends": 50}`.
- `GET /voices/blends/{id}` returns one blend.
- `POST /voices/blends` with `{"name", "components": [{"voice", "weight"}]}`
  returns 201 and the blend. 409 when 50 already exist.
- `PUT /voices/blends/{id}` takes the same body, keeps the id and adds one to
  `version`.
- `DELETE /voices/blends/{id}` returns `{"status": "deleted", "id"}`.

A blend is returned as `{"id", "name", "lang", "version", "components":
[{"voice", "weight", "normalized_weight"}], "created_at", "updated_at"}`.

Pronunciations are kept in `pronunciations.json` in the app data folder, up
to 500 entries. An entry is `{"id", "match", "replacement", "case_sensitive",
"whole_word", "scope", "created_at", "updated_at"}`. `match` is 1 to 100
characters, `replacement` is 0 to 200, and `scope` is `"global"` or a book id.

- `GET /pronunciations?scope=` returns `{"version", "max_entries",
  "entries"}`. `version` goes up on every change.
- `POST /pronunciations` returns 201. 404 when the book scope does not exist,
  409 for a duplicate or when 500 already exist.
- `PUT /pronunciations/{id}` and `DELETE /pronunciations/{id}`.
- `POST /pronunciations/test` with `{"text", "book_id"?}` returns `{"text",
  "spoken", "replacements", "version"}`.

Entries are applied to each phrase just before it is turned into phonemes:
global entries first, then the book's entries, each pass taking the longest
match first and never re-reading its own replacements. Matching is literal,
so regex characters have no special meaning. Whole-word entries do not match
inside a longer word. Phrase boundaries come from the original text, so a
match that spans a phrase break (a comma, a sentence end, or the five-word
chunking of long sentences) is not replaced. Audiobook transcripts show the
original words while the audio speaks the replacement. Deleting a book
deletes its entries.

Audiobook upload (`POST /audiobook`) also accepts a `pause_scale` form field.
A book whose blend was deleted is narrated with the blend's first voice,
saved on the book at upload time, or the default voice.

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
