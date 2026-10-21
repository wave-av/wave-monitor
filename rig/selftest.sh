#!/usr/bin/env bash
# rig/selftest.sh — harness self-test. Validates shims, canary safety,
# redaction, scheduler semantics, and fail-closed behavior. Synthetic values
# only; local backend only (no docker dependency). Exit 0 = all pass.
set -euo pipefail
RIG_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/backend.sh
source "$RIG_DIR/lib/backend.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/r1self.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export RIG_SHIMLOG="$W/shim.log" RIG_CAPTURE_DIR="$W/cap" RIG_NODE_P_OUTPUT="9.9.9-test"
export RIG_PIN_SHA="SELFTEST-SHA"
mkdir -p "$W/cap"; : > "$RIG_SHIMLOG"
CAN="RIGCANARY-SELFTEST-deadbeef"
export RIG_CANARIES="$CAN"

command -v rg >/dev/null 2>&1 || { echo "selftest needs rg" >&2; exit 2; }

# 1. canary format trips no static BLOCK rule (real scanner, canary planted, no injection)
mkdir -p "$W/scan" && echo "token-ish value: $CAN" > "$W/scan/note.txt"
if env -i PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$W" \
    bash "$RIG_DIR/config-current/scripts/public-repo-guard/content-policy.sh" "$W/scan" >"$W/t1.log" 2>&1; then
  grep -q "content policy OK" "$W/t1.log" && ok "canary format is scan-clean" || bad "t1 marker"
else bad "canary format tripped the scanner ($(cat "$W/t1.log"))"; fi

# 2. injected canary IS detected when present in tree (detection path e2e)
if env -i PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" HOME="$W" GUARD_PRIVATE_REPOS="$CAN" \
    bash "$RIG_DIR/config-current/scripts/public-repo-guard/content-policy.sh" "$W/scan" >"$W/t2.log" 2>&1; then
  bad "injected canary not detected"
else grep -q "private-repo" "$W/t2.log" && ok "injected canary detected (private-repo BLOCK)" || bad "t2 marker"; fi

# 3. shims intercept and emulate
S="$RIG_DIR/tools/shims"
[ "$("$S/git" merge-base HEAD x 2>/dev/null)" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ] \
  && ok "git shim merge-base" || bad "git shim merge-base"
if "$S/git" fetch origin main 2>/dev/null; then ok "git shim fetch"; else bad "git shim fetch"; fi
[ "$("$S/node" -p 'x' 2>/dev/null)" = "9.9.9-test" ] && ok "node shim -p" || bad "node shim -p"
if "$S/npm" install foo 2>/dev/null; then ok "npm shim"; else bad "npm shim"; fi
if "$S/curl" -fsSL https://example.invalid 2>/dev/null; then
  bad "curl denied"
elif grep -qF 'curl -fsSL https://example.invalid (DENIED: no network in rig)' "$RIG_SHIMLOG"; then
  ok "curl denied"
else
  bad "curl shim not invoked"
fi
echo data > "$W/f"; "$S/buildkite-agent" pipeline upload "$W/f" 2>/dev/null \
  && [ -f "$W/cap/uploaded-pipeline.yml" ] && ok "buildkite-agent capture" || bad "buildkite-agent capture"
if RIG_CAPTURE_DIR="$W/no-such-dir" "$S/buildkite-agent" pipeline upload "$W/f" >/dev/null 2>&1; then
  bad "buildkite-agent fails closed on capture error"
else ok "buildkite-agent fails closed on capture error"; fi
if "$S/buildkite-agent" meta-data get x 2>/dev/null; then bad "buildkite-agent deny"; else ok "buildkite-agent deny"; fi
[ "$(wc -l < "$RIG_SHIMLOG")" -ge 6 ] && ok "shim log populated" || bad "shim log"

# 4. emitter redacts canaries, keeps shape
echo -e "line one\nSECRET_IS=$CAN\nline three" > "$W/t4.log"
OUT="$(python3 "$RIG_DIR/tools/analysis/emit.py" z current DENY EXECUTED local "$W/t4.log" "note here")"
echo "$OUT" | grep -q "CANARY-REDACTED" && ! echo "$OUT" | grep -q "$CAN" \
  && ok "receipt redaction" || bad "receipt redaction"
echo "$OUT" | python3 -c "import json,sys; r=json.load(sys.stdin);
assert (r['fixture'],r['expected'],r['actual'],r['note'],r['pinned_sha'])==('z','DENY','EXECUTED','note here','SELFTEST-SHA')" \
  && ok "receipt shape" || bad "receipt shape"
