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
#
# WAVE-32956: on an untrusted build (a pull request, or any build of a branch other than the
# pipeline default branch) the gitleaks verdict comes from the DEFAULT BRANCH before anything is
# uploaded: this script runs the default branch's guard-gitleaks.sh in its trusted mode with the
# default branch's .gitleaks.toml, and uploads nothing if it fails. That covers pull requests that
# change .buildkite/ (the self-check pipeline has no gitleaks step) and the author-picked PR base.
# A pull request can still edit this file, the configured entry point: residual for Security review.
set -eu

pipeline=.buildkite/pipeline.yml
step=guard-content-policy
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

gl_pr="${BUILDKITE_PULL_REQUEST:-false}"
gl_branch="${BUILDKITE_BRANCH:-}"
gl_default="${BUILDKITE_PIPELINE_DEFAULT_BRANCH:-}"
gl_untrusted=0
case "$gl_pr" in "" | false) ;; *) gl_untrusted=1 ;; esac
if [ -z "$gl_branch" ] || [ "$gl_branch" != "$gl_default" ]; then gl_untrusted=1; fi

if [ "$gl_untrusted" = 1 ]; then
  if [ -z "$gl_default" ] || ! git check-ref-format --branch "$gl_default" >/dev/null 2>&1; then
    echo "BUILDKITE_PIPELINE_DEFAULT_BRANCH is not a valid branch name; failing closed" >&2
    exit 2
  fi
  git -c core.hooksPath=/dev/null fetch --no-tags --quiet origin "+refs/heads/$gl_default:refs/remotes/origin/$gl_default"
  gl_work="$(mktemp -d)"
  trap 'rm -rf "$gl_work"' EXIT
  if ! git show "origin/$gl_default:.buildkite/scripts/guard-gitleaks.sh" > "$gl_work/trusted-guard-gitleaks.sh"; then
    echo "origin/$gl_default has no .buildkite/scripts/guard-gitleaks.sh; failing closed" >&2
    exit 2
  fi
  # The guard's trusted mode keeps this cwd (the checkout root) and, as a PR build, reads
  # .gitleaks.toml from origin/<base>; base is pinned to the default branch here.
  # A same-repo branch build is handled as a pull request too, so the config also comes from base.
  case "$gl_pr" in "" | false) pr_mark="untrusted-branch-build" ;; *) pr_mark="$gl_pr" ;; esac
  unset GITLEAKS_BIN
  # Pin the config too: with no .gitleaks.toml on the default branch the guard passes no --config,
  # and gitleaks would then read the worktree's (PR-controlled) .gitleaks.toml on its own.
  if git cat-file -e "origin/$gl_default:.gitleaks.toml" 2>/dev/null; then
    git show "origin/$gl_default:.gitleaks.toml" > "$gl_work/default.gitleaks.toml"
  else
    printf '[extend]\nuseDefault = true\n' > "$gl_work/default.gitleaks.toml"
  fi
  GITLEAKS_CONFIG="$gl_work/default.gitleaks.toml"
  export GITLEAKS_CONFIG
  echo "--- :key: gitleaks verdict from origin/$gl_default (WAVE-32956)"
  if ! BUILDKITE_PULL_REQUEST="$pr_mark" BUILDKITE_PULL_REQUEST_BASE_BRANCH="$gl_default" \
    bash "$gl_work/trusted-guard-gitleaks.sh" --trusted-work "$gl_work"; then
    echo "gitleaks (default-branch guard and config) failed; uploading nothing" >&2
    exit 1
  fi
fi

# Never upload a pipeline without its content-policy step.
if ! grep -qE "^[[:space:]]+key:[[:space:]]+${step}[[:space:]]*$" "$pipeline"; then
  echo "$pipeline has no '$step' step; refusing to upload" >&2
  exit 2
fi

exec buildkite-agent pipeline upload "$pipeline"
