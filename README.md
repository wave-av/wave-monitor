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
  Ported from the create-wave-app electron template. <!-- # guard:allow electron template attribution -->
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
fpc-isolated agents run with `--no-command-eval`, so never inline commands. <!-- # guard:allow BK pipeline keyword, not a repo reference -->
Pull requests that change `.buildkite/` do not receive `WAVE_REGISTRY_READ_TOKEN`.
`.buildkite/upload.sh` uploads `.buildkite/pipeline-pr-self-check.yml` for
those builds: bats, shellcheck, and `guard-content-policy-pr` (see below) on
`fpc-isolated`, with no secret. Other builds still upload `pipeline.yml`.
"Changes `.buildkite/`" is measured against the pipeline's default branch
(`BUILDKITE_PIPELINE_DEFAULT_BRANCH`), never the pull request's base branch,
which the author picks; an unset or invalid default branch exits 2.
`upload.sh` also refuses (exit 2) to upload a pipeline file that lacks its
content-policy step (`guard-content-policy` in `pipeline.yml`,
`guard-content-policy-pr` in the self-check).

Host-side setup (not expressible in `pipeline.yml` — this section is the
pointer target):

- **Queues.** All steps run on `fpc-isolated`, except
  `guard-content-policy` and `probe-absence-env`, which run on
  `fpc-isolated-secrets` (the only queue allowed host-injected values; the
  env probe rides it to assert absence where injection happens).
