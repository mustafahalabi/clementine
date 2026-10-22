#!/usr/bin/env python3
"""ElevenLabs TTS with timestamps. Reads the key from ELEVENLABS_API_KEY (set by the calling shell from the keychain).
usage: el_tts.py <voice_id> <model_id> <text_file> <out.mp3> [stability] [speed] [seed]
Writes <out.mp3> and <out>.json (character alignment)."""
import base64, json, os, sys, urllib.request
voice, model, text_file, out = sys.argv[1:5]
stability = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5
speed = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
seed = int(sys.argv[7]) if len(sys.argv) > 7 else 7
text = open(text_file).read().strip()
body = {"text": text, "model_id": model, "seed": seed,
        "voice_settings": {"stability": stability, "similarity_boost": 0.8, "style": 0.0,
                           "use_speaker_boost": True, "speed": speed}}
req = urllib.request.Request(
    f"https://api.elevenlabs.io/v1/text-to-speech/{voice}/with-timestamps?output_format=mp3_44100_192",
    data=json.dumps(body).encode(), headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:500]}")
open(out, "wb").write(base64.b64decode(d["audio_base64"]))
json.dump({"text": text, "alignment": d.get("alignment"), "normalized_alignment": d.get("normalized_alignment")},
          open(os.path.splitext(out)[0] + ".json", "w"))
print(out)
