#!/usr/bin/env bash
# Stands in for the runner's run.sh: reports what the runner would inherit, then
# exits like a finished job, or with STUB_WAIT set waits to be stopped.
mask=$(awk '/^SigIgn:/ { print $2 }' /proc/$$/status)
if ((16#$mask & 2)); then echo "run: SIGINT ignored"; else echo "run: SIGINT not ignored"; fi
leaked=
for var in ACCESS_TOKEN ACCESS_TOKEN_FILE RUNNER_TOKEN RUNNER_TOKEN_FILE; do
  [[ -n ${!var:-} ]] && leaked+=" $var"
done
echo "run: leaked:${leaked:- none}"
echo "run: runner state: $(find . -maxdepth 1 \( -name '.runner*' -o -name '.credentials*' \) -printf '%f ' | xargs)"
if [[ -n ${STUB_WAIT:-} ]]; then
  # Like the real run.sh, which ends with 143 after a SIGTERM.
  trap 'echo "run: stopped"; exit 143' TERM INT
  echo "run: listening"
  while :; do
    sleep 1 &
    wait $!
  done
fi
