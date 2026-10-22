import json, re, sys
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer
norm = EnglishTextNormalizer()
FILLERS = {"um", "uh", "uhm", "erm", "hmm", "mm"}
clips = {}
for line in open(sys.argv[1]):
    r = json.loads(line); clips[r["id"]] = r
def wer(pairs):
    refs = [norm(r) for r, h in pairs]; hyps = [norm(h) for r, h in pairs]
    keep = [(r, h) for r, h in zip(refs, hyps) if r.strip()]
    return 100 * jiwer.wer([r for r, _ in keep], [h if h.strip() else "<empty>" for _, h in keep])
engines = sys.argv[2:]
sets = ["librispeech_other", "ami", "earnings22", "voxpopuli", "common_voice", "disfluency"]
rows = {}
for path in engines:
    name = path.split("/")[-1].replace(".jsonl", "")
    hyp = {json.loads(l)["id"]: json.loads(l) for l in open(path)}
    row = {}
    for s in sets:
        ids = [i for i, c in clips.items() if c["set"] == s and i in hyp]
        row[s] = wer([(clips[i]["ref"], hyp[i]["hyp"]) for i in ids])
        if s == "disfluency":
            row["disfluency_verbatim"] = wer([(clips[i]["ref_verbatim"], hyp[i]["hyp"]) for i in ids])
    row["avg5"] = sum(row[s] for s in sets[:5]) / 5
    words = sum(len(h["hyp"].split()) for h in hyp.values())
    fillers = sum(1 for h in hyp.values() for w in re.findall(r"[a-z]+", h["hyp"].lower()) if w in FILLERS)
    row["fillers_per_1k"] = 1000 * fillers / max(words, 1)
    secs = sum(h["seconds"] for h in hyp.values()); audio = sum(clips[i]["dur"] for i in hyp)
    row["rtfx"] = audio / secs
    row["n"] = len(hyp)
    rows[name] = row
cols = sets + ["disfluency_verbatim", "avg5", "fillers_per_1k", "rtfx", "n"]
print("| engine | " + " | ".join(cols) + " |"); print("|---" * (len(cols) + 1) + "|")
for k, r in rows.items():
    print(f"| {k} | " + " | ".join(f"{r[c]:.2f}" if isinstance(r[c], float) else str(r[c]) for c in cols) + " |")
