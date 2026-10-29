#!/usr/bin/env bash
# governance-enforce — GHA parity with governance-enforce.yml job `enforce`
# (A_BLOCK gate: no-secrets-in-git / secrets-from-doppler / no-hardcoded-paths
# on the PR diff via @wave-av/governance, isolated install).
#
# Packages (WAVE-30138): @wave-av/governance comes through the host-side
# registry proxy, never with a token in the job. The proxy is read-only,
# serves the @wave-av scope only, holds its credential on the host, and is
# reachable from the guest on loopback only. This step receives NO injected
# values and runs on queue fpc-isolated for every build (wave-monitor is
# public: no secrets-allowlist row exists or is wanted). The proxy contract
# is the fleet's shared job registry proxy: default
# http://127.0.0.1:4873/, override with the non-secret WAVE_JOB_REGISTRY_PROXY_URL,
# which must be http://127.0.0.1:<port>/ or http://localhost:<port>/.
# If the proxy is not listening or does not serve the pinned version, the step
# fails closed (exit 2) with a clear message. There is no soft_fail and no
# fallback to any other registry.
#
# Diff base: GHA gets base SHAs from the event payload. Buildkite exposes only
# BUILDKITE_PULL_REQUEST_BASE_BRANCH, so for PR builds we fetch the base branch
# and merge-base against it. For non-PR builds there is no trustworthy base, so
# we scan the full tree against git's empty-tree object — loud, never a silent
# empty/partial pass (same fail-loud rule as the GHA indeterminate-base path).
#
# Fork trust: no credential reaches this step, so a fork could only fail it.
# Fork builds never trigger on venue pipelines (build_pull_request_forks=false,
# WAVE-27333: there is no base-revision checkout). As defence in depth this
# script still refuses when the PR head repo differs from the pipeline repo.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ -n "${BUILDKITE_PULL_REQUEST_REPO:-}" ] && [ -n "${BUILDKITE_REPO:-}" ] \
   && [ "$BUILDKITE_PULL_REQUEST_REPO" != "$BUILDKITE_REPO" ]; then
  echo "fork PR detected (head $BUILDKITE_PULL_REQUEST_REPO != pipeline $BUILDKITE_REPO) — refusing (defence in depth; this step gets no credentials)."
  exit 2
fi

# No credential may reach npm from this job. Drop every token- or auth-shaped
# variable and every npm config override by NAME (values are never read or
# printed), so npm sees only the job-local npmrc written below.
while IFS= read -r v; do
  case "$v" in
    *TOKEN*|*_AUTH*|*PASSWORD*|*SECRET*|NPM_CONFIG_*|npm_config_*) unset "$v" ;;
  esac
done < <(compgen -e)

PROXY="${WAVE_JOB_REGISTRY_PROXY_URL:-http://127.0.0.1:4873/}"
if ! printf '%s' "$PROXY" | grep -Eq '^http://(127\.0\.0\.1|localhost):[0-9]{1,5}/$'; then
  echo "governance-enforce: registry proxy URL must be http://127.0.0.1:<port>/ or http://localhost:<port>/ (loopback only) — failing closed."
  exit 2
fi
# Loopback traffic must never go through an HTTP proxy.
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

if [ -n "${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-}" ]; then
  git fetch --quiet --depth 50 origin "$BUILDKITE_PULL_REQUEST_BASE_BRANCH" || \
    git fetch --quiet origin "$BUILDKITE_PULL_REQUEST_BASE_BRANCH"
  if ! BASE="$(git merge-base HEAD "origin/$BUILDKITE_PULL_REQUEST_BASE_BRANCH" 2>/dev/null)"; then
    # Depth-50 fetch can omit the common ancestor on long-lived PRs — retry
    # with full history before failing (unshallow, else full base fetch).
    if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
      git fetch --quiet --unshallow origin "$BUILDKITE_PULL_REQUEST_BASE_BRANCH"
    else
      git fetch --quiet origin "$BUILDKITE_PULL_REQUEST_BASE_BRANCH"
    fi
    BASE="$(git merge-base HEAD "origin/$BUILDKITE_PULL_REQUEST_BASE_BRANCH")"
  fi
  echo "diffing against merge-base $BASE (origin/$BUILDKITE_PULL_REQUEST_BASE_BRANCH)"
else
  # Indeterminate base (push build / manual run). Do NOT silently scan a partial range —
  # HEAD~1 would skip earlier commits in a multi-commit push and let a violation through
  # (a config-no-silent-noop hole). Diff the full tree against git's empty-tree object so
  # every introduced file is scanned; loud, never a silent empty/partial pass.
  BASE=$(git hash-object -t tree /dev/null)
  echo "warning: indeterminate diff base; scanning full tree (empty-tree base) so no commit is skipped"
fi

# Exact pin (never a range): every run enforces with the same reviewed
# implementation. npm verifies the tarball against the registry packument's
# dist.integrity on fetch, and the registry rejects same-version republishes,
# so the pin is the integrity anchor — bump it and the assertion together.
GOV_VERSION="0.4.6"
GOVDIR="$(mktemp -d)"
trap 'rm -rf "$GOVDIR"' EXIT

# Fail closed with a clear message when the proxy is missing or does not serve
# the pinned version. Prints status only, never the response body.
if ! PROXY="$PROXY" GOV_VERSION="$GOV_VERSION" node -e '
  const u = process.env.PROXY + "@wave-av%2fgovernance";
  const ac = AbortSignal.timeout(10000);
  fetch(u, { signal: ac, headers: { accept: "application/json" } })
    .then(async (r) => {
      if (r.status !== 200) { console.error("proxy answered HTTP " + r.status); process.exit(1); }
      const doc = await r.json();
      if (!doc.versions || !doc.versions[process.env.GOV_VERSION]) {
        console.error("proxy does not serve @wave-av/governance@" + process.env.GOV_VERSION); process.exit(1);
      }
    })
    .catch((e) => { console.error("proxy unreachable: " + (e.cause?.code || e.name)); process.exit(1); });
'; then
  echo "governance-enforce: the host registry proxy at $PROXY is missing or not serving @wave-av/governance@$GOV_VERSION — failing closed."
  echo "This step never falls back to a token or another registry (WAVE-30138). Fix the host proxy, then rebuild."
  exit 2
fi

# Job-local npmrc: only the @wave-av scope mapping, no auth line. Global and
# user config are pinned so no host or repo npmrc can add a token or redirect.
# A private package.json pins npm's local prefix to GOVDIR (otherwise npm may
# walk up to / and fail).
printf '@wave-av:registry=%s\n' "$PROXY" > "$GOVDIR/.npmrc"
printf '{"name":"governance-enforce-job","private":true}\n' > "$GOVDIR/package.json"
cd "$GOVDIR"
NPM_CONFIG_GLOBALCONFIG=/dev/null NPM_CONFIG_USERCONFIG="$GOVDIR/.npmrc" \
  npm install "@wave-av/governance@$GOV_VERSION" --prefix "$GOVDIR" \
    --ignore-scripts --no-save --no-audit --no-fund
INSTALLED="$(node -p "require('./node_modules/@wave-av/governance/package.json').version")"
[ "$INSTALLED" = "$GOV_VERSION" ] || { echo "governance version mismatch: installed $INSTALLED, want $GOV_VERSION"; exit 2; }
cd - >/dev/null
node "$GOVDIR/node_modules/@wave-av/governance/bin/enforce.mjs" --changed "$BASE"
