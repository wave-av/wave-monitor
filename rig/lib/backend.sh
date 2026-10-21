# rig/lib/backend.sh — sourced by run.sh. Workdirs, synthetic env, step execution.
# Expects RIG_DIR set. No output on source.

RIG_SHIMS="$RIG_DIR/tools/shims"
RIG_ANALYSIS="$RIG_DIR/tools/analysis"
RIG_DOCKER_IMAGE="wave-ci-golden-test:local"
RIG_DOCKER_DIGEST="sha256:448db63371bb0cceb0c86b39d64ebc910a615c3d02d6ab0139b03f0f4528c742"
RIG_BACKEND="${RIG_BACKEND:-auto}"

rig_workdir() {
  local w
  w="$(mktemp -d "${TMPDIR:-/tmp}/r1rig.XXXXXX")" || {
    echo "rig_workdir: mktemp failed" >&2
    return 2
  }
  mkdir -p "$w/co" "$w/tmp" "$w/results" || {
    echo "rig_workdir: cannot create workdir dirs under $w" >&2
    rm -rf "$w"
    return 2
  }
  echo "$w"
}

rig_canary() {
  # rig_canary KIND -> RIGCANARY-KIND-<8 lowercase hex>. Synthetic, kind-only.
  local kind="$1" hex
  hex="$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "RIGCANARY-${kind}-${hex}"
}

# rig_step_env KIND GPR_CANARY GH_CANARY — prints NUL-safe VAR=value lines for
# env -i / docker -e consumption. KIND: fork | same | nonpr.
rig_step_env() {
  local kind="$1" gpr="$2" gh="$3"
  printf '%s\n' "BUILDKITE_ORGANIZATION_SLUG=wave-av-synth"
  printf '%s\n' "BUILDKITE_PIPELINE_SLUG=wave-monitor"
  printf '%s\n' "BUILDKITE_BUILD_NUMBER=RIG-1"
  printf '%s\n' "BUILDKITE_COMMIT=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  printf '%s\n' "BUILDKITE_REPO=https://github.com/wave-av/wave-monitor.git"
  case "$kind" in
    fork)
      printf '%s\n' "BUILDKITE_BRANCH=r1-fork-attack"
      printf '%s\n' "BUILDKITE_PULL_REQUEST=119"
      printf '%s\n' "BUILDKITE_PULL_REQUEST_REPO=https://github.com/rig-attacker/wave-monitor.git"
      printf '%s\n' "BUILDKITE_PULL_REQUEST_BASE_BRANCH=main"
      ;;
    same)
      printf '%s\n' "BUILDKITE_BRANCH=r1-same-repo-attack"
      printf '%s\n' "BUILDKITE_PULL_REQUEST=120"
      printf '%s\n' "BUILDKITE_PULL_REQUEST_REPO=https://github.com/wave-av/wave-monitor.git"
      printf '%s\n' "BUILDKITE_PULL_REQUEST_BASE_BRANCH=main"
      ;;
    nonpr)
      printf '%s\n' "BUILDKITE_BRANCH=main"
      ;;
    *)
      echo "rig_step_env: bad KIND '$kind' (want fork|same|nonpr)" >&2
      return 2
      ;;
  esac
  if [ -n "$gpr" ]; then printf '%s\n' "GUARD_PRIVATE_REPOS=$gpr"; fi
  if [ -n "$gh" ]; then printf '%s\n' "GH_PACKAGES_READ_TOKEN=$gh"; fi
  return 0
}

rig_docker_ok() {
  [ "$RIG_BACKEND" = "local" ] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  docker info >/dev/null 2>&1 || return 1
  local id
  id="$(docker image inspect --format '{{.Id}}' "$RIG_DOCKER_IMAGE" 2>/dev/null)" || return 1
  [ "$id" = "$RIG_DOCKER_DIGEST" ] || return 1
  return 0
}

# rig_pick_backend NEEDS_RG -> prints docker|local, or returns 1 with reason.
rig_pick_backend() {
  local needs_rg="$1"
  if [ "$needs_rg" = "yes" ]; then
    if [ "$RIG_BACKEND" = "docker" ]; then
      echo "pinned image lacks rg; fixture needs real rg" >&2
      return 1
    fi
    command -v rg >/dev/null 2>&1 || { echo "rg required but missing" >&2; return 1; }
    echo "local"
    return 0
  fi
  if [ "$RIG_BACKEND" = "local" ]; then echo "local"; return 0; fi
  if rig_docker_ok; then echo "docker"; return 0; fi
  if [ "$RIG_BACKEND" = "docker" ]; then
    echo "docker backend requested but unavailable/pin-mismatch" >&2
    return 1
  fi
  echo "local"
}

# rig_run_local CHECKOUT REL OUTFILE ENVFILE NODEPV SHIMLOG CAPDIR
rig_run_local() {
  local co="$1" rel="$2" out="$3" envfile="$4" nodepv="$5" shimlog="$6" cap="$7"
  local -a evars
  mapfile -t evars < "$envfile"
  : > "$shimlog"; mkdir -p "$cap"
  ( cd "$co" && env -i \
      "PATH=$RIG_SHIMS:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
      "HOME=$co" "TMPDIR=$RIG_WORK/tmp" \
      "RIG_SHIMLOG=$shimlog" "RIG_CAPTURE_DIR=$cap" \
      "RIG_NODE_P_OUTPUT=$nodepv" \
      "${evars[@]}" \
      bash "$rel" >"$out" 2>&1 )
  return $?
}

# rig_run_docker CHECKOUT REL OUTFILE ENVFILE NODEPV SHIMLOG CAPDIR
rig_run_docker() {
  local co="$1" rel="$2" out="$3" envfile="$4" nodepv="$5" shimlog="$6" cap="$7"
  local res="$cap" # per-fixture results dir (never shared across fixtures)
  : > "$shimlog"; mkdir -p "$cap"
  local -a eflags=(
    -e "PATH=/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    -e "HOME=/co" -e "TMPDIR=/tmp"
    -e "RIG_SHIMLOG=/results/shim.log" -e "RIG_CAPTURE_DIR=/results"
    -e "RIG_NODE_P_OUTPUT=$nodepv"
  )
  while IFS= read -r line; do eflags+=(-e "$line"); done < "$envfile"
  docker run --rm --network none \
    -v "$co:/co:ro" -v "$RIG_SHIMS:/shims:ro" -v "$res:/results:rw" \
    -w /co "${eflags[@]}" "$RIG_DOCKER_IMAGE" \
    bash "$rel" >"$out" 2>&1
  local rc=$?
  [ -f "$res/shim.log" ] && cp "$res/shim.log" "$shimlog"
  # uploaded-pipeline.yml already lands in $cap via the /results mount.
  return $rc
}

rig_gov_version() {
  # Parse GOV_VERSION="x" from the governance script under test (fail closed).
  grep -Eo 'GOV_VERSION="[0-9][^"]*"' "$1" | head -1 | cut -d'"' -f2
}
