import json, re, sys

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()

def num_words(n):
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000: return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + num_words(n % 100))
    return str(n)

def norm(text):
    text = re.sub(r"\[\[[^\]]*\]\]", " ", text).lower()
    text = re.sub(r"(\d+)%", lambda m: m.group(1) + " percent", text)
    text = re.sub(r"\d+", lambda m: " " + num_words(int(m.group())) + " ", text)
    text = text.replace("-", " ")
    return re.findall(r"[a-z']+", text)

def sentences(ref):
    plain = re.sub(r"\[\[[^\]]*\]\]", " ", ref)
    return [s for s in re.split(r"(?<=[.?!])\s+", plain) if norm(s)]

def align(r, h):
    n, m = len(r), len(h)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (r[i-1] != h[j-1]))
    i, j, matched, ops = n, m, [False] * n, {"sub": 0, "del": 0, "ins": 0}
    ins_words = []
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (r[i-1] != h[j-1]):
            if r[i-1] == h[j-1]: matched[i-1] = True
            else: ops["sub"] += 1
            i, j = i-1, j-1
        elif i and d[i][j] == d[i-1][j] + 1: ops["del"] += 1; i -= 1
        else: ops["ins"] += 1; ins_words.append(j-1); j -= 1
    return d[n][m], matched, ops, ins_words

def tokens(text):
    return [w for w in re.split(r"[^\w']+", text.lower()) if w]

def common_subsequence(a, b):
    prev = [0] * (len(b) + 1)
    for x in a:
        row = [0] * (len(b) + 1)
        for j, y in enumerate(b):
            row[j + 1] = prev[j] + 1 if x == y else max(prev[j + 1], row[j])
        prev = row
    return prev[-1]

def is_restart(previous, nxt):
    old, new = tokens(previous), tokens(nxt)
    if len(old) < 2 or not new or len(new) >= len(old):
        return False
    return len(new) * 2 <= len(old) or common_subsequence(old, new) * 2 < len(new)

def segmented(events):
    committed, current = [], ""
    for e in events:
        text = e["text"].strip()
        if not text:
            continue
        if is_restart(current, text):
            committed.append(current)
        if e["isFinal"]:
            committed.append(text)
            current = ""
        else:
            current = text
    return " ".join(committed + ([current] if current else [])), 0

def assemble(events, policy):
    if policy == "segmented":
        return segmented(events)
    committed, volatile, shrinks, last_visible = [], "", 0, ""
    for e in events:
        if policy == "replace":
            visible = e["text"]
        else:
            if e["isFinal"]: committed.append(e["text"]); volatile = ""
            else: volatile = e["text"]
            visible = "".join(committed) + volatile
        lv, nv = norm(last_visible), norm(visible)
        if len(nv) < len(lv) - 3: shrinks += 1
        last_visible = visible
    return last_visible, shrinks

def score(ref_text, hyp_text):
    r, h = norm(ref_text), norm(hyp_text)
    dist, matched, ops, ins = align(r, h)
    k, dropped = 0, 0
    for s in sentences(ref_text):
        w = len(norm(s)); hit = sum(matched[k:k+w]); k += w
        if hit < 0.5 * w: dropped += 1
    dup = sum(1 for j in ins if any(h[j] == h[x] for x in range(max(0, j-6), j)))
    return {"ref_words": len(r), "hyp_words": len(h), "wer": round(dist / len(r), 4), **ops,
            "sentences": len(sentences(ref_text)), "dropped_sentences": dropped,
            "duplicate_words": dup, "duplicate_rate": round(dup / len(r), 4)}

if __name__ == "__main__":
    ref = open(sys.argv[1]).read()
    data = json.load(open(sys.argv[2]))
    events = data["events"] if isinstance(data, dict) else data
    policy = sys.argv[3]
    text, shrinks = assemble([e for e in events if "text" in e and (e.get("error") is None)], policy)
    out = score(ref, text); out["visible_shrinks"] = shrinks; out["policy"] = policy
    print(json.dumps(out))
    if len(sys.argv) > 4: open(sys.argv[4], "w").write(text)
