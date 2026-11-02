#!/usr/bin/env bash
# Registers a GitHub Actions runner, runs it until it exits or the container
# stops, and removes the registration again on the way out.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}
# A setting that cannot work. Exit status 78 (EX_CONFIG) tells the systemd unit
# not to restart, since trying again would fail the same way.
invalid() {
  log "error: $*"
  exit 78
}

# flag NAME DEFAULT succeeds for a true value and fails for a false one.
# Anything else stops the container, so a typo cannot quietly flip a setting.
flag() {
  local value=${!1:-$2}
  case "${value,,}" in
    1 | true | yes | on) return 0 ;;
    0 | false | no | off) return 1 ;;
    *) invalid "$1 must be true or false, got '$value'" ;;
  esac
}

# Prints $NAME, or the contents of the file named by $NAME_FILE (Docker secrets).
secret() {
  local name=$1 file_var="${1}_FILE"
  if [[ -n ${!file_var:-} ]]; then
    local file=${!file_var}
    if [[ -d $file ]]; then
      invalid "$file_var: $file is a directory; Docker creates one when the file to mount does not exist"
    fi
    [[ -f $file && -r $file ]] || invalid "$file_var: cannot read $file"
    tr -d '[:space:]' <"$file"
  else
    printf '%s' "${!name:-}"
  fi
}

# Exchanges ACCESS_TOKEN for a short-lived registration or remove token. curl
# reads the token from stdin, where other processes cannot see it, and gives up
# in time for docker stop. Returns 78 when GitHub turns the token down for good
# (bad token, missing permission, wrong URL), 1 when a later try may work.
runner_api_token() {
  local kind=$1 response code message
  response=$(curl -sS --proto =https \
    --connect-timeout 10 --max-time 15 --retry 2 --retry-max-time 25 \
    -X POST -H @- -w '\n%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$api_url/$scope_path/actions/runners/$kind-token" <<<"Authorization: Bearer $access_token") || true
  code=${response##*$'\n'}
  response=${response%$'\n'*}
  if [[ $code == 2?? ]]; then
    jq -er '.token' <<<"$response"
    # Not a bare "return": called from the EXIT trap, that would return the
    # status the script exits with instead of jq's.
    return $?
  fi
  message=$(jq -r '.message // empty' <<<"$response" 2>/dev/null || true)
  log "GitHub refused a $kind token for $scope_path (HTTP $code): $message"
  case $code in
    401 | 404) ;;
    403) [[ $message == *"rate limit"* ]] && return 1 ;;
    *) return 1 ;;
  esac
  log "check GITHUB_URL and that ACCESS_TOKEN may manage runners there (see README)"
  return 78
}

