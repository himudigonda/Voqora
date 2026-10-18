"""Named custom voices built as a weighted mix of built-in Kokoro voices."""

from __future__ import annotations

import math
import re
import threading
import unicodedata
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

import numpy as np

from app.core.config import settings
from app.core.logging import get_logger
from app.services.audiobook_store import _now_iso
from app.services.json_store import JsonDocument
from app.services.languages import espeak_lang_for_voice, is_valid_voice

log = get_logger(__name__)

BLEND_ID_PREFIX = "blend:"
MAX_BLENDS = 50
MIN_COMPONENTS = 2
MAX_COMPONENTS = 4
MIN_WEIGHT = 0.05
MAX_WEIGHT = 1.0
MAX_NAME_CHARS = 40

_BLEND_ID_RE = re.compile(
    r"^blend:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)
_SCHEMA_VERSION = 1


class BlendLimitError(Exception):
    pass


class BlendNotFoundError(Exception):
    pass


@dataclass(frozen=True)
class BlendComponent:
    voice: str
    weight: float


@dataclass(frozen=True)
class VoiceBlend:
    id: str
    name: str
    components: tuple[BlendComponent, ...]
    version: int
    created_at: str
    updated_at: str

    @property
    def lang(self) -> str:
        return espeak_lang_for_voice(self.components[0].voice)

    @property
    def fallback_voice(self) -> str:
        return self.components[0].voice

    @property
    def normalized_weights(self) -> tuple[float, ...]:
        return normalize_weights([c.weight for c in self.components])

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "lang": self.lang,
            "version": self.version,
            "components": [
                {"voice": c.voice, "weight": c.weight, "normalized_weight": n}
                for c, n in zip(self.components, self.normalized_weights, strict=True)
            ],
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


def is_blend_id(value: str) -> bool:
    return bool(_BLEND_ID_RE.fullmatch(value))


def normalize_weights(weights: Sequence[float]) -> tuple[float, ...]:
    total = math.fsum(weights)
    if not weights or total <= 0 or not math.isfinite(total):
        raise ValueError("weights must be positive")
    return tuple(w / total for w in weights)


def blend_styles(styles: Sequence[np.ndarray], weights: Sequence[float]) -> np.ndarray:
    if len(styles) != len(weights) or not styles:
        raise ValueError("each style needs exactly one weight")
    normalized = normalize_weights(weights)
    mixed = np.zeros_like(np.asarray(styles[0], dtype=np.float32))
    for style, weight in zip(styles, normalized, strict=True):
        mixed += np.asarray(style, dtype=np.float32) * np.float32(weight)
    return mixed


def validate_name(name: str) -> str:
    cleaned = unicodedata.normalize("NFC", name).strip()
    if not 1 <= len(cleaned) <= MAX_NAME_CHARS:
        raise ValueError(f"name must be 1 to {MAX_NAME_CHARS} characters")
    if any(unicodedata.category(ch) in {"Cc", "Cf"} for ch in cleaned):
        raise ValueError("name must not contain control characters")
    return cleaned


def validate_components(
    components: Sequence[tuple[str, float]],
) -> tuple[BlendComponent, ...]:
    if not MIN_COMPONENTS <= len(components) <= MAX_COMPONENTS:
        raise ValueError(
            f"a blend needs {MIN_COMPONENTS} to {MAX_COMPONENTS} built-in voices"
        )
    seen: set[str] = set()
    validated: list[BlendComponent] = []
    for voice, weight in components:
        if not is_valid_voice(voice):
            raise ValueError(f"unknown voice: {voice}")
        if voice in seen:
            raise ValueError(f"voice listed twice: {voice}")
        if not (math.isfinite(weight) and MIN_WEIGHT <= weight <= MAX_WEIGHT):
            raise ValueError(f"weights must be between {MIN_WEIGHT} and {MAX_WEIGHT}")
        seen.add(voice)
        validated.append(BlendComponent(voice=voice, weight=float(weight)))
    return tuple(validated)


def _blend_from_record(record: Any) -> VoiceBlend:
    if not isinstance(record, dict):
        raise ValueError("record must be an object")
    blend_id = str(record.get("id", ""))
    if not is_blend_id(blend_id):
        raise ValueError("invalid blend id")
    components = validate_components(
        [
            (str(item.get("voice", "")), float(item.get("weight", 0)))
            for item in record.get("components") or []
            if isinstance(item, dict)
        ]
    )
    version = int(record.get("version", 1))
    if version < 1:
        raise ValueError("invalid version")
    return VoiceBlend(
        id=blend_id,
        name=validate_name(str(record.get("name", ""))),
        components=components,
        version=version,
        created_at=str(record.get("created_at", "")),
        updated_at=str(record.get("updated_at", "")),
    )


def _blend_to_record(blend: VoiceBlend) -> dict[str, Any]:
    return {
        "id": blend.id,
        "name": blend.name,
        "version": blend.version,
        "components": [
            {"voice": c.voice, "weight": c.weight} for c in blend.components
        ],
        "created_at": blend.created_at,
        "updated_at": blend.updated_at,
    }


class VoiceBlendStore:
    def __init__(self, path_provider: Callable[[], str]) -> None:
        self._document = JsonDocument(path_provider, "voice_blends")
        self._lock = threading.RLock()
        self._blends: dict[str, VoiceBlend] | None = None

    def reset(self) -> None:
        with self._lock:
            self._blends = None

    def list(self) -> list[VoiceBlend]:
        with self._lock:
            return list(self._loaded().values())

    def get(self, blend_id: str) -> VoiceBlend | None:
        if not is_blend_id(blend_id):
            return None
        with self._lock:
            return self._loaded().get(blend_id)

    def create(self, name: str, components: Sequence[tuple[str, float]]) -> VoiceBlend:
        validated_name = validate_name(name)
        validated_components = validate_components(components)
        with self._lock:
            blends = self._loaded()
            if len(blends) >= MAX_BLENDS:
                raise BlendLimitError(f"You can save up to {MAX_BLENDS} voice blends.")
            now = _now_iso()
            blend = VoiceBlend(
                id=f"{BLEND_ID_PREFIX}{uuid.uuid4()}",
                name=validated_name,
                components=validated_components,
                version=1,
                created_at=now,
                updated_at=now,
            )
            self._commit({**blends, blend.id: blend})
            return blend

    def update(
        self, blend_id: str, name: str, components: Sequence[tuple[str, float]]
    ) -> VoiceBlend:
        validated_name = validate_name(name)
        validated_components = validate_components(components)
        with self._lock:
            blends = self._loaded()
            current = blends.get(blend_id)
            if current is None:
                raise BlendNotFoundError(blend_id)
            blend = VoiceBlend(
                id=current.id,
                name=validated_name,
                components=validated_components,
                version=current.version + 1,
                created_at=current.created_at,
                updated_at=_now_iso(),
            )
            self._commit({**blends, blend.id: blend})
            return blend

    def delete(self, blend_id: str) -> bool:
        with self._lock:
            blends = self._loaded()
            if blend_id not in blends:
                return False
            self._commit({k: v for k, v in blends.items() if k != blend_id})
            return True

    def _loaded(self) -> dict[str, VoiceBlend]:
        if self._blends is None:
            self._blends = self._read()
        return self._blends

    def _read(self) -> dict[str, VoiceBlend]:
        blends: dict[str, VoiceBlend] = {}
        skipped = 0
        for record in self._document.load().get("blends") or []:
            try:
                blend = _blend_from_record(record)
            except (TypeError, ValueError):
                skipped += 1
                continue
            if blend.id not in blends and len(blends) < MAX_BLENDS:
                blends[blend.id] = blend
            else:
                skipped += 1
        if skipped:
            log.warning(
                "voice_blends.records_skipped",
                extra={"skipped": skipped, "failure_code": "blend_record_invalid"},
            )
        return blends

    def _commit(self, blends: dict[str, VoiceBlend]) -> None:
        self._document.save(
            {
                "schema": _SCHEMA_VERSION,
                "blends": [_blend_to_record(b) for b in blends.values()],
            }
        )
        self._blends = blends


voice_blends = VoiceBlendStore(lambda: settings.VOICE_BLENDS_PATH)
