# guard-gitleaks-base-config.bats — WAVE-27332: on PR builds NOTHING executes
# from the PR checkout except as scan source (trusted self re-exec), and the
# scan uses the base-tip canonical .gitleaks.toml (or built-in defaults).
#
# Run: bats .buildkite/tests/guard-gitleaks-base-config.bats
# The e2e tests need a gitleaks binary: GITLEAKS_BIN, PATH, or downloaded
# pinned (linux) / latest-release (other OS) in setup. They FAIL — never
# skip — without one, so the proof cannot pass silently.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/guard-gitleaks.sh"
  FIX="$(mktemp -d)"
  ORIGIN="$FIX/origin.git"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$FIX/work" 2>/dev/null
  cd "$FIX/work" || return 1
  git config user.email t@t.t
  git config user.name t
  # shellcheck disable=SC1090
  source "$SCRIPT"
}

teardown() {
  cd /tmp || true
  rm -rf "$FIX"
}

_ensure_gitleaks() {
  if [[ -n "${GITLEAKS_BIN:-}" && -x "$GITLEAKS_BIN" ]]; then echo "$GITLEAKS_BIN"; return 0; fi
  if command -v gitleaks >/dev/null 2>&1; then command -v gitleaks; return 0; fi
  # No local binary: fetch one. Linux CI gets the pinned+verified asset
  # (same pin as the guard); anything else gets a version-smoked asset.
  local cache="${TMPDIR:-/tmp}/gitleaks-fixture-bin"
  mkdir -p "$cache"
  if [[ ! -x "$cache/gitleaks" ]]; then
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    [[ "$arch" == "arm64" ]] && arch="arm64"
    [[ "$arch" == "x86_64" ]] && arch="x64"
    if [[ "$os" == "linux" && "$arch" == "x64" ]]; then
      curl -fsSL --proto '=https' --tlsv1.2 -o "$cache/g.tar.gz" \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" || return 1
      (cd "$cache" && echo "${GITLEAKS_SHA256}  g.tar.gz" | sha256sum -c -) || return 1
    else
      curl -fsSL --proto '=https' --tlsv1.2 -o "$cache/g.tar.gz" \
        "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_${os}_${arch}.tar.gz" || return 1
    fi
    tar -xzf "$cache/g.tar.gz" -C "$cache" gitleaks || return 1
    "$cache/gitleaks" version >/dev/null || return 1
  fi
  echo "$cache/gitleaks"
}

_commit_main_strict() {
  # Strict base: custom rule + the REAL guard script (re-exec target).
  printf 'title = "strict-fixture"\n\n[[rules]]\nid = "fixture-token"\ndescription = "fixture"\nregex = %s\ntags = ["test"]\n' "'''FAKESECRET-[0-9]{6}'''" > .gitleaks.toml
  mkdir -p .buildkite/scripts
  cp "$SCRIPT" .buildkite/scripts/guard-gitleaks.sh
  echo "clean" > ok.txt
  git add -A
  git commit -qm "strict base config + guard"
  git push -q origin HEAD:main
}

_commit_main_noconfig() {
  # Base tip with the guard but no config at all.
  mkdir -p .buildkite/scripts
  cp "$SCRIPT" .buildkite/scripts/guard-gitleaks.sh
  echo "clean" > ok.txt
  git add -A
  git commit -qm "guard without config"
  git push -q origin HEAD:main
}

_neuter_plant_poison() {
  # Fork-shaped PR: neutered config + planted secret + guard with an
  # injected early-exit bypass (proves re-exec when it does NOT trigger).
  git checkout -qb pr
  printf 'title = "neutered"\n' > .gitleaks.toml
  echo 'token = FAKESECRET-123456' > secret.txt
  sed 's|^  local config$|  echo PR-SCRIPT-RAN; exit 0\n  local config|' \
    .buildkite/scripts/guard-gitleaks.sh > .buildkite/scripts/guard-gitleaks.sh.new
  mv .buildkite/scripts/guard-gitleaks.sh.new .buildkite/scripts/guard-gitleaks.sh
  git add -A
  git commit -qm "neuter + plant + poison guard"
}

@test "PR build resolves the base-tip config, never the PR copy" {
  _commit_main_strict
  _neuter_plant_poison
  WORK="$(mktemp -d)"
  run --separate-stderr env BUILDKITE_PULL_REQUEST=123 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
    bash -c "source \"$SCRIPT\" && WORK=\"$WORK\" && resolve_config"
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK/base.gitleaks.toml" ]
  [ "$output" != ".gitleaks.toml" ]
  grep -q "fixture-token" "$WORK/base.gitleaks.toml"
}

@test "main build uses the worktree config" {
  _commit_main_strict
  WORK="$(mktemp -d)"
  run --separate-stderr env BUILDKITE_PULL_REQUEST=false \
    bash -c "source \"$SCRIPT\" && WORK=\"$WORK\" && resolve_config"
  [ "$status" -eq 0 ]
  [ "$output" = ".gitleaks.toml" ]
}

@test "no config at base tip scans with built-in defaults, never PR config" {
  _commit_main_noconfig
  git checkout -qb pr
  printf 'title = "pr-only"\n' > .gitleaks.toml
  git add -A
  git commit -qm "pr config"
  WORK="$(mktemp -d)"
  run --separate-stderr env BUILDKITE_PULL_REQUEST=7 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
    bash -c "source \"$SCRIPT\" && WORK=\"$WORK\" && resolve_config"
  [ "$status" -eq 0 ]
  [ "$output" = "DEFAULTS" ]
  [[ "$stderr" == *"WARNING"* ]]
}

@test "PR build with unset base branch fails closed with exit 2" {
  _commit_main_strict
  _neuter_plant_poison
  WORK="$(mktemp -d)"
  run --separate-stderr env BUILDKITE_PULL_REQUEST=11 \
    bash -c "source \"$SCRIPT\" && WORK=\"$WORK\" && resolve_config"
  [ "$status" -eq 2 ]
}

@test "unresolvable base fails closed with exit 2" {
  _commit_main_strict
  _neuter_plant_poison
  WORK="$(mktemp -d)"
  run --separate-stderr env BUILDKITE_PULL_REQUEST=9 BUILDKITE_PULL_REQUEST_BASE_BRANCH=nope-missing \
    bash -c "source \"$SCRIPT\" && WORK=\"$WORK\" && resolve_config"
  [ "$status" -eq 2 ]
}

@test "end-to-end through main(): poisoned guard still scans with teeth" {
  BIN="$(_ensure_gitleaks)"
  [ -n "$BIN" ] && [ -x "$BIN" ]
  _commit_main_strict
  _neuter_plant_poison
  # Drive the REAL (poisoned) PR script: re-exec must replace it with the
  # base copy (no PR-SCRIPT-RAN) and the base config must flag (exit 1).
  run --separate-stderr env BUILDKITE_PULL_REQUEST=123 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
    GITLEAKS_BIN="$BIN" bash .buildkite/scripts/guard-gitleaks.sh
  [ "$status" -eq 1 ]
  [[ "$output" != *"PR-SCRIPT-RAN"* ]]
  # Control: the poison bypasses when re-exec is skipped, proving the
  # test is not vacuous.
  run --separate-stderr env GUARD_TRUSTED=1 GUARD_WORK="$(mktemp -d)" \
    BUILDKITE_PULL_REQUEST=123 BUILDKITE_PULL_REQUEST_BASE_BRANCH=main \
    GITLEAKS_BIN="$BIN" bash .buildkite/scripts/guard-gitleaks.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR-SCRIPT-RAN"* ]]
}
