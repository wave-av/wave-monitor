#!/usr/bin/env bash
# governance-enforce — GHA parity with governance-enforce.yml job `enforce`
# (A_BLOCK gate: no-secrets-in-git / secrets-from-doppler / no-hardcoded-paths
# on the PR diff via @wave-av/governance, isolated install).
#
# Auth: GHA uses secrets.GITHUB_TOKEN (packages:read). Buildkite has no
# GITHUB_TOKEN; the host injects GH_PACKAGES_READ_TOKEN by (pipeline, step key)
# on the fpc-isolated-secrets queue. That name must be in the repo's
# repos.yaml `secrets` allowlist. It must be a token with GH-Packages read for
# the @wave-av scope (fine-grained PAT or equivalent) — see README.md.
#
# Diff base: GHA gets base SHAs from the event payload. Buildkite exposes only
# BUILDKITE_PULL_REQUEST_BASE_BRANCH, so for PR builds we fetch the base branch
# and merge-base against it. For non-PR builds there is no trustworthy base, so
# we scan the full tree against git's empty-tree object — loud, never a silent
# empty/partial pass (same fail-loud rule as the GHA indeterminate-base path).
# The pipeline marks this step pr_only, so the fallback rarely runs.
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${GH_PACKAGES_READ_TOKEN:?host must inject GH_PACKAGES_READ_TOKEN for step key governance-enforce}"

if [ -n "${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}" ]; then
  git fetch --quiet --depth 50 origin "$BUILDKITE_PULL_REQUEST_BASE_BRANCH" || \
    git fetch --quiet origin "$BUILDKITE_PULL_REQUEST_BASE_BRANCH"
  BASE="$(git merge-base HEAD "origin/$BUILDKITE_PULL_REQUEST_BASE_BRANCH")"
  echo "diffing against merge-base $BASE (origin/$BUILDKITE_PULL_REQUEST_BASE_BRANCH)"
else
  # Indeterminate base (push build / manual run). Do NOT silently scan a partial range —
  # HEAD~1 would skip earlier commits in a multi-commit push and let a violation through
  # (a config-no-silent-noop hole). Diff the full tree against git's empty-tree object so
  # every introduced file is scanned; loud, never a silent empty/partial pass.
  BASE=$(git hash-object -t tree /dev/null)
  echo "warning: indeterminate diff base; scanning full tree (empty-tree base) so no commit is skipped"
fi

GOVDIR="$(mktemp -d)"
trap 'rm -rf "$GOVDIR"' EXIT
printf '@wave-av:registry=https://npm.pkg.github.com\n//npm.pkg.github.com/:_authToken=${NODE_AUTH_TOKEN}\n' > "$GOVDIR/.npmrc"
cd "$GOVDIR"
NODE_AUTH_TOKEN="$GH_PACKAGES_READ_TOKEN" npm install @wave-av/governance@^0.4.4 --no-save --no-audit --no-fund
cd - >/dev/null
node "$GOVDIR/node_modules/@wave-av/governance/bin/enforce.mjs" --changed "$BASE"
