#!/usr/bin/env bash
# foundation-secret-scan — GHA parity with _checks.yml job `checks`, step
# "Secret scan (fail-closed, allowlist-aware)". Patterns copied verbatim from
# the vendored _checks.yml; keep in sync with wave-foundation checks.yml@v1  # guard:allow verified-safe doc example of shared checks repo
# on every v1.x bump, exactly like the GHA file.
#
# Deliberate BK hardenings over the GHA step (same gate, safer plumbing):
#   * match CONTENT is never printed — only a generic failure message, so
#     credential values cannot enter Buildkite logs;
#   * the allowlist filter matches the full `pragma: allowlist secret` marker,
#     not the bare substring;
#   * pipeline exit statuses are captured: grep 0/1 continue, anything else
#     fails closed (no `|| true` masking scan errors as clean).
set -euo pipefail
cd "$(dirname "$0")/../.."

# Real-secret patterns. Lines tagged "pragma: allowlist secret" (e.g. test fixtures / regex
# definitions) are skipped — that's how a vetting module can define key-shapes without tripping.
SCAN_TMP="$(mktemp)"
trap 'rm -f "$SCAN_TMP"' EXIT
set +e
grep -rIEn '(sk-[A-Za-z0-9]{20}|sk_(live|test)_[A-Za-z0-9]{20}|npm_[A-Za-z0-9]{30}|sbp_[a-f0-9]{40}|github_pat_[A-Za-z0-9_]{40}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30}|AIzaSy[A-Za-z0-9_-]{20}|xai-[A-Za-z0-9]{40}|xoxb-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY)' \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist . \
  | grep -v 'pragma: allowlist secret' \
  | { [ -f .github/.secret-allowlist ] && grep -vFf .github/.secret-allowlist || cat; } >"$SCAN_TMP"
SCAN_STATUS=("${PIPESTATUS[@]}")
set -e
for s in "${SCAN_STATUS[@]}"; do
  if [ "$s" -gt 1 ]; then
    echo "secret-scan errored (pipeline status ${SCAN_STATUS[*]}) — failing closed"
    exit 2
  fi
done
if [ -s "$SCAN_TMP" ]; then echo "secret-like pattern found — do not commit credentials"; exit 1; fi
echo "secret-scan clean"
