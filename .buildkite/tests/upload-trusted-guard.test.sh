#!/usr/bin/env bash
# WAVE-32956 proof: on an untrusted build, a PR-side edit cannot change the gitleaks verdict.
# Builds a throwaway origin (main = this checkout's .buildkite) and a PR clone, then runs
# .buildkite/upload.sh with a stub buildkite-agent that records what would be uploaded.
#   T1 PR adds a secret                                   -> refused, nothing uploaded
#   T2 PR adds a secret AND neuters the guard script, allowlists everything in .gitleaks.toml,
#      drops the guard step from pipeline.yml, and the job env sets GITLEAKS_BIN=/bin/true
#                                                         -> still refused, nothing uploaded
#   T3 same tampering, no secret                          -> uploads
#   T4 same-repo branch build (no PR) with T2's tampering -> refused
#   T5 default-branch build                               -> uploads, no guard run in the upload step
# NO_BASE_CONFIG=1 builds the origin without .gitleaks.toml (the default-rules path).
# UPLOAD_SH=<path> runs another uploader (the mutation check runs the old one: T2 must then fail).
# Needs bash, git, curl, sha256sum (the guard downloads its pinned gitleaks, as in CI).
# Run: bash .buildkite/tests/upload-trusted-guard.test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
upload="${UPLOAD_SH:-$here/.buildkite/upload.sh}"
t="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$t"' EXIT; echo "tmp=$t"
mkdir -p "$t/bin"
printf '#!/bin/sh\necho "UPLOAD $*" >> "%s/uploads"\n' "$t" > "$t/bin/buildkite-agent"; chmod +x "$t/bin/buildkite-agent"
git init -q -b main "$t/origin"
cp -R "$here/.buildkite" "$t/origin/.buildkite"
if [ "${NO_BASE_CONFIG:-}" != 1 ] && [ -f "$here/.gitleaks.toml" ]; then cp "$here/.gitleaks.toml" "$t/origin/"; fi
echo "# fixture" > "$t/origin/README.md"
git -C "$t/origin" add -A && git -C "$t/origin" -c user.name=t -c user.email=t@t commit -qm base
# A GitHub-PAT-shaped string built at run time, so no secret literal lives in this file.
secret="ghp_$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 36)"
fail=0
run_case() { # name expect(upload|refuse) branch pr setup-fn
  local name="$1" expect="$2" branch="$3" pr="$4" setup="$5" d="$t/w-$1" rc=0
  git clone -q "$t/origin" "$d"; git -C "$d" checkout -q -b "$branch" 2>/dev/null || git -C "$d" checkout -q "$branch"
  (cd "$d" && "$setup")
  git -C "$d" add -A && git -C "$d" -c user.name=t -c user.email=t@t commit -qm change --allow-empty
  rm -f "$t/uploads"
  (cd "$d" && env -u BUILDKITE -u BUILDKITE_JOB_ID PATH="$t/bin:$PATH" GITLEAKS_BIN=/bin/true \
     BUILDKITE_PULL_REQUEST="$pr" BUILDKITE_BRANCH="$branch" BUILDKITE_PIPELINE_DEFAULT_BRANCH=main \
     BUILDKITE_PULL_REQUEST_BASE_BRANCH=attacker-base sh "$upload" >"$t/out-$name" 2>&1) || rc=$?
  local got=refuse; [ -s "$t/uploads" ] && got=upload
  if [ "$got" = "$expect" ]; then echo "ok   $name ($got, rc=$rc)"; else echo "FAIL $name: want $expect got $got (rc=$rc)"; sed 's/^/     /' "$t/out-$name" | tail -8; fail=1; fi
}
add_secret() { printf 'export const token = "%s";\n' "$secret" > leak.ts; }
tamper() {
  printf '#!/usr/bin/env bash\nexit 0\n' > .buildkite/scripts/guard-gitleaks.sh
  printf '[allowlist]\npaths = [".*"]\n' > .gitleaks.toml
  awk 'BEGIN{skip=0} /^  - label: ":key: guard gitleaks"/{skip=1; next} skip && /^  - /{skip=0} !skip' \
    .buildkite/pipeline.yml > .buildkite/pipeline.yml.new && mv .buildkite/pipeline.yml.new .buildkite/pipeline.yml
  ! grep -qE '^[[:space:]]+key:[[:space:]]+guard-gitleaks[[:space:]]*$' .buildkite/pipeline.yml || { echo 'fixture: guard step still present' >&2; exit 3; }
}
none() { :; }
leak_and_tamper() { add_secret; tamper; }
run_case t1-secret refuse feat/x 101 add_secret
run_case t2-secret-tampered refuse feat/x 102 leak_and_tamper
run_case t3-clean-tampered upload feat/x 103 tamper
run_case t4-branch-build-tampered refuse feat/y false leak_and_tamper
run_case t5-default-branch upload main false none
if [ "$fail" = 0 ]; then echo "PASS: a PR-side edit does not change the gitleaks verdict"; else echo "FAILED"; exit 1; fi
