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
- Use an AI provider only for optional document cleanup, scanned-page OCR, and
  the AI reading tools. The provider and key come from the request headers and
  are never stored.

## API

### AI reading tools

`POST /ai/summarize`, `/ai/translate`, `/ai/ask`, `/ai/quiz`, and
`/ai/flashcards` take JSON and return JSON. They are not streamed. Each request
sends the provider in the same headers as audiobook cleanup:
`X-Voqora-LLM-Provider`, `X-Voqora-LLM-Key`, `X-Voqora-LLM-Model`, and
`X-Voqora-LLM-Base-URL`.

| Route | Body | Result |
| --- | --- | --- |
| `/ai/summarize` | `text` (up to 200,000 characters) or `book_id`; `length` `short`, `medium` (default) or `detailed`; optional `language` | `summary`, `chunks` |
| `/ai/translate` | `text` (up to 20,000 characters), `target_language` | `text`, `detected_source_language` |
| `/ai/ask` | `book_id`, `question` (up to 1,000 characters), `history` (up to 10 turns of `role` and `content`) | `answer`, `found`, `citations` of `section_title`, `page`, `passage_index`, `quote` |
| `/ai/quiz` | `text` or `book_id`; `count` 3 to 20 (default 5); `difficulty` `easy`, `medium` (default) or `hard` | `questions` of `question`, four `choices`, `answer_index`, `explanation` |
| `/ai/flashcards` | `text` or `book_id`; `count` 5 to 40 (default 10) | `cards` of `front`, `back` |

Language codes are the app's own: `en-us`, `en-gb`, `es`, `fr-fr`, `it`,
`pt-br`, `hi`, `cmn`. Every result also has `tokens`, `tokens_estimated`,
`cost_usd` (`null` when the model has no known price), `provider`, and `model`.

How it works:

- Long books are summarized in parts, four at a time, and the part summaries
  are then combined.
- Ask splits the book's stored text into passages, ranks them with BM25, and
  sends only the best six. Quotes the model did not copy from a passage are
  replaced with the passage's opening words.
- Quiz and flashcards read up to 60,000 characters sampled evenly from the
  text.
- Document text, questions, and history are sent as marked data that the
  model is told never to follow as instructions.
- The model must reply with JSON that passes validation. One repair attempt is
  made, then the request fails with `ai_invalid_output`.
- One request may use at most `MAX_AI_REQUEST_TOKENS` tokens (600,000) and an
  estimated `MAX_AI_REQUEST_COST_USD` ($2.00). At most three AI requests run at
  once, and at most 30 start per minute.
- Summaries time out after 10 minutes and other tools after 5. Closing the
  connection cancels the work and any provider calls in flight.
- Logs record the tool, provider, model, token count, and duration. They never
  record document text, questions, answers, or keys.

Errors return `{"detail": "...", "code": "..."}`:

| Status | Codes |
| --- | --- |
| 400 | `ai_provider_required`, `llm_config_failed` |
| 404 | `book_not_found` |
| 409 | `book_text_unavailable` |
| 413 | `book_too_long`, `text_too_long`, `ai_budget_exceeded` |
| 422 | `no_text`, or request validation (FastAPI's usual `detail` list) |
| 429 | `ai_busy`, `ai_rate_limited` |
| 502 | `llm_auth_failed`, `llm_billing_failed`, `llm_model_not_found`, `llm_unreachable`, `llm_incomplete`, `llm_rejected`, `llm_failed`, `ai_invalid_output` |
| 503 | `llm_busy` |
| 504 | `ai_timeout` |

An unknown provider or a malformed key is rejected by the shared header check
with a 400 and `detail` only.

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
