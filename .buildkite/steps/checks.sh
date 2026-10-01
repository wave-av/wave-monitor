#!/usr/bin/env bash
# Step `gate-checks`: shadows the "gate / checks" GitHub required check — job `checks` in
# .github/workflows/_checks.yml (this repo's vendored copy of wave-foundation's reusable
# checks.yml@master). Reproduces that job's two gates byte-faithfully, with one deliberate exception
# (secret-scan hit reporting is redacted here — see the Secret scan section below and
# .buildkite/README.md):
#   1. Secret scan (fail-closed, allowlist-aware) — the same grep regex, exclude-dirs, and
#      .github/.secret-allowlist handling as the workflow.
#   2. File-size gate — `git ls-files '*.ts' '*.tsx' '*.js' '*.py'`, `wc -l` <= MAX (default 800),
#      with the same .types.ts/.d.ts exclusion and .github/.filesize-allowlist handling.
#
# This step does NOT reproduce _checks.yml's other two jobs (skill-validate, verify-routes) — only
# the `checks` job is what GitHub's branch protection names as a required context ("gate / checks").
#
# SHADOW MODE: informational only. The GitHub Actions job stays the required check until an
# operator swaps branch protection after a green soak. See .buildkite/README.md.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

cd "$BK_REPO_ROOT"
bk_require_tools git grep wc

MAX="${MAX_LINES:-800}"

bk_section "Secret scan (fail-closed, allowlist-aware)"
# Detection regex, --exclude-dir set, and .github/.secret-allowlist handling are a byte-faithful
# copy of _checks.yml's "Secret scan" step body. Reporting deliberately diverges (CWE-532): the GH
# Actions original prints the full matching line — which, for a true positive, is the credential
# itself — straight into the job log. Buildkite streams logs the same way, so this step prints only
# "path:line" (never the matched text) plus a generic message. Exit behavior (fail-closed, exit 1)
# is unchanged. See .buildkite/README.md for the note that GH Actions carries the same exposure —
# fixing that is a follow-up for wave-foundation's source checks.yml, out of scope here.
HITS=$(grep -rIEn '(sk-[A-Za-z0-9]{20}|sk_(live|test)_[A-Za-z0-9]{20}|npm_[A-Za-z0-9]{30}|sbp_[a-f0-9]{40}|github_pat_[A-Za-z0-9_]{40}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30}|AIzaSy[A-Za-z0-9_-]{20}|xai-[A-Za-z0-9]{40}|xoxb-[A-Za-z0-9-]+|-----BEGIN [A-Z ]*PRIVATE KEY)' \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist . | grep -v 'allowlist secret' \
    | { [ -f .github/.secret-allowlist ] && grep -vFf .github/.secret-allowlist || cat; } || true)
if [ -n "$HITS" ]; then
  echo "::error::secret-like pattern found — do not commit credentials"
  echo "$HITS" | cut -d: -f1,2
  bk_err "secret scan failed — see hits above"
  exit 1
fi
echo "secret-scan clean"

bk_section "File-size gate (MAX=${MAX})"
# Byte-faithful copy of _checks.yml's "File-size gate" step body (MAX substituted for
# ${{ inputs.max_lines }}; the workflow's default is also 800).
fail=0
while IFS= read -r f; do
  grep -qxF "$f" .github/.filesize-allowlist 2>/dev/null && continue   # justified exception
  n=$(wc -l < "$f")
  if [ "$n" -gt "$MAX" ]; then echo "::error::$f has $n lines (> $MAX)"; fail=1; fi
done < <(git ls-files '*.ts' '*.tsx' '*.js' '*.py' | grep -vE '\.(types|d)\.ts$')
if [ "$fail" = 0 ]; then
  echo "file-size gate passed (all <= $MAX lines)"
else
  bk_err "file-size gate failed — see hits above"
fi
exit "$fail"
