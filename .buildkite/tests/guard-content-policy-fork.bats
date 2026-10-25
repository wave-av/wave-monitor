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
# WAVE-28333 M1: PR mode runs the default branch's policy and .guardignore
# (never the PR's, never the PR base branch's), ignores inline markers,
# re-execs the default branch's wrapper once it carries the marker, and
# fails closed when the default branch or its policy is missing.

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
# PR mode runs the DEFAULT BRANCH's policy (WAVE-28333 M1), so positive
# tests build a throwaway origin repo whose main branch holds the trusted
# policy, clone it as the pull-request checkout, and run the PR copy of
# the wrapper there. The scan is of a copy of that checkout without .git,
# so a linked worktree's .git pointer file cannot trip abs-user-path.
#
# _pr_fixture [trusted]: "trusted" also puts a wrapper carrying the
# trusted-runner marker on main (post-bootstrap); without it main has only
# the policy (bootstrap, as for the PR that introduces the marker).
_pr_fixture() {
  TDIR="$(mktemp -d)"
  ORIGIN="$TDIR/origin"
  PRDIR="$TDIR/pr"
  git init -q "$ORIGIN"
  git -C "$ORIGIN" checkout -q -b main
  mkdir -p "$ORIGIN/scripts/public-repo-guard" "$ORIGIN/.buildkite/scripts"
  cp "$POLICY" "$ORIGIN/scripts/public-repo-guard/content-policy.sh"
  if [ "${1:-}" = "trusted" ]; then
    # Tag the default-branch copy so a test can see which copy scanned.
    sed 's/^  _guard_stage=2$/  _guard_stage=2; echo "MAIN-COPY-WRAPPER"/' "$SCRIPT" \
      > "$ORIGIN/.buildkite/scripts/guard-content-policy.sh"
  fi
  printf 'clean\n' > "$ORIGIN/ok.txt"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm base
  git clone -q "$ORIGIN" "$PRDIR"
  git -C "$PRDIR" checkout -q -b pr
  mkdir -p "$PRDIR/.buildkite/scripts"
  cp "$SCRIPT" "$PRDIR/.buildkite/scripts/guard-content-policy.sh"
}

# Commit to origin main (used for .guardignore and branch-switch fixtures).
_origin_commit() {
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -qm "$1"
}

_run_pr_wrapper() {
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    "BUILDKITE_PIPELINE_DEFAULT_BRANCH=${DEFAULT_BRANCH-main}" \
    "BUILDKITE_PULL_REQUEST_BASE_BRANCH=${BASE_BRANCH:-main}" \
    "BUILDKITE_PULL_REQUEST_REPO=$PIPELINE_REPO" \
    "BUILDKITE_REPO=$PIPELINE_REPO" \
    bash "$PRDIR/.buildkite/scripts/guard-content-policy.sh" "$@"
}

# Built from fragments so this file never carries the literal path.
_leak_line() {
  printf '/%s/%s/x' home fixtureuser
}

@test "PR mode on a pull request passes without GUARD_PRIVATE_REPOS" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"guard-content-policy: private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" == *"public-repo-guard: private-repo rule NOT checked (PR mode, no list)"* ]]
  [[ "$output" == *"public-repo-guard: content policy OK"* ]]
  [[ "$output" == *"bootstrap"* ]]
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
  _pr_fixture
  _leak_line > "$PRDIR/leak.txt"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
  [[ "$output" != *"content policy OK"* ]]
}

@test "PR mode re-execs the default branch's wrapper once it has the marker" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture trusted
  _run_pr_wrapper
  local out="$output" st="$status"
  _leak_line > "$PRDIR/leak.txt"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$st" -eq 0 ]
  [[ "$out" == *"running the 'main' copy of this wrapper (trusted stage)"* ]]
  [[ "$out" == *"MAIN-COPY-WRAPPER"* ]]
  [[ "$out" != *"bootstrap"* ]]
  [[ "${out##*$'\n'}" == *"private-repo rule NOT checked (PR mode, no list)"* ]]
  [ "$status" -eq 1 ]
  [[ "$output" == *"MAIN-COPY-WRAPPER"* ]]
  [[ "$output" == *"abs-user-path"* ]]
}

@test "PR mode ignores a no-op policy in the PR checkout" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PRDIR/scripts/public-repo-guard/content-policy.sh"
  _leak_line > "$PRDIR/leak.txt"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
}

@test "PR mode takes .guardignore from the default branch, not the PR" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  printf 'trusted-skip.txt\n' > "$ORIGIN/.guardignore"
  _origin_commit guardignore
  # The PR exempts its own leak file; the default branch's list does not.
  printf 'leak.txt\n' > "$PRDIR/.guardignore"
  _leak_line > "$PRDIR/leak.txt"
  _run_pr_wrapper
  [ "$status" -eq 1 ]
  [[ "$output" == *"leak.txt"* ]]
  # A path the default branch exempts stays exempt.
  rm -f "$PRDIR/leak.txt"
  _leak_line > "$PRDIR/trusted-skip.txt"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 0 ]
}

