import json
import os
import sys
import time
from array import array

SAMPLE_RATE = 44100
LOG_PATH = os.environ.get("FAKE_MING_LOG")
GOOD_DESIGN_SEED = int(os.environ.get("FAKE_MING_GOOD_SEED", "1234"))
SLOW_SECONDS = float(os.environ.get("FAKE_MING_SLOW_SECONDS", "30"))
LOAD_DELAY_SECONDS = float(os.environ.get("FAKE_MING_LOAD_DELAY", "0"))
RUNAWAY_SECONDS = 20.0


def tone(seconds):
    count = int(SAMPLE_RATE * seconds)
    return (array("f", [0.25]) * count).tobytes()


def record(request):
    if LOG_PATH:
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(request, ensure_ascii=False) + "\n")


def reply(message, request=None):
    if request is not None:
        message = {**message, "id": request.get("id")}
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def handle(request):
    operation = request.get("op")
    text = request.get("text", "")
    record(request)
    if operation == "shutdown":
        reply({"ok": True}, request)
        return False
    if "crash" in text:
        os._exit(3)
    if "bad" in text:
        reply({"ok": False, "error": "ValueError: /private/path exploded"}, request)
        return True
    if "slow" in text:
        time.sleep(SLOW_SECONDS)
    if "rogue" in text:
        reply({"ok": True, "sample_rate": SAMPLE_RATE}, {"id": -1})
        return True
    if "noise" in text:
        sys.stderr.write("x" * 1_000_000 + "\n")
        sys.stderr.flush()
    if operation == "design":
        good = request.get("seed") == GOOD_DESIGN_SEED
        seconds = 2.0 if good else 0.1
    elif "endless" in text or ("runaway" in text and request.get("seed") == 1234):
        seconds = RUNAWAY_SECONDS
    else:
        seconds = 0.1
    with open(request["out_path"], "wb") as handle:
        handle.write(tone(seconds))
    reply(
        {"ok": True, "samples": int(SAMPLE_RATE * seconds), "sample_rate": SAMPLE_RATE},
        request,
    )
    return True


def main():
    if os.environ.get("FAKE_MING_FAIL_START"):
        sys.exit(2)
    time.sleep(LOAD_DELAY_SECONDS)
    sys.stderr.write("loading\n")
    reply({"ok": True, "ready": True, "sample_rate": SAMPLE_RATE})
    for line in sys.stdin:
        if line.strip() and not handle(json.loads(line)):
            return


main()
