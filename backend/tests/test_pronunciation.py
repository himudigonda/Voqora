import concurrent.futures
import json
import os
import shutil
import tempfile
import uuid
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services import pronunciation as pronunciation_module
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.engine_manager import EngineManager
from app.services.pronunciation import (
    MAX_ENTRIES,
    MAX_SPOKEN_CHARS,
    SCOPE_GLOBAL,
    DuplicatePronunciationError,
    PronunciationEntry,
    PronunciationLimitError,
    PronunciationNotFoundError,
    PronunciationRules,
    PronunciationStore,
    pronunciations,
)
from app.services.tts import TTSEngine
from app.services.voices import builtin_spec

client = TestClient(app)
BOOK_ID = "a" * 32


def _entry(match, replacement, *, case_sensitive=False, whole_word=True, scope="g"):
    return PronunciationEntry(
        id=uuid.uuid4().hex,
        match=match,
        replacement=replacement,
        case_sensitive=case_sensitive,
        whole_word=whole_word,
        scope=SCOPE_GLOBAL if scope == "g" else scope,
        created_at="",
        updated_at="",
    )


def _apply(entries, text, book_entries=()):
    return PronunciationRules(1, (list(entries), list(book_entries))).apply(text)


class RecordingKokoro:
    voices = {"af_bella": np.zeros((4, 1, 2), dtype=np.float32)}

    def __init__(self):
        self.texts: list[str] = []

    def get_voice_style(self, name):
        return self.voices[name]

    def create(self, text, voice, speed, lang):
        self.texts.append(text)
        return np.ones(2400, dtype=np.float32), 24000


@pytest.fixture
def recording_model():
    model = RecordingKokoro()
    previous_model, previous_executor = TTSEngine._model, TTSEngine._executor
    TTSEngine._model = model
    TTSEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    TTSEngine._lookahead_cache.clear()
    yield model
    TTSEngine._executor.shutdown(wait=True)
    TTSEngine._model, TTSEngine._executor = previous_model, previous_executor
    TTSEngine._lookahead_cache.clear()


