#!/usr/bin/env bats
# WAVE-28333 M1: .buildkite/upload.sh pipeline selection.
# - A pull request is compared with BUILDKITE_PIPELINE_DEFAULT_BRANCH, never
#   BUILDKITE_PULL_REQUEST_BASE_BRANCH (the author picks the base).
# - A missing or invalid default branch fails closed (exit 2).
# - The selected pipeline must carry its content-policy step, or nothing is
#   uploaded (exit 2).
# - The checked-in PR pipeline runs guard-content-policy-pr on fpc-isolated
#   with WAVE_JOB_GUARD_PR=1 and no secrets queue.
# buildkite-agent is a stub on PATH that records what would be uploaded.
#
# Run: bats .buildkite/tests/upload-pr-pipeline.bats (needs bash + git)

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
  TDIR="$(mktemp -d)"
  ORIGIN="$TDIR/origin"
  PRDIR="$TDIR/pr"
  mkdir -p "$TDIR/bin"
  cat > "$TDIR/bin/buildkite-agent" <<'STUB'
#!/bin/sh
echo "UPLOAD $*"
STUB
  chmod +x "$TDIR/bin/buildkite-agent"
  git init -q "$ORIGIN"
  git -C "$ORIGIN" checkout -q -b main
  mkdir -p "$ORIGIN/.buildkite"
  cp "$REPO_ROOT/.buildkite/upload.sh" "$REPO_ROOT/.buildkite/pipeline.yml" \
    "$REPO_ROOT/.buildkite/pipeline-pr-self-check.yml" "$ORIGIN/.buildkite/"
  printf 'x\n' > "$ORIGIN/app.txt"
  _commit "$ORIGIN" base
  git clone -q "$ORIGIN" "$PRDIR"
  git -C "$PRDIR" checkout -q -b pr
}

teardown() {
  rm -rf "$TDIR"
}

_commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm "$2"
}

_upload() {
  run env "PATH=$TDIR/bin:$PATH" \
    "BUILDKITE_PULL_REQUEST=${PR-206}" \
    "BUILDKITE_PIPELINE_DEFAULT_BRANCH=${DEFAULT_BRANCH-main}" \
    "BUILDKITE_PULL_REQUEST_BASE_BRANCH=${BASE_BRANCH:-main}" \
    sh -c 'cd "$1" && sh .buildkite/upload.sh' _ "$PRDIR"
}

@test "non-PR build uploads pipeline.yml" {
  PR=false _upload
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPLOAD pipeline upload .buildkite/pipeline.yml"* ]]
}

@test "PR without .buildkite changes uploads pipeline.yml" {
  printf 'y\n' > "$PRDIR/app.txt"
  _commit "$PRDIR" app
  _upload
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPLOAD pipeline upload .buildkite/pipeline.yml"* ]]
}

@test "PR that changes .buildkite uploads the self-check with the PR content step" {
  printf '# touch\n' >> "$PRDIR/.buildkite/pipeline.yml"
  _commit "$PRDIR" touch
  _upload
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPLOAD pipeline upload .buildkite/pipeline-pr-self-check.yml"* ]]
}

@test "selection compares with the default branch, not the PR base branch" {
  # The author-chosen base already carries the PR's .buildkite change, so a
  # base-branch diff would see no change and upload pipeline.yml.
  printf '# touch\n' >> "$PRDIR/.buildkite/pipeline.yml"
  _commit "$PRDIR" touch
  git -C "$PRDIR" push -q origin pr:author-base
  BASE_BRANCH=author-base _upload
  [ "$status" -eq 0 ]
  [[ "$output" == *"UPLOAD pipeline upload .buildkite/pipeline-pr-self-check.yml"* ]]
}

@test "PR build without a usable default branch fails closed" {
  local name
  for name in "" "bad..name"; do
    DEFAULT_BRANCH="$name" _upload
    [ "$status" -eq 2 ]
    [[ "$output" != *"UPLOAD"* ]]
  done
  DEFAULT_BRANCH=no-such-branch _upload
  [ "$status" -ne 0 ]
  [[ "$output" != *"UPLOAD"* ]]
}

@test "a self-check without guard-content-policy-pr is never uploaded" {
  sed -i.bak 's/key: guard-content-policy-pr/key: something-else/' \
    "$PRDIR/.buildkite/pipeline-pr-self-check.yml"
  rm -f "$PRDIR/.buildkite/pipeline-pr-self-check.yml.bak"
  _commit "$PRDIR" drop
  _upload
  [ "$status" -eq 2 ]
  [[ "$output" == *"no 'guard-content-policy-pr' step"* ]]
  [[ "$output" != *"UPLOAD"* ]]
}

@test "a pipeline.yml without wm-content-policy is never uploaded" {
  sed -i.bak 's/key: wm-content-policy$/key: something-else/' \
    "$PRDIR/.buildkite/pipeline.yml"
  rm -f "$PRDIR/.buildkite/pipeline.yml.bak"
  PR=false _upload
  [ "$status" -eq 2 ]
  [[ "$output" != *"UPLOAD"* ]]
}

@test "checked-in self-check runs the PR content step secret-free" {
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    skip "python3 + pyyaml not installed"
  fi
  run python3 - "$REPO_ROOT/.buildkite/pipeline-pr-self-check.yml" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["steps"]
by_key = {s.get("key"): s for s in steps if isinstance(s, dict)}
s = by_key["guard-content-policy-pr"]
assert s["command"] == ".buildkite/scripts/guard-content-policy.sh", s
assert s["env"] == {"WAVE_JOB_GUARD_PR": "1"}, s
for k in ("soft_fail", "allow_failure", "if", "branches", "skip"):
    assert k not in s, k
for st in steps:
    assert st["agents"]["queue"] == "fpc-isolated", st  # guard:allow BK pipeline keyword, not a repo reference
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
