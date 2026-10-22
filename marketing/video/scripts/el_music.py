#!/usr/bin/env python3
"""Composes the score with the ElevenLabs Music API (music_v2_5), one chunk per section of audio/timeline.json.
usage: el_music.py out.mp3 [seed]"""
import json, os, sys, urllib.request
out = sys.argv[1]; seed = int(sys.argv[2]) if len(sys.argv) > 2 else 21
t = json.load(open(os.path.join(os.path.dirname(__file__), "..", "public", "audio", "timeline.json")))
base = ["instrumental", "modern minimal product film score", "warm analog synths", "felt piano", "100 bpm",
        "polished premium production", "optimistic"]
spec = {
 "Intro":  ("[Intro]\n{sparse felt piano and soft ticking pulse, a little restless, filtered, no drums}",
            base + ["sparse", "restrained", "slightly tense"]),
 "Reveal": ("[Lift]\n{airy swell and reverse cymbal rising into a bright open chord}", ["swell", "riser", "bright", "open"]),
 "Groove": ("[Groove]\n{bouncy plucked synth arpeggio, warm sub bass, crisp light drums, tight claps, playful and confident}",
            ["upbeat", "bouncy pluck arpeggio", "light electronic drums", "warm sub bass", "playful", "confident"]),
 "Build":  ("[Build]\n{fuller drums, layered arpeggios, rising energy, shimmering synths}",
            ["energetic", "fuller drums", "layered synths", "rising", "driving"]),
 "Breath": ("[Breakdown]\n{drums drop out, warm sustained pads and soft piano, calm and reassuring}",
            ["calm", "warm pads", "soft piano", "no drums", "intimate"]),
 "Finale": ("[Finale]\n{full uplifting resolution with drums and bright synths, then a final warm chord that rings out and fades}",
            ["uplifting", "resolved", "triumphant but tasteful", "final chord ring out", "fade out ending"]),
}
chunks = []
for i, sec in enumerate(t["musicSections"]):
    text, styles = spec[sec["name"]]
    chunks.append({"text": text, "duration_ms": int(round((sec["e"] - sec["s"]) * 1000)), "positive_styles": styles,
                   "negative_styles": ["vocals", "singing", "lyrics", "spoken word", "choir", "lo-fi", "distorted"],
                   "context_adherence": "high"})
body = {"model_id": "music_v2_5", "composition_plan": {"chunks": chunks}, "seed": seed}
req = urllib.request.Request("https://api.elevenlabs.io/v1/music?output_format=mp3_48000_192", data=json.dumps(body).encode(),
    headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=600) as r:
        open(out, "wb").write(r.read())
        print(out, {k: v for k, v in r.headers.items() if "id" in k.lower() or "song" in k.lower()})
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()[:800]}")
