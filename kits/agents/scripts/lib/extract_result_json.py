#!/usr/bin/env python3
# Extract the worker's result JSON from captured spawn-agent output.
# Read from stdin; print the first line starting with '{' to stdout.
# Version 1 (buggy — replaced in commit 2): line-based match.
import sys
for line in sys.stdin:
    if line.startswith('{'):
        print(line, end='')
        break
