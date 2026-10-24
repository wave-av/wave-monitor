# .buildkite/tests — pipeline gate tests (WAVE-26503 S1/S2)

Run from the repo root, no repo dependencies:

- S1 fork refusal: `bats .buildkite/tests/guard-content-policy-fork.bats`
  (needs bats; rg optional — without rg the positive controls assert the
  script reaches the rg-missing fail-closed branch instead of the scan).
  The same file covers PR mode (`WAVE_JOB_GUARD_PR=1`): a pull-request
  number skips only the private-repo rule and passes the flag through to
  the policy script; the flag on a non-pull-request build, and a missing
  list with the flag unset, both fail closed.
- S2 guard order + gating proof: `python3 .buildkite/tests/pipeline-gating.py`
  (needs python3 + pyyaml)

Both exit non-zero on failure. They are not wired into `ci.sh`: the FPC
agent image is not known to carry bats/pyyaml, and breaking `node-gates`
on missing test tooling would be worse than no gate. Wiring belongs to
WAVE-26516 (L1 fail-closed lint).
