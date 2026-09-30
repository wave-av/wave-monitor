#!/usr/bin/env bash
# Shared helpers for .buildkite/steps/*.sh. SOURCED by every step script, never run directly.
#
# Vendored from wave-av/wave-gateway .buildkite/scripts/lib/common.sh (draft PR #1928, branch
# feat/buildkite-ci) by way of wave-av/wave-opencode's port (draft PR #222). wave-monitor is a
# PUBLIC repo and wave-foundation's "Buildkite template v0" (PR #1570) lives in a PRIVATE repo, so
# this file is vendored rather than referenced cross-repo, the same way .github/workflows/_checks.yml
# is a vendored copy in this repo (not a `uses:` cross-repo reference).
#
# Local edits from the vendored source: trimmed to only what these two steps need. This pipeline
# runs no `npm install` (no lib/npm-install.sh — neither step touches package.json), needs no Node
# major-version assertion, and touches no Doppler or Cloudflare credential, so those helpers were
# dropped rather than carried in unused. What's kept: strict mode, log grouping, a job-local temp
# dir with cleanup-on-exit, and the multi-gate runner/summary pattern used by every fleet port so
# far (see wave-opencode .buildkite/scripts/lib/common.sh, wave-gateway's original).
# TODO(buildkite-template): re-vendor from wave-av/wave-foundation buildkite/template/v0 (PR #1570)
# once that template is generally available to public repos.
#
# Contract every step script inherits from here:
#   - `set -euo pipefail`, and never `set -x` (xtrace would print expanded values into the build log).
#   - Never print an environment variable's VALUE. Errors name the variable, never its contents.
#   - Temp dirs are job-local and removed on exit, so a disposable guest has nothing left to leak.
set -euo pipefail

BK_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BK_REPO_ROOT

_bk_cleanup_paths=()
_bk_failed_gates=()

bk_cleanup_on_exit() {
  local p
  for p in "${_bk_cleanup_paths[@]+"${_bk_cleanup_paths[@]}"}"; do
    rm -rf -- "$p"
  done
}
trap bk_cleanup_on_exit EXIT

# Buildkite log group. `---` is collapsed; bk_gate expands the group again when its gate fails.
bk_section() {
  printf -- '--- %s\n' "$*"
}

bk_err() {
  printf 'error: %s\n' "$*" >&2
}

# bk_mktemp_dir <var>: create a job-local temp dir, register it for cleanup and store its path in
# <var>. It sets a variable instead of printing the path, because a $(...) subshell would lose the
# cleanup registration.
bk_mktemp_dir() {
  local __dir
  __dir="$(mktemp -d "${TMPDIR:-/tmp}/bk.XXXXXX")"
  _bk_cleanup_paths+=("$__dir")
  printf -v "$1" '%s' "$__dir"
}

bk_require_tools() {
  local tool missing=0
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      bk_err "required tool '$tool' is not on PATH (guest-image prerequisite)"
      missing=1
    fi
  done
  return "$missing"
}

# bk_gate <name> <command...>: run one gate in its own log group and record a failure without
# stopping, so a single build reports every failing gate. Each gate is one external command, because
# errexit is suspended inside `||` and a multi-command body would hide an early failure.
bk_gate() {
  local name="$1"
  shift
  bk_section "$name"
  local rc=0
  "$@" || rc=$?
  if (( rc != 0 )); then
    printf '^^^ +++\n'
    bk_err "gate failed: ${name} (exit ${rc})"
    _bk_failed_gates+=("${name} (exit ${rc})")
  fi
}

# Last call of a gate-running script: exits non-zero when any bk_gate failed, listing each one.
bk_gates_summary() {
  if (( ${#_bk_failed_gates[@]} > 0 )); then
    printf '+++ %s gate(s) failed\n' "${#_bk_failed_gates[@]}"
    printf '  - %s\n' "${_bk_failed_gates[@]}"
    return 1
  fi
  printf '+++ all gates passed\n'
}
