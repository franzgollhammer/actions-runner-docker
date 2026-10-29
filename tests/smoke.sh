#!/usr/bin/env bash
# Smoke tests for the runner image that need no GitHub credentials.
#   tests/smoke.sh <image>
# SMOKE_OFFLINE=1 skips the one check that calls the GitHub API.
set -euo pipefail

image=${1:?usage: tests/smoke.sh <image>}
url=https://github.com/owner/repo
failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# expect_failure <description> <expected log text> [docker run options...]
expect_failure() {
  local description=$1 expected=$2 output
  shift 2
  if output=$(docker run --rm "$@" "$image" 2>&1); then
    fail "$description: container exited 0"
  elif [[ $output != *"$expected"* ]]; then
    fail "$description: expected \"$expected\" in:"
    printf '%s\n' "$output"
  else
    pass "$description"
  fi
}

if docker run --rm --entrypoint bash "$image" -c \
  'test -x /usr/bin/tini && test -x config.sh && test -x run.sh && test -n "$RUNNER_MANUALLY_TRAP_SIG" && docker --version' >/dev/null; then
  pass "image has tini, the runner, signal forwarding and the Docker CLI"
else
  fail "image is missing tini, the runner, RUNNER_MANUALLY_TRAP_SIG or the Docker CLI"
fi

expect_failure "requires GITHUB_URL" "GITHUB_URL is required"
expect_failure "rejects a malformed GITHUB_URL" "GITHUB_URL must be" \
  -e GITHUB_URL=github.com/owner/repo -e ACCESS_TOKEN=x
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

# With stand-ins for config.sh and run.sh the entrypoint runs to the end offline.
stubs="$(cd "$(dirname "$0")" && pwd)/stubs"
status=0
output=$(docker run --rm \
  -v "$stubs/config.sh:/home/runner/config.sh:ro" -v "$stubs/run.sh:/home/runner/run.sh:ro" \
  -e GITHUB_URL="$url" -e RUNNER_TOKEN=x -e RUNNER_NAME=smoke -e RUNNER_LABELS="a, b" -e EPHEMERAL=true \
  "$image" 2>&1) || status=$?
expect_output() {
  if [[ $output == *"$2"* ]]; then
    pass "$1"
  else
    fail "$1: expected \"$2\" in:"
    printf '%s\n' "$output"
  fi
}
if ((status == 0)); then pass "runs through with stubbed runner"; else fail "stubbed run exited $status"; fi
expect_output "passes name, labels and ephemeral to config.sh" "--name smoke --work _work --labels a,b --ephemeral"
expect_output "keeps the token out of the runner's environment" "run: RUNNER_TOKEN unset"
expect_output "starts the runner with SIGINT, which run.sh stops it with" "run: SIGINT not ignored"

if [[ -z ${SMOKE_OFFLINE:-} ]]; then
  expect_failure "passes GitHub API errors on" "Bad credentials" \
    -e GITHUB_URL=https://github.com/actions/runner -e ACCESS_TOKEN=invalid
fi

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
