#!/usr/bin/env python3
"""Turns the character alignment of a narration take into words and paragraphs (blank-line separated) with times.
usage: words.py take.json > words.json"""
import json, sys
d = json.load(open(sys.argv[1])); a = d["alignment"]
chars, st, en = a["characters"], a["character_start_times_seconds"], a["character_end_times_seconds"]
words, cur, para, paras = [], None, 0, []
text = "".join(chars)
i = 0
while i < len(chars):
    c = chars[i]
    if c == "\n" and i + 1 < len(chars) and chars[i + 1] == "\n":
        para += 1; i += 2; cur = None; continue
    if c.isspace():
        cur = None
    else:
        if cur is None:
            cur = {"w": "", "s": st[i], "e": en[i], "p": para}; words.append(cur)
        cur["w"] += c; cur["e"] = en[i]
    i += 1
for p in range(para + 1):
    ws = [w for w in words if w["p"] == p]
    paras.append({"i": p, "s": ws[0]["s"], "e": ws[-1]["e"], "text": " ".join(w["w"] for w in ws)})
json.dump({"words": words, "paragraphs": paras}, sys.stdout, indent=1)
