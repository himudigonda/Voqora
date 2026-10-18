import concurrent.futures
import json
import os
import shutil
import tempfile
from unittest.mock import AsyncMock, patch

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.services import voice_blends as blends_module
from app.services.audiobook_service import AudiobookService
from app.services.audiobook_store import AudiobookStore
from app.services.engine_manager import EngineManager
from app.services.tts import TTSEngine
from app.services.voice_blends import (
    MAX_BLENDS,
    BlendLimitError,
    BlendNotFoundError,
    VoiceBlendStore,
    blend_styles,
    is_blend_id,
    normalize_weights,
    validate_components,
    voice_blends,
)
from app.services.voices import (
    builtin_spec,
    is_known_voice,
    resolve_voice,
    voice_spec,
    voice_with_fallback,
)

client = TestClient(app)


class FakeKokoro:
    def __init__(self, voices=("af_bella", "am_adam", "bf_emma", "ff_siwis")):
        self.voices = {
            voice: np.full((4, 1, 2), index + 1, dtype=np.float32)
            for index, voice in enumerate(voices)
        }
        self.calls: list[tuple] = []

    def get_voice_style(self, name):
        return self.voices[name]

    def create(self, text, voice, speed, lang):
        self.calls.append((text, voice, speed, lang))
        return np.ones(240, dtype=np.float32), 24000


@pytest.fixture
def fake_model():
    model = FakeKokoro()
    previous_model, previous_executor = TTSEngine._model, TTSEngine._executor
    TTSEngine._model = model
    TTSEngine._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    TTSEngine._lookahead_cache.clear()
    TTSEngine._style_cache.clear()
    yield model
    if TTSEngine._executor is not None:
        TTSEngine._executor.shutdown(wait=True)
    TTSEngine._model, TTSEngine._executor = previous_model, previous_executor
    TTSEngine._lookahead_cache.clear()
    TTSEngine._style_cache.clear()


@pytest.fixture
def isolated_books(monkeypatch):
    tmp = tempfile.mkdtemp(prefix="voqora_blend_books_")

    class _PatchedSettings:
        @property
        def AUDIOBOOKS_DIR(self) -> str:
            return tmp

    monkeypatch.setattr("app.services.audiobook_store.settings", _PatchedSettings())
    AudiobookStore._reset_for_tests()
    yield tmp
    AudiobookStore._reset_for_tests()
    shutil.rmtree(tmp, ignore_errors=True)


def _payload(name="Warm mix", components=None):
    return {
        "name": name,
        "components": components
        or [
            {"voice": "af_bella", "weight": 0.75},
            {"voice": "am_adam", "weight": 0.25},
        ],
    }


def _create(**kwargs):
    response = client.post("/voices/blends", json=_payload(**kwargs))
    assert response.status_code == 201, response.text
    return response.json()


# ---------- weighting math ----------


def test_normalize_weights_sums_to_one():
    assert normalize_weights([1.0, 1.0]) == (0.5, 0.5)
    weights = normalize_weights([0.05, 1.0, 0.3])
    assert sum(weights) == pytest.approx(1.0)
    assert weights[1] / weights[0] == pytest.approx(20.0)


@pytest.mark.parametrize("weights", [[], [0.0, 0.0], [float("inf"), 1.0]])
def test_normalize_weights_rejects_degenerate_input(weights):
    with pytest.raises(ValueError):
        normalize_weights(weights)


def test_blend_styles_is_weighted_sum_of_normalized_weights():
    a = np.full((3, 1, 2), 1.0, dtype=np.float32)
    b = np.full((3, 1, 2), 3.0, dtype=np.float32)
    mixed = blend_styles([a, b], [0.5, 1.5])
    assert mixed.dtype == np.float32
    assert mixed.shape == a.shape
    np.testing.assert_allclose(mixed, 0.25 * 1.0 + 0.75 * 3.0)


def test_blend_styles_does_not_mutate_inputs():
    a = np.full((2, 1, 2), 1.0, dtype=np.float32)
    b = np.full((2, 1, 2), 2.0, dtype=np.float32)
    blend_styles([a, b], [1.0, 1.0])
    assert np.all(a == 1.0) and np.all(b == 2.0)


def test_blend_styles_requires_one_weight_per_style():
    with pytest.raises(ValueError):
        blend_styles([np.zeros(2)], [0.5, 0.5])


# ---------- validation ----------


