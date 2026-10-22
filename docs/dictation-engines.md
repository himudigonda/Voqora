# Dictation engine bake-off (2.1.0)

Voqora 2.1.0 adds Underdog Bark 3.0 and Bark 3.0 Clean (Conway Research, CC-BY-4.0)
as on-device dictation engines next to Apple and Parakeet. This page records how
they were compared and what came out.

## Method

- Engines run exactly as the app runs them: FluidAudio `AsrManager` at the
  revision the app pins (`503b4bd1`), encoder on the Neural Engine, one clip per
  `transcribe` call, clips shorter than 5000 samples padded with silence.
- Parakeet is FluidInference's `parakeet-tdt-0.6b-v3-coreml` (what 2.0.0 ships).
  Bark and Bark Clean are FluidInference's `bark-3.0-coreml` at revision
  `73b0c0da`, loaded with `AsrModels.loadLocal(version: .ultra)`.
- Test audio is 1,750 real-speech clips (2.7 hours), sampled with a fixed seed:
  300 each from LibriSpeech test-other, AMI (cleaned), Earnings-22, VoxPopuli
  (cleaned) and Common Voice from the Open ASR Leaderboard sets, plus all 250
  DisfluencySpeech test clips.
- Scoring is corpus WER after the Whisper English normalizer, the leaderboard's
  normalization. DisfluencySpeech is scored twice: against the cleaned
  transcript (fillers, false starts and repeats removed, `transcript_c`) and
  against the verbatim one (`transcript_a`).
- `scripts/dictation_bench/engines/run.sh` reproduces the whole run.

## Results, 1,750 clips

WER in %, lower is better. "avg5" is the mean of the first five sets.

| Engine | LS other | AMI | Earnings-22 | VoxPopuli | Common Voice | avg5 | Disfluency, cleaned | Disfluency, verbatim | Fillers per 1k words |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Parakeet (shipping) | **3.98** | 18.74 | 13.95 | 3.64 | **6.72** | 9.40 | 13.11 | **2.75** | 11.47 |
| Bark | 4.84 | **13.80** | **13.79** | **2.48** | 8.26 | **8.63** | 13.43 | 3.02 | 13.46 |
| Bark Clean | 4.61 | 16.99 | 14.76 | 2.56 | 7.28 | 9.24 | **3.68** | 11.31 | **0.24** |

Bark Clean's avg5 and verbatim scores count every filler it removes on purpose as
an error; its cleaned-transcript score is the one that matches dictation.

## Conversion check, 291-clip subset

The same every-sixth-clip subset run through Conway Research's own MLX runtime
(`bark_mlx.py`, fp16, exact weights) to check that the Core ML builds match the
upstream models, and to see whether Bark 3.0 Plus (no Core ML build exists)
would be worth chasing.

| Engine | Runtime | avg5 | Disfluency, cleaned |
|---|---|--:|--:|
| Parakeet | FluidAudio Core ML | 9.07 | 15.89 |
| Bark | FluidAudio Core ML | 7.99 | 15.64 |
| Bark | upstream MLX | 7.25 | 14.88 |
| Bark 3.0 Plus | upstream MLX | 7.31 | 16.02 |
| Bark Clean | FluidAudio Core ML | 8.14 | 3.03 |
| Bark Clean | upstream MLX | 8.34 | 3.03 |

Bark Clean's Core ML build matches upstream. Bark's Core ML build gives up
about 0.7 points to upstream on this subset, mostly on AMI. Plus is no better
than Bark here, so 2.1.0 does not ship it.

## Speed

Second pass over the 291-clip subset with the models already compiled. The
real-time factor is aggregate: total audio seconds over total transcribe
seconds, on one Apple silicon laptop while unrelated Xcode builds were running,
so treat it as a floor.

| Engine | Load (cached) | Real-time factor |
|---|--:|--:|
| Parakeet | 0.3 s | 35× |
| Bark | 0.5 s | 46× |
| Bark Clean | 0.3 s | 47× |

The first load after a download compiles the encoder for the Neural Engine:
90 s for Bark and 134 s for Bark Clean in the full run above, longer when the Mac is busy.
Voqora starts that compile in the background right after the download and
shows "Getting ready for first use" until it finishes.

## Takeaways

- Bark is the most accurate verbatim engine on conversational speech: AMI
  meetings drop from 18.7% to 13.8% WER, VoxPopuli from 3.6% to 2.5%.
  Parakeet stays ahead on read speech (LibriSpeech, Common Voice) and is the
  only local engine for languages other than English.
- Bark Clean is the best fit for English dictation. On spontaneous speech it
  produces 3.7% WER against cleaned transcripts versus 13.1% for Parakeet, and
  it emits almost no fillers (0.24 per 1,000 words against 11.5), without a
  round trip to an AI provider.
- Recommendation in the app: Bark Clean for English dictation, Parakeet for
  other European languages, Apple when nothing should be downloaded.
