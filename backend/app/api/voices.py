"""Voice blend HTTP surface: named custom voices mixed from built-in voices."""

import hashlib
from typing import Any

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, Field, field_validator, model_validator

from app.core.logging import get_logger
from app.services.audio import AudioService
from app.services.engine_errors import EngineNotInstalledError
from app.services.languages import LANGUAGES, espeak_lang_for_voice
from app.services.speech_stream import (
    MAX_SPEECH_CHARS,
    SpeechStreamResponse,
    open_speech_samples,
)
from app.services.text_normalizer import strip_markdown_for_narration
from app.services.voice_blends import (
    MAX_BLENDS,
    MAX_COMPONENTS,
    MAX_NAME_CHARS,
    MAX_WEIGHT,
    MIN_COMPONENTS,
    MIN_WEIGHT,
    BlendLimitError,
    BlendNotFoundError,
    is_blend_id,
    normalize_weights,
    validate_components,
    validate_name,
    voice_blends,
)
from app.services.voices import VoiceSpec

router = APIRouter()
log = get_logger(__name__)

PREVIEW_ID_PREFIX = "blend:preview:"
_LANGUAGE_CODES = frozenset(language["code"] for language in LANGUAGES)
_DEFAULT_PREVIEW_TEXT = "The quick brown fox jumps over the lazy dog."
_PREVIEW_TEXTS = {
    "es": "El veloz zorro marrón salta sobre el perro perezoso.",
    "fr-fr": "Le vif renard brun saute par-dessus le chien paresseux.",
    "it": "La rapida volpe marrone salta sopra il cane pigro.",
    "pt-br": "A rápida raposa marrom salta sobre o cão preguiçoso.",
    "hi": "तेज़ भूरी लोमड़ी आलसी कुत्ते के ऊपर कूद जाती है।",
    "cmn": "敏捷的棕色狐狸跳过了那只懒狗。",
}


class BlendComponentModel(BaseModel):
    voice: str = Field(min_length=1, max_length=32)
    weight: float = Field(ge=MIN_WEIGHT, le=MAX_WEIGHT)


class BlendRequest(BaseModel):
    name: str = Field(min_length=1, max_length=MAX_NAME_CHARS * 2)
    components: list[BlendComponentModel] = Field(
        min_length=MIN_COMPONENTS, max_length=MAX_COMPONENTS
    )

    @field_validator("name")
    @classmethod
    def require_valid_name(cls, value: str) -> str:
        return validate_name(value)

    @model_validator(mode="after")
    def require_valid_components(self) -> "BlendRequest":
        validate_components(self.pairs())
        return self

    def pairs(self) -> list[tuple[str, float]]:
        return [(c.voice, c.weight) for c in self.components]


class BlendPreviewRequest(BaseModel):
    components: list[str] = Field(min_length=MIN_COMPONENTS, max_length=MAX_COMPONENTS)
    weights: list[float] = Field(min_length=MIN_COMPONENTS, max_length=MAX_COMPONENTS)
    text: str | None = Field(default=None, max_length=MAX_SPEECH_CHARS)
    lang: str | None = None

    @field_validator("text")
    @classmethod
    def require_meaningful_text(cls, value: str | None) -> str | None:
        if value is None:
            return None
        cleaned = strip_markdown_for_narration(value.strip())
        if not cleaned:
            raise ValueError("text must not be blank")
        return cleaned

    @field_validator("lang")
    @classmethod
    def require_known_lang(cls, value: str | None) -> str | None:
        if value is not None and value not in _LANGUAGE_CODES:
            raise ValueError(f"unsupported language: {value}")
        return value

    @model_validator(mode="after")
    def require_valid_components(self) -> "BlendPreviewRequest":
        if len(self.components) != len(self.weights):
            raise ValueError("each voice needs exactly one weight")
        validate_components(self.pairs())
        return self

    def pairs(self) -> list[tuple[str, float]]:
        return list(zip(self.components, self.weights, strict=True))

    def spec(self) -> VoiceSpec:
        validated = validate_components(self.pairs())
        normalized = normalize_weights([c.weight for c in validated])
        mix = "|".join(
            f"{c.voice}:{w:.6f}" for c, w in zip(validated, normalized, strict=True)
        )
        digest = hashlib.sha256(mix.encode()).hexdigest()[:16]
        return VoiceSpec(
            id=f"{PREVIEW_ID_PREFIX}{digest}",
            lang=espeak_lang_for_voice(validated[0].voice),
            components=tuple(
                (c.voice, weight)
                for c, weight in zip(validated, normalized, strict=True)
            ),
        )


