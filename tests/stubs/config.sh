#!/usr/bin/env bash
# Stands in for the runner's config.sh: shows how it was called and keeps a
# fake registration in .runner, like the real one.
args="$*"
echo "config: $args (token: ${ACTIONS_RUNNER_INPUT_TOKEN:-none})"
work=
while (($#)); do
  [[ $1 == --work ]] && work=$2
  shift
done
if [[ -n $work ]]; then
  [[ $work == /* ]] || work="$PWD/$work"
  echo "config: work dir $work mode $(stat -c %a "$work") entries $(find "$work" -mindepth 1 | wc -l)"
fi
case "$args" in
  remove*) rm -f .runner* .credentials* ;;
  *)
    # Like GitHub with an expired registration token.
    [[ ${ACTIONS_RUNNER_INPUT_TOKEN:-} == expired ]] && exit 1
    # Like config.sh retrying while GitHub cannot be reached.
    if [[ ${ACTIONS_RUNNER_INPUT_TOKEN:-} == hang ]]; then
      trap 'echo "config: stopped"; exit 143' TERM
      echo "config: hanging"
      sleep 300 &
      wait $!
    fi
    touch .runner
    ;;
esac