@pytest.mark.parametrize(
    "components",
    [
        [("af_bella", 1.0)],
        [("af_bella", 0.2)]
        + [(v, 0.2) for v in ("am_adam", "bf_emma", "ff_siwis")]
        + [("if_sara", 0.2)],
        [("af_bella", 0.5), ("af_bella", 0.5)],
        [("af_bella", 0.5), ("nope", 0.5)],
        [("af_bella", 0.04), ("am_adam", 0.5)],
        [("af_bella", 1.01), ("am_adam", 0.5)],
        [("af_bella", float("nan")), ("am_adam", 0.5)],
    ],
)
def test_validate_components_rejects_bad_mixes(components):
    with pytest.raises(ValueError):
        validate_components(components)


def test_validate_components_rejects_nested_blends():
    blend = voice_blends.create("Inner", [("af_bella", 0.5), ("am_adam", 0.5)])
    with pytest.raises(ValueError):
        validate_components([(blend.id, 0.5), ("am_adam", 0.5)])


def test_blend_ids_are_prefixed_uuid4():
    blend = voice_blends.create("Mix", [("af_bella", 0.5), ("am_adam", 0.5)])
    assert blend.id.startswith("blend:")
    assert is_blend_id(blend.id)
    assert not is_blend_id("blend:../../etc/passwd")
    assert not is_blend_id("af_bella")


# ---------- persistence ----------


def test_store_persists_atomically_and_reloads(tmp_path):
    path = str(tmp_path / "nested" / "blends.json")
    store = VoiceBlendStore(lambda: path)
    blend = store.create("  Calm  ", [("bf_emma", 0.6), ("af_bella", 0.4)])
    assert blend.name == "Calm"
    assert blend.lang == "en-gb"
    assert blend.fallback_voice == "bf_emma"
    assert os.listdir(os.path.dirname(path)) == ["blends.json"]
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"

    reloaded = VoiceBlendStore(lambda: path)
    assert reloaded.get(blend.id) == blend


def test_update_bumps_version_and_keeps_id(tmp_path):
    store = VoiceBlendStore(lambda: str(tmp_path / "b.json"))
    blend = store.create("A", [("af_bella", 0.5), ("am_adam", 0.5)])
    updated = store.update(blend.id, "B", [("ff_siwis", 0.9), ("af_bella", 0.1)])
    assert updated.id == blend.id
    assert updated.version == blend.version + 1
    assert updated.created_at == blend.created_at
    assert updated.lang == "fr-fr"
    with pytest.raises(BlendNotFoundError):
        store.update(
            f"blend:{'0' * 8}-0000-4000-8000-{'0' * 12}",
            "C",
            [("af_bella", 0.5), ("am_adam", 0.5)],
        )


def test_delete_removes_from_disk(tmp_path):
    path = str(tmp_path / "b.json")
    store = VoiceBlendStore(lambda: path)
    blend = store.create("A", [("af_bella", 0.5), ("am_adam", 0.5)])
    assert store.delete(blend.id) is True
    assert store.delete(blend.id) is False
    assert VoiceBlendStore(lambda: path).list() == []


def test_store_enforces_max_blends(tmp_path):
    store = VoiceBlendStore(lambda: str(tmp_path / "b.json"))
    for index in range(MAX_BLENDS):
        store.create(f"Mix {index}", [("af_bella", 0.5), ("am_adam", 0.5)])
    with pytest.raises(BlendLimitError):
        store.create("One more", [("af_bella", 0.5), ("am_adam", 0.5)])
    assert len(store.list()) == MAX_BLENDS


def test_store_survives_corrupt_file(tmp_path):
    path = tmp_path / "b.json"
    path.write_text("{not json")
    store = VoiceBlendStore(lambda: str(path))
    assert store.list() == []
    store.create("Fresh", [("af_bella", 0.5), ("am_adam", 0.5)])
    assert len(json.loads(path.read_text())["blends"]) == 1


def test_store_skips_invalid_records(tmp_path):
    path = tmp_path / "b.json"
    good = {
        "id": f"blend:{'a' * 8}-aaaa-4aaa-8aaa-{'a' * 12}",
        "name": "Good",
        "version": 2,
        "components": [
            {"voice": "af_bella", "weight": 0.5},
            {"voice": "am_adam", "weight": 0.5},
        ],
    }
    bad_voice = {**good, "id": good["id"].replace("a", "b"), "components": []}
    path.write_text(
        json.dumps({"blends": [good, bad_voice, "junk", {**good, "name": ""}, good]})
    )
    store = VoiceBlendStore(lambda: str(path))
    assert [b.id for b in store.list()] == [good["id"]]
    assert store.list()[0].version == 2