@pytest.fixture
def isolated_books(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="voqora_dict_books_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def _make_book():
    book_id = AudiobookStore.create_book("Dict.txt")
    AudiobookStore.write_meta(
        book_id,
        AudiobookStore.initial_meta(
            book_id, "Dict.txt", 1, "kokoro", "af_bella", 1.0, {"cost_usd": 0.0}
        ),
    )
    return book_id


# ---------- rule application ----------


def test_whole_word_does_not_touch_substrings():
    rules = [_entry("cat", "kitty")]
    assert _apply(rules, "cat concat cats cat.") == "kitty concat cats kitty."


def test_whole_word_matches_next_to_punctuation():
    rules = [_entry("GIF", "jif")]
    assert _apply(rules, "(GIF), GIF! 'GIF' GIF-file") == ("(jif), jif! 'jif' jif-file")


def test_partial_word_match_when_whole_word_disabled():
    rules = [_entry("ph", "f", whole_word=False)]
    assert _apply(rules, "Phone graph") == "fone graf"


def test_case_insensitive_by_default_and_sensitive_on_request():
    assert _apply([_entry("nasa", "nassa")], "NASA and Nasa") == "nassa and nassa"
    sensitive = [_entry("US", "U.S.", case_sensitive=True)]
    assert _apply(sensitive, "US and us") == "U.S. and us"


def test_longest_match_wins_on_overlap():
    rules = [_entry("New", "Knew"), _entry("New York", "Big Apple")]
    assert _apply(rules, "New York is new") == "Big Apple is Knew"


def test_replacements_are_not_rescanned_within_a_pass():
    rules = [_entry("a", "b"), _entry("b", "c")]
    assert _apply(rules, "a b") == "b c"


def test_regex_metacharacters_are_literal():
    rules = [
        _entry("C++", "see plus plus"),
        _entry("a.b", "dot", whole_word=False),
        _entry("(x)", "ex"),
        _entry("$5", "five dollars"),
    ]
    text = "C++ and axb, a.b, (x) $5 C+"
    assert _apply(rules, text) == ("see plus plus and axb, dot, ex five dollars C+")


def test_replacement_backslashes_are_literal():
    assert _apply([_entry("path", r"\1 \g<0>")], "path") == r"\1 \g<0>"


def test_unicode_matching_and_word_boundaries():
    rules = [_entry("café", "ka fay"), _entry("Ñandú", "nyandu")]
    assert _apply(rules, "Un café, cafés y ÑANDÚ.") == "Un ka fay, cafés y nyandu."


def test_decomposed_input_matches_composed_entry():
    rules = [_entry("café", "ka fay")]
    assert _apply(rules, "café time") == "ka fay time"


def test_cjk_partial_match_inside_runs():
    rules = [_entry("北京", "Beijing", whole_word=False)]
    assert _apply(rules, "我爱北京。") == "我爱Beijing。"


def test_global_pass_runs_before_book_pass():
    global_rules = [_entry("Dr", "Doctor")]
    book_rules = [_entry("Doctor Who", "the Doctor", scope=BOOK_ID)]
    assert _apply(global_rules, "Dr Who", book_rules) == "the Doctor"


def test_empty_replacement_deletes_word():
    assert _apply([_entry("um", "")], "so um yes") == "so  yes"


def test_expansion_is_capped_to_original_text():
    rules = [_entry("a", "x" * 200)]
    text = " ".join(["a"] * (MAX_SPOKEN_CHARS // 100))
    assert _apply(rules, text) == text


def test_empty_rules_are_identity():
    rules = PronunciationRules(0, ((), ()))
    assert rules.is_empty
    assert rules.apply("café") == "café"


# ---------- store ----------


def _store(tmp_path):
    return PronunciationStore(lambda: str(tmp_path / "dict.json"))


def _create(store, match="GIF", replacement="jif", **kwargs):
    fields = {
        "case_sensitive": False,
        "whole_word": True,
        "scope": SCOPE_GLOBAL,
        **kwargs,
    }
    return store.create(match=match, replacement=replacement, **fields)


def test_store_persists_and_bumps_version(tmp_path):
    store = _store(tmp_path)
    assert store.version == 0
    entry = _create(store, match="  GIF  ")
    assert entry.match == "GIF"
    assert store.version == 1
    updated = store.update(
        entry.id,
        match="GIF",
        replacement="giff",
        case_sensitive=True,
        whole_word=False,
        scope=SCOPE_GLOBAL,
    )
    assert updated.created_at == entry.created_at
    assert store.version == 2

    reloaded = _store(tmp_path)
    assert reloaded.version == 2
    assert reloaded.get(entry.id) == updated
    assert os.listdir(tmp_path) == ["dict.json"]


def test_store_rejects_duplicates_in_same_scope(tmp_path):
    store = _store(tmp_path)
    _create(store)
    with pytest.raises(DuplicatePronunciationError):
        _create(store, match="gif")
    _create(store, match="gif", case_sensitive=True)
    _create(store, scope=BOOK_ID)


def test_store_limit(tmp_path):
    store = _store(tmp_path)
    for index in range(MAX_ENTRIES):
        _create(store, match=f"word{index}")
    with pytest.raises(PronunciationLimitError):
        _create(store, match="overflow")


def test_store_delete_and_scope_cleanup(tmp_path):
    store = _store(tmp_path)
    keep = _create(store)
    _create(store, match="a", scope=BOOK_ID)
    _create(store, match="b", scope=BOOK_ID)
    _create(store, match="c", scope="b" * 32)
    assert store.delete_scope(BOOK_ID) == 2
    assert store.delete_scope(BOOK_ID) == 0
    assert store.delete_book_scopes() == 1
    assert [e.id for e in store.list()] == [keep.id]
    assert store.delete(keep.id) is True
    assert store.delete(keep.id) is False
    with pytest.raises(PronunciationNotFoundError):
        store.update(
            keep.id,
            match="x",
            replacement="",
            case_sensitive=False,
            whole_word=True,
            scope=SCOPE_GLOBAL,
        )


def test_store_skips_invalid_records(tmp_path):
    valid = {
        "id": "c" * 32,
        "match": "GIF",
        "replacement": "jif",
        "case_sensitive": False,
        "whole_word": True,
        "scope": "global",
    }
    records = [
        valid,
        {**valid, "id": "d" * 32, "scope": "../etc"},
        {**valid, "id": "e" * 32, "match": ""},
        {**valid, "id": "f" * 32, "whole_word": "yes"},
        {**valid, "id": "nope"},
        valid,
        42,
    ]
    (tmp_path / "dict.json").write_text(json.dumps({"version": 7, "entries": records}))
    store = _store(tmp_path)
    assert [e.id for e in store.list()] == ["c" * 32]
    assert store.version == 7


def test_store_survives_corrupt_or_wrong_shape_file(tmp_path):
    (tmp_path / "dict.json").write_text("[1, 2]")
    assert _store(tmp_path).list() == []
    (tmp_path / "dict.json").write_text("{broken")
    store = _store(tmp_path)
    assert store.version == 0
    _create(store)
    assert json.loads((tmp_path / "dict.json").read_text())["version"] == 1


def test_rules_are_cached_per_version_and_scope(tmp_path):
    store = _store(tmp_path)
    _create(store)
    _create(store, match="Bob", replacement="Robert", scope=BOOK_ID)
    first = store.rules_for(None)
    assert store.rules_for(None) is first
    assert first.apply("GIF Bob") == "jif Bob"
    book = store.rules_for(BOOK_ID)
    assert book.apply("GIF Bob") == "jif Robert"
    _create(store, match="Ann", replacement="Anne")
    assert store.rules_for(None) is not first
    assert store.rules_for(None).version == 3
    assert store.rules_for("not-a-book").apply("Bob") == "Bob"


def test_concurrent_creates_keep_every_entry(tmp_path):
    store = _store(tmp_path)

    def add(index):
        return _create(store, match=f"w{index}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(add, range(64)))
    reloaded = _store(tmp_path)
    assert len(reloaded.list()) == 64
    assert reloaded.version == 64


# ---------- API ----------


def _post(**overrides):
    payload = {"match": "GIF", "replacement": "jif", **overrides}
    return client.post("/pronunciations", json=payload)


def test_api_crud_round_trip():
    created = _post()
    assert created.status_code == 201, created.text
    entry = created.json()
    assert entry["scope"] == "global"
    assert entry["whole_word"] is True
    assert entry["case_sensitive"] is False

    listing = client.get("/pronunciations").json()
    assert listing["version"] == 1
    assert listing["max_entries"] == MAX_ENTRIES
    assert [e["id"] for e in listing["entries"]] == [entry["id"]]

    updated = client.put(
        f"/pronunciations/{entry['id']}",
        json={"match": "GIF", "replacement": "giff", "whole_word": False},
    )
    assert updated.status_code == 200
    assert updated.json()["replacement"] == "giff"

    assert client.delete(f"/pronunciations/{entry['id']}").json() == {
        "status": "deleted",
        "id": entry["id"],
    }
    assert client.delete(f"/pronunciations/{entry['id']}").status_code == 404
    assert client.get("/pronunciations").json()["version"] == 3


@pytest.mark.parametrize(
    "overrides",
    [
        {"match": ""},
        {"match": "   "},
        {"match": "x" * 101},
        {"replacement": "x" * 201},
        {"match": "line\nbreak"},
        {"replacement": "tab\there"},
        {"scope": "../../etc"},
        {"scope": "A" * 32},
        {"case_sensitive": "yes"},
        {"whole_word": 1},
    ],
)
def test_api_rejects_invalid_entries(overrides):
    assert _post(**overrides).status_code == 422
    assert pronunciations.list() == []


def test_api_accepts_boundary_lengths():
    assert _post(match="m" * 100, replacement="r" * 200).status_code == 201
    assert _post(match="z", replacement="").status_code == 201


def test_api_duplicate_and_limit_return_409():
    assert _post().status_code == 201
    assert _post(match="gif").status_code == 409
    for index in range(MAX_ENTRIES - 1):
        pronunciations.create(
            match=f"w{index}",
            replacement="",
            case_sensitive=False,
            whole_word=True,
            scope=SCOPE_GLOBAL,
        )
    response = _post(match="overflow")
    assert response.status_code == 409
    assert "500" in response.json()["detail"]


def test_api_book_scope_requires_existing_book(isolated_books):
    assert _post(scope="b" * 32).status_code == 404
    book_id = _make_book()
    created = _post(scope=book_id)
    assert created.status_code == 201
    listed = client.get("/pronunciations", params={"scope": book_id}).json()
    assert [e["id"] for e in listed["entries"]] == [created.json()["id"]]
    assert (
        client.get("/pronunciations", params={"scope": "global"}).json()["entries"]
        == []
    )
    assert client.get("/pronunciations", params={"scope": "bad"}).status_code == 400


def test_deleting_a_book_removes_its_entries(isolated_books):
    book_id = _make_book()
    _post(scope=book_id)
    _post(match="keep")
    with patch.object(
        AudiobookService, "request_delete", new=AsyncMock(return_value=True)
    ):
        assert client.delete(f"/audiobook/{book_id}").status_code == 200
    assert [e.match for e in pronunciations.list()] == ["keep"]


def test_deleting_all_books_removes_book_entries(isolated_books):
    book_id = _make_book()
    _post(scope=book_id)
    _post(match="keep")
    with patch.object(
        AudiobookService, "request_delete_all", new=AsyncMock(return_value=1)
    ):
        assert client.delete("/audiobook").status_code == 200
    assert [e.match for e in pronunciations.list()] == ["keep"]


def test_book_delete_succeeds_when_dictionary_cleanup_fails(
    isolated_books, monkeypatch
):
    book_id = _make_book()
    _post(scope=book_id)

    def boom(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(pronunciation_module.JsonDocument, "save", boom)
    with patch.object(
        AudiobookService, "request_delete", new=AsyncMock(return_value=True)
    ):
        assert client.delete(f"/audiobook/{book_id}").status_code == 200


def test_api_rejects_malformed_entry_ids():
    payload = {"match": "a", "replacement": "b"}
    assert client.put("/pronunciations/nope", json=payload).status_code == 400
    assert client.delete("/pronunciations/../x").status_code in {400, 404}
    assert client.put(f"/pronunciations/{'9' * 32}", json=payload).status_code == 404


def test_api_save_failure_is_generic_500(monkeypatch):
    def boom(*_args, **_kwargs):
        raise OSError("/Users/private/file")

    monkeypatch.setattr(pronunciation_module.JsonDocument, "save", boom)
    response = _post()
    assert response.status_code == 500
    assert "private" not in response.text


def test_test_endpoint_returns_spoken_text(isolated_books):
    _post(match="Dr.", replacement="Doctor")
    _post(match="GIF", replacement="jif")
    response = client.post(
        "/pronunciations/test", json={"text": "Dr. Smith loves GIF files. Truly!"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["text"] == "Dr. Smith loves GIF files. Truly!"
    assert body["spoken"] == "Doctor Smith loves jif files. Truly!"
    assert body["replacements"] == 2
    assert body["version"] == 2

    book_id = _make_book()
    _post(match="Smith", replacement="Smyth", scope=book_id)
    scoped = client.post(
        "/pronunciations/test", json={"text": "Dr. Smith", "book_id": book_id}
    ).json()
    assert scoped["spoken"] == "Doctor Smyth"


@pytest.mark.parametrize(
    "payload",
    [{"text": ""}, {"text": "x" * 5001}, {"text": "hi", "book_id": "../x"}],
)
def test_test_endpoint_validates_input(payload):
    assert client.post("/pronunciations/test", json=payload).status_code == 422


# ---------- synthesis ----------


@pytest.mark.asyncio
async def test_speak_path_speaks_replacement(recording_model):
    _post(match="GIF", replacement="jif")
    async for _ in EngineManager.generate("I love GIF.", "af_bella", 1.0):
        pass
    assert recording_model.texts == ["I love jif."]


@pytest.mark.asyncio
async def test_segment_removed_entirely_is_skipped(recording_model):
    _post(match="um", replacement="")
    chunks = [
        c async for c in EngineManager.generate("Um. Hello there.", "af_bella", 1.0)
    ]
    assert recording_model.texts == ["Hello there."]
    assert len(chunks) == 1


@pytest.mark.asyncio
async def test_segmentation_follows_original_text(recording_model):
    _post(match="Dr", replacement="Doctor. Really")
    async for _ in EngineManager.generate("Dr Smith came. He left.", "af_bella", 1.0):
        pass
    assert recording_model.texts == ["Doctor. Really Smith came.", "He left."]


@pytest.mark.asyncio
async def test_lookahead_key_includes_dictionary_version(recording_model):
    await EngineManager.prewarm_with_lookahead("GIF is fun.", "af_bella", 1.0)
    assert recording_model.texts == ["GIF is fun."]
    _post(match="GIF", replacement="jif")
    async for _ in EngineManager.generate("GIF is fun.", "af_bella", 1.0):
        pass
    assert recording_model.texts == ["GIF is fun.", "jif is fun."]


@pytest.mark.asyncio
async def test_prewarm_caches_spoken_audio_under_current_version(recording_model):
    _post(match="GIF", replacement="jif")
    await EngineManager.prewarm_with_lookahead("GIF is fun.", "af_bella", 1.0)
    key = TTSEngine._lookahead_key(
        "GIF is fun.", builtin_spec("af_bella"), 1.0, "en-us", 1, 1.0
    )
    assert key in TTSEngine._lookahead_cache
    assert recording_model.texts == ["jif is fun."]
    async for _ in EngineManager.generate("GIF is fun.", "af_bella", 1.0):
        pass
    assert recording_model.texts == ["jif is fun."]


@pytest.mark.asyncio
async def test_prewarm_skips_segment_that_becomes_blank(recording_model):
    _post(match="um", replacement="")
    await EngineManager.prewarm_with_lookahead("Um.", "af_bella", 1.0)
    assert recording_model.texts == []
    assert TTSEngine._lookahead_cache == {}


@pytest.mark.asyncio
async def test_audiobook_audio_speaks_replacement_but_transcript_keeps_original(
    recording_model, isolated_books
):
    book_id = _make_book()
    _post(match="Dr.", replacement="Doctor")
    _post(match="Holmes", replacement="Homes", scope=book_id)
    other_book = _make_book()

    with patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()):
        _, lines = await AudiobookService._generate_full_page(
            book_id, "Dr. Holmes waited.\n\nThen he left.", "af_bella", 1.0
        )
        await AudiobookService._generate_full_page(
            other_book, "Holmes.", "af_bella", 1.0
        )

    assert recording_model.texts == ["Doctor Homes waited.", "Then he left.", "Holmes."]
    assert [line["text"] for line in lines] == ["Dr. Holmes waited.", "Then he left."]


@pytest.mark.asyncio
async def test_audiobook_tts_phase_scopes_dictionary_to_book(isolated_books):
    book_id = _make_book()
    path = AudiobookStore.page_clean_path(book_id, 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("A page.")
    seen = []

    async def fake_generate(text, voice, speed, lang=None, **kwargs):
        seen.append(kwargs["book_id"])
        yield np.zeros(240, dtype=np.float32)

    with (
        patch(
            "app.services.audiobook_service.EngineManager.ensure_loaded",
            new=AsyncMock(return_value=None),
        ),
        patch("app.services.audiobook_service.EngineManager.touch"),
        patch(
            "app.services.audiobook_service.EngineManager.generate",
            side_effect=fake_generate,
        ),
        patch("app.services.audiobook_service.asyncio.sleep", new=AsyncMock()),
    ):
        await AudiobookService._phase_tts(book_id, AudiobookStore.read_meta(book_id))
    assert seen == [book_id]
