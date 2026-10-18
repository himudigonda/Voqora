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

Every request needs the per-launch `X-Voqora-IPC-Token` header, and requests
with an `Origin` header are refused. Speech lives in `app/api/tts.py`,
audiobooks in `app/api/audiobook.py`, and web articles in `app/api/article.py`.

### Web articles

| Method and path | Body | Result |
| --- | --- | --- |
| `POST /article/extract` | `{"url"}` | Fetches the page and returns the article |
| `POST /article/extract-html` | `{"url", "html"}` | Reads HTML the client already has, with no fetch. `html` is at most 5 MB |
| `POST /audiobook/url` | `{"url", "voice"?, "speed"?, "engine"?, "llm_provider"?, "llm_model"?, "llm_base_url"?}` | Adds the page to Library and returns the same estimate as `POST /audiobook` |

Both extract routes return `{url, title, byline, site_name, language, text,
markdown, word_count}`. `url` is the final address after redirects, without
the fragment. `text` is the article body as plain paragraphs, and code blocks
stay in it. `markdown` starts with `# title`, then the byline, then the body
with `##` and `###` headings, lists, quotes, and fenced code. `language` is the
page's lowercased `lang` tag, such as `en-gb`, or `null`.

`POST /audiobook/url` stores an article as Markdown, so its headings become
sections. A plain-text page is stored as TXT and a PDF link goes through the PDF
path. The book's metadata keeps `source_url`. As with an upload, narration
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

## Tests

```bash
make test          # fast backend suite only
make verify        # lint + fast backend suite
```

The model and voice artifacts are downloaded by the packaging path and ignored
by Git. See the [architecture guide](../docs/architecture.md) for how the
native app launches the bundled service.