def test_concurrent_creates_never_lose_writes_or_exceed_limit(tmp_path):
    path = str(tmp_path / "b.json")
    store = VoiceBlendStore(lambda: path)

    def attempt(index):
        try:
            return store.create(f"M{index}", [("af_bella", 0.5), ("am_adam", 0.5)])
        except BlendLimitError:
            return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(attempt, range(MAX_BLENDS + 10)))

    assert sum(r is not None for r in results) == MAX_BLENDS
    assert len(VoiceBlendStore(lambda: path).list()) == MAX_BLENDS


def test_save_failure_leaves_previous_state(tmp_path, monkeypatch):
    store = VoiceBlendStore(lambda: str(tmp_path / "b.json"))
    store.create("Kept", [("af_bella", 0.5), ("am_adam", 0.5)])

    def boom(*_args, **_kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(blends_module.JsonDocument, "save", boom)
    with pytest.raises(OSError):
        store.create("Lost", [("af_bella", 0.5), ("am_adam", 0.5)])
    assert [b.name for b in store.list()] == ["Kept"]


# ---------- resolution ----------


def test_resolve_voice_handles_builtins_blends_and_unknowns():
    blend = voice_blends.create("Mix", [("hf_alpha", 0.3), ("af_bella", 0.7)])
    assert resolve_voice("af_bella") == builtin_spec("af_bella")
    spec = resolve_voice(blend.id)
    assert spec is not None and spec.is_blend
    assert spec.lang == "hi"
    assert spec.components == (("hf_alpha", 0.3), ("af_bella", 0.7))
    assert spec.cache_tag == f"{blend.id}@1"
    assert resolve_voice("nope") is None
    assert not is_known_voice(f"blend:{'0' * 8}-0000-4000-8000-{'0' * 12}")
    assert voice_spec("nope") == builtin_spec("nope")


def test_voice_with_fallback_uses_stored_component_then_default():
    blend = voice_blends.create("Mix", [("bf_emma", 0.5), ("af_bella", 0.5)])
    assert voice_with_fallback(blend.id, "bf_emma").id == blend.id
    voice_blends.delete(blend.id)
    assert voice_with_fallback(blend.id, "bf_emma").id == "bf_emma"
    assert voice_with_fallback(blend.id, None).id == "af_bella"
    assert voice_with_fallback(None, None).id == "af_bella"


# ---------- synthesis ----------


@pytest.mark.asyncio
async def test_generate_passes_blended_style_to_kokoro(fake_model):
    blend = voice_blends.create("Mix", [("af_bella", 0.25), ("am_adam", 0.75)])
    chunks = [
        chunk
        async for chunk in EngineManager.generate("Hello there friend.", blend.id, 1.0)
    ]
    assert chunks
    text, style, _, lang = fake_model.calls[0]
    assert text == "Hello there friend."
    assert isinstance(style, np.ndarray)
    np.testing.assert_allclose(style, 0.25 * 1 + 0.75 * 2)
    assert lang == "en-us"


@pytest.mark.asyncio
async def test_blend_style_is_cached_per_version(fake_model):
    blend = voice_blends.create("Mix", [("af_bella", 0.5), ("am_adam", 0.5)])
    async for _ in EngineManager.generate("One.", blend.id, 1.0):
        pass
    first_style = fake_model.calls[0][1]
    voice_blends.update(blend.id, "Mix", [("af_bella", 1.0), ("bf_emma", 0.05)])
    async for _ in EngineManager.generate("Two.", blend.id, 1.0):
        pass
    second_style = fake_model.calls[1][1]
    assert not np.allclose(first_style, second_style)
    assert set(TTSEngine._style_cache) == {f"{blend.id}@1", f"{blend.id}@2"}
    TTSEngine.unload()
    assert TTSEngine._style_cache == {}


@pytest.mark.asyncio
async def test_blend_with_missing_model_voice_falls_back_to_default(fake_model):
    blend = voice_blends.create("Mix", [("af_bella", 0.5), ("hf_alpha", 0.5)])
    async for _ in EngineManager.generate("Hello.", blend.id, 1.0):
        pass
    assert fake_model.calls[0][1] == "af_bella"


@pytest.mark.asyncio
async def test_lookahead_key_includes_blend_version(fake_model):
    blend = voice_blends.create("Mix", [("af_bella", 0.5), ("am_adam", 0.5)])
    await EngineManager.prewarm_with_lookahead("Hello world.", blend.id, 1.0)
    assert len(TTSEngine._lookahead_cache) == 1
    voice_blends.update(blend.id, "Mix", [("af_bella", 0.9), ("am_adam", 0.1)])
    async for _ in EngineManager.generate("Hello world.", blend.id, 1.0):
        pass
    assert len(fake_model.calls) == 2
    assert len(TTSEngine._lookahead_cache) == 1


@pytest.mark.asyncio
async def test_prewarmed_blend_is_served_from_cache(fake_model):
    blend = voice_blends.create("Mix", [("af_bella", 0.5), ("am_adam", 0.5)])
    await EngineManager.prewarm_with_lookahead("Hello world.", blend.id, 1.0)
    async for _ in EngineManager.generate("Hello world.", blend.id, 1.0):
        pass
    assert len(fake_model.calls) == 1
    assert TTSEngine._lookahead_cache == {}


# ---------- API ----------


def test_crud_round_trip():
    created = _create()
    assert created["id"].startswith("blend:")
    assert created["version"] == 1
    assert created["lang"] == "en-us"
    assert [c["normalized_weight"] for c in created["components"]] == [0.75, 0.25]

    listing = client.get("/voices/blends").json()
    assert listing["max_blends"] == MAX_BLENDS
    assert [b["id"] for b in listing["blends"]] == [created["id"]]
    assert client.get(f"/voices/blends/{created['id']}").json() == created

    updated = client.put(
        f"/voices/blends/{created['id']}",
        json=_payload(
            name="Brit",
            components=[
                {"voice": "bm_george", "weight": 1.0},
                {"voice": "bf_emma", "weight": 1.0},
                {"voice": "af_bella", "weight": 0.5},
            ],
        ),
    ).json()
    assert updated["version"] == 2
    assert updated["lang"] == "en-gb"
    assert [c["normalized_weight"] for c in updated["components"]] == [0.4, 0.4, 0.2]

    deleted = client.delete(f"/voices/blends/{created['id']}")
    assert deleted.json() == {"status": "deleted", "id": created["id"]}
    assert client.get(f"/voices/blends/{created['id']}").status_code == 404
    assert client.delete(f"/voices/blends/{created['id']}").status_code == 404


@pytest.mark.parametrize(
    "payload",
    [
        _payload(name=""),
        _payload(name="   "),
        _payload(name="x" * 41),
        _payload(name="bad\u0000name"),
        _payload(components=[{"voice": "af_bella", "weight": 1.0}]),
        _payload(
            components=[{"voice": "af_bella", "weight": 0.5}] * 2,
        ),
        _payload(
            components=[
                {"voice": "af_bella", "weight": 0.01},
                {"voice": "am_adam", "weight": 0.5},
            ]
        ),
        _payload(
            components=[
                {"voice": "af_bella", "weight": 0.5},
                {"voice": "../../x", "weight": 0.5},
            ]
        ),
        {"name": "No voices"},
    ],
)
def test_create_rejects_invalid_payloads(payload):
    assert client.post("/voices/blends", json=payload).status_code == 422
    assert voice_blends.list() == []


def test_create_returns_409_at_limit():
    for index in range(MAX_BLENDS):
        _create(name=f"Mix {index}")
    response = client.post("/voices/blends", json=_payload(name="Overflow"))
    assert response.status_code == 409
    assert "50" in response.json()["detail"]


def test_malformed_blend_ids_are_rejected():
    assert client.get("/voices/blends/blend:nope").status_code == 400
    assert client.put("/voices/blends/af_bella", json=_payload()).status_code == 400
    assert client.delete("/voices/blends/blend:xyz").status_code == 400


def test_unknown_blend_update_is_404():
    missing = f"blend:{'1' * 8}-1111-4111-8111-{'1' * 12}"
    assert client.put(f"/voices/blends/{missing}", json=_payload()).status_code == 404


def test_save_failure_returns_generic_500(monkeypatch):
    def boom(*_args, **_kwargs):
        raise OSError("/Users/someone/private path")

    monkeypatch.setattr(blends_module.JsonDocument, "save", boom)
    response = client.post("/voices/blends", json=_payload())
    assert response.status_code == 500
    assert "private" not in response.text


def test_engine_state_lists_blends_without_changing_builtin_voices():
    created = _create()
    state = client.get("/engine").json()
    assert created["id"] not in state["voices"]
    assert [b["id"] for b in state["blends"]] == [created["id"]]


@patch.object(EngineManager, "ensure_loaded")
def test_speak_accepts_blend_and_rejects_deleted_blend(_ensure):
    created = _create()
    seen = []

    async def fake_generate(text, voice, speed, lang=None, **kwargs):
        seen.append(voice)
        yield np.zeros(10, dtype=np.float32)

    with patch.object(EngineManager, "generate", side_effect=fake_generate):
        ok = client.post("/speak", json={"text": "Hi.", "voice": created["id"]})
        assert ok.status_code == 200
        b"".join(ok.iter_bytes())
    assert seen == [created["id"]]

    client.delete(f"/voices/blends/{created['id']}")
    rejected = client.post("/speak", json={"text": "Hi.", "voice": created["id"]})
    assert rejected.status_code == 422


@patch.object(EngineManager, "ensure_loaded")
def test_prewarm_accepts_blend(_ensure):
    created = _create()
    calls = []

    async def fake_prewarm(text, voice, speed, **kwargs):
        calls.append((voice, kwargs))

    with patch.object(
        EngineManager, "prewarm_with_lookahead", side_effect=fake_prewarm
    ):
        response = client.post(
            "/prewarm", json={"text": "Hi.", "voice": created["id"], "speed": 1.0}
        )
    assert response.status_code == 200
    assert calls == [(created["id"], {"pause_scale": 1.0})]
    missing = f"blend:{'2' * 8}-2222-4222-8222-{'2' * 12}"
    assert client.post("/prewarm", json={"voice": missing}).status_code == 422


def test_speak_rejects_overlong_voice_id():
    response = client.post("/speak", json={"text": "Hi.", "voice": "x" * 65})
    assert response.status_code == 422


# ---------- audiobooks ----------


def _mock_text_extraction(monkeypatch):
    from app.services import text_extractor as _te

    monkeypatch.setattr(_te.TextExtractor, "page_count", classmethod(lambda cls, _: 1))
    monkeypatch.setattr(
        _te.TextExtractor, "read_text", classmethod(lambda cls, _: "document content")
    )
    monkeypatch.setattr(
        _te.TextExtractor, "sample_word_count", classmethod(lambda cls, _: 10)
    )
    monkeypatch.setattr(
        _te.TextExtractor, "sample_char_count", classmethod(lambda cls, _: 50)
    )
    monkeypatch.setattr(
        _te.TextExtractor, "render_cover", classmethod(lambda cls, _: None)
    )


def test_audiobook_upload_accepts_blend_and_stores_fallback(
    monkeypatch, isolated_books
):
    _mock_text_extraction(monkeypatch)
    created = _create(
        components=[
            {"voice": "bf_emma", "weight": 0.5},
            {"voice": "af_bella", "weight": 0.5},
        ]
    )
    response = client.post(
        "/audiobook",
        files={"file": ("notes.txt", b"document content", "text/plain")},
        data={"voice": created["id"]},
    )
    assert response.status_code == 200, response.text
    meta = AudiobookStore.read_meta(response.json()["book_id"])
    assert meta["voice"] == created["id"]
    assert meta["voice_fallback"] == "bf_emma"


def test_audiobook_upload_rejects_unknown_blend(isolated_books):
    missing = f"blend:{'3' * 8}-3333-4333-8333-{'3' * 12}"
    response = client.post(
        "/audiobook",
        files={"file": ("notes.txt", b"document content", "text/plain")},
        data={"voice": missing},
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "Unknown narration voice."


async def _run_tts_phase(book_id):
    seen = []

    async def fake_generate(text, voice, speed, lang=None, **kwargs):
        seen.append(voice)
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
    return seen


def _book_with_voice(voice, fallback):
    book_id = AudiobookStore.create_book("Blend.txt")
    meta = AudiobookStore.initial_meta(
        book_id, "Blend.txt", 1, "kokoro", voice, 1.0, {"cost_usd": 0.0}
    )
    meta["voice_fallback"] = fallback
    AudiobookStore.write_meta(book_id, meta)
    path = AudiobookStore.page_clean_path(book_id, 1)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write("A short page.")
    return book_id


@pytest.mark.asyncio
async def test_audiobook_narrates_with_blend(isolated_books):
    blend = voice_blends.create("Mix", [("bf_emma", 0.5), ("af_bella", 0.5)])
    seen = await _run_tts_phase(_book_with_voice(blend.id, "bf_emma"))
    assert seen and all(spec.id == blend.id for spec in seen)


@pytest.mark.asyncio
async def test_audiobook_with_deleted_blend_uses_stored_fallback(isolated_books):
    blend = voice_blends.create("Mix", [("bf_emma", 0.5), ("af_bella", 0.5)])
    book_id = _book_with_voice(blend.id, "bf_emma")
    voice_blends.delete(blend.id)
    seen = await _run_tts_phase(book_id)
    assert seen and all(spec.id == "bf_emma" for spec in seen)


@pytest.mark.asyncio
async def test_audiobook_without_fallback_uses_default_voice(isolated_books):
    missing = f"blend:{'4' * 8}-4444-4444-8444-{'4' * 12}"
    seen = await _run_tts_phase(_book_with_voice(missing, None))
    assert seen and all(spec.id == "af_bella" for spec in seen)
