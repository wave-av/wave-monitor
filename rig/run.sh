#!/usr/bin/env bash
# rig/run.sh — R1 adversarial fork-PR drill rig (WAVE-26518).
# Full matrix: ./rig/run.sh [--config current|patched|all] [--fixture a-f]
# Receipts (JSON lines) -> stdout; human summary -> stderr.
# Exit 0 clean, 1 on DENY-violation, 2 on harness error / hardened-mismatch.
set -euo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/backend.sh
source "$RIG_DIR/lib/backend.sh"

CONFIGS="all"; ONLY_FIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIGS="$2"; shift 2 ;;
    --fixture) ONLY_FIX="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$CONFIGS" in current|patched|all) ;; *) echo "bad --config" >&2; exit 2;; esac
case "$ONLY_FIX" in ""|a|b|c|d|e|f) ;; *) echo "bad --fixture" >&2; exit 2;; esac

RIG_WORK="$(rig_workdir)"
trap 'rm -rf "$RIG_WORK"' EXIT

# Stage shims under the workdir so step env (PATH) never embeds the operator's
# checkout path — receipts stay free of abs-user-path values.
mkdir -p "$RIG_WORK/stage"
cp -r "$RIG_SHIMS" "$RIG_WORK/stage/shims"
chmod +x "$RIG_WORK/stage/shims/"*
RIG_SHIMS="$RIG_WORK/stage/shims"

CANARY_GPR="$(rig_canary GUARDPRIVATEREPOS)"
CANARY_GH="$(rig_canary GHPACKAGESREAD)"
export RIG_CANARIES="$CANARY_GPR $CANARY_GH"

PIN_SHA="$(grep -Eo 'Pinned SHA: [0-9a-f]+' "$RIG_DIR/PROVENANCE" | awk '{print $3}')"
RESULTS=()  # "fixture|config|expected|actual"

emit() { # FIX CFG EXP ACT BACKEND LOG NOTE [HARD]
  python3 "$RIG_ANALYSIS/emit.py" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}"
  RESULTS+=("$1|$2|$3|$4")
}

want() { # want FIX CFG -> 0 if selected
  [ -n "$ONLY_FIX" ] && [ "$ONLY_FIX" != "$1" ] && return 1
  case "$CONFIGS" in
    all) return 0 ;;
    current) [ "$2" = "current" ] ;;
    patched) [ "$2" != "current" ] ;;
  esac
}

prep_co() { # SRC NAME -> prints checkout path
  local src="$1" name="$2"
  local co="$RIG_WORK/co-$name"
  rm -rf "$co"; cp -r "$src" "$co"; echo "$co"
}

run_step() { # BACKEND CO REL OUTFILE ENVFILE NODEPV SHIMLOG CAPDIR -> rc
  local be="$1"; shift
  if [ "$be" = "docker" ]; then rig_run_docker "$@"; else rig_run_local "$@"; fi
}

