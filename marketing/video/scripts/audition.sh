#!/bin/bash
# Renders one line with several voices on Eleven v4 so they can be compared (one at a time: the plan allows 5 concurrent requests).
set -euo pipefail
cd "$(dirname "$0")/.."
export ELEVENLABS_API_KEY=$(security find-generic-password -s elevenlabs-api-key -w)
for v in "c6SfcYrb2t09NHXiT80T:jarnathan" "cjVigY5qzO86Huf0OWal:eric" "EXAVITQu4vr4xnSDxMaL:sarah" "JBFqnCBsd6RMkjVDRZzb:george" "nPczCjzI2devNBz1zQrb:brian" "qTRV75fy2dUja4REMifv:mira"; do
  id=${v%%:*}; name=${v##*:}
  python3 scripts/el_tts.py "$id" eleven_v4 auditions/line.txt "auditions/$name.mp3" 0.5 1.0
done
