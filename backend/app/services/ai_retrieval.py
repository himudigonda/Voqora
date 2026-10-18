import math
import re
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass

_PARAGRAPH_BREAK = re.compile(r"\n\s*\n")
_SENTENCE_END = re.compile(r"(?<=[.!?。！？।])\s+")
_WORD = re.compile(r"\w+", re.UNICODE)
_CJK = re.compile(r"[㐀-鿿豈-﫿]")


@dataclass(frozen=True)
class Passage:
    index: int
    page: int
    section_title: str
    text: str


def paragraphs(text: str) -> list[str]:
    return [part.strip() for part in _PARAGRAPH_BREAK.split(text) if part.strip()]


def _hard_split(text: str, max_chars: int) -> list[str]:
    return [text[i : i + max_chars] for i in range(0, len(text), max_chars)]


def _bounded_units(paragraph: str, max_chars: int) -> list[str]:
    if len(paragraph) <= max_chars:
        return [paragraph]
    units: list[str] = []
    for sentence in _SENTENCE_END.split(paragraph):
        units.extend(_hard_split(sentence, max_chars))
    return units


def group(units: Iterable[str], max_chars: int, gap: int = 2) -> list[list[str]]:
    groups: list[list[str]] = []
    current: list[str] = []
    size = 0
    for unit in units:
        added = len(unit) + (gap if current else 0)
        if current and size + added > max_chars:
            groups.append(current)
            current, size = [], 0
            added = len(unit)
        current.append(unit)
        size += added
    if current:
        groups.append(current)
    return groups


def pack(blocks: Iterable[str], max_chars: int, separator: str = "\n\n") -> list[str]:
    units = (unit for block in blocks for unit in _bounded_units(block, max_chars))
    return [separator.join(items) for items in group(units, max_chars, len(separator))]


def split_passages(
    pages: Iterable[tuple[int, str, str]], max_chars: int
) -> list[Passage]:
    passages: list[Passage] = []
    for page, section_title, text in pages:
        for chunk in pack(paragraphs(text), max_chars):
            passages.append(Passage(len(passages), page, section_title, chunk))
    return passages


def tokenize(text: str) -> list[str]:
    tokens: list[str] = []
    for word in _WORD.findall(text.lower()):
        if _CJK.search(word):
            tokens.extend(ch for ch in word if not ch.isspace())
        else:
            tokens.append(word)
    return tokens


class BM25:
    def __init__(
        self, documents: list[str], *, k1: float = 1.5, b: float = 0.75
    ) -> None:
        self._k1 = k1
        self._b = b
        self._frequencies = [Counter(tokenize(doc)) for doc in documents]
        self._lengths = [sum(freq.values()) for freq in self._frequencies]
        count = len(documents)
        self._average_length = (sum(self._lengths) / count) if count else 0.0
        document_frequency: Counter[str] = Counter()
        for freq in self._frequencies:
            document_frequency.update(freq.keys())
        self._idf = {
            term: math.log(1 + (count - df + 0.5) / (df + 0.5))
            for term, df in document_frequency.items()
        }

    def score(self, query: str) -> list[float]:
        terms = set(tokenize(query))
        return [
            self._document_score(terms, freq, length)
            for freq, length in zip(self._frequencies, self._lengths, strict=True)
        ]

    def _document_score(
        self, terms: set[str], freq: Counter[str], length: int
    ) -> float:
        if not self._average_length:
            return 0.0
        norm = self._k1 * (1 - self._b + self._b * length / self._average_length)
        total = 0.0
        for term in terms:
            tf = freq.get(term, 0)
            if tf:
                total += self._idf[term] * tf * (self._k1 + 1) / (tf + norm)
        return total

    def top(self, query: str, limit: int) -> list[tuple[int, float]]:
        ranked = sorted(
            ((i, s) for i, s in enumerate(self.score(query)) if s > 0),
            key=lambda item: (-item[1], item[0]),
        )
        return ranked[:limit]


def evenly_spaced(chunks: list[str], max_chars: int) -> list[str]:
    total = sum(len(chunk) for chunk in chunks)
    if total <= max_chars:
        return list(chunks)
    average = total / len(chunks)
    wanted = max(1, min(len(chunks), int(max_chars // max(average, 1.0))))
    step = len(chunks) / wanted
    picked = [chunks[int(i * step)] for i in range(wanted)]
    out: list[str] = []
    used = 0
    for chunk in picked:
        if used + len(chunk) > max_chars and out:
            break
        out.append(chunk[: max_chars - used])
        used += len(out[-1])
    return out