# ---------------------------------------------------------------- fixture (a)
fix_a() { # CFG SRC
  local cfg="$1" src="$2" co
  local out="$RIG_WORK/out-a-$cfg.log" envf="$RIG_WORK/env-a-$cfg"
  co="$(prep_co "$src" "a-$cfg")"
  local be; be="$(rig_pick_backend yes)" || {
    echo "(empty log)" > "$out"
    emit a "$cfg" DENY ERROR "$RIG_BACKEND" "$out" "backend unavailable: $be"; return; }
  if [ "$cfg" = "patched-base" ]; then
    # Fork edits the PR checkout (strip refusal + poison), THEN the trusted
    # host overlays base-revision scripts — the overlay must win.
    python3 "$RIG_DIR/fixtures/strip-refusal.py" \
      "$co/.buildkite/scripts/guard-content-policy.sh" \
      GUARD_PRIVATE_REPOS content-policy.sh >>"$out" 2>&1 || {
      emit a "$cfg" DENY ERROR "$be" "$out" "setup: refusal-strip failed"; return; }
    cp "$RIG_DIR/fixtures/poison-content-policy.sh" \
      "$co/scripts/public-repo-guard/content-policy.sh"
    cp "$src/.buildkite/scripts/guard-content-policy.sh" \
      "$co/.buildkite/scripts/guard-content-policy.sh"
    cp "$src/scripts/public-repo-guard/content-policy.sh" \
      "$co/scripts/public-repo-guard/content-policy.sh"
    grep -q 'BUILDKITE_PULL_REQUEST_REPO' \
      "$co/.buildkite/scripts/guard-content-policy.sh" || {
      emit a "$cfg" DENY ERROR "$be" "$out" "setup: base overlay missing refusal"; return; }
  else
    if [ "$cfg" = "patched-pr" ]; then
      # Fork deletes the S1-style refusal text too — patch alone must lose.
      python3 "$RIG_DIR/fixtures/strip-refusal.py" \
        "$co/.buildkite/scripts/guard-content-policy.sh" \
        GUARD_PRIVATE_REPOS content-policy.sh >>"$out" 2>&1 || {
        emit a "$cfg" DENY ERROR "$be" "$out" "setup: refusal-strip failed"; return; }
    fi
    cp "$RIG_DIR/fixtures/poison-content-policy.sh" \
      "$co/scripts/public-repo-guard/content-policy.sh"
  fi
  rig_step_env fork "$CANARY_GPR" "" > "$envf"
  local rc=0
  run_step "$be" "$co" ".buildkite/scripts/guard-content-policy.sh" \
    "$out" "$envf" "" "$RIG_WORK/shim-a-$cfg.log" "$RIG_WORK/cap-a-$cfg" || rc=$?
  if grep -qF "$CANARY_GPR" "$out"; then
    emit a "$cfg" DENY EXECUTED "$be" "$out" \
      "fork poison printed step env incl. injected kind (rc=$rc)"
  elif grep -q "refusing to run" "$out" && [ "$rc" -ne 0 ]; then
    emit a "$cfg" DENY DENY "$be" "$out" \
      "in-script fork refusal fired before secret use (rc=$rc)"
  elif [ "$rc" -eq 0 ] && grep -q "content policy OK" "$out"; then
    emit a "$cfg" DENY DENY "$be" "$out" \
      "clean base-revision script scanned; poison never executed (rc=0)"
  else
    emit a "$cfg" DENY ERROR "$be" "$out" \
      "inconclusive: rc=$rc, no canary/refusal/clean signal"
  fi
}

# ---------------------------------------------------------------- fixture (b)
fix_b() {
  local cfg="current" src="$RIG_DIR/config-current"
  local co out="$RIG_WORK/out-b.log" envf="$RIG_WORK/env-b"
  co="$(prep_co "$src" "b")"
  grep -q 'BUILDKITE_PULL_REQUEST_REPO' \
    "$src/.buildkite/scripts/governance-enforce.sh" || {
    echo "(empty log)" > "$out"
    emit b "$cfg" DENY ERROR local "$out" "premise broken: no refusal in snapshot"; return; }
  python3 "$RIG_DIR/fixtures/strip-refusal.py" \
    "$co/.buildkite/scripts/governance-enforce.sh" >"$out" 2>&1 || {
    emit b "$cfg" DENY ERROR local "$out" "setup: refusal-strip failed"; return; }
  local be; be="$(rig_pick_backend no)" || {
    emit b "$cfg" DENY ERROR "$RIG_BACKEND" "$out" "backend unavailable"; return; }
  local nodepv; nodepv="$(rig_gov_version "$co/.buildkite/scripts/governance-enforce.sh")"
  [ -n "$nodepv" ] || {
    emit b "$cfg" DENY ERROR "$be" "$out" "setup: GOV_VERSION unparseable"; return; }
  rig_step_env fork "" "$CANARY_GH" > "$envf"
  local rc=0
  run_step "$be" "$co" ".buildkite/scripts/governance-enforce.sh" \
    "$out.run" "$envf" "$nodepv" "$RIG_WORK/shim-b.log" "$RIG_WORK/cap-b" || rc=$?
  cat "$out.run" >> "$out"
  echo "--- shim log ---" >> "$out"; cat "$RIG_WORK/shim-b.log" >> "$out"
  if grep -q "refusing to run" "$out" && [ ! -s "$RIG_WORK/shim-b.log" ] && [ "$rc" -ne 0 ]; then
    emit b "$cfg" DENY DENY "$be" "$out" "refusal held (rc=$rc)"
  elif [ -s "$RIG_WORK/shim-b.log" ] || grep -qE "diffing against merge-base|warning: indeterminate|governance version mismatch|enforce.mjs" "$out"; then
    emit b "$cfg" DENY EXECUTED "$be" "$out" \
      "refusal deleted by fork; script proceeded with injected kind (rc=$rc)"
  else
    emit b "$cfg" DENY ERROR "$be" "$out" "inconclusive: rc=$rc"
  fi
}