def _validate_blend_id(blend_id: str) -> None:
    if not is_blend_id(blend_id):
        raise HTTPException(status_code=400, detail="Invalid blend id.")


def _save_failed(action: str) -> HTTPException:
    log.error(
        "voice_blends.save_failed",
        extra={"action": action, "failure_code": "blend_save_failed"},
        exc_info=True,
    )
    return HTTPException(
        status_code=500, detail="Could not save voice blends. Please try again."
    )


@router.get("/voices/blends")
def list_blends() -> dict[str, Any]:
    """List saved voice blends."""
    return {
        "blends": [blend.to_dict() for blend in voice_blends.list()],
        "max_blends": MAX_BLENDS,
    }


@router.post("/voices/blends/preview")
async def preview_blend(req: BlendPreviewRequest):
    """Speak a sample of an unsaved blend. Nothing is stored."""
    spec = req.spec()
    text = req.text or _PREVIEW_TEXTS.get(spec.lang, _DEFAULT_PREVIEW_TEXT)
    try:
        samples = await open_speech_samples(text, spec, 1.0, req.lang)
    except EngineNotInstalledError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    except Exception:
        log.error(
            "voice_blends.preview_failed",
            extra={"failure_code": "blend_preview_failed", "text_len": len(text)},
            exc_info=True,
        )
        return Response(
            status_code=500,
            content="Speech generation failed. Check that the voice model is available and try again.",
        )
    return SpeechStreamResponse(
        samples,
        AudioService.stream_samples_to_wav(samples, 1.0),
        media_type="audio/wav",
    )


@router.get("/voices/blends/{blend_id}")
def get_blend(blend_id: str) -> dict[str, Any]:
    _validate_blend_id(blend_id)
    blend = voice_blends.get(blend_id)
    if blend is None:
        raise HTTPException(status_code=404, detail="Voice blend not found.")
    return blend.to_dict()


@router.post("/voices/blends", status_code=201)
def create_blend(req: BlendRequest) -> dict[str, Any]:
    """Save a new blend of 2 to 4 built-in voices."""
    try:
        blend = voice_blends.create(req.name, req.pairs())
    except BlendLimitError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except OSError as exc:
        raise _save_failed("create") from exc
    log.info("voice_blends.created", extra={"components": len(blend.components)})
    return blend.to_dict()


@router.put("/voices/blends/{blend_id}")
def update_blend(blend_id: str, req: BlendRequest) -> dict[str, Any]:
    """Replace a blend's name and voices. Its id stays the same."""
    _validate_blend_id(blend_id)
    try:
        blend = voice_blends.update(blend_id, req.name, req.pairs())
    except BlendNotFoundError as exc:
        raise HTTPException(status_code=404, detail="Voice blend not found.") from exc
    except OSError as exc:
        raise _save_failed("update") from exc
    log.info("voice_blends.updated", extra={"version": blend.version})
    return blend.to_dict()


@router.delete("/voices/blends/{blend_id}")
def delete_blend(blend_id: str) -> dict[str, str]:
    _validate_blend_id(blend_id)
    try:
        deleted = voice_blends.delete(blend_id)
    except OSError as exc:
        raise _save_failed("delete") from exc
    if not deleted:
        raise HTTPException(status_code=404, detail="Voice blend not found.")
    log.info("voice_blends.deleted")
    return {"status": "deleted", "id": blend_id}
