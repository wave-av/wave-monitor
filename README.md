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

## Buildkite runbook (BK full-parity CI)

`.buildkite/pipeline.yml` mirrors the GHA gates (lint/typecheck/vitest,
foundation checks, governance A_BLOCK, gitleaks + content-policy guards).
Every step's `command` is exactly one checked-in repo script path — the
fpc-isolated agents run with `--no-command-eval`, so never inline commands.

Host-side setup (not expressible in `pipeline.yml` — this section is the
pointer target):

- **Queues.** All steps run on `fpc-isolated`, except `governance-enforce`
  and `guard-content-policy`, which run on `fpc-isolated-secrets` (the only
  queue allowed host-injected values).
- **Host-injected values, by step key** (never inline in the pipeline file;
  each name must be in this repo's `repos.yaml` `secrets` allowlist):
  - `governance-enforce`: `GH_PACKAGES_READ_TOKEN` — a token with GH-Packages
    **read** for the `@wave-av` scope (fine-grained PAT or equivalent). The
    script fails closed when it is absent.
  - `guard-content-policy`: `GUARD_PRIVATE_REPOS` — comma/space-separated
    private repo/product names for the private-repo rule. The wrapper fails
    closed when it is unset/empty; local callers should run
    `scripts/public-repo-guard/content-policy.sh` directly (rule stays
    optional there). Durable host path (T1/WAVE-27030): the 512B-per-value
    secrets channel carries the list as `GUARD_PRIVATE_REPOS_01.._06`
    (Doppler `wave`/`bkjobs`, granted by step key in the host
    `secrets-allowlist.tsv`); the wrapper assembles them when the full var
    is unset and fails closed unless all six are present.
- **Fork trust.** The secrets-queue steps consume host credentials, so the
  host must (a) check out the **trusted base revision** (not the PR head) for
  `governance-enforce` / `guard-content-policy`, (b) **withhold injection**
  for fork builds, and (c) require a manual **approval gate** before any
  trusted re-run of a fork PR. Both `governance-enforce.sh` and
  `guard-content-policy.sh` additionally refuse
  when `BUILDKITE_PULL_REQUEST_REPO != BUILDKITE_REPO`.
- **Pipeline settings.** Enable "Cancel intermediate builds" (the GHA
  `concurrency` / `cancel-in-progress` equivalent).

## License

[Apache-2.0](./LICENSE). No vendor-licensed binaries; all rendering uses standard
WebRTC + Web Audio APIs.

---

<!-- wave-standard-footer -->
<sub><b><a href="https://wave.online">wave.online</a></b> &nbsp;·&nbsp; <a href="https://docs.wave.online">Docs</a> &nbsp;·&nbsp; <a href="https://dev.wave.online">Developers</a> &nbsp;·&nbsp; <a href="https://agents.wave.online">For agents</a></sub>
