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

# Exact match on the whole string, never line-based (a grep over a value with
# an embedded newline would accept $'http://evil/\nhttp://127.0.0.1:4873/').
# Anything else fails closed.
PROXY="${WAVE_JOB_REGISTRY_PROXY_URL:-http://127.0.0.1:4873/}"
if [[ ! "$PROXY" =~ ^http://(127\.0\.0\.1|localhost):[0-9]{1,5}/$ ]]; then
  echo "governance-enforce: registry proxy URL must be http://127.0.0.1:<port>/ or http://localhost:<port>/ (loopback only) — failing closed."
  exit 2
fi

# No credential may reach node or npm from this job. Every node/npm call runs
# under `env -i` with this explicit allowlist (a deny-list by name misses
# names nobody thought of). Values are never read or printed. HOME and the npm
# cache are job-local, global and user npm config are pinned, and loopback
# never goes through an HTTP proxy. Outbound proxy variables pass only when
# they carry no userinfo (no user:pass@); otherwise they are dropped.
GOVDIR="$(mktemp -d)"
trap 'rm -rf "$GOVDIR"' EXIT
mkdir -p "$GOVDIR/home" "$GOVDIR/tmp" "$GOVDIR/cache" "$GOVDIR/install"
CLEAN_ENV=(
  "PATH=${PATH:-/usr/local/bin:/usr/bin:/bin}"
  "HOME=$GOVDIR/home"
  "TMPDIR=$GOVDIR/tmp"
  "LANG=C.UTF-8"
  "LC_ALL=C.UTF-8"
  "NO_PROXY=127.0.0.1,localhost"
  "no_proxy=127.0.0.1,localhost"
  "NPM_CONFIG_GLOBALCONFIG=/dev/null"
  "NPM_CONFIG_USERCONFIG=$GOVDIR/install/.npmrc"
  "NPM_CONFIG_CACHE=$GOVDIR/cache"
  "NPM_CONFIG_UPDATE_NOTIFIER=false"
  "NPM_CONFIG_FUND=false"
  "NPM_CONFIG_AUDIT=false"
)
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
  val="${!v:-}"
  if [ -n "$val" ] && [[ "$val" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]]; then
    CLEAN_ENV+=("$v=$val")
  fi
done
if [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f "$NODE_EXTRA_CA_CERTS" ]; then
  CLEAN_ENV+=("NODE_EXTRA_CA_CERTS=$NODE_EXTRA_CA_CERTS")
fi
run_clean() { env -i "${CLEAN_ENV[@]}" "$@"; }

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

# Exact pin (never a range) plus the tarball's sha512 (SRI). The integrity is
# the one the fleet registry seed contract records for this version
# (wave-ci ops/RUN-234-registry-seed.manifest.tsv, row @wave-av/governance
# 0.4.6, checked there against GitHub Packages' packument). The tarball is
# fetched from the loopback proxy at a path built here (never a URL taken
# from the packument), hashed, and installed from the local file only when it
# matches; the packument's dist.integrity must match too. Bump GOV_VERSION and
# GOV_INTEGRITY together.
GOV_VERSION="0.4.6"
GOV_INTEGRITY="sha512-GGSDZ0cD2WM+jukChbCRqoRVbPTNitVOd1tFuIX4F3wL6MxYyFV+aUMwh2G0ZHTVMD4P9VfqGCc1TOrLUDP0bA=="
GOV_TGZ="$GOVDIR/governance-$GOV_VERSION.tgz"

# Fail closed with a clear message when the proxy is missing, does not serve
# the pinned version, or serves bytes that do not match the pin. Prints status
# only, never a response body.
if ! run_clean PROXY="$PROXY" GOV_VERSION="$GOV_VERSION" GOV_INTEGRITY="$GOV_INTEGRITY" GOV_TGZ="$GOV_TGZ" node -e '
  const { createHash } = require("node:crypto");
  const { writeFileSync } = require("node:fs");
  const { PROXY, GOV_VERSION, GOV_INTEGRITY, GOV_TGZ } = process.env;
  const MAX = 64 * 1024 * 1024;
  const get = (u) => fetch(u, { signal: AbortSignal.timeout(20000), redirect: "error" });
  const die = (m) => { console.error(m); process.exit(1); };
  (async () => {
    const r = await get(PROXY + "@wave-av%2fgovernance");
    if (r.status !== 200) die("proxy answered HTTP " + r.status + " for the packument");
    const doc = await r.json();
    const ver = doc.versions && doc.versions[GOV_VERSION];
    if (!ver) die("proxy does not serve @wave-av/governance@" + GOV_VERSION);
    if (!ver.dist || ver.dist.integrity !== GOV_INTEGRITY) die("packument dist.integrity for " + GOV_VERSION + " does not match the pinned sha512");
    const t = await get(PROXY + "@wave-av/governance/-/governance-" + GOV_VERSION + ".tgz");
    if (t.status !== 200) die("proxy answered HTTP " + t.status + " for the tarball");
    const buf = Buffer.from(await t.arrayBuffer());
    if (buf.length === 0 || buf.length > MAX) die("tarball size out of bounds: " + buf.length);
    const got = "sha512-" + createHash("sha512").update(buf).digest("base64");
    if (got !== GOV_INTEGRITY) die("tarball sha512 does not match the pinned integrity");
    writeFileSync(GOV_TGZ, buf, { mode: 0o600 });
  })().catch((e) => die("proxy unreachable: " + (e.cause?.code || e.name)));
'; then
  echo "governance-enforce: the host registry proxy at $PROXY is missing, not serving @wave-av/governance@$GOV_VERSION, or serving bytes that do not match the pinned sha512 — failing closed."
  echo "This step never falls back to a token or another registry (WAVE-30138). Fix the host proxy, then rebuild."
  exit 2
fi

# Job-local npmrc: only the @wave-av scope mapping, no auth line (global and
# user config are pinned by CLEAN_ENV). A private package.json pins npm's
# local prefix (otherwise npm may walk up to / and fail). governance is
# installed from the verified local tarball, never re-fetched.
printf '@wave-av:registry=%s\n' "$PROXY" > "$GOVDIR/install/.npmrc"
printf '{"name":"governance-enforce-job","private":true}\n' > "$GOVDIR/install/package.json"
(
  cd "$GOVDIR/install"
  run_clean npm install "$GOV_TGZ" --prefix "$GOVDIR/install" \
    --ignore-scripts --no-save --no-audit --no-fund
)
GOVPKG="$GOVDIR/install/node_modules/@wave-av/governance"
INSTALLED="$(run_clean node -p "const p=require(process.argv[1]); p.name + '@' + p.version" "$GOVPKG/package.json")"
[ "$INSTALLED" = "@wave-av/governance@$GOV_VERSION" ] || { echo "governance package mismatch: installed $INSTALLED, want @wave-av/governance@$GOV_VERSION"; exit 2; }
run_clean node "$GOVPKG/bin/enforce.mjs" --changed "$BASE"
