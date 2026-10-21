#!/usr/bin/env python3
"""RIG receipt emitter. Reads a step log, redacts canaries, prints one JSON
receipt line. Usage: emit.py FIX CONFIG EXPECT ACTUAL BACKEND LOG NOTE [HARD].
Canaries via $RIG_CANARIES (space-separated). KINDs only in output."""
import json
import os
import sys

REDACT = "\u00abCANARY-REDACTED\u00bb"


def main(argv):
    fix, config, expect, actual = argv[1], argv[2], argv[3], argv[4]
    backend, logpath, note = argv[5], argv[6], argv[7]
    hard = argv[8] if len(argv) > 8 else ""
    cans = [c for c in os.environ.get("RIG_CANARIES", "").split() if c]
    try:
        with open(logpath, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        print(f"emit: cannot read step log {logpath}: {e}", file=sys.stderr)
        return 2
    red = []
    for ln in lines:
        for c in cans:
            ln = ln.replace(c, REDACT)
        red.append(ln)
    hits = [i for i, ln in enumerate(red) if REDACT in ln]
    if hits:
        lo = max(0, hits[0] - 2)
        excerpt = red[lo:lo + 8]
    else:
        excerpt = red[-8:] if red else ["(empty log)"]
    rec = {"fixture": fix, "config": config, "expected": expect,
           "actual": actual, "backend": backend,
           "pinned_sha": os.environ.get("RIG_PIN_SHA", ""),
           "log_excerpt": "\n".join(excerpt), "note": note}
    if hard:
        rec["hardening"] = hard
    print(json.dumps(rec))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
