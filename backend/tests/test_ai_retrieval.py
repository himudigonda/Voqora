from __future__ import annotations

from app.services.ai_retrieval import (
    BM25,
    evenly_spaced,
    group,
    pack,
    paragraphs,
    split_passages,
    tokenize,
)


def test_paragraphs_split_on_blank_lines_and_drop_empty_ones() -> None:
    text = "First line\nstill first.\n\n\n  Second.  \n \nThird."
    assert paragraphs(text) == ["First line\nstill first.", "Second.", "Third."]
    assert paragraphs("   \n\n  ") == []


def test_pack_respects_the_size_limit_and_keeps_order() -> None:
    blocks = [f"Paragraph {i} " + "word " * 20 for i in range(30)]
    packed = pack(blocks, 400)
    assert all(len(chunk) <= 400 for chunk in packed)
    assert "".join(packed).replace("\n\n", "") == "".join(blocks)


def test_pack_splits_an_oversized_paragraph_by_sentence_then_hard() -> None:
    sentence = "This is a sentence. "
    packed = pack([sentence * 50 + "x" * 900], 300)
    assert all(len(chunk) <= 300 for chunk in packed)
    assert sum(chunk.count("sentence") for chunk in packed) == 50


def test_group_never_splits_a_unit() -> None:
    units = ["a" * 50, "b" * 500, "c" * 10, "d" * 10]
    assert group(units, 100) == [["a" * 50], ["b" * 500], ["c" * 10, "d" * 10]]
    assert group([], 100) == []


def test_group_caps_the_number_of_units_per_group() -> None:
    assert group(["a", "b", "c", "d", "e"], 100, max_items=2) == [
        ["a", "b"],
        ["c", "d"],
        ["e"],
    ]


def test_tokenize_lowercases_and_splits_cjk_into_characters() -> None:
    assert tokenize("Hello, World! 42") == ["hello", "world", "42"]
    assert tokenize("中文测试") == ["中", "文", "测", "试"]


def test_bm25_ranks_the_matching_passage_first_and_skips_zero_scores() -> None:
    documents = [
        "The cat sat on the mat.",
        "Photosynthesis converts light into chemical energy in plants.",
        "Dogs bark at the mailman.",
        "Plants need light, water, and carbon dioxide for photosynthesis.",
    ]
    ranked = BM25(documents).top("How does photosynthesis use light?", 3)
    assert [index for index, _ in ranked][:2] in ([1, 3], [3, 1])
    assert all(score > 0 for _, score in ranked)
    assert 0 not in [index for index, _ in ranked]
    assert BM25(documents).top("quantum chromodynamics", 3) == []


def test_bm25_rare_terms_outweigh_common_ones() -> None:
    documents = ["the the the apple", "the zebra", "the the banana"]
    ranked = BM25(documents).top("the zebra", 3)
    assert ranked[0][0] == 1


def test_bm25_handles_an_empty_corpus() -> None:
    assert BM25([]).top("anything", 5) == []
    assert BM25([""]).score("anything") == [0.0]


def test_split_passages_carries_page_and_section() -> None:
    pages = [
        (1, "Intro", "Alpha paragraph.\n\nBeta paragraph."),
        (3, "", "Gamma " * 100),
    ]
    passages = split_passages(pages, 200)
    assert passages[0].page == 1
    assert passages[0].section_title == "Intro"
    assert passages[-1].page == 3
    assert [p.index for p in passages] == list(range(len(passages)))
    assert all(len(p.text) <= 200 for p in passages)


def test_evenly_spaced_samples_across_the_whole_text_within_the_budget() -> None:
    chunks = [f"{i:03d}" + "x" * 97 for i in range(100)]
    picked = evenly_spaced(chunks, 1_000)
    assert sum(len(chunk) for chunk in picked) <= 1_000
    assert picked[0].startswith("000")
    assert int(picked[-1][:3]) >= 80
    assert evenly_spaced(chunks[:3], 1_000) == chunks[:3]
    assert evenly_spaced([], 10) == []


def test_evenly_spaced_trims_a_single_oversized_chunk() -> None:
    assert evenly_spaced(["y" * 500], 100) == ["y" * 100]
