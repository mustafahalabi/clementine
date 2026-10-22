#!/usr/bin/env python3
"""Measures each SFX's onset (first point within 20 dB of its peak) and peak time, so cues can land on the transient."""
import glob, json, os, subprocess, sys
import numpy as np
res = {}
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.mp3"))):
    x = np.abs(np.frombuffer(subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-ac", "1", "-ar", "44100", "-f", "f32le", "-"],
                                     capture_output=True).stdout, np.float32))
    env = np.convolve(x, np.ones(220) / 220, "same")
    pk = env.max(); on = int(np.argmax(env > pk * 0.1)); peak = int(np.argmax(env))
    res[os.path.basename(p)[:-4]] = {"onset": round(on / 44100, 3), "peak": round(peak / 44100, 3), "dur": round(len(x) / 44100, 3)}
print(json.dumps(res, indent=1))
