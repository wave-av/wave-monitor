#!/usr/bin/env bats
# S1 (WAVE-26505): fork-refusal in guard-content-policy.sh.
# Negative: fork-shaped env exits 2 with the refusal message, before the
# script touches GUARD_PRIVATE_REPOS. Positive: same-repo / non-PR env
# proceeds past the fork check into the vendored scan.
#
# The positive control asserts "not refused + scan reached a verdict" rather
# than exit 0: in a linked git worktree the scan flags the worktree's own
# `.git` pointer file (environmental abs-user-path KIND hit — CI clones use
# a `.git` directory, which the scanner excludes). The unit under test here
# is the refusal block, not the vendored scanner's verdict on a given tree.
#
# Run: bats .buildkite/tests/guard-content-policy-fork.bats
# (no repo deps; needs bash + git checkout; rg optional — see below)
#
# PR mode (WAVE_JOB_GUARD_PR=1) is covered at the bottom: a pull-request
# number with no private-repo list skips only private-repo, and the output
# says that rule was NOT checked (never a plain clean pass); any other
# non-empty flag value exits 2; the flag
# together with any list variable exits 2; the flag on a non-pull-request
# build fails closed; a missing list with the flag unset still fails closed.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SCRIPT="$SCRIPT_DIR/../scripts/guard-content-policy.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  POLICY="$REPO_ROOT/scripts/public-repo-guard/content-policy.sh"
  PIPELINE_REPO="https://github.com/wave-av/wave-monitor"
  FORK_REPO="https://github.com/example-fork/wave-monitor"
  # Assembled from fragments so the full fixture token never occurs
  # literally in this tree — the private-repo rule must find zero matches.
  FIXTURE_REPOS="zz-fixture-$(printf '%s' 'no-such-repo-zz')"
  # Isolate PR-mode inputs from the caller. A token already present in this
  # tree (used only as a stand-in name, never printed). Sentinel is absent
  # from the tree and must never appear in output.
  unset WAVE_JOB_GUARD_PR
  unset BUILDKITE_PULL_REQUEST
  HITTING_NAME="WAVE-27030"
  LIST_SENTINEL="zz-sentinel-$(printf '%s' 'private-list-zz')"
}

@test "fork PR env refuses with exit 2 before touching secrets (injection unset)" {
  run env -u GUARD_PRIVATE_REPOS \
    "BUILDKITE_PULL_REQUEST_REPO=$FORK_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
  [[ "$output" != *"GUARD_PRIVATE_REPOS"* ]]
}

@test "fork PR env refuses with exit 2 when injection is set" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$FORK_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
}

@test "same-repo PR env proceeds past the fork check (positive control)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  else
    [ "$status" -eq 2 ]
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}

@test "non-PR env (vars unset) proceeds past the fork check" {
  run env -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  else
    [ "$status" -eq 2 ]
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}

# T1 (WAVE-27030): six-chunk host injection (512B MAX_SECRET per value).
@test "chunks assemble when full var is unset (durable host path)" {
  run env -u GUARD_PRIVATE_REPOS -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "GUARD_PRIVATE_REPOS_01=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_02=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_03=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_04=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_05=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_06=$FIXTURE_REPOS" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  [[ "$output" != *"failing closed"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  fi
}

@test "missing chunk fails closed with exit 2 (never narrows the rule)" {
  run env -u GUARD_PRIVATE_REPOS -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "GUARD_PRIVATE_REPOS_01=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_02=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_03=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_04=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_05=$FIXTURE_REPOS" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing GUARD_PRIVATE_REPOS_06"* ]]
  [[ "$output" != *"public-repo-guard:"* ]]
}

@test "no injection at all fails closed with exit 2" {
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing GUARD_PRIVATE_REPOS_01"* ]]
}

# Review findings (S3): URL normalization + degenerate values fail closed.
@test "same-repo PR with SSH pipeline URL proceeds (URL normalization)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=git@github.com:wave-av/wave-monitor.git" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  else
    [ "$status" -eq 2 ]
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}

@test "PR repo set but pipeline repo empty refuses (fail closed)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$FORK_REPO" \
    "BUILDKITE_REPO=" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
}

@test "whitespace-only GUARD_PRIVATE_REPOS fails closed (never silently disables)" {
  run env -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "GUARD_PRIVATE_REPOS= , ," \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"zero repo names"* ]]
  else
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}

# Review round 2: degenerate values + URL normalization, continued.
# NOTE: set-but-empty / tab-only reach the vendored policy directly (the BK
# wrapper diverts empty full-values to chunk assembly first), so these two
# invoke content-policy.sh itself on an empty dir, GHA-path style.
@test "set-but-empty GUARD_PRIVATE_REPOS fails closed (unset still skips)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  run env "GUARD_PRIVATE_REPOS=" bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"zero repo names"* ]]
}

