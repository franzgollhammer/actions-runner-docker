#!/usr/bin/env bash
# Usage: sudo host/install.sh --prepare | --check
# Prepare one dedicated Ubuntu x64 host; never stop the old runner or enable timers.
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG

die() { printf 'ci-runner install: %s\n' "$*" >&2; exit 1; }
mode=${1:---check}
[[ $# -le 1 && ( $mode == --check || $mode == --prepare ) ]] || die 'use --check or --prepare'
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'requires Linux x86_64'
[[ $(hostname) == fg-hetzner-1 ]] || die 'wrong host (expected fg-hetzner-1)'
((EUID == 0)) || die 'run with sudo'
for command in python3 docker systemctl loginctl runuser mountpoint fallocate mkswap swapon newuidmap newgidmap dockerd-rootless-setuptool.sh; do
  command -v "$command" >/dev/null || die "missing $command; install the vetted distribution package first"
done
[[ $(docker --host unix:///var/run/docker.sock info --format '{{.CgroupVersion}}/{{.CgroupDriver}}') == 2/systemd ]] || die 'system Docker needs cgroup v2/systemd'
[[ -f $source_dir/ci_host.py && -f $source_dir/host.example.json ]] || die 'incomplete checkout'
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || die 'cgroup v2 is required'

if getent passwd ci-ucsl >/dev/null; then
  [[ $(id -u ci-ucsl) == 1001 && $(id -g ci-ucsl) == 1001 ]] || die 'ci-ucsl must own uid/gid 1001'
  [[ $(getent passwd ci-ucsl | cut -d: -f6-7) == /home/ci-ucsl:/usr/sbin/nologin ]] || die 'unexpected ci-ucsl account'
  [[ $(id -G ci-ucsl) == 1001 ]] || die 'ci-ucsl must not have supplementary groups'
else
  ! getent passwd 1001 >/dev/null || die 'uid 1001 is already used'
  ! getent group 1001 >/dev/null || die 'gid 1001 is already used'
  [[ ! -e /home/ci-ucsl ]] || die 'unmanaged /home/ci-ucsl already exists'
fi

for path in /etc/ci-runner /var/lib/ci-runner /var/log/ci-runner /srv/ci-runner /srv/ci-runner/workspace /etc/systemd/system/user@1001.service.d; do
  [[ ! -L $path ]] || die "symlink at $path"
  [[ ! -e $path || -d $path ]] || die "not a directory: $path"
done
# Fail before mutations rather than adopting arbitrary configuration or a swap file.
if [[ -e /etc/ci-runner/host.json ]]; then
  cmp -s "$source_dir/host.example.json" /etc/ci-runner/host.json || die 'existing host.json differs; review and update it explicitly'
fi
if [[ -e /swap-ci-runner ]]; then
  [[ ! -L /swap-ci-runner && -f /swap-ci-runner ]] || die 'unsafe swap path'
  [[ $(stat -c '%u:%a:%s' /swap-ci-runner) == 0:600:2147483648 ]] || die 'unexpected swap file owner, permissions or size'
  [[ $(blkid -s TYPE -o value /swap-ci-runner) == swap ]] || die 'existing swap file has no swap header'
  grep -qxF '/swap-ci-runner none swap sw 0 0' /etc/fstab || die 'existing swap file is not managed by this installer'
else
  ! grep -qF /swap-ci-runner /etc/fstab || die 'fstab references a missing swap file'
fi
if [[ $mode == --check ]]; then
  printf 'Preflight passed. No changes made. Preparation leaves existing runners and timers alone.\n'
  exit 0
fi

backup="/var/backups/ci-runner/$(date -u +%Y%m%dT%H%M%SZ)-$$"
install -d -m 700 "$backup"
for path in /etc/fstab /etc/subuid /etc/subgid /etc/ci-runner /usr/local/sbin/ci-host /usr/local/sbin/ci-host-set-token /etc/systemd/system/user@1001.service.d; do
  if [[ -e $path ]]; then cp -a --parents "$path" "$backup/"; fi
done
for path in "$source_dir"/systemd/ci-runner.* "$source_dir"/systemd/ci-runner-*.service "$source_dir"/systemd/ci-runner-*.timer; do
  destination="/etc/systemd/system/${path##*/}"
  if [[ -e $destination ]]; then cp -a --parents "$destination" "$backup/"; fi
done
docker --host unix:///var/run/docker.sock ps -a --no-trunc >"$backup/containers.txt"
systemctl list-unit-files 'ci-runner*' >"$backup/units.txt"
printf '%s\n' "$backup" >"$backup/backup-path"

if ! getent passwd ci-ucsl >/dev/null; then
  groupadd --gid 1001 ci-ucsl
  useradd --uid 1001 --gid 1001 --create-home --shell /usr/sbin/nologin ci-ucsl
  printf 'created\n' >"$backup/account-created"
fi
chmod 700 /home/ci-ucsl
# Ubuntu useradd allocates non-overlapping subordinate ID ranges for regular users.
python3 - "$source_dir" <<'PY'
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
from ci_host import validate_local_accounts
validate_local_accounts('ci-ucsl')
PY
if [[ ! -e /swap-ci-runner ]]; then
  fallocate -l 2G /swap-ci-runner
  chmod 600 /swap-ci-runner
  mkswap /swap-ci-runner
  printf '/swap-ci-runner none swap sw 0 0\n' >>/etc/fstab
  printf 'created\n' >"$backup/swap-created"
fi
if ! swapon --show=NAME --noheadings | grep -qx /swap-ci-runner; then swapon /swap-ci-runner; fi

install -d -m 700 /etc/ci-runner /var/lib/ci-runner /var/lib/ci-runner/docker-client /var/log/ci-runner
install -d -m 755 /srv/ci-runner /etc/systemd/system/user@1001.service.d
# Keep an existing mounted workspace's owner and permissions intact.
if [[ ! -d /srv/ci-runner/workspace ]]; then install -d -m 700 /srv/ci-runner/workspace; fi
install -m 600 "$source_dir/host.example.json" /etc/ci-runner/host.json
install -m 755 "$source_dir/ci_host.py" /usr/local/sbin/ci-host
install -m 755 "$source_dir/set_token.py" /usr/local/sbin/ci-host-set-token
install -m 644 "$source_dir/systemd/user-1001.conf" /etc/systemd/system/user@1001.service.d/ci-runner.conf
for path in "$source_dir"/systemd/ci-runner.* "$source_dir"/systemd/ci-runner-*.service "$source_dir"/systemd/ci-runner-*.timer; do
  install -m 644 "$path" "/etc/systemd/system/${path##*/}"
done
systemctl daemon-reload
# An already running user manager must be in the right slice; never kill jobs on rerun.
group=$(systemctl show user@1001.service -p ControlGroup --value)
[[ -z $group || $group == /ci.slice/ci-runner.slice/* ]] || die 'existing user manager is outside the CI slice; drain and stop it before rerunning'
loginctl enable-linger ci-ucsl
systemctl start user@1001.service
runuser -u ci-ucsl -- env HOME=/home/ci-ucsl XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
  dockerd-rootless-setuptool.sh install --force
printf '\nPrepared. Backup: %s\n' "$backup"
printf 'Existing runner untouched. No UCSL service or timer enabled. Follow host/README.md for token setup and cutover.\n'
