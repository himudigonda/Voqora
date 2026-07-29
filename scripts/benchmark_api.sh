#!/bin/bash
echo "Benchmarking Voqora API End-to-End..."
for i in {1..5}
do
   curl -o /dev/null -s -w "Iteration $i - Connect: %{time_connect}s | TTFB: %{time_starttransfer}s | Total: %{time_total}s\n" \
   -X POST http://localhost:10101/speak \
   -H "Content-Type: application/json" \
   -d '{"text": "This is an end-to-end benchmark of the Voqora streaming pipeline.", "voice": "af_bella"}'
done
