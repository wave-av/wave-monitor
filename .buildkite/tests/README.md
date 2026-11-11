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
  PR-mode scans use the default branch's policy and `.guardignore` from a
  throwaway origin repo (WAVE-28333 M1): a no-op PR policy, a PR
  `.guardignore`, a PR `# guard:allow` marker, a PR `.ignore` /
  `.rgignore` / `.gitignore` at any depth (MF-W1), or an author-picked base
  branch cannot pass a leak; a missing default branch or policy exits 2.
- Upload selection: `bats .buildkite/tests/upload-pr-pipeline.bats` (needs
  bash + git; pyyaml optional). `upload.sh` compares with the default
  branch, fails closed without one, and never uploads a pipeline file that
  lacks its content-policy step.
- governance-enforce proxy (WAVE-30138):
  `bats .buildkite/tests/governance-enforce-proxy.bats` (needs bash + git;
  node + npm for the fake-proxy cases, which skip without them). Covers
  newline injection and other non-loopback proxy URLs (exit 2 before node
  runs), packument or tarball sha512 not matching the pin (exit 2, npm never
  runs), and `env -i`: job variables never reach node (names checked only).
- S2 guard order + gating proof: `python3 .buildkite/tests/pipeline-gating.py`
  (needs python3 + pyyaml)

Both exit non-zero on failure. They are not wired into `ci.sh`: the FPC
agent image is not known to carry bats/pyyaml, and breaking `node-gates`
on missing test tooling would be worse than no gate. Pull requests that
change `.buildkite/` upload `pipeline-pr-self-check.yml` instead, which
runs `bats .buildkite/tests/*.bats`, shellcheck on `.buildkite/scripts`, and
`guard-content-policy-pr`.