- **Host-injected values, by step key** (never inline in the pipeline file;
  each name must be in this repo's `repos.yaml` `secrets` allowlist):
  - `guard-content-policy`: `GUARD_PRIVATE_REPOS` — comma/space-separated
    private repo/product names for the private-repo rule. The wrapper fails
    closed when it is unset/empty; local callers should run
    `scripts/public-repo-guard/content-policy.sh` directly (rule stays
    optional there). Durable host path (T1/WAVE-27030): the 512B-per-value
    secrets channel carries the list as `GUARD_PRIVATE_REPOS_01.._06`
    (Doppler `wave`/`bkjobs`, granted by step key in the host
    `secrets-allowlist.tsv`); the wrapper assembles them when the full var
    is unset and fails closed unless all six are present. Pull-request
    builds do not receive the list. The non-secret `WAVE_JOB_GUARD_PR=1` is
    set only by the pull-request step `guard-content-policy-pr` (in
    `pipeline-pr-self-check.yml`, queue `fpc-isolated`).
    `.buildkite/scripts/guard-content-policy.sh` and
    `scripts/public-repo-guard/content-policy.sh` then run every rule except
    private-repo, and only when `BUILDKITE_PULL_REQUEST` is a positive
    pull-request number and `GUARD_PRIVATE_REPOS` / `GUARD_PRIVATE_REPOS_01`..`_06`
    are all unset. If the flag is set and any of those names is set (including
    empty), both scripts exit 2 and leave the list in place: that list is not
    part of a pull-request build, so both together means the job environment
    was overridden and the private-repo rule must not be skipped. The same flag
    when `BUILDKITE_PULL_REQUEST` is empty, `false`, or not a number fails
    closed (exit 2), so a default-branch build cannot drop the rule. With the
    flag unset, a missing list still fails closed. Any other non-empty flag
    value exits 2. PR mode is not a private-name clearance: both scripts log
    `private-repo rule NOT checked (PR mode, no list)`, including on the
    final verdict line.
- **Trusted content policy on pull requests (WAVE-28333 M1).** In PR mode the
  wrapper never runs the pull request's policy. It fetches
  `refs/heads/$BUILDKITE_PIPELINE_DEFAULT_BRANCH` and runs that branch's
  `scripts/public-repo-guard/content-policy.sh` and `.guardignore` against a
  copy of the pull-request tree (data only, `.git` excluded). Inline
  `# guard:allow` markers are ignored in PR mode, since they are pull-request
  content, and the copy's `.ignore`, `.rgignore` and `.gitignore` files are
  deleted (MF-W1); the policy also scans with `rg --no-ignore`, so the
  built-in excludes plus the default branch's `.guardignore` are the only
  exclusion source. A missing or invalid default branch, a failed fetch, or a default
  branch without the policy exits 2; nothing falls back to the pull
  request's copy. Once the default branch's wrapper carries the line
  `# guard-content-policy trusted-pr-runner: v1`, the pull request's wrapper
  re-execs that copy instead of running these steps itself. Until then
  (bootstrap, i.e. the pull request that adds the line) the pull request's
  wrapper runs them, still with the default branch's policy. **Residual:**
  a Buildkite step's command is always a checkout script
  (`--no-command-eval`), and `upload.sh` is checkout code too, so a pull
  request that edits `.buildkite/` can still change the wrapper or drop the
  step. Closing that needs a host-side anchor (a host-owned uploader or a
  step rendered from host-side CI code) plus a required status check on
  `main` (M2).
- **Registry proxy (governance-enforce, WAVE-30138).** `governance-enforce`
  gets no host-injected value and runs on `fpc-isolated` for every build.
  It installs the pinned `@wave-av/governance` through the host-side registry
  proxy on loopback (default `http://127.0.0.1:4873/`, override with the
  non-secret `WAVE_JOB_REGISTRY_PROXY_URL`; only `http://127.0.0.1:<port>/` or
  `http://localhost:<port>/` is accepted). The proxy is read-only, serves the
  `@wave-av` scope only and holds its credential on the host. The job-local
  npmrc has no auth line, and node and npm run under `env -i` with an
  explicit allowlist (PATH, a job-local HOME/TMPDIR/npm cache, pinned npm
  config, loopback NO_PROXY, outbound proxy URLs only without userinfo), so
  no job variable reaches them. The proxy URL is matched as a whole string,
  so an embedded newline cannot smuggle a second URL. The tarball is fetched
  from the proxy, checked against the pinned sha512 integrity (and the
  packument's `dist.integrity`), and installed from the verified local file.
  If the proxy is missing, does not serve the pinned version, or serves bytes
  that do not match, the step fails closed with exit 2. The repo is public, so it has
  no secrets-allowlist row for this step.
- **Fork trust.** The secrets-queue steps consume host credentials, so the
  host must (a) run them from the **trusted base ref** as a base-branch build
  — re-running the fork build itself keeps fork metadata
  (`BUILDKITE_PULL_REQUEST_REPO` still points at the fork) so the guards
  still refuse it, (b) **withhold injection** for fork builds, and (c) require
  a manual **approval gate** before any trusted re-run of a fork PR. Both
  `governance-enforce.sh` and `guard-content-policy.sh` refuse when the
  normalized head/pipeline identities differ (host/owner/name comparison —
  SSH-vs-HTTPS or case variants of the same repository proceed; malformed
  or empty identities refuse).
  `guard-gitleaks.sh` likewise never trusts PR-head rules: PR builds scan
  the checkout with the canonical `.gitleaks.toml` from the merge-base
  with the base branch (WAVE-27332).
- **Pipeline settings.** Enable "Cancel intermediate builds" (the GHA
  `concurrency` / `cancel-in-progress` equivalent).

## Absence probes (R2 fork-build tripwires)

Three absence probes watching fork-shaped builds (WAVE-26519, epic
WAVE-26503), currently report-mode: FLAGs annotate, internal errors fail the
build, and promotion to build-blocking follows PROMOTION.md. KINDs only,
never values — findings carry paths + KINDs, receipts carry env NAMES,
nothing else.

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
  every run (a FLAG naming a pipeline secret on a fork build means the host
  failed to withhold; generic unexpected-name FLAGs are allowlist tuning,
  not withholding failures).
- **No fork builds on venue pipelines.** There is NO base-revision checkout
  in the host (WAVE-27333: searched end to end, stock BK checks out the
  triggering commit) — and none is needed: `build_pull_request_forks=false`
  (API-verified on all 12 fleet pipelines) means fork builds never trigger,
  so a fork cannot neuter the detectors it is observed by. Backstopped by
  zero injection for fork-shaped builds plus in-script refusal. Until the
  provider flags are re-verified in venue (PROMOTION.md P1), fork-observable
  probe behavior is advisory, not proof.
- **Ungated.** Probe steps carry no `depends_on` and sit in no wait-segment
  shadow: gating them on guards would blind them exactly when guards fail.
  (Stacking note: S2's `pipeline-gating.py` needs the `probe-*` exemption
  in PROMOTION.md P4.)
## License

[Apache-2.0](./LICENSE). No vendor-licensed binaries; all rendering uses standard
WebRTC + Web Audio APIs.

---

<!-- wave-standard-footer -->
<sub><b><a href="https://wave.online">wave.online</a></b> &nbsp;·&nbsp; <a href="https://docs.wave.online">Docs</a> &nbsp;·&nbsp; <a href="https://dev.wave.online">Developers</a> &nbsp;·&nbsp; <a href="https://agents.wave.online">For agents</a></sub> <!-- # guard:allow public agents.wave.online URL; guard term matches at dot boundary -->
