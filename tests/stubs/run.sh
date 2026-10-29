#!/usr/bin/env bash
# Stands in for the runner's run.sh: reports what the runner would inherit.
mask=$(awk '/^SigIgn:/ { print $2 }' /proc/$$/status)
if (( 16#$mask & 2 )); then echo "run: SIGINT ignored"; else echo "run: SIGINT not ignored"; fi
echo "run: RUNNER_TOKEN ${RUNNER_TOKEN:+set}${RUNNER_TOKEN:-unset}"
