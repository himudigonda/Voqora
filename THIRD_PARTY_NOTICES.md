# Third-party notices

Voqora is distributed with third-party software and assets. Those components
keep their own licenses and are not relicensed by Voqora's licenses. Thank you
to every author and maintainer below; Voqora would not exist without them.

## App

| Component | Role | License / source |
| --- | --- | --- |
| KeyboardShortcuts | macOS global shortcut support | [MIT](https://github.com/sindresorhus/KeyboardShortcuts/blob/main/license) |
| Sparkle | Update framework, linked but not started in the early-access channel | [MIT and bundled notices](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE) |
| Poppins | Bundled interface typeface | [SIL Open Font License 1.1](https://fonts.google.com/specimen/Poppins/about) |

## Local speech server

| Component | Role | License / source |
| --- | --- | --- |
| Kokoro-82M weights | Local speech model | [Apache-2.0](https://huggingface.co/hexgrad/Kokoro-82M) |
| kokoro-onnx | ONNX packaging of Kokoro and its model files | [MIT](https://github.com/thewh1teagle/kokoro-onnx) |
| phonemizer-fork | Text-to-phoneme conversion | [GPL-3.0](https://github.com/bootphon/phonemizer) |
| espeak-ng (via espeakng-loader) | Phonemization library and data | [GPL-3.0-or-later](https://github.com/espeak-ng/espeak-ng) |
| ONNX Runtime | Local model inference | [MIT](https://github.com/microsoft/onnxruntime/blob/main/LICENSE) |
| ONNX | Model format | [Apache-2.0](https://github.com/onnx/onnx) |
| FastAPI, Pydantic, pydantic-settings | Local HTTP service | MIT |
| Starlette, Uvicorn | Local HTTP service | BSD-3-Clause |
| python-multipart, aiofiles | Upload handling | Apache-2.0 |
| NumPy | Audio processing | BSD-3-Clause and bundled notices |
| soundfile (libsndfile, LAME, mpg123) | Audio encoding and MP3 export | BSD-3-Clause; libsndfile is LGPL-2.1; LAME is LGPL-2.0; mpg123 is LGPL-2.1 |
| psutil | Resource checks | BSD-3-Clause |
| pdfplumber, pdfminer.six | PDF text extraction | MIT |
| pypdfium2 (PDFium) | PDF rendering | BSD-3-Clause, Apache-2.0 |
| Pillow | Image handling | MIT-CMU and bundled notices |
| python-docx | DOCX import | MIT |
| lxml | DOCX, EPUB, HTML parsing and web article extraction | BSD-3-Clause |
| pypinyin | Chinese pronunciation | MIT |
| google-genai | Optional Gemini cleanup | Apache-2.0 |
| httpx | Optional AI provider cleanup and web article download | BSD-3-Clause |
| huggingface-hub | Model download | Apache-2.0 |
| supertonic (Python package) | Runs the optional Supertonic speech engine | [MIT](https://github.com/supertone-inc/supertonic-py) |
| Supertonic 3 weights (optional download) | Optional local speech model, fetched on request and never bundled | [BigScience OpenRAIL-M](https://huggingface.co/Supertone/supertonic-3) |

The app bundle also contains this notice, the Voqora license, and the
commercial-license notice. Before redistributing a modified bundle, review the
licenses and notices shipped by each bundled dependency and preserve all terms
that apply to it.

## Supertonic (optional speech engine)

Supertonic is an optional engine that Voqora downloads only when you choose
**Download** under Preferences, Speech Engines. The model files are not part of
the app bundle. Voqora fetches Supertone's `Supertone/supertonic-3` repository
at a pinned revision (`724fb5abbf5502583fb520898d45929e62f02c0b`) from Hugging
Face into `~/Library/Application Support/com.himudigonda.Voqora/models/` and
keeps the license file that ships with the model next to the files.

- The `supertonic` Python package (1.3.1, Supertone Inc.) is MIT licensed and is
  bundled in the local speech server.
- The model weights are released under the BigScience Open RAIL-M License. It
  grants broad rights to use and redistribute the model, and it attaches
  use-based restrictions (Attachment A of the license) that must travel with
  the model and any derivative of it. Read those restrictions before relying on
  Supertonic voices: <https://huggingface.co/Supertone/supertonic-3>. Voqora
  does not relicense the weights, and removing the engine in Preferences deletes
  the downloaded files.

## GPL components and source code

The local speech server bundles phonemizer-fork 3.3.2 (GPL-3.0) and
espeakng-loader 0.2.4 with the espeak-ng library and data (GPL-3.0-or-later).
For that reason the speech server (`backend/`) is itself licensed under
GPL-3.0-or-later (see `backend/LICENSE`). Its complete source, including the
build scripts in `scripts/`, is in this repository at the tag matching each
release: <https://github.com/himudigonda/Voqora>.

The GPL components are unmodified upstream releases. Their source is available
from the projects listed above and from PyPI (`phonemizer-fork==3.3.2`,
`espeakng-loader==0.2.4`). If you cannot get any source you are entitled to
under the GPL from those locations, open an issue in this repository and it
will be provided.

The Voqora app is a separate program. It starts the speech server as a separate
process and communicates with it only over a private local HTTP connection.