# ---------------------------------------------------------------- fixture (c)
fix_c() {
  local cfg="current" src="$RIG_DIR/config-current"
  local co out="$RIG_WORK/out-c.log" envf="$RIG_WORK/env-c"
  co="$(prep_co "$src" "c")"
  cp "$RIG_DIR/fixtures/fork-pipeline.yml" "$co/.buildkite/pipeline.yml"
  local be; be="$(rig_pick_backend no)" || {
    echo "(empty log)" > "$out"
    emit c "$cfg" DENY ERROR "$RIG_BACKEND" "$out" "backend unavailable"; return; }
  if grep -qiE "base.revision|pin(ned|ning)?|validat|expected.sha|sha256" \
      "$src/.buildkite/upload.sh"; then pinned="yes"; else pinned="no"; fi
  rig_step_env fork "" "" > "$envf"
  local rc=0
  run_step "$be" "$co" ".buildkite/upload.sh" \
    "$out.run" "$envf" "" "$RIG_WORK/shim-c.log" "$RIG_WORK/cap-c" || rc=$?
  cat "$out.run" > "$out" 2>/dev/null || : >"$out"
  echo "--- shim log ---" >> "$out"; cat "$RIG_WORK/shim-c.log" >> "$out"
  local cap="$RIG_WORK/cap-c/uploaded-pipeline.yml"
  [ -f "$cap" ] || {
    emit c "$cfg" DENY ERROR "$be" "$out" "upload capture missing (rc=$rc)"; return; }
  local diff
  diff="$(python3 "$RIG_ANALYSIS/pipeline.py" diff \
    "$src/.buildkite/pipeline.yml" "$cap")" || {
    echo "$diff" >> "$out"
    emit c "$cfg" DENY ERROR "$be" "$out" "pipeline diff failed"; return; }
  echo "--- pipeline diff base->uploaded ---" >> "$out"; echo "$diff" >> "$out"
  if cmp -s "$cap" "$src/.buildkite/pipeline.yml"; then
    emit c "$cfg" DENY DENY "$be" "$out" "host pinned pipeline to base revision"
  elif echo "$diff" | grep -q "guard-content-policy" \
    && echo "$diff" | grep -q "test-log-upload"; then
    emit c "$cfg" DENY EXECUTED "$be" "$out" \
      "PR-checkout pipeline uploaded unvalidated (pinning=$pinned, rc=$rc): guards removed, secrets-queue step added"
  else
    emit c "$cfg" DENY ERROR "$be" "$out" "unexpected diff shape (rc=$rc)"
  fi
}

# ------------------------------------------------------- fixtures (d) and (e)
fix_de() { # FIX KIND EXPECT HARDENING
  local fix="$1" kind="$2" expect="$3" hard="$4"
  local cfg="current" src="$RIG_DIR/config-current"
  local co out="$RIG_WORK/out-$fix.log" envf="$RIG_WORK/env-$fix"
  co="$(prep_co "$src" "$fix")"
  if [ "$fix" = "e" ]; then
    local sched
    sched="$(python3 "$RIG_ANALYSIS/pipeline.py" schedule \
      "$src/.buildkite/pipeline.yml" "" nonpr)" || {
      echo "(empty log)" > "$out"
      emit e "$cfg" "$expect" ERROR local "$out" "schedule analysis failed"; return; }
    if python3 -c "import json,sys; s=json.load(sys.stdin);
assert 'guard-content-policy' in s['blocked'], 'not blocked'" <<<"$sched" 2>/dev/null; then
      echo "$sched" > "$out"
      emit e "$cfg" "$expect" DENY local "$out" \
        "residual hardened: host if-gate now excludes non-PR builds" "$hard"; return
    fi
  fi
  cp "$RIG_DIR/fixtures/poison-content-policy.sh" \
    "$co/scripts/public-repo-guard/content-policy.sh"
  local be; be="$(rig_pick_backend yes)" || {
    echo "(empty log)" > "$out"
    emit "$fix" "$cfg" "$expect" ERROR "$RIG_BACKEND" "$out" "backend unavailable" "$hard"; return; }
  rig_step_env "$kind" "$CANARY_GPR" "" > "$envf"
  local rc=0
  run_step "$be" "$co" ".buildkite/scripts/guard-content-policy.sh" \
    "$out" "$envf" "" "$RIG_WORK/shim-$fix.log" "$RIG_WORK/cap-$fix" || rc=$?
  if grep -qF "$CANARY_GPR" "$out"; then
    emit "$fix" "$cfg" "$expect" OPEN "$be" "$out" \
      "control executed (rc=$rc): residual reproduced, see hardening" "$hard"
  elif grep -q "refusing to run" "$out" && [ "$rc" -ne 0 ]; then
    emit "$fix" "$cfg" "$expect" DENY "$be" "$out" \
      "residual hardened: step refused (rc=$rc)" "$hard"
  else
    emit "$fix" "$cfg" "$expect" ERROR "$be" "$out" \
      "inconclusive control: rc=$rc" "$hard"
  fi
}

