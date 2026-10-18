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
match first and never re-reading its own replacements. A book entry with the
same match and options as a global entry replaces that global entry for the
book. Matching is literal, so regex characters have no special meaning.
Whole-word entries do not match inside a longer word. Phrase boundaries come
from the original text, so a match that spans punctuation that ends a phrase
(such as a comma or a sentence end) is not replaced. A phrase that is left
with no letters or digits is skipped. Audiobook transcripts show the
original words while the audio speaks the replacement. Deleting a book
deletes its entries.

Audiobook upload (`POST /audiobook`) also accepts a `pause_scale` form field.
A book whose blend was deleted is narrated with the blend's first voice,
saved on the book at upload time, or the default voice.

## API

Every request needs the per-launch `X-Voqora-IPC-Token` header, and requests
with an `Origin` header are refused. Speech lives in `app/api/tts.py`,
audiobooks in `app/api/audiobook.py`, and web articles in `app/api/article.py`.

### Web articles

| Method and path | Body | Result |
| --- | --- | --- |
| `POST /article/extract` | `{"url"}` | Fetches the page and returns the article |
| `POST /article/extract-html` | `{"url", "html"}` | Reads HTML the client already has, with no fetch. `html` is at most 5 MB |
| `POST /audiobook/url` | `{"url", "voice"?, "speed"?, "engine"?, "pause_scale"?, "llm_provider"?, "llm_model"?, "llm_base_url"?}` | Adds the page to Library and returns the same estimate as `POST /audiobook` |

Both extract routes return `{url, title, byline, site_name, language, text,
markdown, word_count}`. `url` is the final address after redirects, without
the fragment. `text` is the article body as plain paragraphs, and code blocks
stay in it. `markdown` starts with `# title`, then the byline, then the body
with `##` and `###` headings, lists, quotes, and fenced code. `language` is the
page's lowercased `lang` tag, such as `en-gb`, or `null`. The text encoding
comes from a byte order mark, the `Content-Type` charset, or a `<meta charset>`
tag, in that order; an undeclared page is read as UTF-8, or Windows-1252 if it
is not valid UTF-8.

`POST /audiobook/url` stores an article as Markdown, so its headings become
sections. A plain-text page is stored as TXT and a PDF link goes through the PDF
path. The book's metadata keeps `source_url`, and the article's byline becomes
the book's `author`. `voice` may be a blend id, and `pause_scale` works as it
does for an upload. As with an upload, narration
waits for `POST /audiobook/{book_id}/start`.

Fetching rules: http and https only, no user name or password in the URL, at
most 5 redirects, 15 seconds in total, and 10 MB after decompression. The
service resolves the host itself, refuses loopback, private, link-local,
shared, multicast, reserved, and unspecified addresses (IPv4, IPv6, and IPv4
inside IPv6), then connects to the checked address with the original `Host`
header and TLS name, so a DNS answer cannot change between the check and the
connection. Every redirect is checked the same way. Environment proxies are not
used. Accepted types are HTML, XHTML, plain text, and PDF. At most four fetches
run at once.

Failures return `{"detail": "<message for the user>", "code": "<code>"}`:

| Status | Code | Meaning |
| --- | --- | --- |
| 403 | `blocked_address` | Local or private address |
| 413 | `too_large` | Page over 10 MB, or HTML over 5 MB |
| 415 | `unsupported_type` | Not HTML, text, or PDF |
| 415 | `pdf_document` | A PDF sent to `/article/extract`; use `/audiobook/url` |
| 422 | `invalid_url` | Not an http or https address, or has credentials |
| 422 | `paywalled` | The site asked for a sign-in or subscription |
| 422 | `no_readable_content` | No article text was found |
| 429 | `busy` | Four fetches are already running |
| 502 | `unreachable` | DNS or connection failure |
| 502 | `not_found` | The site returned 404 or 410 |
| 502 | `http_error` | Other site errors, or a broken redirect |
| 502 | `too_many_redirects` | More than 5 redirects |
| 504 | `timeout` | The 15 second limit ran out |

Request validation failures (missing or oversized fields) are FastAPI's usual
422 with a `detail` list. Book creation failures on `/audiobook/url` use the
same `detail` messages as `POST /audiobook`.

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

## API

Every request needs the `X-Voqora-IPC-Token` header. Errors are JSON
`{"detail": "..."}` with a message safe to show the user.

### Transcript and exports

Export routes need a finished book. They return `409` while the book is
still being generated, `404` for an unknown book or a missing transcript or
audio, and `400` for a malformed `book_id`.

| Route | Returns |
| --- | --- |
| `GET /audiobook/{id}/transcript?words=true` | The transcript, with a `words` list (`text`, `start`, `end`) added to every timed line. Without `words=true` the response is unchanged. |
| `GET /audiobook/{id}/export/srt` | SubRip subtitles (`application/x-subrip`). |
| `GET /audiobook/{id}/export/vtt` | WebVTT subtitles (`text/vtt`). |
| `GET /audiobook/{id}/chapters` | `{"book_id", "total_audio_seconds", "chapters": [{"title", "start_seconds", "end_seconds"}]}`. |
| `GET /audiobook/{id}/export/mp3?bitrate=96` | The book's audio as a constant-bitrate MP3 (`audio/mpeg`). |
| `POST /audio/mp3?bitrate=96&name=clip` | One WAV clip, sent as the raw `audio/wav` body, converted to MP3. |

Subtitle cues follow the transcript's sentence timings. Lines wrap at 42
characters, a cue holds at most two lines, and cues never overlap. A long
sentence is split into several cues, timed by text length. Headings are
narrated as their own transcript line, so they appear as their own cue.
Section titles are not added as extra cues.

Chapters start at zero, are contiguous, and end at the end of the audio.
Section start times come from the per-page audio offsets.

Word timings are estimates: each sentence's duration is shared across its
words by their count of letters and digits. Punctuation joins the word before
it. Chinese, Japanese, and Korean text is timed per character.

MP3 bitrates are 64, 80, 96, 112, 128, 160, or 192 kbps (default 96). Mono
input stays mono. 24 kHz audio at 192 kbps is encoded at 48 kHz, because
MPEG-2 stops at 160 kbps. Encoding uses the LAME encoder inside the bundled
libsndfile. The MP3 is encoded to a temporary file under the audiobook data
folder, then streamed with `Content-Length` and deleted. The response starts
only after encoding finishes, so allow a long timeout for a long book. One
MP3 encode runs at a time; a second one gets `429` with `Retry-After`.

Clip conversion accepts 16-bit PCM or 32-bit float WAV, mono or stereo, at
16, 22.05, 24, 32, 44.1, or 48 kHz, up to `MAX_WAV_CONVERT_MB` (200 MB). It
returns `415` for another content type, `400` for an empty, non-WAV, or
unsupported file, `413` above the size limit, and `422` for a bad bitrate or
a `name` over 120 characters. A `503` means the build has no MP3 encoder.

Downloads carry `Content-Disposition: attachment` with an ASCII `filename`
and a UTF-8 `filename*`, both made from the book title with unsafe
characters replaced.

## Tests

```bash
make test          # fast backend suite only
make verify        # lint + fast backend suite
```

The model and voice artifacts are downloaded by the packaging path and ignored
by Git. See the [architecture guide](../docs/architecture.md) for how the
native app launches the bundled service.
