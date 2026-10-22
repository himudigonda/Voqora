import argparse
import json
import os
import sys

PROTOCOL = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
os.dup2(2, 1)
sys.stdout = sys.stderr

os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

DEFAULT_SEED = 1234
MAX_DECODE_STEPS = 250
WARMUP_TEXT = "Hello."
WARMUP_LANGUAGE = "en"


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--code", required=True)
    parser.add_argument("--model", required=True)
    return parser.parse_args()


def cast_inputs_to_parameter_dtype(module, args):
    dtype = next(module.parameters()).dtype
    return tuple(
        (
            arg.to(dtype)
            if hasattr(arg, "is_floating_point") and arg.is_floating_point()
            else arg
        )
        for arg in args
    )


def load_model(code_dir, model_dir):
    import torch

    sys.path.insert(0, code_dir)
    from ming_tts import MingTTS

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    tts = MingTTS(model_dir, device=device, text_normalization=False)
    tts.model.spk_head.register_forward_pre_hook(cast_inputs_to_parameter_dtype)
    tts.model.linear_proj_audio.register_forward_pre_hook(
        cast_inputs_to_parameter_dtype
    )
    return tts


def render(tts, request, **synthesis):
    import torch

    torch.manual_seed(int(request.get("seed", DEFAULT_SEED)))
    waveform = tts.synthesize(max_decode_steps=MAX_DECODE_STEPS, **synthesis)
    samples = waveform.float().cpu().numpy().reshape(-1).astype("<f4")
    samples.tofile(request["out_path"])
    return {"ok": True, "samples": int(samples.size), "sample_rate": tts.sample_rate}


def synthesize(tts, request):
    reference_wav = request.get("reference_wav")
    task = request.get("task", "TTS")
    if task == "FREEFORM" and not reference_wav:
        raise ValueError("a style needs a reference voice")
    return render(
        tts,
        request,
        task=task,
        text=request["text"],
        language_id=request.get("language"),
        instruction=request.get("instruction"),
        controls=request.get("controls"),
        prompt_wav_path=reference_wav,
        prompt_text=request.get("reference_text") if reference_wav else None,
        use_spk_emb=bool(reference_wav),
    )


def design(tts, request):
    return render(
        tts,
        request,
        task="VOICE_DESIGN",
        text=request["text"],
        language_id=request.get("language"),
        controls={"style": request["description"]},
    )


def ip_reference(tts, request):
    return render(
        tts,
        request,
        task="IP",
        text=request["text"],
        language_id=request.get("language"),
        controls={"ip": request["ip"]},
    )


OPERATIONS = {
    "synthesize": synthesize,
    "design": design,
    "ip_reference": ip_reference,
}


def reply(message):
    PROTOCOL.write(json.dumps(message, ensure_ascii=False) + "\n")
    PROTOCOL.flush()


def handle(tts, line):
    request_id = None
    try:
        request = json.loads(line)
        request_id = request.get("id")
        if request.get("op") == "shutdown":
            reply({"ok": True, "id": request_id})
            return False
        reply({**OPERATIONS[request["op"]](tts, request), "id": request_id})
    except Exception as error:
        reply(
            {"ok": False, "id": request_id, "error": f"{type(error).__name__}: {error}"}
        )
    return True


def serve(tts):
    for line in sys.stdin:
        if line.strip() and not handle(tts, line):
            return


def main():
    arguments = parse_arguments()
    tts = load_model(arguments.code, arguments.model)
    render(
        tts,
        {"out_path": os.devnull},
        task="TTS",
        text=WARMUP_TEXT,
        language_id=WARMUP_LANGUAGE,
    )
    reply({"ok": True, "ready": True, "sample_rate": tts.sample_rate})
    serve(tts)


if __name__ == "__main__":
    main()
