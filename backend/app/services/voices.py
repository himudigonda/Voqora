"""One place that decides what a voice id means: a built-in voice, a blend, or a
Supertonic voice."""

from __future__ import annotations

from dataclasses import dataclass

from app.services.languages import DEFAULT_VOICE, espeak_lang_for_voice, is_valid_voice
from app.services.supertonic_catalog import ENGINE_ID as SUPERTONIC_ENGINE
from app.services.supertonic_catalog import is_supertonic_voice
from app.services.voice_blends import VoiceBlend, is_blend_id, voice_blends

KOKORO_ENGINE = "kokoro"


@dataclass(frozen=True)
class VoiceSpec:
    id: str
    lang: str
    components: tuple[tuple[str, float], ...]
    version: int = 0
    engine: str = KOKORO_ENGINE

    @property
    def is_blend(self) -> bool:
        return len(self.components) > 1

    @property
    def cache_tag(self) -> str:
        return f"{self.id}@{self.version}" if self.is_blend else self.id

    @property
    def fallback_voice(self) -> str:
        return self.components[0][0]


def builtin_spec(voice_id: str) -> VoiceSpec:
    return VoiceSpec(
        id=voice_id,
        lang=espeak_lang_for_voice(voice_id),
        components=((voice_id, 1.0),),
    )


def supertonic_spec(voice_id: str) -> VoiceSpec:
    return VoiceSpec(
        id=voice_id,
        lang="",
        components=((voice_id, 1.0),),
        engine=SUPERTONIC_ENGINE,
    )


def blend_spec(blend: VoiceBlend) -> VoiceSpec:
    return VoiceSpec(
        id=blend.id,
        lang=blend.lang,
        components=tuple(
            (component.voice, weight)
            for component, weight in zip(
                blend.components, blend.normalized_weights, strict=True
            )
        ),
        version=blend.version,
    )


def resolve_voice(voice_id: str) -> VoiceSpec | None:
    if is_valid_voice(voice_id):
        return builtin_spec(voice_id)
    if is_supertonic_voice(voice_id):
        return supertonic_spec(voice_id)
    if is_blend_id(voice_id):
        blend = voice_blends.get(voice_id)
        if blend is not None:
            return blend_spec(blend)
    return None


def is_known_voice(voice_id: str) -> bool:
    return resolve_voice(voice_id) is not None


def is_kokoro_voice(voice_id: str) -> bool:
    spec = resolve_voice(voice_id)
    return spec is not None and spec.engine == KOKORO_ENGINE


def voice_spec(voice: str | VoiceSpec) -> VoiceSpec:
    if isinstance(voice, VoiceSpec):
        return voice
    return resolve_voice(voice) or builtin_spec(voice)


def voice_with_fallback(voice_id: str | None, fallback: str | None) -> VoiceSpec:
    for candidate in (voice_id, fallback):
        if candidate:
            spec = resolve_voice(candidate)
            if spec is not None:
                return spec
    return builtin_spec(DEFAULT_VOICE)
