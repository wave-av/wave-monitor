#!/usr/bin/env bash
# guard-content-policy — GHA parity with public-repo-guard.yml step "content
# policy (WAVE trade-secret / internal-leak gate)": runs the VENDORED
# scripts/public-repo-guard/content-policy.sh (never fetched at run time).
#
# GUARD_PRIVATE_REPOS arrives via host injection by (pipeline, step key) on the
# fpc-isolated-secrets queue — it is confidential config (private repo names),
# so it must NOT be inlined in pipeline.yml or any committed file. Unset/empty
# FAILS CLOSED here: a Buildkite config error must never silently disable the
# blocking private-repo rule. (Local callers run the vendored
# scripts/public-repo-guard/content-policy.sh directly, where the rule stays
# optional — see README.md.)
#
# GHA apt-installs ripgrep when missing; FPC guests must not assume sudo/apt,
# so a missing rg fails closed with a clear message instead.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep (rg) is required but not installed in the agent image — failing closed."
  exit 2
}
# RIG DEMONSTRATION PATCH (acceptance 4; S1 owns the real fix): in-script
# fork refusal BEFORE the secret is required. Proves nothing on its own — the
# fork deletes it (fixture b) unless the host runs scripts from the trusted
# base revision. The rig runs both provenances to prove the dependency.
if [ -n "${BUILDKITE_PULL_REQUEST_REPO:-}" ] && [ -n "${BUILDKITE_REPO:-}" ] \
   && [ "$BUILDKITE_PULL_REQUEST_REPO" != "$BUILDKITE_REPO" ]; then
  echo "fork PR detected (head $BUILDKITE_PULL_REQUEST_REPO != pipeline $BUILDKITE_REPO) — refusing to run with host-injected credentials."
  exit 2
fi
: "${GUARD_PRIVATE_REPOS:?host must inject GUARD_PRIVATE_REPOS for step key guard-content-policy}"
bash scripts/public-repo-guard/content-policy.sh .
