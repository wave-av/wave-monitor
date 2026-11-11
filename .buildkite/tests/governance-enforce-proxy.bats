#!/usr/bin/env bats
# WAVE-30138 governance-enforce: loopback registry proxy, fail closed.
# - The proxy URL is matched as a whole string (bash [[ =~ ]]), never per line:
#   an embedded newline cannot smuggle a non-loopback URL past the check.
# - The packument's dist.integrity and the tarball's sha512 must both equal
#   the pinned GOV_INTEGRITY, or the step exits 2 before npm runs.
# - node and npm run under env -i with an allowlist: token-shaped and
#   unknown variables from the job never reach them (names checked only).
# A fake proxy (node http server on 127.0.0.1) stands in for the host proxy;
# node and npm on PATH are wrappers that log variable NAMES, then exec the
# real binaries.
#
# Run: bats .buildkite/tests/governance-enforce-proxy.bats (needs bash + git;
# node + npm for the fake-proxy tests, which skip without them)

setup() {
  TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
  TDIR="$(mktemp -d)"
  REPO="$TDIR/repo"
  mkdir -p "$REPO/.buildkite/scripts" "$TDIR/bin"
  cp "$REPO_ROOT/.buildkite/scripts/governance-enforce.sh" "$REPO/.buildkite/scripts/"
  git init -q "$REPO"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm base
  REAL_NODE="$(command -v node || true)"
  REAL_NPM="$(command -v npm || true)"
  [ -n "$REAL_NODE" ] && [ -n "$REAL_NPM" ] || return 0
  for b in node npm; do
    real="$REAL_NODE"; [ "$b" = npm ] && real="$REAL_NPM"
    cat > "$TDIR/bin/$b" <<STUB
#!/bin/sh
env | sed 's/=.*//' | sort > "$TDIR/env-names.$b.\$\$"
exec "$real" "\$@"
STUB
    chmod +x "$TDIR/bin/$b"
  done
  SERVER_PID=""
}

teardown() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TDIR"
}

# The URL-refusal tests need no node: the script refuses before node runs.
# The fake-proxy tests need node + npm and skip loudly without them.
_need_node() {
  [ -n "$REAL_NODE" ] && [ -n "$REAL_NPM" ] || skip "node/npm not on PATH (fake-proxy tests need node)"
}

# _serve MODE: start a fake proxy. MODE = 404 | badpackument | badtarball.
_serve() {
  _need_node
  "$REAL_NODE" -e '
    const http = require("node:http");
    const mode = process.argv[1];
    const pinned = process.argv[2];
    const tgz = Buffer.from("not the real governance tarball");
    const srv = http.createServer((q, s) => {
      if (mode === "404") { s.writeHead(404); return s.end(); }
      if (q.url === "/@wave-av%2fgovernance") {
        const integrity = mode === "badpackument" ? "sha512-AAAA" : pinned;
        s.writeHead(200, { "content-type": "application/json" });
        return s.end(JSON.stringify({ versions: { "0.4.6": { dist: { integrity } } } }));
      }
      if (q.url === "/@wave-av/governance/-/governance-0.4.6.tgz") { s.writeHead(200); return s.end(tgz); }
      s.writeHead(404); s.end();
    });
    srv.listen(0, "127.0.0.1", () => console.log(srv.address().port));
  ' "$1" "$(_pinned)" > "$TDIR/port" &
  SERVER_PID=$!
  for _ in $(seq 50); do [ -s "$TDIR/port" ] && break; sleep 0.1; done
  PORT="$(cat "$TDIR/port")"
}

_pinned() {
  sed -n 's/^GOV_INTEGRITY="\(sha512-[^"]*\)"$/\1/p' "$REPO_ROOT/.buildkite/scripts/governance-enforce.sh"
}

# _run URL [extra env...]: run the script with a clean, known environment.
_run() {
  local url="$1"; shift
  run env -i "PATH=$TDIR/bin:/usr/local/bin:/usr/bin:/bin" "HOME=$TDIR" \
    "WAVE_JOB_REGISTRY_PROXY_URL=$url" "$@" \
    bash "$REPO/.buildkite/scripts/governance-enforce.sh"
}

# _none GLOB...: fail when any file matches (bats ignores `! cmd` under set -e).
_none() {
  local f
  for f in "$@"; do if [ -e "$f" ]; then echo "unexpected: $f"; return 1; fi; done
}

