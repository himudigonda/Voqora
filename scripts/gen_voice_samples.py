"""Pre-generate one short sample WAV per voice, bundled in the app for instant
'Hear a sample' preview in onboarding (no backend round-trip).

Run from the repo root:  cd backend && PYTHONPATH=. uv run python ../scripts/gen_voice_samples.py
(or `make samples`). Needs backend/kokoro-v1.0.onnx + voices-v1.0.bin present.

Each voice reads a native-language pangram — MUST match
DashboardViewModel.sampleSentence(forVoice:) in the Swift app. 24 kHz mono 16-bit.
Output: frontend/Voqora/Voqora/Resources/VoiceSamples/<voice_id>.wav (~4 MB total).
"""

import os
import wave

import numpy as np
import onnxruntime as ort
from app.services.languages import VOICES, espeak_lang_for_voice
from kokoro_onnx import Kokoro

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_DIR = os.path.join(
    REPO, "frontend", "Voqora", "Voqora", "Resources", "VoiceSamples"
)
MODEL = os.path.join(REPO, "backend", "kokoro-v1.0.onnx")
VOICES_BIN = os.path.join(REPO, "backend", "voices-v1.0.bin")

# Keep in lockstep with DashboardViewModel.sampleSentence(forVoice:).
SENTENCE = {
    "es": "El veloz zorro marrón salta sobre el perro perezoso.",
    "fr-fr": "Le vif renard brun saute par-dessus le chien paresseux.",
    "it": "La rapida volpe marrone salta sopra il cane pigro.",
    "pt-br": "A rápida raposa marrom salta sobre o cão preguiçoso.",
    "hi": "तेज़ भूरी लोमड़ी आलसी कुत्ते के ऊपर कूद जाती है।",
    "cmn": "敏捷的棕色狐狸跳过了那只懒狗。",
}
DEFAULT_SENTENCE = "The quick brown fox jumps over the lazy dog."


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    sess = ort.InferenceSession(MODEL, providers=["CPUExecutionProvider"])
    model = Kokoro.from_session(sess, VOICES_BIN)
    model.create("Hi.", "af_bella", 1.0, "en-us")  # warmup

    for v in VOICES:
        vid = v["id"]
        lang = espeak_lang_for_voice(vid)
        text = SENTENCE.get(lang, DEFAULT_SENTENCE)
        audio, sr = model.create(text, vid, 1.0, lang)
        pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2")
        path = os.path.join(OUT_DIR, f"{vid}.wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(sr)
            w.writeframes(pcm.tobytes())
        print(f"  {vid:14} {lang:6} {len(audio) / sr:4.2f}s")

    print(f"✅ {len(VOICES)} samples → {OUT_DIR}")


if __name__ == "__main__":
    main()
