#!/bin/bash
# brand-proof.sh — static brand assertions: the app carries its own identity
# (never the template's or a sibling's) in package.json, the bundle config,
# the icon slots, the IPC channels, and — when release/ exists — the
# shipped artifacts. Pattern from the template's brand-proof.sh.
set -uo pipefail

cd "$(dirname "$0")/.."
fail=0
check() { # check <desc> <command...> — records but never aborts
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok: $desc"; else echo "FAIL: $desc"; fail=1; fi
}
check_str() { # check_str <desc> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok: $1 ($2)"; else echo "FAIL: $1 — got [$2] want [$3]"; fail=1; fi
}

PKG_NAME="$(node -p "require('./package.json').name")"
PKG_VERSION="$(node -p "require('./package.json').version")"
PRODUCT="$(node -p "require('./package.json').build.productName")"
APP_ID="$(node -p "require('./package.json').build.appId")"
FEED="$(node -p "require('./package.json').build.publish.url")"
ICON="$(node -p "require('./package.json').build.mac.icon")"

check_str "package name" "$PKG_NAME" "wave-monitor"
check_str "package version" "$PKG_VERSION" "0.1.0"
check_str "productName" "$PRODUCT" "WAVE Monitor"
check_str "appId" "$APP_ID" "online.wave.monitor"
check_str "update feed" "$FEED" "https://updates.wave.online/wave-monitor"
case "$FEED" in https://*) echo "ok: update feed is https";; *) echo "FAIL: update feed must be https (got $FEED)"; fail=1;; esac

check "icon slot $ICON exists" test -f "$ICON"
MAGIC="$(head -c 4 "$ICON" 2>/dev/null || true)"
check_str "icon slot magic" "$MAGIC" "icns"
check "icon master resources/icon.png exists" test -f "resources/icon.png"

check "preload exposes window.wave.updates" grep -q "updates" src/preload/index.ts
check "shared IPC carries update channels" grep -q "wave:monitor:update-status" src/shared/channels.ts
check "shared ipc re-exports the channel map" grep -q "from './channels'" src/shared/ipc.ts
check "updater points at the feed" grep -q "https://updates.wave.online/wave-monitor" src/main/updater/updater.ts
check "control plane defaults to :7729" grep -q "7729" src/main/control-plane/index.ts

if ls release/*.dmg >/dev/null 2>&1; then
  DMG="$(ls -t release/*.dmg | head -1)"
  case "$DMG" in *"WAVE Monitor"*"0.1.0"*) echo "ok: dmg carries product+version ($DMG)";; *) echo "FAIL: dmg name must carry product+version ($DMG)"; fail=1;; esac
  APP_PLIST="release/mac-arm64/WAVE Monitor.app/Contents/Info.plist"
  check "shipped Info.plist exists" test -f "$APP_PLIST"
  if [ -f "$APP_PLIST" ]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP_PLIST" 2>/dev/null || true)"
    check_str "shipped bundle id" "$BUNDLE_ID" "online.wave.monitor"
  fi
fi

[ $fail -eq 0 ] && echo "BRAND-PROOF PASS: every surface says WAVE Monitor"
exit $fail
