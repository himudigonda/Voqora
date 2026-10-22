#!/bin/zsh
set -euo pipefail
here=${0:A:h}
work=${1:-${TMPDIR:-/tmp}/voqora-engine-bench}
mkdir -p "$work/clips" "$work/results"
cd "$work"
[[ -d .venv ]] || uv venv -q --python 3.11 .venv
uv pip install -q --python .venv/bin/python huggingface_hub numpy soundfile soxr jiwer whisper-normalizer pyarrow
.venv/bin/python -I - <<'PY'
from huggingface_hub import hf_hub_download as get, snapshot_download
for f in ["librispeech/test.other-00000-of-00001.parquet", "ami_cleaned/test-00002-of-00003.parquet", "earnings22/test-00003-of-00005.parquet", "voxpopuli_cleaned_aa/test-00000-of-00001.parquet", "common_voice/test-00002-of-00003.parquet"]:
    get("hf-audio/open-asr-leaderboard", f, repo_type="dataset", local_dir="data")
get("amaai-lab/DisfluencySpeech", "data/test-00000-of-00001.parquet", repo_type="dataset", local_dir="data/disfluency")
snapshot_download("FluidInference/bark-3.0-coreml", revision="73b0c0da665d29ea0332e9f0d32da8e26a4cdb38", local_dir="fluid", ignore_patterns=["*/Encoder_lut3.mlmodelc/*"])
PY
[[ -f clips/manifest.jsonl ]] || .venv/bin/python -I "$here/prep.py" "$work"
swift build -c release --package-path "$here/asrbench" --scratch-path "$work/asrbench-build"
bench="$work/asrbench-build/release/asrbench"
"$bench" parakeet clips/manifest.jsonl results/parakeet.jsonl
"$bench" "$work/fluid/bark-3.0" clips/manifest.jsonl results/bark-3.0.jsonl
"$bench" "$work/fluid/bark-3.0-clean" clips/manifest.jsonl results/bark-3.0-clean.jsonl
.venv/bin/python -I "$here/score.py" clips/manifest.jsonl results/parakeet.jsonl results/bark-3.0.jsonl results/bark-3.0-clean.jsonl
