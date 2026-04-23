#!/usr/bin/env python3
# Extract the last complete top-level JSON object from stdin.
# Robust to multi-line JSON, log lines before/after, and multiple
# JSON objects (returns the LAST — the consolidated result from
# the Python wrapper is always emitted last).
import json, sys
text = sys.stdin.read()
decoder = json.JSONDecoder()
last = None
i = 0
while i < len(text):
    if text[i] != '{':
        i += 1
        continue
    try:
        obj, end = decoder.raw_decode(text, i)
        if isinstance(obj, dict):
            last = text[i:end]
        i = end
    except json.JSONDecodeError:
        i += 1
if last:
    sys.stdout.write(last)
