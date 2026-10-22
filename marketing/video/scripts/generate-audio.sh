#!/bin/bash
# Regenerates every ElevenLabs asset (costs credits: ~720 characters of TTS, one 65 s song, 13 sound effects).
# The API key is read from the keychain into the environment only; it's never written anywhere.
# usage: generate-audio.sh [narration|music|sfx|analyse]…   (no arguments = all)
set -euo pipefail
cd "$(dirname "$0")/.."
A=public/audio
export ELEVENLABS_API_KEY="$(security find-generic-password -s elevenlabs-api-key -w)"
VOICE=cjVigY5qzO86Huf0OWal   # "Eric - Smooth, Trustworthy"
steps=("$@")
has() { [ ${#steps[@]} -eq 0 ] || [[ " ${steps[*]} " == *" $1 "* ]]; }
if has narration; then
  python3 scripts/el_tts.py "$VOICE" eleven_v4 "$A/narration.txt" "$A/narration-take1.mp3" 0.5 0.96 11
  python3 scripts/words.py "$A/narration-take1.json" > "$A/words-take1.json"
fi
if has music; then
  python3 scripts/el_music.py "$A/music-take1.mp3" 21
  ffmpeg -loglevel error -y -i "$A/music-take1.mp3" -af "lowpass=f=650,lowpass=f=650" -b:a 192k "$A/music-take1-lp.mp3"
fi
if has sfx; then
  python3 scripts/el_sfx.py
  ffmpeg -loglevel error -y -f lavfi -i "sine=f=1000:d=0.45" -af "afade=t=in:d=0.01,afade=t=out:st=0.4:d=0.05,volume=0.4" -b:a 128k "$A/sfx/bleep.mp3"
fi
if has analyse || [ ${#steps[@]} -eq 0 ]; then
  uv run -q --with numpy python scripts/onsets.py "$A/sfx" > "$A/sfx/onsets.json"
  uv run -q --with numpy python scripts/beats.py "$A/music-take1.mp3" > "$A/beats.json"
fi
cp "$A/words-take1.json" src/data/words.json
cp "$A/timeline.json" src/data/timeline.json
cp "$A/beats.json" src/data/beats.json
echo done
