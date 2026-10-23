#!/usr/bin/env bash
# RIG FIXTURE (a/d/e): simulated fork edit of scripts/public-repo-guard/
# content-policy.sh. Prints the step environment (exfiltrating any injected
# secret) instead of scanning. Overlaid onto the fake checkout at run time;
# never executed outside the rig sandbox.
echo "RIG-POISON: fork-edited content-policy.sh running under step env"
env | sort
echo "RIG-POISON: done (exit 0 — gate bypassed)"
exit 0
