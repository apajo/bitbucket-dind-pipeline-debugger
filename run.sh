#!/usr/bin/env bash
# Reproduce one bitbucket-pipelines.yml step locally, following Atlassian's
# "troubleshoot failed pipelines locally with Docker" recipe:
# https://support.atlassian.com/bitbucket-cloud/kb/troubleshoot-failed-bitbucket-pipelines-locally-with-docker/
#
# Extends that recipe with a docker:dind sidecar for steps that declare
# `services: [docker]`, so DOCKER_HOST points at a *separate* daemon the same
# way Bitbucket's own "docker" service does (a sibling container, not the host
# engine) -- including the same memory cap (definitions.services.docker.memory
# in bitbucket-pipelines.yml), since that's the resource budget shared by every
# container the step spawns.
#
# The step's `script:`/`after-script:` are pulled live out of the real YAML
# (see lib/pipeline_step.py) -- nothing here is a hand-copied, driftable
# duplicate of the pipeline.
#
# Usage:
#   ./run.sh --repo <path> "<step name>"          run the step's script, then after-script
#   ./run.sh -C <path> "<step name>" --shell       drop into the agent container instead;
#                                                   /tmp/step-script.sh and /tmp/after-script.sh
#                                                   are there to run by hand
#   ./run.sh --repo <path> --list                  list step names found in the yaml
#   ./run.sh --clean                               remove the sidecar/network/agent
#
# The target repo (whose bitbucket-pipelines.yml you're reproducing) can also
# be given via the REPO_DIR env var instead of --repo/-C; one of the two is
# required.
#
# Config (env vars, or put them in ./secrets.env which is sourced if present):
#   REPO_DIR      local checkout to mount as $BITBUCKET_CLONE_DIR (required; or use --repo/-C)
#   YAML_FILE     pipeline file to read steps from (default: $REPO_DIR/bitbucket-pipelines.yml)
#   BITBUCKET_BRANCH, BITBUCKET_COMMIT, BITBUCKET_REPO_FULL_NAME
#                 default to REPO_DIR's current branch/HEAD and its git remote's owner/repo
#   KEEP=1        leave the dind sidecar + network running after the agent exits
#                 (faster repeat runs; clean up later with ./run.sh --clean)
#
# Any other KEY=value pairs defined in secrets.env are repository variables --
# every one that's non-empty is forwarded into the agent container automatically,
# exactly like an unset Bitbucket repo variable would be (see "Secrets" in README.md).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK=pipe-debug-net
DIND=pipe-debug-dind
AGENT=pipe-debug-agent

[ -f "$HERE/secrets.env" ] && source "$HERE/secrets.env"

while [ "${1:-}" = "--repo" ] || [ "${1:-}" = "-C" ]; do
  REPO_DIR="$2"
  shift 2
done

if [ "${1:-}" = "--clean" ]; then
  docker rm -f "$AGENT" "$DIND" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  echo "removed $AGENT, $DIND, $NETWORK (if they existed)"
  exit 0
fi

REPO_DIR="$(cd "${REPO_DIR:?target repo required: pass --repo <path>/-C <path> or set REPO_DIR}" && pwd)"
YAML_FILE="${YAML_FILE:-$REPO_DIR/bitbucket-pipelines.yml}"
BITBUCKET_CLONE_DIR=/opt/atlassian/pipelines/agent/build

step_field() { python3 "$HERE/lib/pipeline_step.py" "$YAML_FILE" "$@"; }

if [ "${1:-}" = "--list" ]; then
  step_field --list
  exit 0
fi

STEP_NAME="${1:?Usage: $0 --repo <path> \"<step name>\" [--shell]  (or: $0 --repo <path> --list / $0 --clean)}"
shift || true
MODE="${1:-}"

IMAGE="$(step_field --step "$STEP_NAME" --field image)"
SIZE="$(step_field --step "$STEP_NAME" --field size)"
SERVICES="$(step_field --step "$STEP_NAME" --field services)"
DOCKER_SVC_MEM_MIB="$(step_field --docker-service-memory)"
[ -n "$DOCKER_SVC_MEM_MIB" ] || DOCKER_SVC_MEM_MIB=2048