# The runner handles its work directory itself and needs sudo only for what it
# cannot do alone: root-owned files from Docker jobs, or a directory Docker
# created on the host.
remove_work_dir() {
  rm -rf -- "$work_path" 2>/dev/null || sudo -n rm -rf -- "$work_path"
}
make_work_dir() {
  local parent=${work_path%/*} owner mode
  # A directory shared with the host: whoever else can write to it could swap
  # the runner's directory for their own.
  if [[ $work_dir == /* ]] && mountpoint -q -- "$parent"; then
    read -r owner mode < <(stat -c '%u %a' -- "$parent")
    if ((8#$mode & 8#022)) || [[ $owner != 0 && $owner != "$(id -u)" ]]; then
      invalid "$parent (uid $owner, mode $mode) is writable by others or not owned by root; use a directory only root can change"
    fi
  fi
  [[ -d $work_path ]] && return 0
  mkdir -m 700 -- "$work_path" 2>/dev/null ||
    sudo -n install -d -m 700 -o "$(id -u)" -g "$(id -g)" -- "$work_path"
}

# shellcheck disable=SC2329 # called by finish
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
  # Bounded, so token request and removal fit into the 90 seconds docker stop
  # waits; GitHub drops an offline runner later anyway.
  ACTIONS_RUNNER_INPUT_TOKEN=$remove_token timeout 40 ./config.sh remove ||
    log "warning: could not remove $runner_name"
}

# Runs on every exit, also after an error during startup.
# shellcheck disable=SC2329 # called by the EXIT trap
finish() {
  deregister
  # A work directory on the host outlives the container, and the next
  # container gets a new name, so nothing would use it again.
  if [[ $work_dir == /* ]]; then
    remove_work_dir || log "warning: could not remove $work_path"
  fi
}

cd /home/runner

github_url=${GITHUB_URL:-}
github_url=${github_url%/}
github_url=${github_url%.git}
[[ -n $github_url ]] || invalid "GITHUB_URL is required, e.g. https://github.com/<owner>/<repo> or https://github.com/<org>"
[[ $github_url =~ ^(https://[^/]+)/([^/]+)(/([^/]+))?$ ]] ||
  invalid "GITHUB_URL must be https://<host>/<owner>/<repo>, https://<host>/<org> or https://<host>/enterprises/<name>"
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
[[ $api_url == https://* ]] || invalid "GITHUB_API_URL must start with https://"

access_token=$(secret ACCESS_TOKEN)
runner_token=$(secret RUNNER_TOKEN)
[[ -n $access_token || -n $runner_token ]] ||
  invalid "set ACCESS_TOKEN or ACCESS_TOKEN_FILE (recommended), or RUNNER_TOKEN or RUNNER_TOKEN_FILE"

ephemeral=false no_default_labels=false disable_update=false
flag EPHEMERAL false && ephemeral=true
flag NO_DEFAULT_LABELS false && no_default_labels=true
flag DISABLE_AUTO_UPDATE false && disable_update=true

runner_name=${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-docker}-$HOSTNAME}
[[ $runner_name =~ ^[A-Za-z0-9._-]+$ ]] || invalid "RUNNER_NAME may only contain letters, digits, '.', '_' and '-'"
labels=${RUNNER_LABELS:-}
labels=${labels// /}

# A relative work dir lives in the runner's home. An absolute one is usually
# shared with the host (Docker jobs), so each runner gets its own subdirectory.
work_dir=${RUNNER_WORKDIR:-_work}
if [[ $work_dir == /* ]]; then
  [[ $work_dir != *..* ]] || invalid "RUNNER_WORKDIR must not contain '..'"
  work_dir="${work_dir%/}/$runner_name"
  work_path=$work_dir
else
  [[ $work_dir =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || invalid "a relative RUNNER_WORKDIR must be a plain directory name"
  work_path="$PWD/$work_dir"
fi

# From here on every exit deregisters and cleans up. bash runs a trap only after
# the foreground command, so a stop during configuration still removes the
# registration it just created.
trap finish EXIT
trap 'exit 143' TERM INT

if [[ $ephemeral == true ]]; then
  # Every job starts with an empty work directory, also after a restart.
  remove_work_dir
fi
make_work_dir

if [[ -S /var/run/docker.sock ]] && ! docker_error=$(docker version 2>&1 >/dev/null); then
  hint=
  if [[ $docker_error == *"permission denied"* ]]; then
    hint="; set DOCKER_GID=$(stat -c %g /var/run/docker.sock)"
  fi
  invalid "/var/run/docker.sock is mounted but unusable (${docker_error##*$'\n'})$hint"
fi

if [[ -z $access_token && -f .runner ]]; then
  # Without ACCESS_TOKEN the last stop left the registration in place, and
  # RUNNER_TOKEN has probably expired since, so keep using it.
  log "reusing the existing registration of this container"
else
  # Left over when a previous run of this container did not shut down cleanly;
  # "remove --local" also clears the files of a migrated runner.
  if compgen -G '.runner*' >/dev/null || compgen -G '.credentials*' >/dev/null; then
    ./config.sh remove --local
  fi
  if [[ -n $access_token ]]; then
    registration_token=$(runner_api_token registration) || {
      status=$?
      ((status != 78)) || invalid "ACCESS_TOKEN cannot register runners at $github_url"
      die "could not get a registration token, will try again"
    }
  else
    registration_token=$runner_token
    if [[ $ephemeral == true ]]; then
      log "warning: RUNNER_TOKEN expires after an hour; an ephemeral runner needs ACCESS_TOKEN to register again after its job"
    fi
  fi

  config_args=(--unattended --replace --url "$github_url" --name "$runner_name" --work "$work_dir")
  [[ -n $labels ]] && config_args+=(--labels "$labels")
  [[ -n ${RUNNER_GROUP:-} ]] && config_args+=(--runnergroup "$RUNNER_GROUP")
  [[ $ephemeral == true ]] && config_args+=(--ephemeral)
  [[ $no_default_labels == true ]] && config_args+=(--no-default-labels)
  [[ $disable_update == true ]] && config_args+=(--disableupdate)

  log "registering $runner_name at $github_url (labels: ${labels:-default only}, ephemeral: $ephemeral)"
  # The runner reads ACTIONS_RUNNER_INPUT_<option>, which keeps the token off
  # the command line. In the background, because bash would only act on a stop
  # once config.sh is done, and config.sh keeps retrying for minutes when it
  # cannot reach GitHub; docker stop would kill everything before that.
  ACTIONS_RUNNER_INPUT_TOKEN=$registration_token ./config.sh "${config_args[@]}" &
  config_pid=$!
  trap 'kill -TERM "$config_pid" 2>/dev/null; exit 143' TERM INT
  config_status=0
  wait "$config_pid" || config_status=$?
  trap 'exit 143' TERM INT
  if ((config_status != 0)); then
    # A RUNNER_TOKEN that did not work will not work later either: it only
    # gets older.
    [[ -n $access_token ]] || invalid "config.sh could not register with RUNNER_TOKEN, which is valid for an hour; use ACCESS_TOKEN"
    die "config.sh could not register $runner_name"
  fi
  unset registration_token
fi
unset runner_token

runner_pid='' stop_requested=false
# shellcheck disable=SC2329 # called by the trap below
stop_runner() {
  log "stopping runner"
  stop_requested=true
  if [[ -n $runner_pid ]]; then
    kill -TERM "$runner_pid" 2>/dev/null || true
  fi
}
trap stop_runner TERM INT

# Without job control bash starts background commands with SIGINT ignored, and
# the runner inherits that. run.sh stops the runner with SIGINT, so turn it on.
set -m
# Jobs inherit the runner's environment; keep the GitHub credentials out of it.
env -u ACCESS_TOKEN -u ACCESS_TOKEN_FILE -u RUNNER_TOKEN -u RUNNER_TOKEN_FILE ./run.sh &
runner_pid=$!
# A stop that came in before the runner had a pid.
if [[ $stop_requested == true ]]; then
  kill -TERM "$runner_pid" 2>/dev/null || true
fi
status=0
wait "$runner_pid" || status=$?
# A trapped signal interrupts wait before the runner has finished.
while kill -0 "$runner_pid" 2>/dev/null; do
  status=0
  wait "$runner_pid" || status=$?
done
exit "$status"
