# R2 absence probes — promotion plan (WAVE-26519, epic WAVE-26503)

Status as of 2026-10-20: REPORT MODE. The three `probe-*` steps in
`.buildkite/pipeline.yml` soft-fail FLAG (exit 1) only: a FLAG annotates the
build but never breaks it, while internal errors (exit 2) still fail it.
This file is the dated plan to build-failing mode (acceptance criterion 5).

## What the probes are

Fail-closed detectors asserting no secret material is observable in
fork-shaped builds (KINDs only, never values, everywhere):

- `probe-absence-env` — zero-injection allowlist assertion on env NAMES.
  Runs on `fpc-isolated-secrets` with NOTHING mapped to its step key: the
  secrets queue is where injection happens, so it is the only queue where
  asserting absence is non-vacuous.
- `probe-absence-fs` — workspace + tmp + npm-cache scan with the vendored
  inspector value-shape families (`secret-value`, `nda-term`, `nda-pattern`).
- `probe-absence-log` — workspace-reachable log/artifact KIND scan.

Probes receive zero injection, and fork builds never trigger on venue
pipelines (no base-revision checkout exists — WAVE-27333); both are host
controls (README runbook) proven by R1 fixtures, not by
files in this repo. Detector tables are vendored into
`.buildkite/scripts/absence-scanner.mjs` (sync date 2026-10-20); the NAME
families (`secret-assignment`, `secret-name`) are env-population only after
measured false positives on file trees — see the scoping note in the scanner.

## Gates to failing mode

- [ ] P0 — STACKED. This branch (`feat/absence-probes-r2`) lands AFTER S1/S2
  (`ci/bk-full-parity`, PR #119). Owner: parent lane. Due: at S1/S2 merge.
- [ ] P1 — HOST CONTROLS LIVE. Base-revision checkout STRUCK (does not exist
  in the host, WAVE-27333 — documented instead of built); P1 now verifies
  (a) fork builds never trigger (provider flags, API-verified on all 12
  fleet pipelines) + (b) zero-injection mapping (no values for any probe
  key) by probe receipts. Owner: host/parent. Review: 2026-10-27.
- [ ] P2 — NDA-TERM CHANNEL. Host mounts a versioned denylist cache the
  probes read via `ABSENCE_PROBE_TERMS_FILE`; until then the family reports
  unscanned (a note in report mode, a fail-closed FAIL in enforcing mode).
  Owner: host/parent. Due: 2026-11-03.
- [ ] P3 — LOG-TAIL REDACTION. Probes cover workspace-reachable logs; the
  Buildkite job-log tail stays a host control (a step cannot read its own
  tail without API credentials, which would violate zero-injection).
  Owner: host. Due: 2026-11-03, or an explicitly accepted residual with a
  new date — never silent.
- [ ] P4 — GATING PROBE-KEY EXEMPTION. On the stacked pipeline, S2's
  `pipeline-gating.py` checks 3b/4 classify `probe-absence-env` as
  secret-bearing by queue and demand guard gating. Probes must run UNGATED
  (gating them on guards blinds them exactly when guards fail); they are
  zero-injection BY CONSTRUCTION — the host maps nothing to `probe-*` keys
  and probe-env self-verifies every run. Exempt `probe-*` keys from the
  secret-bearing set (one-line heuristic change, owned by the S1/S2 lane).
  Due: at stack time, before the stacked pipeline merges.

## The flip

When P0–P4 are all closed AND the probes have 7 consecutive green cycles
(real builds + R1 rig runs; FLAGs only on true positives): delete the three
`soft_fail` blocks in `.buildkite/pipeline.yml` (one commit). No script
change needed — the probes already exit 1 on FLAG, 2 on internal error.
Earliest flip: 2026-10-27 (P1 review). Hard backstop: the flip rides with the
S4 re-verdict — per-case OKs stay until S4 is all-PASS either way, so probes
failing earlier than S4 is allowed but not required.

## Accepted residuals (tracked, not silent)

- Files over the size cap (default 1 MiB) are COUNTED, not scanned —
  evasion needs a >1 MiB carrier. Revisit the cap at P1.
- `node_modules/` is excluded (registry supply-chain residual, accepted on
  the epic); `.git/` and the guard's own docs dir are excluded with counts.
- Non-PR builds cannot prove fork-shape from URL vars (R1 fixture (e) OPEN);
  probes note it and treat them as trusted.
- Literal same-agent post-step observation needs a host post-command hook;
  the pipeline step scans its own checkout + agent-local tmp/caches, and the
  R1 rig wires the literal post-step in-container.
