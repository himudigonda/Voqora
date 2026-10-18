"""One place that decides what a voice id means: a built-in voice or a blend."""

from __future__ import annotations

from dataclasses import dataclass

from app.services.languages import DEFAULT_VOICE, espeak_lang_for_voice, is_valid_voice
from app.services.voice_blends import VoiceBlend, is_blend_id, voice_blends


@dataclass(frozen=True)
class VoiceSpec:
    id: str
    lang: str
    components: tuple[tuple[str, float], ...]
    version: int = 0

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
    if is_blend_id(voice_id):
        blend = voice_blends.get(voice_id)
        if blend is not None:
            return blend_spec(blend)
    return None


def is_known_voice(voice_id: str) -> bool:
    return resolve_voice(voice_id) is not None


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
