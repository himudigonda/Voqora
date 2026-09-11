#!/bin/bash
set -euo pipefail
BASE_URL="${VOQORA_BACKEND_URL:?Set VOQORA_BACKEND_URL for an authenticated development backend.}"
IPC_TOKEN="${VOQORA_IPC_TOKEN:?Set VOQORA_IPC_TOKEN for an authenticated development backend.}"
echo "Benchmarking Voqora API End-to-End..."
for i in {1..5}
do
   curl -o /dev/null -s -w "Iteration $i - Connect: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" \
   -X POST "${BASE_URL%/}/speak" \
   -H "Content-Type: application/json" \
   -H "X-Voqora-IPC-Token: $IPC_TOKEN" \
   -d '{"text": "This is an end-to-end benchmark of the Voqora streaming pipeline.", "voice": "af_bella"}'
done
