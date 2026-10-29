#!/usr/bin/env bash
# provenance-emit — WAVE-26520 O1 wiring v1: emit the per-run provenance.json
# (SLSA-style, feeds WAVE-26504 Q4 attestation) and upload it as a BK artifact.
#
# QUEUE: fpc-isolated. This step receives NO secrets. Secret NAMES below
# (GUARD_PRIVATE_REPOS, GH_PACKAGES_READ_TOKEN) are name-only claims about
# what the host injected into OTHER steps on a default-branch build — never
# values. The vendored emitter enforces UPPER_SNAKE names and fails closed on
# anything value-shaped.
#
# PLACEMENT: final step behind its own `wait` barrier, so it runs only after
# every prior step passed. V1 emits green-build provenances only: a failed
# guard blocks this step by barrier semantics, so failure shapes cannot emit
# here (they stay covered by the O1 fixtures until a v2 API-driven emitter).
#
# HONESTY NOTES (v1, all reversible):
# - The manifest lists exactly the gated steps that ran in this build's shape
#   (WAVE-30137), each with exit 0: this step runs only when all of them
#   passed, and a skipped step must not be claimed as exited.
#   * pull request (BUILDKITE_PULL_REQUEST is a PR number): the secret-free
#     guard-content-policy-pr on fpc-isolated; no governance-enforce; nothing
#     injected.
#   * default branch (not a PR, BUILDKITE_BRANCH equals
#     BUILDKITE_PIPELINE_DEFAULT_BRANCH): guard-content-policy and
#     governance-enforce on fpc-isolated-secrets with their injected names.
#   * any other branch push: no content-policy guard, no governance-enforce,
#     nothing injected.
#   Anything else (a non-numeric PR value, or an empty branch or default
#   branch on a non-PR build) fails closed. Report-mode probes soft-fail and
#   are not claimed. pipeline-gating.py check 9 keeps these manifests equal
#   to the pipeline.
# - Self (provenance-emit) is listed exit 0: any DELIVERED artifact implies
#   the emitter + upload both succeeded, so the step exited 0. Local-only
#   files from failed runs never leave the ephemeral agent.
# - base_rev is BUILDKITE_COMMIT (the built rev). The true fork-point base is
#   resolvable from pr.{base_repo,base_ref,number} in the artifact; resolving
#   it at emit time (fetch + merge-base) is deferred to v2 to keep this step
#   free of new network failure modes.
# - Upload uses a relative path from the repo root (documented
#   buildkite-agent behavior); the emitter itself runs with --no-upload.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROV=".buildkite/provenance"
OUT="provenance.json"

command -v node >/dev/null 2>&1 || {
  echo "provenance-emit: node is required but missing — failing closed."
  exit 2
}
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "provenance-emit: node >= 18 required, found $(node --version) — failing closed."
  exit 2
fi
[ -f "$PROV/bin/emit-provenance.mjs" ] || {
  echo "provenance-emit: vendored emitter missing at $PROV — failing closed."
  exit 2
}

PR_RAW="${BUILDKITE_PULL_REQUEST:-}"
if [ -n "$PR_RAW" ] && [ "$PR_RAW" != "false" ]; then
  [[ "$PR_RAW" =~ ^[1-9][0-9]*$ ]] || {
    echo "provenance-emit: BUILDKITE_PULL_REQUEST is neither a PR number nor false — failing closed."
    exit 2
  }
  SHAPE="pr"
else
  if [ -z "${BUILDKITE_BRANCH:-}" ] || [ -z "${BUILDKITE_PIPELINE_DEFAULT_BRANCH:-}" ]; then
    echo "provenance-emit: BUILDKITE_BRANCH and BUILDKITE_PIPELINE_DEFAULT_BRANCH are required on a non-PR build — failing closed."
    exit 2
  fi
  if [ "$BUILDKITE_BRANCH" = "$BUILDKITE_PIPELINE_DEFAULT_BRANCH" ]; then
    SHAPE="main"
  else
    SHAPE="branch"
  fi
fi

TMP="$(mktemp -d)"
STEPS="$TMP/steps.json"
GUARDS="$TMP/guards.json"
trap 'rm -rf "$TMP"' EXIT

# One manifest per shape. pipeline-gating.py check 9 parses the
# INJECTED_<SHAPE> lines and the <<'<SHAPE>_STEPS' / <<'<SHAPE>_GUARDS'
# heredocs below and compares them with pipeline.yml; keep the layout.
INJECTED_PR=""
INJECTED_MAIN="guard-content-policy:GUARD_PRIVATE_REPOS,governance-enforce:GH_PACKAGES_READ_TOKEN"
INJECTED_BRANCH=""

case "$SHAPE" in
  pr)
    INJECTED="$INJECTED_PR"
    cat >"$STEPS" <<'PR_STEPS'