@test "PR mode ignores inline guard:allow markers from the PR" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  printf '%s # guard:allow fixture reason\n' "$(_leak_line)" > "$PRDIR/leak.txt"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
  [[ "$output" == *"markers ignored in PR mode ("* ]]
}

@test "PR mode fails closed when the default branch has no policy" {
  _pr_fixture
  git -C "$ORIGIN" rm -q scripts/public-repo-guard/content-policy.sh
  _origin_commit "drop policy"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no fallback to the pull-request copy"* ]]
  [[ "$output" != *"content policy OK"* ]]
}

@test "PR mode uses the pipeline default branch, never the PR base branch" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  # The author-chosen base carries a no-op policy.
  git -C "$ORIGIN" checkout -q -b author-base
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ORIGIN/scripts/public-repo-guard/content-policy.sh"
  _origin_commit "no-op policy"
  git -C "$ORIGIN" checkout -q main
  _leak_line > "$PRDIR/leak.txt"
  BASE_BRANCH=author-base _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
}

@test "PR mode fails closed without a usable default branch" {
  _pr_fixture
  local name
  for name in "" "bad..name" "no-such-branch"; do
    DEFAULT_BRANCH="$name" _run_pr_wrapper
    [ "$status" -eq 2 ]
    [[ "$output" == *"failing closed"* ]]
    [[ "$output" != *"content policy OK"* ]]
  done
  rm -rf "$TDIR"
}

@test "--trusted-stage outside PR mode or outside its temp dir fails closed" {
  _pr_fixture
  run env -u GUARD_PRIVATE_REPOS -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
    bash "$PRDIR/.buildkite/scripts/guard-content-policy.sh" --trusted-stage
  [ "$status" -eq 2 ]
  [[ "$output" == *"only valid in PR mode"* ]]
  # From the checkout (not a guard-content-policy.* temp dir) it must refuse and
  # must not remove anything.
  _run_pr_wrapper --trusted-stage
  [ "$status" -eq 2 ]
  [[ "$output" == *"must run from its guard-content-policy.* temp dir"* ]]
  [ -f "$PRDIR/.buildkite/scripts/guard-content-policy.sh" ]
  rm -rf "$TDIR"
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
  local pr loc
  # Byte-exact FULLWIDTH DIGIT ONE and ARABIC-INDIC DIGIT ONE: printf '\uXXXX'
  # depends on the running locale. Run the child under en_US.UTF-8, where
  # [0-9] matches them (C.UTF-8 does not), so LC_ALL=C in the script is what
  # rejects them.
  loc="$(locale -a 2>/dev/null | grep -i -m1 -E '^en_US\.utf-?8$')" ||
    skip "en_US.UTF-8 locale not installed"
  for pr in $'\xef\xbc\x91' $'\xd9\xa1'; do
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 -u BUILDKITE_PULL_REQUEST_REPO -u BUILDKITE_REPO \
      "LC_ALL=$loc" \
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
  # The wrapper checks for rg before it checks the list.
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
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
  local pr loc
  # Byte-exact FULLWIDTH DIGIT ONE and ARABIC-INDIC DIGIT ONE: printf '\uXXXX'
  # depends on the running locale. Run the child under en_US.UTF-8, where
  # [0-9] matches them (C.UTF-8 does not), so LC_ALL=C in the script is what
  # rejects them.
  loc="$(locale -a 2>/dev/null | grep -i -m1 -E '^en_US\.utf-?8$')" ||
    skip "en_US.UTF-8 locale not installed"
  for pr in $'\xef\xbc\x91' $'\xd9\xa1'; do
    TDIR="$(mktemp -d)"
    run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
      -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
      -u GUARD_PRIVATE_REPOS_06 \
      "LC_ALL=$loc" \
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

@test "content-policy PR mode ignores inline guard:allow markers" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  printf '%s # guard:allow fixture reason\n' "$(_leak_line)" > "$TDIR/leak.txt"
  run env -u GUARD_PRIVATE_REPOS -u GUARD_PRIVATE_REPOS_01 -u GUARD_PRIVATE_REPOS_02 \
    -u GUARD_PRIVATE_REPOS_03 -u GUARD_PRIVATE_REPOS_04 -u GUARD_PRIVATE_REPOS_05 \
    -u GUARD_PRIVATE_REPOS_06 \
    WAVE_JOB_GUARD_PR=1 \
    BUILDKITE_PULL_REQUEST=206 \
    bash "$POLICY" "$TDIR"
  local pr_status="$status"
  run env -u GUARD_PRIVATE_REPOS -u WAVE_JOB_GUARD_PR BUILDKITE_PULL_REQUEST=false \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$pr_status" -eq 1 ]
  # Outside PR mode the documented marker still applies.
  [ "$status" -eq 0 ]
}

# MF-W1: rg's own ignore files in the pull request must not exempt a leak.
# Each case runs twice: with this checkout's policy on origin main, and with
# a "legacy" main policy that still honours .ignore/.rgignore (the bootstrap
# state, before the policy gained --no-ignore), so the wrapper's own deletion
# of PR ignore files is what catches the leak there.
_legacy_main_policy() {
  sed 's/ --no-ignore / --no-ignore-vcs /' "$POLICY" \
    > "$ORIGIN/scripts/public-repo-guard/content-policy.sh"
  grep -q -- '--no-ignore-vcs' "$ORIGIN/scripts/public-repo-guard/content-policy.sh"
  _origin_commit legacy-policy
}

