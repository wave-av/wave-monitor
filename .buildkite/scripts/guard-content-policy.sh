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
# Chunking (T1/WAVE-27030): the host secrets channel caps each value at 512B
# (golden image MAX_SECRET), so Doppler wave/bkjobs carries the list as
# GUARD_PRIVATE_REPOS_01.._06 and the allowlist grants all six to this step
# key. A full GUARD_PRIVATE_REPOS (GHA org var, per-build proof injection)
# takes precedence when set; otherwise all six chunks must be present — a
# missing chunk fails closed, never silently narrows the rule.
#
# PR mode (WAVE-27678): pull-request builds do not receive the list. The
# non-secret WAVE_JOB_GUARD_PR=1 runs every content-policy rule except
# private-repo, and only when BUILDKITE_PULL_REQUEST is a positive integer
# (Buildkite's pull-request number). The flag is passed through to
# content-policy.sh; the list is not. The same flag when that variable is
# empty, "false", or any other non-number fails closed (exit 2), so a
# default-branch build cannot drop the rule. With the flag unset, a missing
# list still fails closed.
#
# GHA apt-installs ripgrep when missing; FPC guests must not assume sudo/apt,
# so a missing rg fails closed with a clear message instead.
set -euo pipefail
cd "$(dirname "$0")/../.."

_norm_repo() {
  # host/owner/name lowercase, no scheme/user/suffix (review findings: a raw
  # comparison false-refuses SSH-style pipeline URLs, but dropping the host
  # would collapse distinct SCM hosts into one identity). Anything without a
  # host/owner/name shape normalizes to EMPTY (not an identity): equally
  # malformed PR/pipeline values must refuse, never compare equal and bypass.
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E -e 's#^(https?|ssh|git)://([^/@]+@)?([^/]+)/#\3/#' -e 's#^git@([^:]+):#\1/#' -e 's#/$##' -e 's#\.git$##' | awk -F/ 'NF >= 3 && $1 != "" && $2 != "" && $3 != "" { print }'
}

# Buildkite sets BUILDKITE_PULL_REQUEST to the pull-request number, or to the
# string "false". Only a positive decimal integer selects PR mode.
_guard_is_pr_number() {
  [[ "${BUILDKITE_PULL_REQUEST:-}" =~ ^[1-9][0-9]*$ ]]
}

if [ -n "${BUILDKITE_PULL_REQUEST_REPO:-}" ]; then
  _head="$(_norm_repo "$BUILDKITE_PULL_REQUEST_REPO")"
  _pipe="$(_norm_repo "${BUILDKITE_REPO:-}")"
  if [ -z "$_head" ] || [ -z "$_pipe" ] || [ "$_head" != "$_pipe" ]; then
    # Log NORMALIZED forms: raw URLs can embed userinfo credentials.
    echo "fork PR detected (head ${_head:-<unparseable>} != pipeline ${_pipe:-<unparseable>}) — refusing to run with host-injected credentials."
    echo "Host must approve a trusted re-run; see README.md (Buildkite runbook). There is no base-revision checkout (WAVE-27333)."
    exit 2
  fi
fi

# Reject a downgrade before any scan. A legal PR-mode build still needs rg
# below, because every rule except private-repo must actually run.
if [ "${WAVE_JOB_GUARD_PR:-}" = "1" ] && ! _guard_is_pr_number; then
  echo "WAVE_JOB_GUARD_PR=1 is set but BUILDKITE_PULL_REQUEST is not a pull-request number — failing closed (private-repo rule must not be skipped)."
  exit 2
fi

command -v rg >/dev/null 2>&1 || {
  echo "ripgrep (rg) is required but not installed in the agent image — failing closed."
  exit 2
}
if [ "${WAVE_JOB_GUARD_PR:-}" = "1" ]; then
  echo "guard-content-policy: private-repo rule skipped for PR mode; remaining content-policy rules still run."
  # content-policy.sh lives outside .buildkite/ and can be edited on a pull
  # request, so the confidential list must not be in its environment. The
  # non-secret flag and BUILDKITE_PULL_REQUEST are passed through unchanged.
  unset GUARD_PRIVATE_REPOS \
    GUARD_PRIVATE_REPOS_01 GUARD_PRIVATE_REPOS_02 GUARD_PRIVATE_REPOS_03 \
    GUARD_PRIVATE_REPOS_04 GUARD_PRIVATE_REPOS_05 GUARD_PRIVATE_REPOS_06
  export WAVE_JOB_GUARD_PR
  exec bash scripts/public-repo-guard/content-policy.sh .
fi
if [ -n "${GUARD_PRIVATE_REPOS+x}" ]; then
  # Set (even to empty): must be non-degenerate, takes precedence. An
  # explicitly empty/whitespace full value fails closed here — it must
  # never silently fall through to chunks (or disable the rule).
  _full_stripped="$(printf '%s' "$GUARD_PRIVATE_REPOS" | tr -d '[:space:]')"
  if [ -z "$_full_stripped" ]; then
    echo "GUARD_PRIVATE_REPOS is explicitly empty/whitespace — failing closed (an explicit empty value must never silently select chunks or disable the rule)."
    exit 2
  fi
else
  for _i in 01 02 03 04 05 06; do
    _v="GUARD_PRIVATE_REPOS_$_i"
    # Whitespace-only counts as missing: the policy splits on whitespace,
    # so a blank chunk would silently narrow the rule.
    if [ -z "$(printf '%s' "${!_v:-}" | tr -d '[:space:]')" ]; then
      echo "host must inject GUARD_PRIVATE_REPOS (full) or all of GUARD_PRIVATE_REPOS_01.._06 for step key guard-content-policy (missing $_v) — failing closed."
      exit 2
    fi
  done
  GUARD_PRIVATE_REPOS="$GUARD_PRIVATE_REPOS_01,$GUARD_PRIVATE_REPOS_02,$GUARD_PRIVATE_REPOS_03,$GUARD_PRIVATE_REPOS_04,$GUARD_PRIVATE_REPOS_05,$GUARD_PRIVATE_REPOS_06"
  export GUARD_PRIVATE_REPOS
fi
bash scripts/public-repo-guard/content-policy.sh .
