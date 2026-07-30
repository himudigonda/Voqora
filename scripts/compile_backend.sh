#!/bin/bash
set -euo pipefail
echo "🚀 STARTING BACKEND BUILD..."

RESOURCE_DIR="frontend/Voqora/Voqora/Resources"
ARCHIVE_PATH="$RESOURCE_DIR/VoqoraServer.zip"
ARCHIVE_BUILD_ID_PATH="$RESOURCE_DIR/VoqoraServer.build-id"
INPUT_BUILD_ID_PATH="$RESOURCE_DIR/VoqoraServer.inputs.sha256"

# Rebuilding the frozen service takes significant CPU and memory. Reuse a
# package only when the exact runtime inputs, lockfile and archive digest all
# match. Set FORCE_BACKEND_REBUILD=1 for a clean release-candidate build.
compute_input_build_id() {
    {
        printf '%s\n' 'compile-script'
        shasum -a 256 "$0"
        printf '%s\n' 'runtime-source'
        # BSD sort on macOS does not support GNU's `-z`; Python source names
        # in this project are newline-free, so a normal stable line sort is
        # both portable and deterministic here.
        find backend/app -type f -name '*.py' -print | LC_ALL=C sort | while IFS= read -r file; do
            shasum -a 256 "$file"
        done
        printf '%s\n' 'dependency-lock'
        shasum -a 256 backend/pyproject.toml backend/uv.lock
        printf '%s\n' 'pinned-runtime-assets'
        printf '%s\n' 'kokoro-v1.0.onnx:7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5'
        printf '%s\n' 'voices-v1.0.bin:bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d'
    } | shasum -a 256 | awk '{print $1}'
}

INPUT_BUILD_ID="$(compute_input_build_id)"
if [ "${FORCE_BACKEND_REBUILD:-0}" != "1" ] \
    && [ -f "$ARCHIVE_PATH" ] \
    && [ -f "$ARCHIVE_BUILD_ID_PATH" ] \
    && [ -f "$INPUT_BUILD_ID_PATH" ]; then
    STORED_INPUT_BUILD_ID="$(tr -d '[:space:]' < "$INPUT_BUILD_ID_PATH")"
    STORED_ARCHIVE_BUILD_ID="$(tr -d '[:space:]' < "$ARCHIVE_BUILD_ID_PATH")"
    CURRENT_ARCHIVE_BUILD_ID="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
    if [ "$STORED_INPUT_BUILD_ID" = "$INPUT_BUILD_ID" ] \
        && [ "$STORED_ARCHIVE_BUILD_ID" = "$CURRENT_ARCHIVE_BUILD_ID" ]; then
        echo "✅ Backend package inputs are unchanged — reusing verified bundle."
        exit 0
    fi
fi

# 1. Cleanup
# Packaging a zip never needs to terminate a running local server. That server
# may belong to an installed app or another candidate and has already loaded
# its own extracted copy. Killing every process by name made an ordinary build
# disrupt unrelated Voqora sessions.
rm -rf backend/dist backend/build
rm -f "$ARCHIVE_PATH" "$ARCHIVE_BUILD_ID_PATH" "$INPUT_BUILD_ID_PATH"
# Remove any stale PyInstaller spec — it's gitignored, but a previous build's
# .spec may still hold the previous machine's `espeakng_loader` absolute path.
# We regenerate from CLI flags below so the dynamic ESPEAK_PATH is used. See HARD-051.
rm -f backend/VoqoraServer.spec

cd backend
# Ensure venv exists and is up to date
uv sync

# The speech model and voice pack are intentionally not committed to Git.
# Fetch the exact Voqora v1 assets on a clean checkout and verify their
# checksums before PyInstaller includes them in the local backend bundle.
MODEL_RELEASE_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
ensure_asset() {
    local file_name="$1"
    local expected_sha="$2"
    local actual_sha

    if [ -f "$file_name" ]; then
        actual_sha="$(shasum -a 256 "$file_name" | awk '{print $1}')"
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "✅ Verified $file_name"
            return
        fi
        echo "❌ $file_name exists but does not match the pinned Voqora v1 asset." >&2
        exit 1
    fi

    echo "📥 Downloading $file_name..."
    local temp_file="${file_name}.download"
    rm -f "$temp_file"
    curl --fail --location --retry 3 --output "$temp_file" "$MODEL_RELEASE_URL/$file_name"
    actual_sha="$(shasum -a 256 "$temp_file" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "❌ Downloaded $file_name failed checksum verification." >&2
        rm -f "$temp_file"
        exit 1
    fi
    mv "$temp_file" "$file_name"
    echo "✅ Downloaded and verified $file_name"
}

ensure_asset "kokoro-v1.0.onnx" "7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5"
ensure_asset "voices-v1.0.bin" "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"

