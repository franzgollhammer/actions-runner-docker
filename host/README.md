# Dedicated UCSL runner on Hetzner

This is an opt-in controller for **fg-hetzner-1**, an otherwise disposable CI
host (Ubuntu, x86_64, two vCPUs, 4 GB RAM). It replaces the dotagents runner with
one repository runner for `franzgollhammer/ucsl-app`. It is not a general-purpose
Docker-host cleanup service.

## Runtime and resource budget

The system Docker daemon runs the outer runner. Jobs receive only the Docker
socket of a dedicated rootless daemon owned by `ci-ucsl` (UID/GID 1001, no login
shell or supplementary groups). They never receive the system Docker socket or
the host's GitHub PAT. Both the outer container and the rootless user's service
tree belong to `ci-runner.slice`, under `/ci.slice/ci-runner.slice`:

| Setting | Value |
| --- | --- |
| CPUQuota | 200% (two CPUs) |
| MemoryHigh | 2560 MiB |
| MemoryMax | 2816 MiB, shared across runner and Docker jobs |
| MemorySwapMax | 2048 MiB |
| Host swap | `/swap-ci-runner`, 2 GiB |
| Runner shared memory | 512 MiB, charged to the same slice |

These limits protect the host; whether the complete Cypress/build workload fits
must be measured on this machine. Swap can prevent an OOM but costs performance.
The implementation never silently reduces test coverage or resizes the server.

The host owns the Docker volume `ci-ucsl-work` and bind-mounts it at
`/srv/ci-runner/workspace` on both the host and runner. The runner adds its name as
a subdirectory. Rootless Docker sees the identical path, so workflow bind mounts
work. The root controller never uses a path supplied by the untrusted job daemon
as a mount/chown destination. Other Docker volumes are retained.

The runner is persistent during the day. Jobs can affect subsequent UCSL jobs;
only the nightly reset recreates the container and workspace. Keep workflow
execution limited to trusted code and use repository fork approval controls.
Rootless Docker reduces host privilege but is not a separate VM or kernel.

## Maintenance and recovery

`ci-host refresh` obtains the Linux amd64 image digest before changing routing.
It removes the `hetzner-ci` routing label, waits without a job deadline, and
requires 65 continuous idle seconds confirmed by GitHub and local
`Runner.Worker` processes. The runner has only custom labels, so the default
`self-hosted` label cannot accidentally route new work during a drain.

After draining it archives the last 2,000 runner log lines (up to 2 MB, seven
files, root-only), stops/deregisters the runner, and deletes **all containers,
all images, and all builder caches on both Docker engines**, including Buildx
cache volumes. It unmounts/removes only the managed workspace volume. It then
pulls the pinned digest and starts one runner. The long-lived credential remains
in `/etc/ci-runner/github.token`, root-owned mode 600; only a short-lived
registration token enters the container through stdin.

Readiness requires GitHub online status, the expected labels, the shared slice
and working access to the job daemon. Only then is `hetzner-ci` restored. A failed
new image triggers a re-pull of the previous successful digest. Keep candidate
image manifests in GHCR: deleting them would break rollback. Both network and
registry availability are required after a full image purge.

State is atomically recorded under `/var/lib/ci-runner`. All controller commands
share a lock; boot recovery resumes an interrupted maintenance operation with
its recorded digest. A minute timer checks recovery, with ten-minute backoff
after errors. Failed guard checks leave the host untouched. No deadline cancels
a busy job; an API outage blocks cleanup rather than assuming idle.

The refresh timer uses `03:00 Europe/Vienna`, including DST, with `Persistent=true`
for missed runs. The public image workflow builds at 23:17 UTC (00:17 CET /
01:17 CEST) without layer cache and tests the amd64 candidate before moving
`latest`. GitHub schedule delays are possible; in that case the host uses the
last tested published image. ARM64 remains in the multiarch manifest but is not
the platform exercised by the smoke suite. Branch dispatches publish candidate
tags only; stable tags move only from main.

## Prepare without interrupting the existing runner

1. Review this branch and its CI results. Vet the exact new Ubuntu `uidmap` and
   `libsubid5` package versions before installation. Docker and its rootless
   extras are already installed on this host. The installer does not install
   packages or change system Docker configuration. It refuses missing tools,
   occupied IDs, symlinks, unmanaged swap/configuration and a mismatched host.
2. Stage this checkout on the host. Run `sudo host/install.sh --check`, then
   `sudo host/install.sh --prepare`. Preparation creates a private backup at
   `/var/backups/ci-runner/<timestamp>-<pid>` before mutations. It installs the
   account, subordinate IDs, swap, slice, user-manager override, controller and
   units; it enables lingering and starts the rootless daemon. It **does not**
   stop the existing runner, start UCSL, or enable either timer.
3. In GitHub create a fine-grained PAT limited to `franzgollhammer/ucsl-app` with
   **Administration: read/write**. Set an expiry and arrange renewal. In an
   interactive SSH terminal run `sudo /usr/local/sbin/ci-host-set-token`. It
   prompts without echo, validates runner-registration access, and stores it
   privately. Do not paste the PAT into chat, a command argument, or the runner's
   `.env`. Re-run this helper to rotate it; the previous file is backed up.
