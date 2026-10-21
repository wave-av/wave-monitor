#!/usr/bin/env python3
"""RIG FIXTURE (b) + patched-(a) setup: delete the fork-refusal block from a
step-script COPY (simulating a fork edit). Usage: strip-refusal.py PATH
[ANCHOR ...] — anchors default to the governance-enforce set; pass the
guard-content-policy set (GUARD_PRIVATE_REPOS, content-policy.sh) for the
wrapper. Fails closed if the refusal text is absent or the shape changed — a
silent no-op would fake a DENY."""
import re
import sys

path = sys.argv[1]
anchors = sys.argv[2:] or ('GH_PACKAGES_READ_TOKEN', 'GOV_VERSION=', 'merge-base')
src = open(path).read()
start = src.find('if [ -n "${BUILDKITE_PULL_REQUEST_REPO')
if start < 0:
    print("strip-refusal: refusal block not found — premise broken", file=sys.stderr)
    sys.exit(2)
# The closing `fi` must sit at the SAME indentation as the opening `if` —
# a column-0-only search would over-delete through an indented block up to a
# later unrelated `fi`.
linestart = src.rfind("\n", 0, start) + 1
indent = src[linestart:start]
if indent.strip(" \t"):
    print("strip-refusal: refusal opener not at line start", file=sys.stderr)
    sys.exit(2)
term = f"\n{indent}fi\n"
end = src.find(term, start)
if end < 0:
    print("strip-refusal: refusal terminator not found", file=sys.stderr)
    sys.exit(2)
out = src[:start] + src[end + len(term):]
if "BUILDKITE_PULL_REQUEST_REPO" in out:
    print("strip-refusal: refusal remnants remain", file=sys.stderr)
    sys.exit(2)
for anchor in anchors:
    if anchor not in out:
        print(f"strip-refusal: anchor lost ({anchor}) — over-deleted", file=sys.stderr)
        sys.exit(2)
open(path, "w").write(out)
print("strip-refusal: refusal block removed, anchors intact")
