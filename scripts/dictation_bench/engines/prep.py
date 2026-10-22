import io, json, random, sys
import numpy as np, pyarrow.parquet as pq, soundfile as sf, soxr
root = sys.argv[1]
sets = {
    "librispeech_other": ("data/librispeech/test.other-00000-of-00001.parquet", 300),
    "ami": ("data/ami_cleaned/test-00002-of-00003.parquet", 300),
    "earnings22": ("data/earnings22/test-00003-of-00005.parquet", 300),
    "voxpopuli": ("data/voxpopuli_cleaned_aa/test-00000-of-00001.parquet", 300),
    "common_voice": ("data/common_voice/test-00002-of-00003.parquet", 300),
    "disfluency": ("data/disfluency/data/test-00000-of-00001.parquet", 250),
}
out = open(f"{root}/clips/manifest.jsonl", "w")
total = 0.0
for name, (path, n) in sets.items():
    rows = pq.read_table(f"{root}/{path}").to_pylist()
    random.Random(7).shuffle(rows)
    kept = 0
    for i, r in enumerate(rows):
        if kept >= n:
            break
        ref = r.get("text") or r.get("transcript_c")
        if not ref or not ref.strip():
            continue
        wave, sr = sf.read(io.BytesIO(r["audio"]["bytes"]), dtype="float32", always_2d=True)
        wave = wave.mean(1)
        if sr != 16000:
            wave = soxr.resample(wave, sr, 16000)
        dur = len(wave) / 16000
        if dur < 0.5 or dur > 40:
            continue
        wav = f"{root}/clips/{name}_{kept:04d}.wav"
        sf.write(wav, wave, 16000, subtype="PCM_16")
        rec = {"id": f"{name}_{kept:04d}", "set": name, "path": wav, "ref": ref, "dur": dur}
        if name == "disfluency":
            rec["ref_verbatim"] = r["transcript_a"]
        out.write(json.dumps(rec) + "\n")
        kept += 1
        total += dur
    print(name, kept)
print("hours", total / 3600)