# 2. LOCATE CRITICAL ASSETS
PYTHON_EXEC="./.venv/bin/python"
ESPEAK_PATH=$($PYTHON_EXEC -c "import os, espeakng_loader; print(os.path.dirname(espeakng_loader.__file__))")
KOKORO_CONFIG=$($PYTHON_EXEC -c "import os, kokoro_onnx; print(os.path.join(os.path.dirname(kokoro_onnx.__file__), 'config.json'))")

echo "📍 Kokoro config: $KOKORO_CONFIG"
echo "📍 Espeak data:   $ESPEAK_PATH"

# 3. COMPILE (Kokoro-only — ~300 MB vs ~700 MB with Kitten)
#
# PyInstaller Analysis phase pulls ~2 GB RAM and macOS jetsam (memory-pressure
# daemon) can issue SIGTERM mid-run (exit 143). The first attempt uses --clean
# (fresh .toc files). On SIGTERM/OOM the cached .toc files from the aborted run
# survive on disk; subsequent retries DROP --clean so PyInstaller reuses them —
# far less RAM, much less likely to be killed again.
PYINSTALLER_FLAGS=(
    --noconsole --onedir --noconfirm --name 'VoqoraServer'
    --paths .
    --add-data 'kokoro-v1.0.onnx:.'
    --add-data 'voices-v1.0.bin:.'
    --add-data "$ESPEAK_PATH:espeakng_loader"
    --collect-all 'phonemizer'
    --collect-all 'language_tags'
    --collect-all 'kokoro_onnx'
    --collect-all 'misaki'
    --collect-all 'pdfplumber'
    --collect-all 'pdfminer'
    --collect-all 'pypdfium2'
    --collect-all 'pypdfium2_raw'
    # Keep Gemini's runtime package data without recursively collecting its
    # bundled test suite. `--collect-all` asks PyInstaller to analyse hundreds
    # of SDK test modules, wasting CPU and bloating every local server bundle.
    --collect-data 'google.genai'
    --collect-all 'PIL'
    --hidden-import 'uvicorn.loops.asyncio'
    --hidden-import 'uvicorn.protocols.http.h11_impl'
    --hidden-import 'fastapi'
    --hidden-import 'starlette'
    --hidden-import 'python_multipart'
    --hidden-import 'multipart'
    --hidden-import 'google.genai.types'
    --hidden-import 'pdfminer.layout'
    --hidden-import 'pdfminer.high_level'
    app/main.py
)

MAX_ATTEMPTS=3
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if [ "$attempt" -eq 1 ]; then
        CLEAN_FLAG="--clean"
    else
        # Subsequent retries reuse cached .toc files to stay under macOS jetsam
        # memory limit — Analysis is the heaviest phase and is already done.
        CLEAN_FLAG=""
        echo "⚠️  Attempt $attempt/$MAX_ATTEMPTS (reusing cached analysis tocs)..."
        sleep 2
    fi
    set +e
    $PYTHON_EXEC -m PyInstaller $CLEAN_FLAG "${PYINSTALLER_FLAGS[@]}"
    EXIT_CODE=$?
    set -e
    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "✅ PyInstaller succeeded on attempt $attempt."
        break
    fi
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        echo "❌ PyInstaller failed after $MAX_ATTEMPTS attempts (exit $EXIT_CODE)."
        exit $EXIT_CODE
    fi
    echo "⚠️  PyInstaller exited $EXIT_CODE on attempt $attempt, retrying..."
done

# 4. SURGICAL INJECTION — force-copy config.json if collect-all missed it
DEST_DIR="dist/VoqoraServer/_internal/kokoro_onnx"
if [ ! -f "$DEST_DIR/config.json" ]; then
    echo "💉 Manual injection of config.json..."
    mkdir -p "$DEST_DIR"
    cp "$KOKORO_CONFIG" "$DEST_DIR/"
else
    echo "✅ config.json collected automatically."
fi

# 5. ZIP AND MOVE
echo "📦 Zipping backend..."
cd dist
# `zip -r` is interrupt-prone for this large universal payload on macOS.
# `ditto` ships with macOS, produces a standards-compatible zip archive, and
# has been materially more reliable for the bundled server payload.
ditto -c -k --sequesterRsrc --keepParent VoqoraServer VoqoraServer.zip
cd ..

echo "📦 Installing to Resources..."
mkdir -p "../$RESOURCE_DIR"
mv dist/VoqoraServer.zip "../$ARCHIVE_PATH"
# The app uses this compact archive identity to decide whether its extracted
# local server is current. A version number alone is insufficient while
# developing or rebuilding a release candidate with the same app version.
shasum -a 256 "../$ARCHIVE_PATH" | awk '{print $1}' > "../$ARCHIVE_BUILD_ID_PATH"
printf '%s\n' "$INPUT_BUILD_ID" > "../$INPUT_BUILD_ID_PATH"

echo "✅ Backend build complete."
