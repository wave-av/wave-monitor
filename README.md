# wave-monitor

**Lightweight audio + video monitor for any WAVE feed.** Paste a feed URL, hit Connect, see signal. Equivalent of NDI Studio Monitor + NDI Audio Monitor, but for WAVE.

Built on `@wave-av/sdk`. ~300 lines of app code. Also a **"Build on WAVE" demo** — what every customer can build on top of the public SDK.

## What it does

- Single window: video preview on the left, dual-channel peak+RMS audio meters on the right
- Paste any `https://api.wave.online/feed/...` URL or stream key
- Connect / Disconnect
- That's it — no encoding, no multiview, no settings. Open it, confirm signal, close it.

## Why this exists

Every operator's first question: "is my stream actually live?" Today the answer involves opening the WAVE web app, signing in, navigating to a dashboard. After wave-monitor ships, the answer is "double-click the WAVE Monitor icon, paste, done."

Also serves as the smallest, cleanest example of building on the WAVE SDK — bundled with every wave-desktop release and shipped standalone at `downloads.wave.online/monitor`.

## Quick start

```sh
git clone https://github.com/wave-av/wave-monitor.git
cd wave-monitor
npm install
npm run dev
```

`npm run dist:mac` produces a `.dmg` (+ `.zip` for auto-update) for arm64 + x64 — signed + hardened-runtime when Developer ID certs are available (release CI); local builds such as `cold-boot.sh` are unsigned.

## Productization (0.1.0 ship)

Second Wave desktop app on the proven path: frameless shell + loopback
control plane + rollout-gated auto-updates. See [RELEASE-CHECKLIST.md](./RELEASE-CHECKLIST.md)
for the nine release gates (`npm run release-check` runs 1–5).

- `src/main/control-plane/` — loopback HTTP API on `127.0.0.1:7729`
  (`WAVE_MONITOR_PORT` overrides): `GET /v1/status`, `GET /v1/version`,
  `POST /v1/monitor/start|stop`. Bearer key in OS safeStorage; same state
  the IPC layer owns. Ported from wave-desktop's control plane.
- `src/main/updater/` — `electron-updater` against
  `https://updates.wave.online/wave-monitor`, gated by a staged-rollout
  check (`rollout.json` pin + stable machine cohort; fails closed).
  Ported from the create-wave-app electron template.
- `scripts/` — `smoke.sh`, `cold-boot.sh`, `brand-proof.sh`,
  `rollout-sim.sh` (+ `local-feed.mjs` stub feed). `--smoke-test` mode in
  main prints one `SMOKE_OK` JSON line and quits.

## Architecture

```text
┌── renderer (CSP-locked) ───────────────────┐
│  React UI:                                  │
│  ┌─ URL bar + Connect ──────────────────┐  │
│  │ <video> + peak/RMS meters             │  │
│  └────────────────────────────────────────┘  │
└────────────────────┬───────────────────────┘
                     │ IPC (Zod-validated)
┌────────────────────▼───────────────────────┐
│  main                                       │
│  · RTCPeerConnection to gateway (W2)        │
│  · AudioWorkletProcessor → peak/RMS         │
└────────────────────┬───────────────────────┘
                     │ WebRTC + JWT (Bearer)
                     ▼
             api.wave.online
```

## Roadmap

| Wave | Surface | Status |
|---|---|---|
| W1 | This scaffold (Electron shell + IPC + meter component) | this PR |
| W2 | Real WebRTC pull from gateway + audio worklet computing peak/RMS @ 20Hz | next |
| W3 | Multi-window: open N monitors simultaneously, drag between displays | pending |
| W4 | Always-on-top toggle + transparent-window mode (overlay use) | pending |

## Absence probes (R2 fork-build tripwires)

Three fail-closed probes asserting no secret material is observable in
fork-shaped builds (WAVE-26519, epic WAVE-26503). KINDs only, never values —
findings carry paths + KINDs, receipts carry env NAMES, nothing else.

- `probe-absence-env` (`.buildkite/scripts/probe-absence-env.mjs`) —
  zero-injection allowlist assertion on env names. Must run on
  `fpc-isolated-secrets` (the queue where injection happens — anywhere else
  the assertion is vacuous) with NOTHING mapped to its step key.
- `probe-absence-fs` — workspace + tmp + npm-cache scan with the vendored
  inspector value-shape families. Runs on `fpc-isolated`.
- `probe-absence-log` — workspace-reachable log/artifact KIND scan. Runs on
  `fpc-isolated`.

Detector tables are vendored into
`.buildkite/scripts/absence-scanner.mjs` (no cross-repo imports at runtime).
Suite: `npx vitest run .buildkite/tests/absence-scanner.test.mjs` (also under
plain `npm test`). Report-mode wiring + dated promotion plan:
`.buildkite/absence-probes-PROMOTION.md`.

Host-side setup (not expressible in `pipeline.yml` — this section is the
pointer target):

- **Zero injection.** The host maps no injected values to any `probe-*` step
  key, on any queue, on any build. `probe-absence-env` self-verifies this
  every run (its FLAG on a fork build means the host failed to withhold).
- **Base-pinned execution.** The host checks out the trusted base revision
  (not the PR head) for the `probe-*` steps, so a fork cannot neuter the
  detectors it is observed by. Same control the secrets-queue steps need;
  R1 fixtures prove the dependency.
- **Ungated.** Probe steps carry no `depends_on` and sit in no wait-segment
  shadow: gating them on guards would blind them exactly when guards fail.
  (Stacking note: S2's `pipeline-gating.py` needs the `probe-*` exemption
  in PROMOTION.md P4.)

## License

[Apache-2.0](./LICENSE). No vendor-licensed binaries; all rendering uses standard
WebRTC + Web Audio APIs.

---

<!-- wave-standard-footer -->
<sub><b><a href="https://wave.online">wave.online</a></b> &nbsp;·&nbsp; <a href="https://docs.wave.online">Docs</a> &nbsp;·&nbsp; <a href="https://dev.wave.online">Developers</a> &nbsp;·&nbsp; <a href="https://agents.wave.online">For agents</a></sub>
