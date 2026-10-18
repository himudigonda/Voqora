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