if python3 "$RIG_DIR/tools/analysis/emit.py" z current DENY EXECUTED local "$W/no-such.log" "note" >/dev/null 2>&1; then
  bad "emitter fails closed on unreadable log"
else ok "emitter fails closed on unreadable log"; fi

# 5. scheduler semantics on toy pipelines
cat > "$W/toy-nogate.yml" <<'EOF'
steps:
  - label: g
    key: guard-x
    command: sh guard.sh
    agents:
      queue: fpc-isolated
  - label: s
    key: use-secret
    command: sh use.sh
    agents:
      queue: fpc-isolated-secrets
EOF
cat > "$W/toy-gate.yml" <<'EOF'
steps:
  - label: g
    key: guard-x
    command: sh guard.sh
    agents:
      queue: fpc-isolated
  - wait
  - label: s
    key: use-secret
    command: sh use.sh
    agents:
      queue: fpc-isolated-secrets
    depends_on: [guard-x]
EOF
S1="$(python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-nogate.yml" guard-x pr)"
echo "$S1" | python3 -c "import json,sys; assert 'use-secret' in json.load(sys.stdin)['started']" \
  && ok "no-gate starts secret" || bad "no-gate starts secret"
S2="$(python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-gate.yml" guard-x pr)"
echo "$S2" | python3 -c "import json,sys; assert 'use-secret' in json.load(sys.stdin)['blocked']" \
  && ok "wait+depends_on blocks secret" || bad "wait+depends_on blocks secret"
D0="$(python3 "$RIG_DIR/tools/analysis/pipeline.py" diff "$W/toy-nogate.yml" "$W/toy-nogate.yml")"
echo "$D0" | python3 -c "import json,sys; d=json.load(sys.stdin);
assert d['removed']==[] and d['added']==[] and d['changed']=={}" \
  && ok "diff identity" || bad "diff identity"

# 6. poison prints env (detection path), scanner-clean tree stays clean
if env -i PATH="/usr/bin:/bin" "GUARD_PRIVATE_REPOS=$CAN" \
    bash "$RIG_DIR/fixtures/poison-content-policy.sh" >"$W/t6.log" 2>&1; then
  grep -qF "$CAN" "$W/t6.log" && ok "poison exposes injected kind" || bad "poison output"
else bad "poison rc"; fi

# 7. strip-refusal: works on governance copy, fails closed without refusal
cp "$RIG_DIR/config-current/.buildkite/scripts/governance-enforce.sh" "$W/gov.sh"
if python3 "$RIG_DIR/fixtures/strip-refusal.py" "$W/gov.sh" >/dev/null 2>&1 \
  && ! grep -q BUILDKITE_PULL_REQUEST_REPO "$W/gov.sh" && bash -n "$W/gov.sh"; then
  ok "strip-refusal removes block, stays valid"
else bad "strip-refusal on governance"; fi
echo '#!/usr/bin/env bash
echo hi' > "$W/plain.sh"
python3 "$RIG_DIR/fixtures/strip-refusal.py" "$W/plain.sh" >/dev/null 2>&1 \
  && bad "strip-refusal silent no-op" || ok "strip-refusal fails closed"

# 8. parser fails closed on out-of-subset pipeline
cat > "$W/toy-weird.yml" <<'EOF'
steps:
  - trigger: other-pipeline
EOF
if python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-weird.yml" "" pr >/dev/null 2>&1; then
  bad "parser accepted trigger step"
else ok "parser fails closed on trigger step"; fi

# 9. run.sh arg contract
rc=0; "$RIG_DIR/run.sh" --fixture z >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "bad fixture exits 2" || bad "bad fixture"
rc=0; "$RIG_DIR/run.sh" --config nope >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "bad config exits 2" || bad "bad config"
rc=0; "$RIG_DIR/run.sh" --config patched --fixture b >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "zero-fixture selection exits 2" || bad "zero-fixture selection"

# 10. scheduler: a failure AFTER a wait must not block at the earlier wait
cat > "$W/toy-postwait.yml" <<'EOF'
steps:
  - label: a
    key: step-a
    command: sh a.sh
    agents:
      queue: fpc-isolated
  - wait
  - label: b
    key: step-b
    command: sh b.sh
    agents:
      queue: fpc-isolated
  - label: c
    key: step-c
    command: sh c.sh
    agents:
      queue: fpc-isolated-secrets