# Bitbucket's own size->resource mapping isn't published for this comparison to
# be exact; these are just plausible local caps in the right ballpark so a run
# doesn't silently get more headroom than CI ever gives it.
case "$SIZE" in
  1x) MEM=4g; CPUS=4 ;;
  2x) MEM=8g; CPUS=4 ;;
  4x) MEM=16g; CPUS=8 ;;
  8x) MEM=32g; CPUS=8 ;;
  *) MEM=4g; CPUS=4 ;;
esac

WORKDIR="$HERE/work"
mkdir -p "$WORKDIR"
SLUG="$(printf '%s' "$STEP_NAME" | tr -c 'A-Za-z0-9' '_')"
SCRIPT_FILE="$WORKDIR/${SLUG}.script.sh"
AFTER_FILE="$WORKDIR/${SLUG}.after-script.sh"

{
  echo '#!/usr/bin/env bash'
  # Just -e, matching Bitbucket's actual step semantics ("fails if any command
  # returns non-zero") -- no -u/pipefail, which Bitbucket doesn't set either
  # and which would make e.g. a genuinely-unset repo variable abort with
  # "unbound variable" here instead of the script's own, friendlier check.
  echo 'set -e'
  step_field --step "$STEP_NAME" --field script
} >"$SCRIPT_FILE"

{
  echo '#!/usr/bin/env bash'
  # Each after-script line already ends in "|| true" where it needs to
  # tolerate failure -- don't add a blanket set -e that could still abort one
  # that doesn't.
  echo 'set +e'
  step_field --step "$STEP_NAME" --field after-script
} >"$AFTER_FILE"
chmod +x "$SCRIPT_FILE" "$AFTER_FILE"

echo "== $STEP_NAME =="
echo "image:    $IMAGE"
echo "size:     $SIZE  (mem=$MEM cpus=$CPUS)"
echo "services: ${SERVICES:-<none>}"
echo "script:   $SCRIPT_FILE"
echo "after:    $AFTER_FILE"
echo

NEEDS_DOCKER_SVC=0
if printf '%s\n' "$SERVICES" | grep -qx docker; then
  NEEDS_DOCKER_SVC=1
fi

# atlassian/default-image doesn't actually bundle a `docker` CLI -- Bitbucket
# injects one for steps that declare `services: [docker]`. Cache a static
# binary (pulled once from docker:dind, which we need anyway for the sidecar)
# and bind-mount it in the same way.
DOCKER_CLI_BIN="$HERE/.cache/docker-cli/docker"
# atlassian/default-image's docker CLI (once injected) also lacks the buildx
# CLI plugin that real Bitbucket agents ship, which `docker build` needs
# whenever DOCKER_BUILDKIT=1.
DOCKER_BUILDX_BIN="$HERE/.cache/docker-cli/docker-buildx"
ensure_docker_cli() {
  [ -x "$DOCKER_CLI_BIN" ] && [ -x "$DOCKER_BUILDX_BIN" ] && return
  mkdir -p "$(dirname "$DOCKER_CLI_BIN")"
  echo "caching a docker CLI binary for the agent container (one-time) ..."
  local cid
  cid="$(docker create docker:dind)"
  docker cp "$cid:/usr/local/bin/docker" "$DOCKER_CLI_BIN"
  docker cp "$cid:/usr/local/libexec/docker/cli-plugins/docker-buildx" "$DOCKER_BUILDX_BIN"
  docker rm "$cid" >/dev/null
}

