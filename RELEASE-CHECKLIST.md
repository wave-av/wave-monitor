# WAVE Monitor — release checklist (0.1.0)

Productization proof for the second Wave desktop app: frameless Electron
shell + loopback control plane + rollout-gated auto-updates. Every gate
below must be green before a dmg ships. Publish + tag stay **dry-run only**
until the `updates.wave.online/wave-monitor` feed is live.

## Gates (in order)

| # | Gate | Command | What it proves |
|---|------|---------|----------------|
| 1 | types | `npm run type-check` | main + preload + renderer compile |
| 2 | lint | `npm run lint` | zero warnings |
| 3 | unit | `npm test` | control plane (server/router/auth/routes/rotate), rollout guard, updater state machine |
| 4 | brand | `npm run brand-proof` | identity on every surface; shipped dmg/plist when `release/` exists |
| 5 | smoke | `npm run smoke` | unpacked app paints on a scratch port; bridge + control plane answer; `:7729` untouched |
| 6 | cold-boot | `npm run cold-boot` | unsigned dmg mounts; shipped `.app` cold-boots on scratch; no socket to `:7729` |
| 7 | rollout | `npm run rollout-sim` | staged rollout holds against a local feed (0/25/50/100%, pin + fail-closed) |
| 8 | signed dmg | `npm run dist:mac` → `codesign -dv`, `spctl -a` | Developer ID signature + hardened runtime on the shipped binary |
| 9 | publish/tag | **dry-run only** | `electron-builder --publish never`; no git tag; no feed upload |

`npm run release-check` runs gates 1–5 in one shot.

## Architecture (where the pattern lives)

- `src/main/control-plane/` — loopback HTTP API on `127.0.0.1:7729`
  (`WAVE_MONITOR_PORT` overrides; `0` = ephemeral for gates). Bearer key in
  OS safeStorage. Ported from wave-desktop's control plane; routes here are
  `GET /v1/status`, `GET /v1/version`, `POST /v1/monitor/start|stop`.
- `src/main/updater/` — `electron-updater` + staged-rollout gate
  (`rollout-guard.ts`, ported from the create-wave-app electron template).
  Checks download nothing until the feed's `rollout.json` admits this
  machine; downloads never auto-install (`ready` → user restarts).
- Frameless shell: `frame: false` + `.wave-drag` header + app/edit/window
  menu (same pattern as Wave Desk).

## Signing (this box)

- Identity: `Developer ID Application: WAVE Online, LLC (429D888C5J)`.
- `notarize: false` — no Apple API credentials on this box, so 0.1.0 ships
  signed + hardened-runtime but un-notarized (Gatekeeper asks on first
  Finder launch; direct exec works). Flip `notarize` + add `CSC_*` /
  `APPLE_*` creds in CI for the notarized release.
- Verify: `codesign -dv --verbose=4 "release/mac-arm64/WAVE Monitor.app"`
  shows the Developer ID authority + `flags=0x10000(runtime)`;
  `spctl -a -vv` assesses (un-notarized = `rejected` source note, expected).

## Known follow-ups (not gates)

- `resources/icon.*` is the template placeholder mark — final brand art TBD.
- `updates.wave.online/wave-monitor` feed + `latest-mac.yml`/`rollout.json`
  publishing pipeline not yet live (hence dry-run gate 9).
- `wave-desktop-kit` does not exist yet as a shared package; the modules
  here are vendored ports (attributed in-file). Extract the kit when the
  third app lands so all three consume one source.
