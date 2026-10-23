# guard-gitleaks-base-config.bats — WAVE-27332: PR checkouts are scanned with
# the BASE revision's canonical .gitleaks.toml, never the PR's own.
#
# Run: bats .buildkite/tests/guard-gitleaks-base-config.bats
# The end-to-end test needs a gitleaks binary (GITLEAKS_BIN or PATH); it
# skips otherwise. All resolve_config tests are offline (git only).

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/guard-gitleaks.sh"
  FIX="$(mktemp -d)"
  ORIGIN="$FIX/origin.git"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$FIX/work" 2>/dev/null
  cd "$FIX/work"
  git config user.email t@t.t
  git config user.name t
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

teardown() {
  cd /tmp || true
  rm -rf "$FIX"
}

_commit_main_strict() {
  printf 'title = "strict-fixture"\n\n[[rules]]\nid = "fixture-token"\ndescription = "fixture"\nregex = %s\ntags = ["test"]\n' "'''FAKESECRET-[0-9]{6}'''" > .gitleaks.toml
  echo "clean" > ok.txt
  git add -A
  git commit -qm "strict base config"
  git push -q origin HEAD:main
  git branch --set-upstream-to=origin/main 2>/dev/null || true
}

_neuter_and_plant() {
  git checkout -qb pr
  printf 'title = "neutered"\n' > .gitleaks.toml
  # Fixture token: caught by the strict base rule, by nothing when neutered.
  echo 'token = FAKESECRET-123456' > secret.txt
  git add -A
  git commit -qm "neuter config + plant secret"
}

@test "PR build resolves the base revision config" {
  _commit_main_strict
  _neuter_and_plant
  W="$(mktemp -d)"
  BUILDKITE_PULL_REQUEST=123 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main run \
    resolve_config "$W"
  [ "$status" -eq 0 ]
  [ "$output" = "$W/base.gitleaks.toml" ]
  grep -q "fixture-token" "$W/base.gitleaks.toml"
}

@test "main build uses the worktree config" {
  _commit_main_strict
  W="$(mktemp -d)"
  BUILDKITE_PULL_REQUEST=false run resolve_config "$W"
  [ "$status" -eq 0 ]
  [ "$output" = ".gitleaks.toml" ]
}

@test "base without config falls back to worktree with warning" {
  echo clean > ok.txt
  git add -A
  git commit -qm "no config on main"
  git push -q origin HEAD:main
  git checkout -qb pr
  printf 'title = "pr-only"\n' > .gitleaks.toml
  git add -A
  git commit -qm "pr config"
  W="$(mktemp -d)"
  BUILDKITE_PULL_REQUEST=7 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main run --separate-stderr \
    resolve_config "$W"
  [ "$status" -eq 0 ]
  [ "$output" = ".gitleaks.toml" ]
  [[ "$stderr" == *"WARNING"* ]]
}

@test "unresolvable base fails closed with exit 2" {
  _commit_main_strict
  _neuter_and_plant
  W="$(mktemp -d)"
  BUILDKITE_PULL_REQUEST=9 BUILDKITE_PULL_REQUEST_BASE_BRANCH=nope-missing run \
    resolve_config "$W"
  [ "$status" -eq 2 ]
}

@test "end-to-end: neutered PR still scanned with teeth" {
  BIN="${GITLEAKS_BIN:-$(command -v gitleaks || true)}"
  [ -n "$BIN" ] || skip "gitleaks binary not installed"
  _commit_main_strict
  _neuter_and_plant
  W="$(mktemp -d)"
  cfg="$(BUILDKITE_PULL_REQUEST=123 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
    resolve_config "$W")"
  # Base (strict) config flags the planted secret...
  run "$BIN" detect --no-git --source . --config "$cfg" --no-banner --exit-code 1
  [ "$status" -eq 1 ]
  # ...while the PR's neutered config would have passed it.
  run "$BIN" detect --no-git --source . --config .gitleaks.toml --no-banner --exit-code 1
  [ "$status" -eq 0 ]
}
