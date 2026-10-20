#!/bin/bash
# cold-boot.sh — prove `electron-builder --mac` yields a launchable arm64
# dmg that cold-boots against a SCRATCH control-plane port and never
# touches live :7729.
#
# Steps: unsigned `dist` (CSC_IDENTITY_AUTO_DISCOVERY=false; release signs
# with the real Developer ID) -> assert dmg+zip exist and the app binary is
# arm64 -> mount the DMG, copy the .app out, launch it with
# WAVE_MONITOR_PORT=0 --smoke-test -> assert SMOKE_OK (scratch port,
# product title, preload bridge present, control plane answering, zero node
# leak) and that no socket to :7729 was opened.
# Pattern from the template's cold-boot.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d /tmp/wave-monitor-proof.XXXXXX)"
# Mount point lives under the unique work dir: a fixed /tmp path would race
# across concurrent runs (attach collision + the EXIT trap detaching the
# other run's DMG).
MNT="$WORK/mnt"
mkdir -p "$MNT"
trap 'rm -rf "$WORK"; hdiutil detach "$MNT" -quiet 2>/dev/null || true' EXIT

echo "== 1. npm run build + unsigned dist (arm64)"
npm run build >/dev/null 2>&1
CSC_IDENTITY_AUTO_DISCOVERY=false npx electron-builder --mac --arm64 2>&1 | tail -n 15

echo "== 2. artifacts"
VERSION="$(node -p "require('./package.json').version")"
DMG="release/WAVE Monitor-$VERSION-arm64.dmg"
ZIP="release/WAVE Monitor-$VERSION-arm64-mac.zip"
[ -f "$DMG" ] || { echo "FAIL: no arm64 dmg at $DMG"; ls -la release/; exit 1; }
[ -f "$ZIP" ] || { echo "FAIL: no arm64 zip at $ZIP"; ls -la release/; exit 1; }
ls -la "$DMG" "$ZIP"
case "$DMG" in *"WAVE Monitor"*) ;; *) echo "FAIL: dmg name must carry the product name: $DMG"; exit 1;; esac
APP_DIR="release/mac-arm64/WAVE Monitor.app"
BIN="$APP_DIR/Contents/MacOS/WAVE Monitor"
[ -x "$BIN" ] || { echo "FAIL: no app binary at $BIN"; exit 1; }
ARCHS="$(lipo -archs "$BIN")"
echo "binary archs: $ARCHS"
[ "$ARCHS" = "arm64" ] || { echo "FAIL: expected arm64-only, got $ARCHS"; exit 1; }

echo "== 3. mount DMG, stage the shipped .app"
hdiutil attach "$DMG" -mountpoint "$MNT" -nobrowse -quiet
cp -R "$MNT/WAVE Monitor.app" "$WORK/Shipped.app"
hdiutil detach "$MNT" -quiet
SHIPPED_BIN="$WORK/Shipped.app/Contents/MacOS/WAVE Monitor"
[ -x "$SHIPPED_BIN" ] || { echo "FAIL: DMG has no launchable WAVE Monitor.app"; exit 1; }

echo "== 4. cold-boot shipped .app on a scratch port (never :7729)"
command -v lsof >/dev/null 2>&1 || { echo "FAIL: lsof is required to prove :7729 untouched"; exit 1; }
WAVE_MONITOR_PORT=0 "$SHIPPED_BIN" --smoke-test >"$WORK/smoke.log" 2>&1 &
APP_PID=$!
# While it runs, poll for any socket to live :7729 from the app tree
# (LISTEN or ESTABLISHED — any touch counts).
TOUCHED_LIVE=0
for _ in $(seq 1 300); do
  grep -q "SMOKE_OK\|SMOKE_FAIL" "$WORK/smoke.log" 2>/dev/null && break
  kill -0 "$APP_PID" 2>/dev/null || break
  LSOF_OUT="$(lsof -a -p "$APP_PID" -iTCP:7729 2>"$WORK/lsof.err" || true)"
  if [ -s "$WORK/lsof.err" ]; then
    echo "FAIL: :7729 socket probe errored (fail-open is not an option):"
    cat "$WORK/lsof.err"
    exit 1
  fi
  if echo "$LSOF_OUT" | grep -q .; then TOUCHED_LIVE=1; fi
  sleep 0.2
done
if kill -0 "$APP_PID" 2>/dev/null; then
  # Past the 45s in-app smoke timer with no verdict: kill so the gate fails
  # instead of hanging on `wait` forever.
  echo "WARN: shipped app still alive after 60s — killing"
  kill "$APP_PID" 2>/dev/null || true
  sleep 2
  kill -9 "$APP_PID" 2>/dev/null || true
fi
wait "$APP_PID" || SMOKE_EXIT=$?
cat "$WORK/smoke.log"
[ "${SMOKE_EXIT:-0}" = "0" ] || { echo "FAIL: shipped app smoke exited ${SMOKE_EXIT:-?}"; exit 1; }
[ "$TOUCHED_LIVE" = "0" ] || { echo "FAIL: shipped app opened a socket to live :7729"; exit 1; }

SMOKE="$(grep "SMOKE_OK" "$WORK/smoke.log" | head -n 1 || true)"
[ -n "$SMOKE" ] || { echo "FAIL: no SMOKE_OK line"; exit 1; }
node -e "
const s = JSON.parse(process.argv[1].slice(process.argv[1].indexOf('{')));
const assert = require('node:assert');
assert.notEqual(s.port, 7729, 'must never boot against live :7729');
assert.ok(s.port > 0, 'control plane must report a bound port');
assert.match(s.title, /WAVE Monitor/, 'title must carry the product name');
assert.equal(s.hasBridge, true, 'preload bridge window.wave must exist');
assert.equal(s.nodeLeak, false, 'zero node exposure in the shipped page');
assert.equal(s.controlPlane, true, 'shipped control plane must answer with the live key');
console.log('PASS: port=' + s.port + ' title=' + JSON.stringify(s.title));
" "$SMOKE"

echo "COLD-BOOT PASS: shipped dmg cold-boots on scratch, :7729 untouched"