_assert_url_rejected() {
  _run "$1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"loopback only"* ]]
  _none "$TDIR"/env-names.*   # refused before node/npm ran
}

@test "pinned integrity is a full sha512 SRI (not a placeholder)" {
  [[ "$(_pinned)" =~ ^sha512-[A-Za-z0-9+/]{86}==$ ]]
}

@test "newline injection: evil line then loopback line is rejected" {
  _assert_url_rejected $'http://evil/\nhttp://127.0.0.1:4873/'
}

@test "newline injection: loopback line then evil line is rejected" {
  _assert_url_rejected $'http://127.0.0.1:4873/\nhttp://evil.example/'
}

@test "trailing newline after a loopback URL is rejected" {
  _assert_url_rejected $'http://127.0.0.1:4873/\n'
}

@test "non-loopback and malformed URLs are rejected" {
  for u in 'http://evil.example:4873/' 'https://127.0.0.1:4873/' \
           'http://127.0.0.1:4873' 'http://127.0.0.1:4873/x/' \
           'http://127.0.0.1.evil.example:4873/' 'http://user:pw@127.0.0.1:4873/' \
           'http://127.0.0.1:123456/' 'http://127.0.0.1:/' 'http://[::1]:4873/' \
           ' http://127.0.0.1:4873/' 'http://127.0.0.1:4873/ ' 'http://localhost.:4873/' \
           'http://127.0.0.2:4873/'; do
    _assert_url_rejected "$u"
  done
}

@test "empty override falls back to the default loopback URL" {
  _need_node
  _run ""
  # WAVE_JOB_REGISTRY_PROXY_URL= (empty) uses the default 127.0.0.1:4873,
  # which is not the fake proxy; either way it must not be the URL refusal.
  [ "$status" -eq 2 ]
  [[ "$output" != *"loopback only"* ]]
}

@test "loopback URL passes the check, proxy 404 fails closed" {
  _serve 404
  for host in 127.0.0.1 localhost; do
    _run "http://$host:$PORT/"
    [ "$status" -eq 2 ]
    [[ "$output" != *"loopback only"* ]]
    [[ "$output" == *"failing closed"* ]]
    [[ "$output" == *"HTTP 404"* ]]
  done
}

@test "packument integrity different from the pin fails closed" {
  _serve badpackument
  _run "http://127.0.0.1:$PORT/"
  [ "$status" -eq 2 ]
  [[ "$output" == *"dist.integrity"*"does not match the pinned sha512"* ]]
}

@test "tarball bytes that do not hash to the pin fail closed, npm never runs" {
  _serve badtarball
  _run "http://127.0.0.1:$PORT/"
  [ "$status" -eq 2 ]
  [[ "$output" == *"tarball sha512 does not match the pinned integrity"* ]]
  _none "$TDIR"/env-names.npm.*
}

@test "node runs under env -i: job variables never reach it (names only)" {
  _serve 404
  _run "http://127.0.0.1:$PORT/" NPM_TOKEN=x GH_TOKEN=x BUILDKITE_AGENT_ACCESS_TOKEN=x \
    NODE_AUTH_TOKEN=x NPM_CONFIG_REGISTRY=http://evil/ npm_config__auth=x \
    SOME_UNLISTED_VAR=x NODE_OPTIONS=--require=/nonexistent HTTPS_PROXY=http://u:p@proxy.example:3128/
  [ "$status" -eq 2 ]
  ls "$TDIR"/env-names.node.* >/dev/null
  run cat "$TDIR"/env-names.node.*
  for n in NPM_TOKEN GH_TOKEN BUILDKITE_AGENT_ACCESS_TOKEN NODE_AUTH_TOKEN \
           NPM_CONFIG_REGISTRY npm_config__auth SOME_UNLISTED_VAR NODE_OPTIONS \
           HTTPS_PROXY WAVE_JOB_REGISTRY_PROXY_URL; do
    if grep -qx "$n" <<<"$output"; then echo "leaked to node: $n"; return 1; fi
  done
  grep -qx NPM_CONFIG_GLOBALCONFIG <<<"$output"
  grep -qx NO_PROXY <<<"$output"
}

@test "a proxy URL without userinfo is passed through to node" {
  _serve 404
  _run "http://127.0.0.1:$PORT/" HTTPS_PROXY=http://proxy.example:3128/
  [ "$status" -eq 2 ]
  run cat "$TDIR"/env-names.node.*
  grep -qx HTTPS_PROXY <<<"$output"
}
