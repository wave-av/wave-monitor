#!/bin/bash
# smoke.sh — boot the built-but-unpacked app (`npx electron .`) against an
# ephemeral control-plane port and assert first paint + preload bridge +
# loopback control plane + zero node leak. Never touches live :7729.
# Fast; run on every change. Pattern from the template's smoke.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d /tmp/wave-monitor-smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "== build (unpacked)"
if ! npm run build >"$WORK/build.log" 2>&1; then
  echo "FAIL: npm run build"
  cat "$WORK/build.log"
  exit 1
fi

WAVE_MONITOR_PORT=0 npx electron . --smoke-test >"$WORK/smoke.log" 2>&1 || SMOKE_EXIT=$?
cat "$WORK/smoke.log"
[ "${SMOKE_EXIT:-0}" = "0" ] || { echo "FAIL: unpacked app smoke exited ${SMOKE_EXIT:-?}"; exit 1; }

SMOKE="$(grep "SMOKE_OK" "$WORK/smoke.log" | head -n 1 || true)"
[ -n "$SMOKE" ] || { echo "FAIL: no SMOKE_OK line"; exit 1; }
node -e "
const s = JSON.parse(process.argv[1].slice(process.argv[1].indexOf('{')));
const assert = require('node:assert');
assert.notEqual(s.port, 7729, 'must never boot against live :7729');
assert.ok(s.port > 0, 'control plane must report a bound port');
assert.match(s.title, /WAVE Monitor/, 'page title must carry the product name');
assert.equal(s.hasBridge, true, 'preload bridge window.wave must exist');
assert.equal(s.nodeLeak, false, 'zero node exposure: no require/process in page');
assert.equal(s.controlPlane, true, 'loopback control plane must answer with the live key');
console.log('PASS: port=' + s.port + ' title=' + JSON.stringify(s.title));
" "$SMOKE"

echo "SMOKE PASS: WAVE Monitor paints unpacked on scratch, :7729 untouched"