# ---------------------------------------------------------------- fixture (f)
fix_f() {
  local cfg="current" src="$RIG_DIR/config-current"
  local co out="$RIG_WORK/out-f.log" envf="$RIG_WORK/env-f"
  co="$(prep_co "$src" "f")"
  cp "$RIG_DIR/fixtures/dotenv-block-content" "$co/.env"
  local be; be="$(rig_pick_backend yes)" || {
    echo "(empty log)" > "$out"
    emit f "$cfg" DENY ERROR "$RIG_BACKEND" "$out" "backend unavailable"; return; }
  rig_step_env fork "$CANARY_GPR" "" > "$envf"
  local rc=0
  run_step "$be" "$co" ".buildkite/scripts/guard-content-policy.sh" \
    "$out" "$envf" "" "$RIG_WORK/shim-f.log" "$RIG_WORK/cap-f" || rc=$?
  if grep -qF "$CANARY_GPR" "$out"; then
    emit f "$cfg" DENY ERROR "$be" "$out" \
      "gate itself leaked injected kind into output (rc=$rc)"; return
  fi
  if [ "$rc" -eq 0 ] || ! grep -q "committed-dotenv" "$out"; then
    emit f "$cfg" DENY ERROR "$be" "$out" \
      "guard did not fail on planted violation (rc=$rc)"; return
  fi
  local sched
  sched="$(python3 "$RIG_ANALYSIS/pipeline.py" schedule \
    "$src/.buildkite/pipeline.yml" "guard-gitleaks,guard-content-policy" pr)" || {
    echo "$sched" >> "$out"
    emit f "$cfg" DENY ERROR "$be" "$out" "schedule analysis failed"; return; }
  echo "--- schedule with guards failed ---" >> "$out"; echo "$sched" >> "$out"
  if python3 -c "import json,sys; s=json.load(sys.stdin);
sys.exit(0 if set(s['secret']) & set(s['started']) else 1)" <<<"$sched"; then
    local started
    started="$(python3 -c "import json,sys; s=json.load(sys.stdin);
print(','.join(sorted(set(s['secret']) & set(s['started']))))" <<<"$sched")"
    emit f "$cfg" DENY EXECUTED "$be" "$out" \
      "guard failed (rc=$rc) yet secret steps still start: $started (no wait/depends_on)"
  else
    emit f "$cfg" DENY DENY "$be" "$out" \
      "guard failed (rc=$rc) and secret steps blocked by gating"
  fi
}

# ------------------------------------------------------------------ main loop
want a current && fix_a current "$RIG_DIR/config-current"
want a patched-pr && fix_a patched-pr "$RIG_DIR/config-patched"
want a patched-base && fix_a patched-base "$RIG_DIR/config-patched"
want b current && fix_b
want c current && fix_c
want d current && fix_de d same OPEN "WAVE-26503 residual: same-repo attacker branches pass URL checks — needs identity gating"
want e current && fix_de e nonpr OPEN "WAVE-26503 residual: non-PR builds skip refusal — needs fail-closed default"
want f current && fix_f

# ------------------------------------------------------------------ summary
viol=0; err=0; hard=0
{
echo ""
echo "R1 drill rig — snapshot $PIN_SHA — backend default $RIG_BACKEND"
printf '%-7s %-12s %-8s %-8s\n' FIX CONFIG EXPECT ACTUAL
for r in "${RESULTS[@]}"; do
  IFS='|' read -r f c e a <<<"$r"
  printf '%-7s %-12s %-8s %-8s\n' "$f" "$c" "$e" "$a"
  if [ "$e" = "DENY" ] && [ "$a" = "EXECUTED" ]; then viol=$((viol+1)); fi
  if [ "$e" = "DENY" ] && [ "$a" = "OPEN" ]; then viol=$((viol+1)); fi
  if [ "$a" = "ERROR" ]; then err=$((err+1)); fi
  if [ "$e" = "OPEN" ] && [ "$a" = "DENY" ]; then hard=$((hard+1)); fi
done
if [ "$err" -gt 0 ]; then echo "HARNESS ERROR in $err fixture(s) — fail closed, investigate."
elif [ "$hard" -gt 0 ]; then echo "RESIDUAL HARDENED in $hard fixture(s) — update rig expectations."
elif [ "$viol" -gt 0 ]; then echo "DENY-VIOLATION in $viol fixture(s) — fork path reaches secret execution."
else echo "CLEAN — no DENY-violation, no error."; fi
} >&2

if [ "$err" -gt 0 ] || [ "$hard" -gt 0 ]; then exit 2; fi
[ "$viol" -gt 0 ] && exit 1
exit 0
