#!/usr/bin/env bash
# Runs the commands of systemd/actions-runner@.service the way systemd would,
# with the stubs from tests/stubs in place of the runner and curl.
#   tests/systemd.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
unit="$root/systemd/actions-runner@.service"
instance=smoke-systemd
failures=0

pass() { echo "ok   $1"; }
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# unit_command KEY: the words of that line of the unit, with %i filled in and a
# leading "-" (ignore failure) dropped. Where docker is not in /usr/bin (macOS),
# the one from PATH stands in.
unit_command() {
  read -ra cmd < <(sed -n "s/^$1=-\{0,1\}//p" "$unit" | sed "s/%i/$instance/g")
  [[ -x ${cmd[0]} ]] || cmd[0]=${cmd[0]##*/}
}

# A copy of the unit's working directory with an env file and an override that
# mounts the stubs, so the checkout itself stays untouched.
dir=$(mktemp -d)
cleanup() {
  docker rm -f "$instance-runner" >/dev/null 2>&1 || true
  docker image rm "$instance-runner" >/dev/null 2>&1 || true
  rm -rf "$dir"
}
trap cleanup EXIT
cp "$root"/{compose.yaml,Dockerfile,entrypoint.sh,.dockerignore} "$dir"/
cat >"$dir/compose.override.yaml" <<EOF
services:
  runner:
    environment:
      STUB_WAIT: "1"
    volumes:
      - $root/tests/stubs/config.sh:/home/runner/config.sh:ro
      - $root/tests/stubs/run.sh:/home/runner/run.sh:ro
      - $root/tests/stubs/curl:/usr/local/bin/curl:ro
EOF
cd "$dir"
unset COMPOSE_FILE COMPOSE_PROJECT_NAME

# ExecCondition keeps the unit down while the env file is missing or incomplete.
unit_command ExecCondition
if ! "${cmd[@]}" >/dev/null 2>&1; then pass "ExecCondition fails without an env file"; else fail "ExecCondition passed without an env file"; fi
printf '%s\n' ACCESS_TOKEN=secret >"$instance.env"
if ! "${cmd[@]}" >/dev/null 2>&1; then pass "ExecCondition fails without GITHUB_URL"; else fail "ExecCondition passed without GITHUB_URL"; fi

# EPHEMERAL=false must not win: the unit is for one job per container.
printf '%s\n' GITHUB_URL=https://github.com/owner/repo ACCESS_TOKEN=secret EPHEMERAL=false >"$instance.env"
if "${cmd[@]}" >/dev/null 2>&1; then pass "ExecCondition passes a complete env file"; else fail "ExecCondition failed a complete env file"; fi
unit_command ExecStartPre
"${cmd[@]}" >/dev/null 2>&1 || true
# Build first, so the wait below measures the start, not a cold image build.
docker compose -p "$instance" --env-file "$instance.env" build >/dev/null 2>&1
unit_command ExecStart
"${cmd[@]}" >run.log 2>&1 &
start_pid=$!
if timeout 120 bash -c 'until grep -q "run: listening" run.log; do sleep 1; done'; then
  if grep -q -- "--ephemeral" run.log; then pass "registers an ephemeral runner despite EPHEMERAL=false"; else fail "runner is not ephemeral"; fi
  unit_command ExecStop
  started=$SECONDS
  "${cmd[@]}" >/dev/null
  status=0
  wait "$start_pid" || status=$?
  took=$((SECONDS - started))
  if grep -q "run: stopped" run.log; then pass "ExecStop stops the runner"; else fail "runner was not stopped"; fi
  if grep -q "config: remove (token: t)" run.log; then pass "ExecStop deregisters it"; else fail "runner was not deregistered"; fi
  if ((took < 30)); then pass "ExecStop returns within ${took}s"; else fail "ExecStop took ${took}s"; fi
  if [[ -z $(docker ps -aq --filter "name=^$instance-runner$") ]]; then pass "leaves no container behind"; else fail "container left behind"; fi
  echo "     (ExecStart exited $status)"
else
  fail "runner never started listening; end of its log:"
  tail -20 run.log
  kill "$start_pid" 2>/dev/null || true
fi

# A setting that cannot work ends with 78, which RestartPreventExitStatus stops on.
printf '%s\n' GITHUB_URL=http://github.com/owner/repo ACCESS_TOKEN=secret >"$instance.env"
unit_command ExecStart
status=0
"${cmd[@]}" >run.log 2>&1 || status=$?
if ((status == 78)) && grep -q "RestartPreventExitStatus=78" "$unit"; then
  pass "a configuration error exits 78 and stops the restarts"
else
  fail "configuration error exited $status"
  cat run.log
fi

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
