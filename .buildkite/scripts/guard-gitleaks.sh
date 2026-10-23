#!/usr/bin/env bash
# guard-gitleaks — GHA parity with public-repo-guard.yml steps "Install gitleaks
# (pinned + checksum-verified)" + "gitleaks (secret scan — published tree)".
#
# Version pin + SHA-256 copied from the GHA workflow; bump the two together.
# One deliberate change: GHA `sudo install`s to /usr/local/bin. FPC guests must
# not assume sudo, so the verified binary runs from a temp dir instead — same
# scan, smaller footprint.
#
# Base-pinned config (WAVE-27332): the PR checkout is only the scan SOURCE.
# The rules come from the canonical .gitleaks.toml at the merge-base with the
# base branch, so a PR that neuters its own config is still scanned with
# teeth. Base without a config falls back to the worktree copy with a loud
# warning; an unresolvable base fails closed (exit 2). Main builds use the
# worktree config (HEAD is trusted there). GITLEAKS_BIN, when set, skips the
# download (test seam; CI never sets it).
set -euo pipefail

GITLEAKS_VERSION="8.30.1"
GITLEAKS_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"

# resolve_config <workdir>: print the config path gitleaks must use.
resolve_config() {
  local work="$1" pr="${BUILDKITE_PULL_REQUEST:-false}"
  if [[ "$pr" == "false" || -z "$pr" ]]; then
    echo ".gitleaks.toml"
    return 0
  fi
  local base_branch="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}"
  if [[ -z "$base_branch" ]]; then
    echo "guard-gitleaks: PR build without BUILDKITE_PULL_REQUEST_BASE_BRANCH — failing closed" >&2
    return 2
  fi
  local base_rev=""
  base_rev="$(git merge-base HEAD "origin/${base_branch}" 2>/dev/null)" || base_rev=""
  if [[ -z "$base_rev" ]]; then
    echo "guard-gitleaks: cannot resolve merge-base with origin/${base_branch} — failing closed" >&2
    return 2
  fi
  if git cat-file -e "${base_rev}:.gitleaks.toml" 2>/dev/null; then
    git show "${base_rev}:.gitleaks.toml" > "${work}/base.gitleaks.toml"
    echo "${work}/base.gitleaks.toml"
  else
    echo "guard-gitleaks: WARNING base ${base_rev} has no .gitleaks.toml — falling back to worktree config" >&2
    echo ".gitleaks.toml"
  fi
}

main() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.."
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  local bin
  if [[ -n "${GITLEAKS_BIN:-}" ]]; then
    bin="$GITLEAKS_BIN"
  else
    cd "$WORK"
    curl -fsSL --proto '=https' --tlsv1.2 -o gitleaks.tar.gz \
      "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    echo "${GITLEAKS_SHA256}  gitleaks.tar.gz" | sha256sum -c -
    tar -xzf gitleaks.tar.gz gitleaks
    ./gitleaks version
    cd - >/dev/null
    bin="$WORK/gitleaks"
  fi
  local config
  config="$(resolve_config "$WORK")" || exit 2
  "$bin" detect --no-git --source . --config "$config" --redact --no-banner --exit-code 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
