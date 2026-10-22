#!/usr/bin/env python3
"""Generates the UI sound effects with the ElevenLabs sound-effects API into audio/sfx/. usage: el_sfx.py [name…]"""
import json, os, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor
SFX = {
 "whoosh":  (0.7, "soft airy cinematic whoosh, clean and short, premium UI transition, no hiss"),
 "swipe":   (0.5, "quick soft swoosh of a card sliding past, light and crisp, minimal UI"),
 "bloom":   (1.0, "soft magical glassy bloom swell, UI wheel opening, gentle shimmer, warm, clean"),
 "tick":    (0.5, "crisp short UI click, trackpad tap, clear transient, close up, clean, no reverb"),
 "pop":     (0.5, "satisfying soft bubbly pop, file dropped into place, warm UI confirmation"),
 "chime":   (1.2, "bright soft success chime, two rising notes, warm marimba and glass, minimal Apple-like UI sound"),
 "key":     (0.5, "single soft mechanical laptop keyboard key press, Mac keyboard, close up, clean"),
 "impact":  (2.5, "deep warm cinematic sub boom with airy shimmering tail, elegant logo reveal, not aggressive"),
 "riser":   (2.5, "soft airy cinematic riser building tension, smooth reverse swell, clean, ends abruptly"),
 "glitch":  (0.6, "short soft digital error buzz, website upload failed, subtle glitch"),
 "notify":  (0.6, "generic web browser notification blip, slightly annoying, short"),
 "drone":   (5.0, "deep warm ambient drone, low soft hum with gentle air, cinematic opening, very calm"),
}
key = os.environ["ELEVENLABS_API_KEY"]
out_dir = os.path.join(os.path.dirname(__file__), "..", "public", "audio", "sfx")
def gen(name):
    dur, text = SFX[name]
    body = {"text": text, "duration_seconds": dur, "prompt_influence": 0.6, "model_id": "eleven_text_to_sound_v2"}
    req = urllib.request.Request("https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
        data=json.dumps(body).encode(), headers={"xi-api-key": key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            open(os.path.join(out_dir, name + ".mp3"), "wb").write(r.read())
        return name + " ok"
    except urllib.error.HTTPError as e:
        return f"{name} HTTP {e.code}: {e.read().decode()[:300]}"
with ThreadPoolExecutor(4) as ex:
    for r in ex.map(gen, sys.argv[1:] or list(SFX)): print(r)
