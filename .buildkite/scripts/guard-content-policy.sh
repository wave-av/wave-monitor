#!/usr/bin/env bash
# guard-content-policy — GHA parity with public-repo-guard.yml step "content
# policy (WAVE trade-secret / internal-leak gate)": runs the VENDORED
# scripts/public-repo-guard/content-policy.sh (never fetched at run time).
#
# GUARD_PRIVATE_REPOS arrives via host injection by (pipeline, step key) on the
# fpc-isolated-secrets queue — it is confidential config (private repo names),
# so it must NOT be inlined in pipeline.yml or any committed file. Unset/empty
# keeps GHA-local behavior: the private-repo rule is skipped (content-policy.sh
# handles that itself).
#
# GHA apt-installs ripgrep when missing; FPC guests must not assume sudo/apt,
# so a missing rg fails closed with a clear message instead.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep (rg) is required but not installed in the agent image — failing closed."
  exit 2
}
if [ -z "${GUARD_PRIVATE_REPOS:-}" ]; then
  echo "warning: GUARD_PRIVATE_REPOS is empty — the private-repo rule is skipped (same as local runs)."
fi
bash scripts/public-repo-guard/content-policy.sh .
