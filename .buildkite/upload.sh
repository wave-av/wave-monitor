#!/bin/sh
# FPC agents run --no-command-eval: the pipeline-upload step must be a repo  # guard:allow BK pipeline keyword, not a repo reference
# script, never an inline command.
#
# Pull requests that change .buildkite/ do not receive WAVE_REGISTRY_READ_TOKEN.
# The full pipeline cannot run there: governance-enforce.sh installs from the
# private package registry. Those builds upload the secret-free self-check,
# which carries the PR content-policy step (WAVE-28333 M1).
# The comparison is against the pipeline's default branch
# (BUILDKITE_PIPELINE_DEFAULT_BRANCH), never BUILDKITE_PULL_REQUEST_BASE_BRANCH:
# the pull-request author picks the base. This script only fetches that public
# ref and uploads a checked-in file.
set -eu

pipeline=.buildkite/pipeline.yml
step=wm-content-policy
pr="${BUILDKITE_PULL_REQUEST:-false}"
case "$pr" in
  "" | false) ;;
  *)
    default="${BUILDKITE_PIPELINE_DEFAULT_BRANCH:-}"
    if [ -z "$default" ] || ! git check-ref-format --branch "$default" >/dev/null 2>&1; then
      echo "BUILDKITE_PIPELINE_DEFAULT_BRANCH is not a valid branch name; failing closed" >&2
      exit 2
    fi
    git -c core.hooksPath=/dev/null fetch --no-tags origin "refs/heads/$default"
    # Differences from the default-branch tip mean this pull request edits .buildkite/.
    if ! git diff --quiet "FETCH_HEAD...HEAD" -- .buildkite; then
      pipeline=.buildkite/pipeline-pr-self-check.yml
      step=guard-content-policy-pr
      echo "pull request changes .buildkite; uploading secret-free self-check"
    fi
    ;;
esac

# Never upload a pipeline without its content-policy step.
if ! grep -qE "^[[:space:]]+key:[[:space:]]+${step}[[:space:]]*$" "$pipeline"; then
  echo "$pipeline has no '$step' step; refusing to upload" >&2
  exit 2
fi

exec buildkite-agent pipeline upload "$pipeline"