@test "tab-only GUARD_PRIVATE_REPOS fails closed (whitespace token, not a name)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  run env "$(printf 'GUARD_PRIVATE_REPOS=\t')" bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"zero repo names"* ]]
}

@test "malformed PR URL normalizing to empty refuses (fail closed)" {
  # PR value "/" normalizes to empty, so the refusal exercises the
  # empty-head branch (not the empty-pipeline branch).
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=/" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
}

@test "cross-host same-path PR refuses (host is part of identity)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=https://evil.example/wave-av/wave-monitor" \
    "BUILDKITE_REPO=https://github.com/wave-av/wave-monitor" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
}

@test "same-repo PR with ssh:// pipeline URL proceeds (normalization)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=ssh://git@github.com/wave-av/wave-monitor.git" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
  if command -v rg >/dev/null 2>&1; then
    [[ "$output" == *"public-repo-guard:"* ]]
  else
    [ "$status" -eq 2 ]
    [[ "$output" == *"ripgrep (rg) is required"* ]]
  fi
}

# Review round 3 (wave-1): fail-closed completeness.
@test "explicitly empty full value fails closed even when chunks exist" {
  run env -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO "GUARD_PRIVATE_REPOS=" \
    "GUARD_PRIVATE_REPOS_01=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_02=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_03=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_04=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_05=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_06=$FIXTURE_REPOS" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"explicitly empty"* ]]
}

@test "whitespace-only chunk counts as missing (fails closed)" {
  run env -u GUARD_PRIVATE_REPOS -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    "GUARD_PRIVATE_REPOS_01=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_02=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_03=   " \
    "GUARD_PRIVATE_REPOS_04=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_05=$FIXTURE_REPOS" \
    "GUARD_PRIVATE_REPOS_06=$FIXTURE_REPOS" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing GUARD_PRIVATE_REPOS_03"* ]]
}

@test "degenerate token with no alphanumerics fails closed" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  run env "GUARD_PRIVATE_REPOS=[]" bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"degenerate token"* ]]
}

@test "equally malformed PR/pipeline URLs refuse (no identity, no bypass)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=https://github.com/" \
    "BUILDKITE_REPO=https://github.com/" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
}

@test "fork refusal redacts userinfo (logs normalized forms only)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=https://user:s3cret@github.com/fork/repo" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
  [[ "$output" != *"s3cret"* ]]
  [[ "$output" == *"github.com/fork/repo"* ]]
}

@test "multi-line value tokenizes every line (no silent drop)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  # "[]" on line 2 must still be seen (degenerate-token exit 2); a
  # first-line-only read would miss it and exit 0 on the empty dir.
  run env "$(printf 'GUARD_PRIVATE_REPOS=goodname\n[]')" bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"degenerate token"* ]]
}

@test "same-repo PR with git:// pipeline URL proceeds (normalization)" {
  run env "GUARD_PRIVATE_REPOS=$FIXTURE_REPOS" \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=git://github.com/wave-av/wave-monitor.git" \
    "$SCRIPT"
  [[ "$output" != *"refusing to run"* ]]
}

# PR mode. The hitting name is a token already in this tree, so a run that
# still applies private-repo exits 1. The sentinel is not in the tree and
# must never be printed.
# The wrapper cds to its own repo root, so PR-mode positive tests run a copy
# of the wrapper and policy inside a clean temp tree. A full-repo scan is
# environment-dependent (a linked worktree's .git pointer file trips
# abs-user-path), so no PR-mode test asserts exit 0 on this checkout.
_clean_tree() {
  TDIR="$(mktemp -d)"
  mkdir -p "$TDIR/.buildkite/scripts" "$TDIR/scripts/public-repo-guard"
  cp "$SCRIPT" "$TDIR/.buildkite/scripts/guard-content-policy.sh"
  cp "$POLICY" "$TDIR/scripts/public-repo-guard/content-policy.sh"
  printf 'clean\n' > "$TDIR/ok.txt"
}

