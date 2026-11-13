#!/usr/bin/env bats
# WAVE-32956: a pull-request-side edit cannot change the gitleaks verdict. The cases and the
# fixture live in upload-trusted-guard.test.sh (shared with wave-codec-edge); this runs it.
# Needs bash, git, curl, sha256sum (the guard downloads its pinned gitleaks).

@test "PR-side edits to pipeline.yml, the guard, .gitleaks.toml or GITLEAKS_BIN do not change the gitleaks verdict" {
  run bash "$BATS_TEST_DIRNAME/upload-trusted-guard.test.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: a PR-side edit does not change the gitleaks verdict"* ]]
}