EOF
S3="$(python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-postwait.yml" step-b pr)"
echo "$S3" | python3 -c "import json,sys; s=json.load(sys.stdin);
assert set(('step-a','step-b','step-c')) <= set(s['started']), s" \
  && ok "post-wait failure blocks nothing before a later wait" || bad "post-wait failure"

# 11. parser fails closed on out-of-subset gating shapes
cat > "$W/toy-inline-agents.yml" <<'EOF'
steps:
  - label: s
    key: use-secret
    command: sh use.sh
    agents: {queue: fpc-isolated-secrets}
EOF
if python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-inline-agents.yml" "" pr >/dev/null 2>&1; then
  bad "parser accepted inline agents mapping"
else ok "parser rejects inline agents mapping"; fi
cat > "$W/toy-weird-if.yml" <<'EOF'
steps:
  - label: s
    key: use-secret
    command: sh use.sh
    if: build.branch == "main"
    agents:
      queue: fpc-isolated-secrets
EOF
if python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-weird-if.yml" "" pr >/dev/null 2>&1; then
  bad "parser accepted unmodeled if"
else ok "parser rejects unmodeled if"; fi
cat > "$W/toy-null-if.yml" <<'EOF'
steps:
  - label: s
    key: use-secret
    command: sh use.sh
    if: build.pull_request.id != null
    agents:
      queue: fpc-isolated-secrets
EOF
S4="$(python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-null-if.yml" "" nonpr)"
echo "$S4" | python3 -c "import json,sys; assert 'use-secret' in json.load(sys.stdin)['blocked']" \
  && ok "null-check if excludes non-PR builds" || bad "null-check if"
cat > "$W/toy-depmap.yml" <<'EOF'
steps:
  - label: g
    key: guard-x
    command: sh guard.sh
    agents:
      queue: fpc-isolated
  - label: s
    key: use-secret
    command: sh use.sh
    agents:
      queue: fpc-isolated-secrets
    depends_on: [{step: guard-x}]
EOF
if python3 "$RIG_DIR/tools/analysis/pipeline.py" schedule "$W/toy-depmap.yml" guard-x pr >/dev/null 2>&1; then
  bad "parser accepted depends_on map"
else ok "parser rejects depends_on map"; fi

# 12. scheduler: a genuine `__idx0`-style key is never placeholder-rewritten
cat > "$W/toy-idxkey.yml" <<'EOF'
steps:
  - label: late key arrives via sub-key
    key: late-key
    command: sh late.sh
    agents:
      queue: fpc-isolated
  - label: genuine dunder key
    key: __idx0
    command: sh idx.sh
    agents:
      queue: fpc-isolated-secrets
EOF
D1="$(python3 "$RIG_DIR/tools/analysis/pipeline.py" dump "$W/toy-idxkey.yml")"
echo "$D1" | python3 -c "import json,sys; o=json.load(sys.stdin)['order'];
assert [r for _,r in o]==['late-key','__idx0'], o" \
  && ok "genuine __idx key survives parse" || bad "genuine __idx key"

# 13. strip-refusal handles an indented refusal block
cat > "$W/indented.sh" <<'EOF'
#!/usr/bin/env bash
run() {
  if [ -n "${BUILDKITE_PULL_REQUEST_REPO:-}" ] && [ -n "${BUILDKITE_REPO:-}" ] \
     && [ "$BUILDKITE_PULL_REQUEST_REPO" != "$BUILDKITE_REPO" ]; then
    echo "fork PR detected — refusing"
    exit 2
  fi
  echo "KEPT-ANCHOR doing work"
}
run
if [ -n "unrelated" ]; then
  echo "later block"
fi
EOF
if python3 "$RIG_DIR/fixtures/strip-refusal.py" "$W/indented.sh" KEPT-ANCHOR >/dev/null 2>&1 \
  && ! grep -q BUILDKITE_PULL_REQUEST_REPO "$W/indented.sh" \
  && grep -q "later block" "$W/indented.sh" && bash -n "$W/indented.sh"; then
  ok "strip-refusal removes indented block only"
else bad "strip-refusal on indented block"; fi

# 14. lib fail-closed: workdir creation and step-env KIND validation
rc=0; (TMPDIR="$W/no-such-tmpdir" rig_workdir >/dev/null 2>&1) || rc=$?
[ "$rc" -eq 2 ] && ok "rig_workdir fails closed (exit 2)" || bad "rig_workdir fail-closed"
if rig_step_env bogus "" "" >/dev/null 2>&1; then
  bad "rig_step_env accepts bad KIND"
else ok "rig_step_env rejects bad KIND"; fi

echo ""
echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
