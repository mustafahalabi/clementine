#!/usr/bin/env python3
"""Estimates tempo and beat phase of the score (onset envelope autocorrelation). usage: beats.py music.mp3 > beats.json"""
import json, subprocess, sys
import numpy as np
sr = 22050; hop = 256
x = np.frombuffer(subprocess.run(["ffmpeg", "-v", "error", "-i", sys.argv[1], "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"],
                                 capture_output=True).stdout, np.float32)
n = 1024; frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * np.hanning(n)
spec = np.log1p(np.abs(np.fft.rfft(frames, axis=1)))
flux = np.maximum(0, np.diff(spec, axis=0)).sum(1); flux = (flux - flux.mean()) / (flux.std() + 1e-9)
fps = sr / hop
def tempo(seg):
    ac = np.correlate(seg, seg, "full")[len(seg) - 1:]
    lags = np.arange(len(ac)); bpm = 60 * fps / np.maximum(lags, 1)
    m = (bpm > 70) & (bpm < 160)
    return 60 * fps / lags[m][np.argmax(ac[m])]
s0, s1 = int(20 * fps), int(50 * fps)  # groove + build
bpm = tempo(flux[s0:s1]); period = 60 / bpm
# beat phase: maximise onset energy on the grid inside the groove
best = max(np.linspace(0, period, 120, endpoint=False),
           key=lambda ph: sum(flux[int((t) * fps)] for t in np.arange(20 + ph, 50, period) if int(t * fps) < len(flux)))
beats = [round(t, 3) for t in np.arange(best % period, len(x) / sr, period)]
print(json.dumps({"bpm": round(bpm, 2), "period": round(period, 4), "phase": round(best % period, 4), "beats": beats}))
