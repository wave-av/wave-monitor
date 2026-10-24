#!/bin/sh
# FPC agents run --no-command-eval: the pipeline-upload step must be a repo  # guard:allow BK pipeline keyword, not a repo reference
# script, never an inline command.
#
# Pull requests that change .buildkite/ do not receive WAVE_REGISTRY_READ_TOKEN.
# The full pipeline cannot run there: governance-enforce.sh installs from the
# private package registry. Those builds upload the secret-free self-check.
# This script only fetches the public base ref and uploads a checked-in file.
set -eu

pipeline=.buildkite/pipeline.yml
pr="${BUILDKITE_PULL_REQUEST:-false}"
case "$pr" in
  "" | false) ;;
  *)
    base="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-main}"
    git fetch --no-tags origin "$base"
    # Differences from the base tip mean this pull request edits .buildkite/.
    if ! git diff --quiet "FETCH_HEAD...HEAD" -- .buildkite; then
      pipeline=.buildkite/pipeline-pr-self-check.yml
      echo "pull request changes .buildkite; uploading secret-free self-check"
    fi
    ;;
esac

exec buildkite-agent pipeline upload "$pipeline"