[
  {"key": "guard-gitleaks", "queue": "fpc-isolated", "command": ".buildkite/scripts/guard-gitleaks.sh", "exit": 0},
  {"key": "guard-content-policy-pr", "queue": "fpc-isolated", "command": ".buildkite/scripts/guard-content-policy.sh", "exit": 0},
  {"key": "node-gates", "queue": "fpc-isolated", "command": ".buildkite/scripts/ci.sh", "exit": 0},
  {"key": "foundation-secret-scan", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-secret-scan.sh", "exit": 0},
  {"key": "foundation-file-size", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-file-size.sh", "exit": 0},
  {"key": "foundation-skill-validate", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-skill-validate.sh", "exit": 0},
  {"key": "foundation-verify-routes", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-verify-routes.sh", "exit": 0},
  {"key": "provenance-emit", "queue": "fpc-isolated", "command": ".buildkite/scripts/provenance-emit.sh", "exit": 0}
]
PR_STEPS
    cat >"$GUARDS" <<'PR_GUARDS'
[
  {"key": "guard-gitleaks", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"},
  {"key": "guard-content-policy-pr", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"}
]
PR_GUARDS
    ;;
  main)
    INJECTED="$INJECTED_MAIN"
    cat >"$STEPS" <<'MAIN_STEPS'
[
  {"key": "guard-gitleaks", "queue": "fpc-isolated", "command": ".buildkite/scripts/guard-gitleaks.sh", "exit": 0},
  {"key": "guard-content-policy", "queue": "fpc-isolated-secrets", "command": ".buildkite/scripts/guard-content-policy.sh", "exit": 0},
  {"key": "node-gates", "queue": "fpc-isolated", "command": ".buildkite/scripts/ci.sh", "exit": 0},
  {"key": "foundation-secret-scan", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-secret-scan.sh", "exit": 0},
  {"key": "foundation-file-size", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-file-size.sh", "exit": 0},
  {"key": "foundation-skill-validate", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-skill-validate.sh", "exit": 0},
  {"key": "foundation-verify-routes", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-verify-routes.sh", "exit": 0},
  {"key": "governance-enforce", "queue": "fpc-isolated-secrets", "command": ".buildkite/scripts/governance-enforce.sh", "exit": 0},
  {"key": "provenance-emit", "queue": "fpc-isolated", "command": ".buildkite/scripts/provenance-emit.sh", "exit": 0}
]
MAIN_STEPS
    cat >"$GUARDS" <<'MAIN_GUARDS'
[
  {"key": "guard-gitleaks", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"},
  {"key": "guard-content-policy", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"}
]
MAIN_GUARDS
    ;;
  branch)
    INJECTED="$INJECTED_BRANCH"
    cat >"$STEPS" <<'BRANCH_STEPS'
[
  {"key": "guard-gitleaks", "queue": "fpc-isolated", "command": ".buildkite/scripts/guard-gitleaks.sh", "exit": 0},
  {"key": "node-gates", "queue": "fpc-isolated", "command": ".buildkite/scripts/ci.sh", "exit": 0},
  {"key": "foundation-secret-scan", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-secret-scan.sh", "exit": 0},
  {"key": "foundation-file-size", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-file-size.sh", "exit": 0},
  {"key": "foundation-skill-validate", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-skill-validate.sh", "exit": 0},
  {"key": "foundation-verify-routes", "queue": "fpc-isolated", "command": ".buildkite/scripts/foundation-verify-routes.sh", "exit": 0},
  {"key": "provenance-emit", "queue": "fpc-isolated", "command": ".buildkite/scripts/provenance-emit.sh", "exit": 0}
]
BRANCH_STEPS
    cat >"$GUARDS" <<'BRANCH_GUARDS'
[
  {"key": "guard-gitleaks", "verdict": "pass", "detail": "exit 0 (build proceeded past wait barrier)"}
]
BRANCH_GUARDS
    ;;
esac

# Nothing injected: pass no --injected at all and clear the env fallback, so
# the emitter records an empty injected list.
INJECTED_ARGS=()
if [ -n "$INJECTED" ]; then
  INJECTED_ARGS=(--injected "$INJECTED")
fi
unset PROVENANCE_INJECTED

: "${BUILDKITE_COMMIT:?provenance-emit: BUILDKITE_COMMIT is required}"
node "$PROV/bin/emit-provenance.mjs" \
  --repo-dir . \
  --steps "$STEPS" \
  --guards "$GUARDS" \
  --base-rev "$BUILDKITE_COMMIT" \
  --out "$OUT" \
  "${INJECTED_ARGS[@]}" \
  --no-upload

if [ "${BUILDKITE:-}" = "true" ]; then
  command -v buildkite-agent >/dev/null 2>&1 || {
    echo "provenance-emit: on BK but buildkite-agent missing — failing closed."
    exit 2
  }
  buildkite-agent artifact upload "$OUT"
else
  echo "provenance-emit: not on BK (BUILDKITE!=true) — upload skipped, artifact at $OUT"
fi
