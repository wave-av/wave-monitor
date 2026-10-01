#!/usr/bin/env bash
# Step `secrets-content-policy`: shadows the "Secrets + content policy" GitHub required check —
# job `guard` in .github/workflows/public-repo-guard.yml. Reproduces that job's two gates:
#   1. gitleaks 8.30.1, installed with the SAME pin + sha256 verification the workflow uses, run as
#      `gitleaks detect --no-git --source . --config .gitleaks.toml --redact --no-banner --exit-code 1`.
#   2. `bash scripts/public-repo-guard/content-policy.sh .` (needs ripgrep), with GUARD_PRIVATE_REPOS
#      handled the same way the workflow handles it (see below).
#
# Both .gitleaks.toml and scripts/public-repo-guard/content-policy.sh are already vendored into this
# repo (that's the existing pattern this step reuses, not a new vendor) — this script only adds the
# Buildkite-side install + invocation, matching the workflow byte-for-byte on the parts that matter
# (version pin, checksum, and command line).
#
# GUARD_PRIVATE_REPOS: the workflow reads this from `${{ vars.GUARD_PRIVATE_REPOS }}`, an org/repo
# Actions variable. When that variable is unset, GitHub still passes GUARD_PRIVATE_REPOS="" (empty,
# not absent) into the job env, and content-policy.sh's `[[ -n "${GUARD_PRIVATE_REPOS:-}" ]]` check
# then skips the private-repo-name rule. This step matches that: it reads GUARD_PRIVATE_REPOS from
# the Buildkite agent/job environment if present (an operator can export it from the agent
# environment hook, the Buildkite equivalent of an Actions variable) and does NOT fabricate a value
# when it's absent — content-policy.sh's own `${GUARD_PRIVATE_REPOS:-}` fallback then behaves
# identically to the unset-variable case on GitHub: the private-repo-name rule is skipped.
#
# SHADOW MODE: informational only. The GitHub Actions job stays the required check until an
# operator swaps branch protection after a green soak. See .buildkite/README.md.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

cd "$BK_REPO_ROOT"
bk_require_tools curl sha256sum tar bash

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

bk_section "Install gitleaks ${GITLEAKS_VERSION} (pinned + checksum-verified)"
gl_dir=""
bk_mktemp_dir gl_dir
( cd "$gl_dir" \
  && curl -fsSL --proto '=https' --tlsv1.2 -o gitleaks.tar.gz \
       "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  && echo "${GITLEAKS_SHA256}  gitleaks.tar.gz" | sha256sum -c - \
  && tar -xzf gitleaks.tar.gz gitleaks )
if [[ -w /usr/local/bin ]] || [[ "$(id -u)" == "0" ]]; then
  install -m 0755 "${gl_dir}/gitleaks" /usr/local/bin/gitleaks
elif command -v sudo >/dev/null 2>&1; then
  sudo install -m 0755 "${gl_dir}/gitleaks" /usr/local/bin/gitleaks
else
  bk_err "cannot install gitleaks to /usr/local/bin (not writable, no sudo); guest image should provision this"
  exit 1
fi
gitleaks version

bk_gate "gitleaks (secret scan — published tree)" \
  gitleaks detect --no-git --source . --config .gitleaks.toml --redact --no-banner --exit-code 1

bk_section "Install ripgrep"
if ! command -v rg >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    if [[ "$(id -u)" == "0" ]]; then
      apt-get update -qq && apt-get install -y -qq ripgrep
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq && sudo apt-get install -y -qq ripgrep
    fi
  fi
fi
bk_require_tools rg

bk_gate "content policy (WAVE trade-secret / internal-leak gate)" \
  bash scripts/public-repo-guard/content-policy.sh .

bk_gates_summary