cleanup() {
  docker rm -f "$AGENT" >/dev/null 2>&1 || true
  if [ "$NEEDS_DOCKER_SVC" = "1" ] && [ "${KEEP:-0}" != "1" ]; then
    docker rm -f "$DIND" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
docker rm -f "$AGENT" >/dev/null 2>&1 || true # stale from an unclean previous exit

default_repo_full_name() {
  local url
  url="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  url="$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
  printf '%s' "${url:-$(basename "$REPO_DIR")}"
}

RUN_ARGS=(
  --rm -it --name "$AGENT"
  --memory="$MEM" --cpus="$CPUS"
  -e "BITBUCKET_CLONE_DIR=$BITBUCKET_CLONE_DIR"
  -e "BITBUCKET_BRANCH=${BITBUCKET_BRANCH:-$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo main)}"
  -e "BITBUCKET_COMMIT=${BITBUCKET_COMMIT:-$(git -C "$REPO_DIR" rev-parse HEAD)}"
  -e "BITBUCKET_REPO_FULL_NAME=${BITBUCKET_REPO_FULL_NAME:-$(default_repo_full_name)}"
  -e "CI=true"
  -v "$REPO_DIR:$BITBUCKET_CLONE_DIR"
  -v "$SCRIPT_FILE:/tmp/step-script.sh:ro"
  -v "$AFTER_FILE:/tmp/after-script.sh:ro"
  -w "$BITBUCKET_CLONE_DIR"
)

# Forward every repository variable defined in secrets.env (that's non-empty
# in the environment), whatever its name -- the tool has no hardcoded notion
# of which variables any given project's pipeline needs. The harness's own
# control vars are excluded even if someone happens to also define them there.
CONTROL_VARS=" KEEP REPO_DIR YAML_FILE BITBUCKET_BRANCH BITBUCKET_COMMIT BITBUCKET_REPO_FULL_NAME "
if [ -f "$HERE/secrets.env" ]; then
  while IFS='=' read -r name _; do
    case "$name" in ''|'#'*) continue ;; esac
    case "$CONTROL_VARS" in *" $name "*) continue ;; esac
    if [ -n "${!name:-}" ]; then
      RUN_ARGS+=(-e "$name=${!name}")
    fi
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$HERE/secrets.env")
fi

if [ "$NEEDS_DOCKER_SVC" = "1" ]; then
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
  if [ "$(docker inspect -f '{{.State.Running}}' "$DIND" 2>/dev/null)" != "true" ]; then
    docker rm -f "$DIND" >/dev/null 2>&1 || true # stale/exited from a previous crash
    echo "starting docker-in-docker sidecar ($DIND, memory=${DOCKER_SVC_MEM_MIB}m) ..."
    docker run -d --name "$DIND" --network "$NETWORK" --privileged \
      --memory="${DOCKER_SVC_MEM_MIB}m" \
      -e DOCKER_TLS_CERTDIR= \
      -v "$REPO_DIR:$BITBUCKET_CLONE_DIR" \
      docker:dind --storage-driver=overlay2 >/dev/null
    ready=0
    for _ in $(seq 1 30); do
      docker exec "$DIND" docker info >/dev/null 2>&1 && { ready=1; break; }
      sleep 1
    done
    if [ "$ready" != "1" ]; then
      echo "ERROR: $DIND did not become ready within 30s; its logs:" >&2
      docker logs "$DIND" >&2 || true
      exit 1
    fi
  fi
  ensure_docker_cli
  RUN_ARGS+=(
    --network "$NETWORK" -e "DOCKER_HOST=tcp://$DIND:2375"
    -v "$DOCKER_CLI_BIN:/usr/local/bin/docker:ro"
    -v "$DOCKER_BUILDX_BIN:/usr/local/libexec/docker/cli-plugins/docker-buildx:ro"
  )
fi

if [ "$MODE" = "--shell" ]; then
  echo "Dropping into a shell in the agent container for '$STEP_NAME'."
  echo "Run /tmp/step-script.sh and /tmp/after-script.sh yourself when ready."
  docker run "${RUN_ARGS[@]}" --entrypoint /bin/bash "$IMAGE"
else
  docker run "${RUN_ARGS[@]}" --entrypoint /bin/bash "$IMAGE" \
    -c '/tmp/step-script.sh; code=$?; /tmp/after-script.sh; exit $code'
fi
