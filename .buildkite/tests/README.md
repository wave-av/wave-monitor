# .buildkite/tests — pipeline gate tests (WAVE-26503 S1/S2)

Run from the repo root, no repo dependencies:

- S1 fork refusal: `bats .buildkite/tests/guard-content-policy-fork.bats`
  (needs bats; rg optional — without rg the positive controls assert the
  script reaches the rg-missing fail-closed branch instead of the scan).
  The same file covers PR mode (`WAVE_JOB_GUARD_PR=1`): a pull-request
  number with none of the private-repo list variables set skips only that
  rule; the flag together with `GUARD_PRIVATE_REPOS` or any
  `GUARD_PRIVATE_REPOS_01`..`_06` exits 2; the flag on a non-pull-request
  build, and a missing list with the flag unset, both fail closed.
- S2 guard order + gating proof: `python3 .buildkite/tests/pipeline-gating.py`
  (needs python3 + pyyaml)

Both exit non-zero on failure. They are not wired into `ci.sh`: the FPC
agent image is not known to carry bats/pyyaml, and breaking `node-gates`
on missing test tooling would be worse than no gate. Pull requests that
change `.buildkite/` upload `pipeline-pr-self-check.yml` instead, which
runs `bats .buildkite/tests/*.bats` and shellcheck on `.buildkite/scripts`.
