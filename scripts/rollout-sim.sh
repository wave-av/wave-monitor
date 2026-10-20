#!/bin/bash
# rollout-sim.sh — staged-rollout simulation against a LOCAL feed. Bundles
# the real src/main/updater/rollout-guard.ts (via the declared esbuild
# devDependency — never transitive hoisting) and sweeps it across rollout
# fractions served by scripts/local-feed.mjs:
#   - fraction 0 admits nobody; fraction 1 admits everybody
#   - fraction 0.25/0.5 admit ~that share over 2000 machines (±5pp)
#   - a version the manifest does not pin is refused
#   - an unreachable feed fails closed
# Dry-run only: nothing publishes, nothing tags. See RELEASE-CHECKLIST.md.
set -euo pipefail

cd "$(dirname "$0")/.."
WORK="$(mktemp -d /tmp/wave-monitor-rollout.XXXXXX)"
trap 'kill ${FEED_PID:-} 2>/dev/null || true; rm -rf "$WORK"' EXIT

echo "== bundle the real rollout guard"
./node_modules/.bin/esbuild src/main/updater/rollout-guard.ts --bundle --platform=node --format=cjs \
  --outfile="$WORK/rollout-guard.cjs" --log-level=error
node -e "const g = require('$WORK/rollout-guard.cjs'); console.log('guard buckets=' + g.BUCKETS)"

serve() { # serve <version> <rollout> — writes feed url to $WORK/feed.url, sets FEED_PID
  rm -f "$WORK/feed.json"
  node scripts/local-feed.mjs --version "$1" --rollout "$2" >"$WORK/feed.json" 2>"$WORK/feed.err" &
  FEED_PID=$!
  for _ in $(seq 1 100); do
    [ -s "$WORK/feed.json" ] && break
    sleep 0.1
  done
  [ -s "$WORK/feed.json" ] || { echo "FAIL: local feed did not print its url"; cat "$WORK/feed.err"; exit 1; }
  node -e "console.log(JSON.parse(require('fs').readFileSync('$WORK/feed.json','utf8')).url)" >"$WORK/feed.url"
}

sweep() { # sweep <feed-url> <version> <fraction> — prints admit rate over 2000 machines
  node -e "
const guard = require('$WORK/rollout-guard.cjs');
(async () => {
  const [url, version] = process.argv.slice(1);
  let hits = 0;
  const N = 2000;
  for (let i = 0; i < N; i++) {
    const r = await guard.rolloutAllows({ feedUrl: url, version, machineId: 'sim-' + i });
    if (r.allowed) hits++;
  }
  console.log((hits / N).toFixed(4));
})();
" "$1" "$2"
}

check_rate() { # check_rate <fraction> <got> — |got-fraction| <= 0.05
  node -e "
const want = Number(process.argv[1]), got = Number(process.argv[2]);
if (Math.abs(got - want) > 0.05) { console.error('FAIL: fraction ' + want + ' admitted ' + got); process.exit(1); }
console.log('ok: fraction ' + want + ' admitted ' + got);
" "$1" "$2"
}

echo "== fraction 0 admits nobody"
serve 0.2.0 0; URL="$(cat "$WORK/feed.url")"; RATE="$(sweep "$URL" 0.2.0)"; kill "$FEED_PID" 2>/dev/null || true
check_rate 0 "$RATE"

echo "== fraction 1 admits everybody"
serve 0.2.0 1; URL="$(cat "$WORK/feed.url")"; RATE="$(sweep "$URL" 0.2.0)"; kill "$FEED_PID" 2>/dev/null || true
check_rate 1 "$RATE"

for F in 0.25 0.5; do
  echo "== fraction $F admits ~$F"
  serve 0.2.0 "$F"; URL="$(cat "$WORK/feed.url")"; RATE="$(sweep "$URL" 0.2.0)"; kill "$FEED_PID" 2>/dev/null || true
  check_rate "$F" "$RATE"
done

echo "== unpinned version refused"
serve 0.2.0 1; URL="$(cat "$WORK/feed.url")"
node -e "
const guard = require('$WORK/rollout-guard.cjs');
guard.rolloutAllows({ feedUrl: process.argv[1], version: '9.9.9', machineId: 'sim-1' }).then((r) => {
  if (r.allowed || !/version-not-in-rollout/.test(r.reason)) { console.error('FAIL: ' + JSON.stringify(r)); process.exit(1); }
  console.log('ok: refused (' + r.reason + ')');
});
" "$URL"
kill "$FEED_PID" 2>/dev/null || true

echo "== unreachable feed fails closed"
node -e "
const guard = require('$WORK/rollout-guard.cjs');
guard.rolloutAllows({ feedUrl: 'http://127.0.0.1:1/', version: '0.2.0', machineId: 'sim-1' }).then((r) => {
  if (r.allowed || !/no-rollout-manifest/.test(r.reason)) { console.error('FAIL: ' + JSON.stringify(r)); process.exit(1); }
  console.log('ok: closed (' + r.reason + ')');
});
" "$URL"

echo "ROLLOUT-SIM PASS: staged rollout holds against a local feed (dry-run)"