# _ignore_case <variant> <ignore-file> <ignore-content> <leak-file>
_ignore_case() {
  _pr_fixture
  if [ "$1" = "legacy" ]; then
    _legacy_main_policy
  fi
  mkdir -p "$PRDIR/$(dirname "$2")" "$PRDIR/$(dirname "$4")"
  printf '%s\n' "$3" > "$PRDIR/$2"
  _leak_line > "$PRDIR/$4"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
  [[ "$output" == *"$4"* ]]
}

@test "PR mode: a PR .ignore does not hide a leak (MF-W1)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _ignore_case current .ignore leak.md leak.md
  _ignore_case legacy .ignore leak.md leak.md
}

@test "PR mode: a PR docs/.rgignore does not hide a leak (MF-W1)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _ignore_case current docs/.rgignore '*' docs/leak.md
  _ignore_case legacy docs/.rgignore '*' docs/leak.md
}

@test "PR mode: a nested PR .gitignore does not hide a leak (MF-W1)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _ignore_case current sub/deep/.gitignore leak.md sub/deep/leak.md
  _ignore_case legacy sub/deep/.gitignore leak.md sub/deep/leak.md
}

@test "PR mode: a symlinked PR .ignore is removed, its target untouched (MF-W1)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  _legacy_main_policy
  printf 'leak.md\n' > "$TDIR/outside-ignore"
  ln -s "$TDIR/outside-ignore" "$PRDIR/.ignore"
  _leak_line > "$PRDIR/leak.md"
  _run_pr_wrapper
  local target
  target="$(cat "$TDIR/outside-ignore")"
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"leak.md"* ]]
  [ "$target" = "leak.md" ]
}

@test "PR mode: the default branch's wrapper also drops PR ignore files (MF-W1)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture trusted
  printf '*\n' > "$PRDIR/.rgignore"
  _leak_line > "$PRDIR/leak.md"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MAIN-COPY-WRAPPER"* ]]
  [[ "$output" == *"leak.md"* ]]
}

@test "content-policy ignores .ignore/.rgignore/.gitignore in full mode too (MF-W1)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  TDIR="$(mktemp -d)"
  git init -q "$TDIR"
  mkdir -p "$TDIR/docs" "$TDIR/sub"
  printf 'a.md\n' > "$TDIR/.ignore"
  printf '*\n' > "$TDIR/docs/.rgignore"
  printf 'c.md\n' > "$TDIR/sub/.gitignore"
  _leak_line > "$TDIR/a.md"
  _leak_line > "$TDIR/docs/b.md"
  _leak_line > "$TDIR/sub/c.md"
  run env -u GUARD_PRIVATE_REPOS -u WAVE_JOB_GUARD_PR BUILDKITE_PULL_REQUEST=false \
    bash "$POLICY" "$TDIR"
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.md"* ]]
  [[ "$output" == *"b.md"* ]]
  [[ "$output" == *"c.md"* ]]
}

@test "PR mode: a leak in a file with a NUL byte is caught (MF-W4)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _pr_fixture
  { _leak_line; printf '\n\000binary-tail\n'; } > "$PRDIR/blob.dat"
  _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
  [[ "$output" == *"blob.dat"* ]]
}

# _rgconfig_case <glob|ignore-file> : a RIPGREP_CONFIG_PATH config must not
# hide a PR guard:allow marker from the neutralizing scan (MF-W1b). origin
# main gets a policy that still honours markers in PR mode (like main before
# M1, the bootstrap state), so the wrapper's neutralizing is what must work.
_rgconfig_case() {
  _pr_fixture
  sed 's/^  if \[\[ "\$_guard_pr_mode" == "1" \]\]; then$/  if false; then/' "$POLICY" \
    > "$ORIGIN/scripts/public-repo-guard/content-policy.sh"
  grep -q '^  if false; then$' "$ORIGIN/scripts/public-repo-guard/content-policy.sh"
  _origin_commit marker-honouring-policy
  printf 'marked.txt\n' > "$TDIR/hide.ignore"
  if [ "$1" = "glob" ]; then
    printf -- '--glob=!marked.txt\n' > "$TDIR/ripgreprc"
  else
    printf -- '--ignore-file=%s\n' "$TDIR/hide.ignore" > "$TDIR/ripgreprc"
  fi
  printf '%s # guard:allow fixture reason\n' "$(_leak_line)" > "$PRDIR/marked.txt"
  RIPGREP_CONFIG_PATH="$TDIR/ripgreprc" _run_pr_wrapper
  rm -rf "$TDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"abs-user-path"* ]]
  [[ "$output" == *"marked.txt"* ]]
}

@test "PR mode: RIPGREP_CONFIG_PATH cannot hide a guard:allow marker (MF-W1b)" {
  if ! command -v rg >/dev/null 2>&1; then
    skip "rg not installed"
  fi
  _rgconfig_case glob
  _rgconfig_case ignore-file
}
