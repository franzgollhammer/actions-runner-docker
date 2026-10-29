#!/usr/bin/env bash
# Registers a GitHub Actions runner, runs it until it exits or the container
# stops, and removes the registration again on the way out.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

is_true() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints $NAME, or the contents of the file named by $NAME_FILE (Docker secrets).
secret() {
  local name=$1 file_var="${1}_FILE"
  if [[ -n ${!file_var:-} ]]; then
    [[ -r ${!file_var} ]] || die "$file_var: cannot read ${!file_var}"
    tr -d '[:space:]' <"${!file_var}"
  else
    printf '%s' "${!name:-}"
  fi
}

# Exchanges ACCESS_TOKEN for a short-lived registration or remove token.
runner_api_token() {
  local kind=$1 response
  if ! response=$(curl -sS --fail-with-body --retry 3 -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $access_token" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$api_url/$scope_path/actions/runners/$kind-token"); then
    log "GitHub refused a $kind token for $scope_path: $(jq -r '.message // empty' <<<"$response" 2>/dev/null)"
    log "check GITHUB_URL and that ACCESS_TOKEN may manage runners there (see README)"
    return 1
  fi
  jq -er '.token' <<<"$response"
}

deregister() {
  # Ephemeral runners delete their local config once their job is done.
  [[ -f .runner ]] || return 0
  if [[ -z $access_token ]]; then
    log "no ACCESS_TOKEN: leaving $runner_name registered, GitHub removes offline runners after a while"
    return 0
  fi
  log "removing $runner_name from GitHub"
  local remove_token
  remove_token=$(runner_api_token remove) || return 0
  ./config.sh remove --token "$remove_token" || log "warning: could not remove $runner_name"
}

cd /home/runner

github_url=${GITHUB_URL:-}
github_url=${github_url%/}
github_url=${github_url%.git}
[[ -n $github_url ]] || die "GITHUB_URL is required, e.g. https://github.com/<owner>/<repo> or https://github.com/<org>"
[[ $github_url =~ ^(https?://[^/]+)/([^/]+)(/([^/]+))?$ ]] ||
  die "GITHUB_URL must be https://<host>/<owner>/<repo>, https://<host>/<org> or https://<host>/enterprises/<name>"
host=${BASH_REMATCH[1]} owner=${BASH_REMATCH[2]} repo=${BASH_REMATCH[4]}
if [[ -z $repo ]]; then
  scope_path="orgs/$owner"
elif [[ $owner == enterprises ]]; then
  scope_path="enterprises/$repo"
else
  scope_path="repos/$owner/$repo"
fi
if [[ -n ${GITHUB_API_URL:-} ]]; then
  api_url=${GITHUB_API_URL%/}
elif [[ $host == https://github.com ]]; then
  api_url=https://api.github.com
else
  api_url="$host/api/v3" # GitHub Enterprise Server
fi

access_token=$(secret ACCESS_TOKEN)
runner_token=$(secret RUNNER_TOKEN)
[[ -n $access_token || -n $runner_token ]] || die "set ACCESS_TOKEN (recommended) or RUNNER_TOKEN"

runner_name=${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-docker}-$HOSTNAME}
[[ $runner_name =~ ^[A-Za-z0-9._-]+$ ]] || die "RUNNER_NAME may only contain letters, digits, '.', '_' and '-'"
labels=${RUNNER_LABELS:-}
labels=${labels// /}
ephemeral=${EPHEMERAL:-false}

# A relative work dir lives in the runner's home. An absolute one is usually
# shared with the host (Docker jobs), so each runner gets its own subdirectory.
work_dir=${RUNNER_WORKDIR:-_work}
if [[ $work_dir == /* ]]; then
  [[ $work_dir != *..* ]] || die "RUNNER_WORKDIR must not contain '..'"
  work_dir="${work_dir%/}/$runner_name"
  work_path=$work_dir
else
  [[ $work_dir =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || die "a relative RUNNER_WORKDIR must be a plain directory name"
  work_path="$PWD/$work_dir"
fi
if is_true "$ephemeral"; then
  # Every job starts clean, also after a container restart. Docker jobs may
  # leave root-owned files behind, hence sudo.
  sudo -n rm -rf -- "$work_path"
fi
sudo -n install -d -o "$(id -u)" -g "$(id -g)" -- "$work_path"

if [[ -S /var/run/docker.sock ]] && ! docker version >/dev/null 2>&1; then
  log "warning: /var/run/docker.sock is mounted but $(id -un) cannot use it; set DOCKER_GID=$(stat -c %g /var/run/docker.sock)"
fi

# Left over when a previous run of this container did not shut down cleanly.
rm -f .runner .credentials .credentials_rsaparams

if [[ -n $access_token ]]; then
  registration_token=$(runner_api_token registration) || die "could not get a registration token"
else
  registration_token=$runner_token
  if is_true "$ephemeral"; then
    log "warning: RUNNER_TOKEN expires after an hour; an ephemeral runner needs ACCESS_TOKEN to register again after its job"
  fi
fi

config_args=(--unattended --replace --url "$github_url" --token "$registration_token" --name "$runner_name" --work "$work_dir")
[[ -n $labels ]] && config_args+=(--labels "$labels")
[[ -n ${RUNNER_GROUP:-} ]] && config_args+=(--runnergroup "$RUNNER_GROUP")
is_true "$ephemeral" && config_args+=(--ephemeral)
is_true "${NO_DEFAULT_LABELS:-false}" && config_args+=(--no-default-labels)
is_true "${DISABLE_AUTO_UPDATE:-false}" && config_args+=(--disableupdate)

# bash runs a trap only after the foreground command, so a stop during
# configuration still removes the registration it just created.
trap 'deregister; exit 143' TERM INT
log "registering $runner_name at $github_url (labels: ${labels:-default only}, ephemeral: $ephemeral)"
./config.sh "${config_args[@]}"
unset registration_token runner_token

runner_pid=
# shellcheck disable=SC2329 # called by the trap below
stop_runner() {
  log "stopping runner"
  kill -TERM "$runner_pid" 2>/dev/null || true
}
trap stop_runner TERM INT

# Without job control bash starts background commands with SIGINT ignored, and
# the runner inherits that. run.sh stops the runner with SIGINT, so turn it on.
set -m
# Jobs inherit the runner's environment; keep the GitHub credentials out of it.
env -u ACCESS_TOKEN -u ACCESS_TOKEN_FILE -u RUNNER_TOKEN -u RUNNER_TOKEN_FILE ./run.sh &
runner_pid=$!
status=0
wait "$runner_pid" || status=$?
# A trapped signal interrupts wait before the runner has finished.
while kill -0 "$runner_pid" 2>/dev/null; do
  status=0
  wait "$runner_pid" || status=$?
done

deregister
exit "$status"