@test "PR mode on a pull request passes without GUARD_PRIVATE_REPOS" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _clean_tree
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    bash "$TDIR/.buildkite/scripts/guard-content-policy.sh"
  rm -rf "$TDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"guard-content-policy: private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" == *"public-repo-guard: private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" == *"public-repo-guard: content policy OK"* ]]
  [[ "$output" != *"failing closed"* ]]
  [[ "$output" != *"(private-repo)"* ]]
  # Not a clean pass: the verdict line itself says private names were not checked.
  [[ "${lines[${#lines[@]}-1]}" == *"private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "${lines[${#lines[@]}-1]}" != "public-repo-guard: content policy OK" ]]
}

@test "PR mode still fails a violation in the PR tree" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _clean_tree
  # Built from fragments so this file never carries the literal path.
  printf '/%s/%s/x\n' home fixtureuser > "$TDIR/leak.txt"
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    bash "$TDIR/.buildkite/scripts/guard-content-policy.sh"
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
  [[ "$output" != *"content policy OK"* ]]
}

@test "WAVE_JOB_GUARD_PR values other than 1 fail closed in the wrapper" {
  local val
  for val in 0 true yes 01 " 1" "1 " false; do
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
      "WAVE_JOB_GUARD_PR=$val" \
      BUILDKITE_PULL_REQUEST=206 \
      "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be unset, empty, or 1"* ]]
    [[ "$output" != *"NOT checked"* ]]
    [[ "$output" != *"content policy OK"* ]]
  done
}

@test "content-policy rejects WAVE_JOB_GUARD_PR values other than 1" {
  local val
  for val in 0 true yes 01 " 1" "1 " false; do
    TDIR="$(mktemp -d)"
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 \
      "WAVE_JOB_GUARD_PR=$val" \
      BUILDKITE_PULL_REQUEST=false \
      bash "$POLICY" "$TDIR"
    rm -rf "$TDIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"must be unset, empty, or 1"* ]]
    [[ "$output" != *"NOT checked"* ]]
    [[ "$output" != *"content policy OK"* ]]
  done
}

@test "content-policy treats an empty WAVE_JOB_GUARD_PR as unset" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  run env -u GUARD_PRIVATE_REPOS WAVE_JOB_GUARD_PR= BUILDKITE_PULL_REQUEST=false \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 0 ]
  [[ "${lines[${#lines[@]}-1]}" == "public-repo-guard: content policy OK" ]]
  [[ "$output" != *"NOT checked"* ]]
}

@test "PR mode with the private-repo list fails closed and does not print it" {
  run env \
    -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 \
    -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "GUARD_PRIVATE_REPOS=$HITTING_NAME" \
    "GUARD_PRIVATE_REPOS_01=$LIST_SENTINEL" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"private-repo list"* ]]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" == *"failing closed"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"(private-repo)"* ]]
  [[ "$output" != *"$HITTING_NAME"* ]]
  [[ "$output" != *"$LIST_SENTINEL"* ]]
}

@test "PR mode with only a list chunk fails closed and does not print it" {
  run env -u GUARD_PRIVATE_REPOS \
    -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_04 \
    -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "GUARD_PRIVATE_REPOS_03=$LIST_SENTINEL" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"$LIST_SENTINEL"* ]]
}

@test "PR mode with an empty or whitespace private-repo list fails closed" {
  local val
  for val in "" " " $'\t' " , ,"; do
    run env -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 \
      -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
      WAVE_JOB_GUARD_PR=1 \
      BUILDKITE_PULL_REQUEST=206 \
      "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
      "BUILDKITE_REPO=$PIPELINE_REPO" \
      "GUARD_PRIVATE_REPOS=$val" \
      "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"spoofed"* ]]
    [[ "$output" != *"explicitly empty"* ]]
    [[ "$output" != *"private-repo rule NOT checked"* ]]
    [[ "$output" != *"content policy OK"* ]]
  done
}

@test "WAVE_JOB_GUARD_PR on a main build with the list fails closed as spoofed" {
  run env -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_03 \
    -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=false \
    "GUARD_PRIVATE_REPOS=$HITTING_NAME" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" == *"failing closed"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"not a pull-request number"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"(private-repo)"* ]]
  [[ "$output" != *"$HITTING_NAME"* ]]
}

@test "WAVE_JOB_GUARD_PR with BUILDKITE_PULL_REQUEST=false and no list fails closed" {
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=false \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a pull-request number"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"spoofed"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
}

@test "WAVE_JOB_GUARD_PR with empty BUILDKITE_PULL_REQUEST fails closed" {
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST= \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a pull-request number"* ]]
  [[ "$output" != *"missing GUARD_PRIVATE_REPOS"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
}

@test "WAVE_JOB_GUARD_PR rejects zero and non-numeric pull-request values" {
  local pr
  for pr in 0 01 main true " 5" "5 "; do
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
      WAVE_JOB_GUARD_PR=1 \
      "BUILDKITE_PULL_REQUEST=$pr" \
      "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a pull-request number"* ]]
    [[ "$output" != *"spoofed"* ]]
    [[ "$output" != *"private-repo rule NOT checked"* ]]
  done
}

@test "pull-request number check rejects non-ASCII digits" {
  local pr
  for pr in "$(printf '\uFF11')" "$(printf '\u0661')"; do
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
      LC_ALL=en_US.utf8 \
      WAVE_JOB_GUARD_PR=1 \
      "BUILDKITE_PULL_REQUEST=$pr" \
      "$SCRIPT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a pull-request number"* ]]
    [[ "$output" != *"private-repo rule NOT checked"* ]]
    [[ "$output" != *"content policy OK"* ]]
  done
}

