#!/usr/bin/env bash
# Smoke tests for the runner image. Stand-ins for config.sh, run.sh and curl
# (tests/stubs) let the entrypoint run end to end without GitHub.
#   tests/smoke.sh <image>
# SMOKE_ONLINE=1 adds one check against the real GitHub API.
set -euo pipefail

image=${1:?usage: tests/smoke.sh <image>}
stubs="$(cd "$(dirname "$0")" && pwd)/stubs"
url=https://github.com/owner/repo
stubbed=(-v "$stubs/config.sh:/home/runner/config.sh:ro" -v "$stubs/run.sh:/home/runner/run.sh:ro")
with_curl=(-v "$stubs/curl:/usr/local/bin/curl:ro")
failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# run_container [docker run options...] [-- command...]: sets $output and $status.
run_container() {
  local options=()
  while (($#)) && [[ $1 != -- ]]; do
    options+=("$1")
    shift
  done
  [[ ${1:-} == -- ]] && shift
  status=0
  output=$(docker run --rm "${options[@]}" "$image" "$@" 2>&1) || status=$?
}

# expect / reject <description> <text>: checks the output of the last run.
expect() {
  if [[ $output == *"$2"* ]]; then
    pass "$1"
  else
    fail "$1: expected \"$2\" in:"
    printf '%s\n' "$output"
  fi
}
reject() {
  if [[ $output != *"$2"* ]]; then
    pass "$1"
  else
    fail "$1: did not expect \"$2\" in:"
    printf '%s\n' "$output"
  fi
}
expect_success() { expect_status "$1" 0; }
expect_status() {
  if ((status == $2)); then
    pass "$1"
  else
    fail "$1: exited $status, expected $2"
    printf '%s\n' "$output"
  fi
}

# expect_failure <description> <expected log text> [docker run options...]
expect_failure() {
  local description=$1 expected=$2
  shift 2
  run_container "$@"
  if ((status == 0)); then
    fail "$description: container exited 0"
    printf '%s\n' "$output"
  else
    expect "$description" "$expected"
  fi
}

if docker run --rm --entrypoint bash "$image" -c \
  'test -x /usr/bin/tini && test -x config.sh && test -x run.sh && test -n "$RUNNER_MANUALLY_TRAP_SIG" && docker --version' >/dev/null; then
  pass "image has tini, the runner, signal forwarding and the Docker CLI"
else
  fail "image is missing tini, the runner, RUNNER_MANUALLY_TRAP_SIG or the Docker CLI"
fi
if docker run --rm --entrypoint bash "$image" -c \
  'command -v xvfb-run gcc gh shellcheck zip rsync >/dev/null && ldconfig -p | grep -q libgtk-3.so.0 && ldconfig -p | grep -q libnss3.so' >/dev/null; then
  pass "image has the baseline (xvfb, gcc, gh, shellcheck, zip, rsync, GTK, NSS)"
else
  fail "image is missing part of the baseline"
fi

echo "# configuration errors"
expect_failure "requires GITHUB_URL" "GITHUB_URL is required"
expect_status "exits 78 for a setting that cannot work" 78
expect_failure "refuses persistent workspace settings for ephemeral runners" "CLEAN_WORKDIR_ON_EXIT=false requires EPHEMERAL=false" \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e EPHEMERAL=true -e CLEAN_WORKDIR_ON_EXIT=false
expect_failure "rejects a malformed GITHUB_URL" "GITHUB_URL must be" \
  -e GITHUB_URL=github.com/owner/repo -e ACCESS_TOKEN=x
expect_failure "rejects plain http" "GITHUB_URL must be https" \
  "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL=http://github.com/owner/repo -e ACCESS_TOKEN=x
expect_failure "rejects a plain http API URL" "GITHUB_API_URL must start with https" \
  "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="$url" -e GITHUB_API_URL=http://api.example.com -e ACCESS_TOKEN=x
expect_failure "requires a token" "set ACCESS_TOKEN" \
  -e GITHUB_URL="$url"
expect_failure "reports an unreadable token file" "ACCESS_TOKEN_FILE: cannot read" \
  -e GITHUB_URL="$url" -e ACCESS_TOKEN_FILE=/run/secrets/missing
expect_failure "rejects unsafe runner names" "RUNNER_NAME may only contain" \
  -e GITHUB_URL="$url" -e ACCESS_TOKEN=x -e RUNNER_NAME=a/b
expect_failure "rejects a work dir outside the runner home" "plain directory name" \
  -e GITHUB_URL="$url" -e ACCESS_TOKEN=x -e RUNNER_WORKDIR=../etc
expect_failure "rejects '..' in an absolute work dir" "must not contain '..'" \
  -e GITHUB_URL="$url" -e ACCESS_TOKEN=x -e RUNNER_WORKDIR=/var/tmp/../etc
expect_failure "rejects a mistyped boolean" "EPHEMERAL must be true or false, got 'ture'" \
  "${stubbed[@]}" -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e EPHEMERAL=ture
expect_failure "refuses a mounted Docker socket it cannot use" "/var/run/docker.sock is mounted but unusable" \
  "${stubbed[@]}" -v /var/run/docker.sock:/var/run/docker.sock -e DOCKER_HOST=unix:///nonexistent.sock \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x
expect_failure "passes GitHub API errors on" "Bad credentials" \
  "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="$url" -e ACCESS_TOKEN=invalid
expect_status "gives up for good on a token GitHub rejects" 78
expect_failure "retries later when GitHub is unavailable" "HTTP 503" \
  "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="$url" -e ACCESS_TOKEN=unavailable
expect_status "exits 1 for it, so the unit tries again" 1
expect_failure "rejects a directory in place of the token file" "is a directory; Docker creates one" \
  -v /tmp:/run/secrets/access_token:ro -e GITHUB_URL="$url" -e ACCESS_TOKEN_FILE=/run/secrets/access_token
expect_status "exits 78 for it" 78
expect_failure "gives up for good on a RUNNER_TOKEN config.sh refused" "valid for an hour; use ACCESS_TOKEN" \
  "${stubbed[@]}" -e GITHUB_URL="$url" -e RUNNER_TOKEN=expired
expect_status "exits 78 for it" 78
expect_failure "passes options real curl understands" "curl: (7)" \
  "${stubbed[@]}" -e GITHUB_URL="$url" -e GITHUB_API_URL=https://127.0.0.1:9 -e ACCESS_TOKEN=secret
reject "gives curl no option it rejects" "curl: option"

echo "# registration with RUNNER_TOKEN"
run_container "${stubbed[@]}" -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e RUNNER_NAME=smoke \
  -e RUNNER_LABELS="a, b" -e EPHEMERAL=true
expect_success "runs through"
expect "passes name, labels and ephemeral to config.sh" "--name smoke --work _work --labels a,b --ephemeral"
expect "hands config.sh the token in its environment" "(token: x)"
reject "keeps the token off config.sh's command line" "--token"
expect "creates a work dir only the runner can read" "work dir /home/runner/_work mode 700"
expect "starts the runner with SIGINT, which run.sh stops it with" "run: SIGINT not ignored"
expect "keeps the token out of the runner's environment" "run: leaked: none"

echo "# registration with ACCESS_TOKEN"
run_container "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="$url" -e ACCESS_TOKEN=secret -e RUNNER_NAME=smoke
expect_success "runs through"
expect "asks for a registration token, token on stdin" \
  "curl: https://api.github.com/repos/owner/repo/actions/runners/registration-token (auth: stdin, token 6 chars)"
expect "registers with the token from the API" "(token: t)"
expect "keeps ACCESS_TOKEN out of the runner's environment" "run: leaked: none"

echo "# token from a file"
secrets=$(mktemp -d)
printf 'filetoken\n' >"$secrets/access_token"
chmod 644 "$secrets/access_token"
run_container "${stubbed[@]}" "${with_curl[@]}" -v "$secrets/access_token:/run/secrets/access_token:ro" \
  -e GITHUB_URL="$url" -e ACCESS_TOKEN_FILE=/run/secrets/access_token
expect_success "runs through"
expect "reads the file without its trailing newline" "(auth: stdin, token 9 chars)"
expect "keeps ACCESS_TOKEN_FILE out of the runner's environment" "run: leaked: none"
rm -rf "$secrets"

echo "# API endpoints"
for case in \
  "https://github.com/my-org|https://api.github.com/orgs/my-org" \
  "https://github.com/enterprises/acme|https://api.github.com/enterprises/acme" \
  "https://ghe.example.com/owner/repo|https://ghe.example.com/api/v3/repos/owner/repo" \
  "https://github.com/owner/repo.git/|https://api.github.com/repos/owner/repo"; do
  run_container "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="${case%%|*}" -e ACCESS_TOKEN=secret
  expect "uses ${case#*|} for ${case%%|*}" "curl: ${case#*|}/actions/runners/registration-token"
done
run_container "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="$url" -e GITHUB_API_URL=https://api.example.com/ \
  -e ACCESS_TOKEN=secret
expect "honours GITHUB_API_URL" "curl: https://api.example.com/repos/owner/repo/actions/runners/registration-token"

echo "# flags"
run_container "${stubbed[@]}" -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e RUNNER_GROUP=builders \
  -e NO_DEFAULT_LABELS=TRUE -e DISABLE_AUTO_UPDATE=yes -e EPHEMERAL=off
expect "passes group, no-default-labels and disableupdate" "--runnergroup builders --no-default-labels --disableupdate"
reject "registers a persistent runner for EPHEMERAL=off" "--ephemeral"
run_container "${stubbed[@]}" --security-opt no-new-privileges -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e EPHEMERAL=true
expect_success "starts with no-new-privileges"

echo "# leftovers from an unclean stop"
run_container "${stubbed[@]}" "${with_curl[@]}" -e GITHUB_URL="$url" -e ACCESS_TOKEN=secret \
  --entrypoint bash -- -c 'touch .runner_migrated .credentials_migrated && exec /usr/local/bin/entrypoint.sh'
expect "clears old runner state with the runner's own command" "config: remove --local"
expect "leaves only the new registration, no migrated files" "run: runner state: .runner"$'\n'
run_container "${stubbed[@]}" -e GITHUB_URL="$url" -e RUNNER_TOKEN=expired \
  --entrypoint bash -- -c 'touch .runner && exec /usr/local/bin/entrypoint.sh'
expect_success "restarts with RUNNER_TOKEN"
expect "keeps a registration it could not renew" "reusing the existing registration"
reject "does not register again" "config: --unattended"

echo "# shared work dir (Docker mode)"
# As on a Docker host: the daemon created the mounted directory as root, and a
# Docker job left root-owned files behind, so the runner needs its sudo fallbacks.
shared=$(mktemp -d)
work=$shared/work
as_root() { docker run --rm --user 0 -v "$shared:$shared" --entrypoint sh "$image" -c "$1"; }
as_root "mkdir -p '$work/smoke' && touch '$work/smoke/stale' && chown -R 0:0 '$work' && chmod 755 '$work'"
run_container "${stubbed[@]}" -v "$work:$work" -e RUNNER_WORKDIR="$work" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e EPHEMERAL=true
expect_success "runs through"
expect "gives each runner its own subdirectory" "--work $work/smoke"
expect "starts ephemeral runners in an empty private work dir" "work dir $work/smoke mode 700 entries 0"
if [[ ! -e $work/smoke ]]; then pass "removes the shared work dir on exit"; else fail "left $work/smoke behind"; fi
run_container "${stubbed[@]}" -v "$work:$work" -e RUNNER_WORKDIR="$work" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e EPHEMERAL=ture
if [[ ! -e $work/smoke ]]; then pass "creates nothing in it for a setting that cannot work"; else fail "left $work/smoke behind after an error"; fi
run_container "${stubbed[@]}" "${with_curl[@]}" -v "$work:$work" -e RUNNER_WORKDIR="$work" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e ACCESS_TOKEN=invalid
if [[ ! -e $work/smoke ]]; then pass "removes it after a failed registration"; else fail "left $work/smoke behind after a failed registration"; fi
run_container "${stubbed[@]}" -v "$work:$work" -e RUNNER_WORKDIR="$work" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e EPHEMERAL=false -e CLEAN_WORKDIR_ON_EXIT=false
expect_success "runs with host-managed workspace cleanup"
if [[ -d $work/smoke ]]; then pass "preserves persistent workspace on stop"; else fail "removed persistent workspace"; fi
# Reuse the registration after a container restart without deleting its checkout.
as_root "touch '$work/smoke/retained'"
run_container "${stubbed[@]}" -v "$work:$work" -e RUNNER_WORKDIR="$work" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=expired -e EPHEMERAL=false -e CLEAN_WORKDIR_ON_EXIT=false \
  --entrypoint bash -- -c 'touch .runner && exec /usr/local/bin/entrypoint.sh'
expect_success "restarts a persistent runner without a fresh registration token"
if [[ -f $work/smoke/retained ]]; then pass "restart keeps the workspace"; else fail "restart removed checkout"; fi
as_root "rm -f '$work/smoke/retained' && rmdir '$work/smoke'"
as_root "chmod 777 '$work'"
run_container "${stubbed[@]}" -v "$work:$work" -e RUNNER_WORKDIR="$work" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x
expect "refuses a shared directory others can write to" "is writable by others or not owned by root"
expect_status "exits 78 for it" 78
as_root "rm -rf '$work'"
rm -rf "$shared"

echo "# docker stop"
cid=$(docker run -d "${stubbed[@]}" "${with_curl[@]}" -e STUB_WAIT=1 -e GITHUB_URL="$url" \
  -e ACCESS_TOKEN=secret -e RUNNER_NAME=smoke "$image")
# shellcheck disable=SC2016 # $1 belongs to the inner bash
if timeout 30 bash -c 'until docker logs "$1" 2>&1 | grep -q "run: listening"; do sleep 0.5; done' _ "$cid"; then
  start=$SECONDS
  docker stop -t 30 "$cid" >/dev/null
  took=$((SECONDS - start))
  output=$(docker logs "$cid" 2>&1)
  expect "stops the runner" "run: stopped"
  expect "fetches a removal token, token on stdin" \
    "curl: https://api.github.com/repos/owner/repo/actions/runners/remove-token (auth: stdin, token 6 chars)"
  expect "deregisters with the removal token" "config: remove (token: t)"
  if ((took < 15)); then pass "stops within ${took}s"; else fail "took ${took}s to stop"; fi
else
  fail "stubbed runner never started listening"
  docker logs "$cid" 2>&1
fi
docker rm -f "$cid" >/dev/null

# A stop while config.sh is stuck must not wait for it.
shared=$(mktemp -d)
cid=$(docker run -d "${stubbed[@]}" -v "$shared:$shared" -e RUNNER_WORKDIR="$shared" -e RUNNER_NAME=smoke \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=hang "$image")
# shellcheck disable=SC2016 # $1 belongs to the inner bash
if timeout 30 bash -c 'until docker logs "$1" 2>&1 | grep -q "config: hanging"; do sleep 0.5; done' _ "$cid"; then
  start=$SECONDS
  docker stop -t 30 "$cid" >/dev/null
  took=$((SECONDS - start))
  status=$(docker inspect -f '{{.State.ExitCode}}' "$cid")
  if ((took < 10 && status == 143)); then
    pass "a stop during registration ends config.sh (${took}s, exit $status)"
  else
    fail "a stop during registration took ${took}s, exit $status"
  fi
  if [[ ! -e $shared/smoke ]]; then pass "and still removes the work dir"; else fail "left $shared/smoke behind"; fi
else
  fail "stubbed config.sh never started"
fi
docker rm -f "$cid" >/dev/null
rm -rf "$shared"

if [[ -n ${SMOKE_ONLINE:-} ]]; then
  echo "# GitHub API"
  expect_failure "passes real GitHub API errors on" "Bad credentials" \
    -e GITHUB_URL=https://github.com/actions/runner -e ACCESS_TOKEN=invalid
  # The real config.sh takes the token from ACTIONS_RUNNER_INPUT_TOKEN: GitHub
  # rejects the made-up one, instead of config.sh asking for a token.
  expect_failure "real config.sh reads the token from its environment" "404 (Not Found)" \
    -e GITHUB_URL=https://github.com/actions/runner -e RUNNER_TOKEN=made-up-token
  reject "real config.sh did not miss the token" "Invalid configuration provided for token"
fi

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
