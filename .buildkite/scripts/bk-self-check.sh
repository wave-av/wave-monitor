#!/usr/bin/env bash
# Secret-free gate for pull requests that change .buildkite/.
# No private registry, no npm, no Doppler. bats and shellcheck come from
# the agent PATH when the image has them. Otherwise shellcheck is the
# digest-pinned public image, and bats is the digest-pinned bats image's
# program copied onto the agent: that image has no git or curl, and the
# suites need both. If docker is absent, the same versions are taken from
# checksum-pinned public release archives.
set -euo pipefail
cd "$(dirname "$0")/../.."

BATS_IMAGE='bats/bats@sha256:e56e7c49087cb766b1ba9c5732b8f5402d289252d52f64e1eefb88269f74125c'
SHELLCHECK_IMAGE='koalaman/shellcheck@sha256:2097951f02e735b613f4a34de20c40f937a6c8f18ecb170612c88c34517221fb'
BATS_VERSION='1.11.1'
BATS_SHA256='5c57ed9616b78f7fd8c553b9bae3c7c9870119edd727ec17dbd1185c599f79d9'
SHELLCHECK_VERSION='0.10.0'
SHELLCHECK_SHA256='6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

docker_ok() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

fetch_checked() {
  local url="$1" dest="$2" sha="$3"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url"
  echo "$sha  $dest" | sha256sum -c -
}

run_shellcheck() {
  # warning and above. The two info notes in existing scripts are
  # intentional (literal npm token; empty-allowlist cat) and are not this gate.
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=warning .buildkite/scripts/*.sh
    return
  fi
  if docker_ok; then
    local status=0
    docker run --rm --network none -v "$PWD:/work:ro" -w /work \
      "$SHELLCHECK_IMAGE" --severity=warning .buildkite/scripts/*.sh || status=$?
    # 125 is docker itself (daemon or pull). shellcheck findings are 1.
    if [ "$status" -eq 0 ]; then
      return
    fi
    if [ "$status" -ne 125 ]; then
      exit "$status"
    fi
    echo "shellcheck image unavailable; using the pinned release archive"
  fi
  fetch_checked \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    "$WORK/shellcheck.tar.xz" \
    "$SHELLCHECK_SHA256"
  tar -xJf "$WORK/shellcheck.tar.xz" -C "$WORK"
  "$WORK/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" --severity=warning .buildkite/scripts/*.sh
}

run_bats() {
  local bats_bin=""
  if command -v bats >/dev/null 2>&1; then
    bats_bin="$(command -v bats)"
  elif docker_ok; then
    local cid=""
    if cid="$(docker create "$BATS_IMAGE")"; then
      docker cp "$cid:/opt/bats" "$WORK/bats-image"
      docker rm "$cid" >/dev/null
      bats_bin="$WORK/bats-image/bin/bats"
    else
      echo "bats image unavailable; using the pinned release archive"
    fi
  fi
  if [ -z "$bats_bin" ]; then
    fetch_checked \
      "https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz" \
      "$WORK/bats.tar.gz" \
      "$BATS_SHA256"
    tar -xzf "$WORK/bats.tar.gz" -C "$WORK"
    bats_bin="$WORK/bats-core-${BATS_VERSION}/bin/bats"
  fi
  "$bats_bin" .buildkite/tests/*.bats
}

run_shellcheck
run_bats
