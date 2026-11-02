#!/usr/bin/env bash
# Checks what the compose files hand the runner container, without starting it.
# Renders with an empty env file and explicit -f, so a local .env (with a real
# token) or compose.override.yaml never takes part.
#   tests/compose.sh
set -euo pipefail

cd "$(dirname "$0")/.."
unset COMPOSE_FILE COMPOSE_PROJECT_NAME
env='.services.runner.environment'
failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# check <description> <jq condition> <rendered config>
check() {
  if jq -e "$2" >/dev/null <<<"$3"; then pass "$1"; else fail "$1: $2"; fi
}

# render [compose options...]: the config of project "smoke" as JSON.
render() { docker compose --env-file /dev/null -p smoke "$@" config --format json; }

export GITHUB_URL=https://github.com/owner/repo

config=$(ACCESS_TOKEN_FILE=/run/secrets/access_token RUNNER_TOKEN_FILE=/run/secrets/runner_token \
  RUNNER_LABELS=containerized render -f compose.yaml)
check "passes ACCESS_TOKEN_FILE" "$env.ACCESS_TOKEN_FILE == \"/run/secrets/access_token\"" "$config"
check "passes RUNNER_TOKEN_FILE" "$env.RUNNER_TOKEN_FILE == \"/run/secrets/runner_token\"" "$config"
check "passes RUNNER_LABELS" "$env.RUNNER_LABELS == \"containerized\"" "$config"
check "is ephemeral by default" "$env.EPHEMERAL == \"true\"" "$config"
check "leaves time to deregister on stop" '.services.runner.stop_grace_period == "1m30s"' "$config"

config=$(RUNNER_LABELS=containerized DOCKER_GID=999 render -f compose.yaml -f compose.docker.yml)
check "gives the Docker set only its own labels" \
  "$env.RUNNER_LABELS == \"docker\" and $env.NO_DEFAULT_LABELS == \"true\"" "$config"
check "adds the socket's group" '.services.runner.group_add | map(tostring) == ["999"]' "$config"
check "resolves host.docker.internal" \
  '.services.runner.extra_hosts | tostring | test("host.docker.internal[:=]host-gateway")' "$config"
check "points the runner at a work dir per project" \
  "$env.RUNNER_WORKDIR == \"/var/lib/actions-runner/smoke\"" "$config"
check "mounts that work dir at the same path" \
  '[.services.runner.volumes[] | select(.target == "/var/lib/actions-runner/smoke")][0].source == "/var/lib/actions-runner/smoke"' \
  "$config"
config=$(RUNNER_DOCKER_LABELS=docker,big DOCKER_GID=999 render -f compose.yaml -f compose.docker.yml)
check "takes RUNNER_DOCKER_LABELS" "$env.RUNNER_LABELS == \"docker,big\"" "$config"

# How a runner set (and a systemd instance) switches to Docker mode.
set_env=$(mktemp)
printf '%s\n' COMPOSE_FILE=compose.yaml:compose.docker.yml DOCKER_GID=999 >"$set_env"
config=$(docker compose --env-file "$set_env" -p smoke config --format json)
rm -f "$set_env"
check "switches to Docker mode through COMPOSE_FILE in the env file" "$env.RUNNER_LABELS == \"docker\"" "$config"

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