4. Run `sudo ci-host status` and `sudo ci-host refresh --dry-run`. Inspect the
   inventory: every listed container/image will be removed by a real refresh.

## Cutover and acceptance

The existing dotagents runner must be idle before retirement. Temporarily pause
its workflow scheduling, let active/assigned jobs finish, archive its logs and
root-only configuration, record its container/image/registration IDs, then stop
and remove its container and GitHub registration. Preserve its checkout and
private `.env` for rollback. Restore workflow scheduling afterward; dotagents
has no runner on this machine after this change. Do not leave its old systemd
unit or restart policy enabled.

```sh
sudo systemctl start ci-runner.service
sudo ci-host status
# Only after readiness and the workflow PR are available:
gh variable set CI_RUNS_ON -R franzgollhammer/ucsl-app --body '["hetzner-ci","ucsl"]'
gh workflow run test.yml -R franzgollhammer/ucsl-app --ref <tested-branch>
```

Run the entire UCSL Test workflow through GitHub Actions. Confirm each job's
runner name, including Cypress and both Docker runtime matrix jobs. Check the
slice's `memory.peak`, `memory.swap.peak` and `memory.events` under
`/sys/fs/cgroup/ci.slice/ci-runner.slice/`; retain before/after OOM counters and
job timings. Check `systemctl show user@1001.service -p ControlGroup` and the
outer container's `HostConfig.CgroupParent`.

Also verify a Docker bind-mount fixture, isolation from `/home/fg`, drain while a
job is busy, a manual refresh, recovery after container exit and a host reboot.
The fixture must prove the job daemon reads the same workspace contents, not
merely that its socket responds. Nightly maintenance stays disabled until these
live checks pass.

```sh
sudo systemctl enable ci-runner.service
sudo systemctl enable --now ci-runner-recover.timer
# Enable this only after live acceptance, including a manual refresh:
sudo systemctl enable --now ci-runner-refresh.timer
systemctl list-timers 'ci-runner*'
```

## Inspection and incident handling

```sh
sudo ci-host status
sudo ci-host refresh --dry-run
sudo systemctl start --no-block ci-runner-refresh.service
sudo journalctl -fu ci-runner-refresh.service
sudo journalctl -u ci-runner-recover.service --since today
sudo cat /sys/fs/cgroup/ci.slice/ci-runner.slice/memory.events
```

Stopping a controller process while it drains does not stop a job. The recorded
phase remains `draining`; recovery removes routing again and rechecks idle.
Do not manually add routing labels during maintenance. Repair expired PATs with
the token helper; retry with `sudo ci-host start` after repair. That explicit
command skips the automatic ten-minute backoff.

## Rollback

Record the preparation backup path and the old runner's private configuration
before cutover. No Docker cleanup can restore deleted local images/workspace;
image recovery pulls the recorded GHCR digest. Other volumes are not deleted.

1. Disable both timers and the boot unit:
   `sudo systemctl disable --now ci-runner-refresh.timer ci-runner-recover.timer`;
   `sudo systemctl disable ci-runner.service`. If refresh is currently draining,
   stop that **controller service**, not the runner. Withdraw `hetzner-ci` through
   GitHub and wait for `busy=false` and no `Runner.Worker` for 65 seconds before
   stopping `ucsl-hetzner-1`. Remove its GitHub registration when idle.
2. Delete the UCSL `CI_RUNS_ON` variable to restore hosted routing for new jobs:
   `gh variable delete CI_RUNS_ON -R franzgollhammer/ucsl-app`. Re-run queued
   workflows; this does not repair an exhausted hosted Actions budget.
3. Restore the old dotagents checkout's saved private `.env`, pull its recorded
   image, and run its original Compose/systemd command. Mint a new registration
   token if the saved configuration uses an expired short-lived one. Verify
   exactly one intended runner is online before restoring its scheduling.
4. After all UCSL jobs have stopped, stop its user manager with
   `sudo systemctl stop user@1001.service`, then
   `sudo loginctl disable-linger ci-ucsl`. Unmount the workspace if mounted:
   `sudo umount /srv/ci-runner/workspace`. Keep the account and Docker data until
   rollback is accepted; no recursive deletion is required.
5. For a full host rollback, restore only files present in the timestamped backup.
   Move newly installed `ci-runner*` system units, `ci-host`, `ci-host-set-token`
   and `user@1001.service.d/ci-runner.conf` into that backup before restoring their
   old copies. Do not overwrite unrelated edits to fstab or subordinate IDs. If
   the backup has `swap-created`, run `sudo swapoff /swap-ci-runner` only after
   verifying sufficient free memory, remove only its exact fstab line, and move
   `/swap-ci-runner` into the backup. Run `sudo systemctl daemon-reload`.
   Review the saved `units.txt` and restore prior enablement. Retain root-only
   token backups until the PAT is revoked; never put them in Git.

Useful upstream references: [Docker rootless setup](https://docs.docker.com/engine/security/rootless/),
[rootless limits](https://docs.docker.com/engine/security/rootless/tips/),
[GitHub runner REST API](https://docs.github.com/en/rest/actions/self-hosted-runners),
[routing labels](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-labels).
