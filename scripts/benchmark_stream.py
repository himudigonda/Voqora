import time

import requests

url = "http://localhost:10101/speak"
payload = {
    "text": "This is a streaming test to measure the first audio chunk.",
    "voice": "af_bella",
}

print(f"📡 Sniffing stream latency from {url}...")
try:
    start = time.perf_counter()
    with requests.post(url, json=payload, stream=True) as r:
        r.raise_for_status()
        first_byte_time = None
        first_audio_time = None
        bytes_received = 0

        for chunk in r.iter_content(chunk_size=None):
            bytes_received += len(chunk)
            now = time.perf_counter()

            if not first_byte_time:
                first_byte_time = (now - start) * 1000
                print(f"Header Received:  {first_byte_time:.2f} ms")

            # Chunks after the 44-byte header are audio
            if bytes_received > 44 and not first_audio_time:
                first_audio_time = (now - start) * 1000
                print(f"First Audio PCM:  {first_audio_time:.2f} ms")
                break

    print(f"Network/IPC Lag:  {first_byte_time:.2f} ms")
    print(f"Total TTFA (E2E): {first_audio_time:.2f} ms")
except Exception as e:
    print(f"❌ Error sniffing stream: {e}")
    print("Ensure the server is running (make run or background process)")
