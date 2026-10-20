# R1 adversarial fork-PR drill rig (WAVE-26518)

Checked-in hermetic rig proving fork-shaped PRs cannot reach secret-bearing
execution — and documenting exactly where the current config still lets them
through. Epic: WAVE-26503 (public-repo leak guarantee).

## Run

```sh
./rig/run.sh                  # full matrix: current config + patched (a) proof
./rig/run.sh --config current # current config only (acceptance 3)
./rig/run.sh --config patched # patched (a) base-revision proof only (acceptance 4)
./rig/run.sh --fixture c      # single fixture (a|b|c|d|e|f)
./rig/selftest.sh             # harness self-test (shims, redaction, scheduler)
```

Machine receipts go to stdout as JSON lines; the human summary goes to stderr.
Exit 0 = no DENY-violation and no harness error. Exit 1 = at least one
expected=DENY fixture actually EXECUTED. Exit 2 = harness error (fail closed:
an inconclusive fixture never reads as DENY) or a documented OPEN residual
observed DENY (hardened — update rig expectations).

Current config is EXPECTED to exit 1: fixtures (a)/(b)/(c)/(f) fail exactly,
(d)/(e) document OPEN. The rig turns green as S1/S2+L1/L2 land.

## Fixtures

| fix | attack | expected (current) | proves |
|-----|--------|-------------------|--------|
| (a) | fork poisons scripts/public-repo-guard/content-policy.sh to print env | DENY | I1: secret env must not reach PR-checkout code |
| (b) | fork deletes fork-refusal blocks | DENY | S1 text is fork-deletable without base-revision checkout |
| (c) | fork rewrites pipeline.yml steps/queues | DENY | pipeline upload must pin/validate, not trust checkout |
| (d) | same-repo branch PR with attacker code (control) | OPEN | URL checks pass; needs identity gating (residual) |
| (e) | non-PR build, unset PR env, fork code present | OPEN | refusal skipped; needs fail-closed default (residual) |
| (f) | guards failing; secret steps must never start | DENY | guards need wait/depends_on, not just position (S2) |

Verdict semantics: DENY = positive evidence of refusal or clean completion
with the canary absent from step output. EXECUTED = canary in output, or the
script proceeded past the refusal point (shim log non-empty / post-refusal
markers), or the scheduler start-set includes a secret step with guards
failed. OPEN = executed shape on an accepted-residual path (epic WAVE-26503
KNOWN RESIDUAL). Anything else = ERROR (fail closed).

## Hermeticity

- Real step scripts from the pinned snapshot (see PROVENANCE), synthetic
  BUILDKITE_* env, synthetic canary secrets redacted from receipts.
- Execution backends: `docker` (pinned image, `--network none`, read-only
  checkout mount) where the image carries the needed tools, else `local`
  (PATH shims shadow every network-touching tool). Receipts record the backend.
- No live credentials anywhere; no network access by construction.

## Hardening links (residuals)

- (d) same-repo branches: needs identity gating — epic WAVE-26503 residual.
- (e) non-PR builds: needs fail-closed default — epic WAVE-26503 residual.
- (f) guard gating: S2 WAVE-26506 must add wait/depends_on (redteam R-d).
- Durable guarantee: L1 WAVE-26516 lint + L2 WAVE-26517 template injection.
