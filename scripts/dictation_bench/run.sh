#!/bin/zsh
set -euo pipefail
here=${0:A:h}
out=${1:-${TMPDIR:-/tmp}/voqora-dictation-bench}
speed=${2:-0}
mkdir -p "$out"

build() {
  local name=$1 source=$2 binary=$3
  local app="$out/$name.app"
  mkdir -p "$app/Contents/MacOS"
  sed "s/dictation-repro/dictation-$binary/" "$here/Info.plist" > "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $binary" "$app/Contents/Info.plist"
  swiftc -parse-as-library -O "$here/$source" -o "$app/Contents/MacOS/$binary"
  codesign -s - --force "$app" >/dev/null
}

for fixture in multi-paragraph-49s long-session-10min; do
  [[ -f "$out/$fixture.aiff" ]] || say -v Samantha -o "$out/$fixture.aiff" -f "$here/$fixture.say.txt"
done
build AnalyzerBench analyzer.swift analyzer
build LegacyBench legacy.swift legacy

for fixture in multi-paragraph-49s long-session-10min; do
  /usr/bin/time -l "$out/AnalyzerBench.app/Contents/MacOS/analyzer" "$out/$fixture.aiff" "$out/$fixture.analyzer.json" "$speed" speech 2> "$out/$fixture.analyzer.time"
  for policy in replace ledger; do
    python3 "$here/score.py" "$here/$fixture.say.txt" "$out/$fixture.analyzer.json" "$policy"
  done
done

open -W -n "$out/LegacyBench.app" --args "$out/multi-paragraph-49s.aiff" "$out/multi-paragraph-49s.legacy.json" 1
python3 "$here/score.py" "$here/multi-paragraph-49s.say.txt" "$out/multi-paragraph-49s.legacy.json" replace
python3 "$here/score.py" "$here/multi-paragraph-49s.say.txt" "$out/multi-paragraph-49s.legacy.json" segmented
