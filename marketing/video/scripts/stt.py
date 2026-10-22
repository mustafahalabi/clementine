#!/usr/bin/env python3
"""Transcribes audio with ElevenLabs Scribe to check a take says what the script says. usage: stt.py file…"""
import json, os, sys, urllib.request, uuid
for path in sys.argv[1:]:
    b = uuid.uuid4().hex
    data = (f"--{b}\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v1\r\n"
            f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n").encode() \
        + open(path, "rb").read() + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request("https://api.elevenlabs.io/v1/speech-to-text", data=data,
        headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": f"multipart/form-data; boundary={b}"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=300))
        print(os.path.basename(path), "|", d.get("text"))
    except urllib.error.HTTPError as e:
        print(path, "HTTP", e.code, e.read().decode()[:300])