@test "no PR-mode flag and no private-repo list fails closed" {
  run env -u WAVE_JOB_GUARD_PR -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 \
    -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 \
    -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    BUILDKITE_PULL_REQUEST=false \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"missing GUARD_PRIVATE_REPOS_01"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"not a pull-request number"* ]]
}

@test "default-branch build with the list runs every rule including private-repo" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  run env -u WAVE_JOB_GUARD_PR -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_03 \
    -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    BUILDKITE_PULL_REQUEST=false \
    "GUARD_PRIVATE_REPOS=$HITTING_NAME" \
    "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"(private-repo)"* ]]
  [[ "$output" == *"blocking content-policy violation"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"$HITTING_NAME"* ]]
}

@test "PR mode does not bypass fork refusal" {
  run env -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_03 \
    -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    "GUARD_PRIVATE_REPOS=$HITTING_NAME" \
    "BUILDKITE_PULL_REQUEST_REPO=$FORK_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to run"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"$HITTING_NAME"* ]]
}

@test "content-policy PR mode passes without the list" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"public-repo-guard: private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" == *"content policy OK"* ]]
  [[ "$output" != *"guard-content-policy:"* ]]
  [[ "${lines[${#lines[@]}-1]}" == *"private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" != *"(private-repo)"* ]]
}

@test "content-policy PR mode with the list fails closed and does not print it" {
  TDIR="$(mktemp -d)"
  printf '%s\n' "$HITTING_NAME" > "$TDIR/note.txt"
  run env -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_03 \
    -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=83 \
    "GUARD_PRIVATE_REPOS=$HITTING_NAME" \
    "GUARD_PRIVATE_REPOS_01=$LIST_SENTINEL" \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error title=public-repo-guard (pr-mode)::"* ]]
  [[ "$output" == *"private-repo list"* ]]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"(private-repo)"* ]]
  [[ "$output" != *"guard-content-policy:"* ]]
  [[ "$output" != *"$HITTING_NAME"* ]]
  [[ "$output" != *"$LIST_SENTINEL"* ]]
}

@test "content-policy PR mode with only a list chunk fails closed" {
  TDIR="$(mktemp -d)"
  run env -u GUARD_PRIVATE_REPOS \
    -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 -u GUARD_PRIVATE_REPOS_04 \
    -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=83 \
    "GUARD_PRIVATE_REPOS_03=$LIST_SENTINEL" \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"$LIST_SENTINEL"* ]]
}

@test "content-policy PR mode with an empty list variable fails closed" {
  TDIR="$(mktemp -d)"
  run env -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 \
    -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=83 \
    GUARD_PRIVATE_REPOS= \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" != *"zero repo names"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
}

@test "content-policy flag on a main build with the list fails closed as spoofed" {
  TDIR="$(mktemp -d)"
  printf '%s\n' "$HITTING_NAME" > "$TDIR/note.txt"
  run env -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 \
    -u GUARD_PRIVATE_REPOS_05 -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=false \
    "GUARD_PRIVATE_REPOS=$HITTING_NAME" \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"spoofed"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"not a pull-request number"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"(private-repo)"* ]]
  [[ "$output" != *"$HITTING_NAME"* ]]
}

@test "content-policy flag with BUILDKITE_PULL_REQUEST=false and no list fails closed" {
  TDIR="$(mktemp -d)"
  printf '%s\n' "$HITTING_NAME" > "$TDIR/note.txt"
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=false \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a pull-request number"* ]]
  [[ "$output" == *"must not be skipped"* ]]
  [[ "$output" != *"spoofed"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"(private-repo)"* ]]
}

@test "content-policy pull-request number check rejects non-ASCII digits" {
  local pr
  for pr in "$(printf '\uFF11')" "$(printf '\u0661')"; do
    TDIR="$(mktemp -d)"
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 \
      LC_ALL=en_US.utf8 \
      WAVE_JOB_GUARD_PR=1 \
      "BUILDKITE_PULL_REQUEST=$pr" \
      bash "$POLICY" "$TDIR"
    rm -rf "$TDIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not a pull-request number"* ]]
    [[ "$output" != *"private-repo rule NOT checked"* ]]
    [[ "$output" != *"content policy OK"* ]]
  done
}

@test "content-policy flag with empty BUILDKITE_PULL_REQUEST fails closed" {
  TDIR="$(mktemp -d)"
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST= \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a pull-request number"* ]]
  [[ "$output" != *"content policy OK"* ]]
  [[ "$output" != *"private-repo rule NOT checked"* ]]
}

@test "content-policy without the flag still skips an unset list" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  run env -u WAVE_JOB_GUARD_PR -u GUARD_PRIVATE_REPOS \
    BUILDKITE_PULL_REQUEST=false \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"content policy OK"* ]]
  [[ "$output" != *"private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" != *"failing closed"* ]]
}
