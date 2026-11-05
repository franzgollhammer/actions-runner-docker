#!/usr/bin/env python3
"""Usage: ci-host {start,status,refresh,recover} [--dry-run] [--config PATH].

Root-owned lifecycle controller for an exclusive Linux CI host. Jobs never get
its GitHub credential or the system Docker socket. All writes share one lock.
"""

import argparse
import fcntl
import grp
import json
import os
import pathlib
import pwd
import re
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request


class Error(RuntimeError):
    pass


def log(message):
    print(f"[ci-host] {message}", flush=True)


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    directory = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise Error(f"{path} must be a root-owned regular file, mode 600")


def image_digest(manifest, reference):
    """Select Linux x64 explicitly; never accidentally emulate ARM on Hetzner."""
    for item in manifest.get("manifests", []):
        platform = item.get("platform", {})
        digest = item.get("digest", "")
        if platform.get("os") == "linux" and platform.get("architecture") == "amd64":
            if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
                raise Error("Registry returned an invalid image digest")
            repository = reference.split("@")[0].rsplit(":", 1)[0]
            return f"{repository}@{digest}"
    raise Error("Published image must contain a Linux amd64 manifest")


def validate_subids(contents, account_ids, user):
    """Reject overlapping namespace ranges or ranges containing real accounts."""
    ranges = []
    for line in contents.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        owner, start, count = line.split(":")
        ranges.append((owner, int(start), int(start) + int(count)))
    ours = [v for v in ranges if v[0] == user]
    if not ours or not any(end - start >= 65536 for _, start, end in ours):
        raise Error("Dedicated CI account needs at least 65536 subordinate IDs")
    for owner, start, end in ours:
        if start < 100000 or end <= start or any(start <= uid < end for uid in account_ids):
            raise Error("CI subordinate IDs overlap real account IDs")
        if any(other != owner and max(start, low) < min(end, high)
               for other, low, high in ranges):
            raise Error("CI subordinate IDs overlap another user's range")


def validate_local_accounts(user):
    # CVE-2024-56433: default subuid ranges can overlap network identities.
    nss = pathlib.Path("/etc/nsswitch.conf").read_text()
    for line in nss.splitlines():
        if line.startswith(("passwd:", "group:", "subid:")):
            sources = line.partition(":")[2].partition("#")[0].split()
            if any(source not in ("files", "systemd") for source in sources):
                raise Error("Network account/subid sources need a separate ID-range audit")
    mounts = pathlib.Path("/proc/mounts").read_text().splitlines()
    if any(line.split()[2] in ("nfs", "nfs4") for line in mounts):
        raise Error("NFS mounts need a separate subordinate-ID audit")
    validate_subids(pathlib.Path("/etc/subuid").read_text(), [v.pw_uid for v in pwd.getpwall()], user)
    validate_subids(pathlib.Path("/etc/subgid").read_text(), [v.gr_gid for v in grp.getgrall()], user)


class Controller:
    def __init__(self, config):
        self.config = config
        self.repo = config["repository"]
        self.name = config["runner_name"]
        self.uid = config["ci_uid"]
        self.user = config["ci_user"]
        self.image = config["image"]
        self.route = "hetzner-ci"
        self.volume = "ci-ucsl-work"
        self.workspace = pathlib.Path("/srv/ci-runner/workspace")
        self.root = pathlib.Path("/var/lib/ci-runner")
        self.state_path = self.root / "state.json"
        self.clock = time.monotonic
        self.sleep = time.sleep
        self.state = {}
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text())
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", self.repo):
            raise Error("Invalid repository")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", self.name):
            raise Error("Invalid runner name")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", self.user):
            raise Error("Invalid CI user")
        if not isinstance(self.uid, int) or self.uid < 1001:
            raise Error("CI user must have a dedicated unprivileged UID")
        if not re.fullmatch(r"ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+:[A-Za-z0-9_.-]+", self.image):
            raise Error("Use an explicit GHCR image tag")

    def save(self, **changes):
        self.state.update(changes)
        atomic_json(self.state_path, self.state)

    def command(self, *args, timeout=120, check=True, input_text=None):
        environment = {k: v for k, v in os.environ.items()
                       if not k.startswith(("DOCKER_", "GH_", "GITHUB_"))}
        environment.update(PATH="/usr/sbin:/usr/bin:/sbin:/bin",
                           DOCKER_CONFIG=str(self.root / "docker-client"))
        try:
            result = subprocess.run(args, input=input_text, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, env=environment, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Error(f"{pathlib.Path(args[0]).name} did not complete") from exc
        if check and result.returncode:
            # Do not echo subprocess output: pulls may contain signed URLs and
            # untrusted containers can emit credentials or terminal escapes.
            raise Error(f"{pathlib.Path(args[0]).name} failed (exit {result.returncode})")
        return result

    def docker(self, engine, *args, **options):
        endpoints = {"host": "unix:///var/run/docker.sock",
                     "jobs": f"unix:///run/user/{self.uid}/docker.sock"}
        return self.command("/usr/bin/docker", "--host", endpoints[engine], *args, **options)

    def api(self, method, suffix, payload=None, missing=False):
        token_path = pathlib.Path(self.config["github_token_file"])
        private_file(token_path)
        token = token_path.read_text().strip()
        if not token or any(c.isspace() for c in token):
            raise Error("GitHub token file is empty or malformed")
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}/actions/runners{suffix}",
            data=data, method=method, headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "ci-host",
            })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as exc:
            if missing and exc.code == 404:
                return None
            raise Error(f"GitHub {method} {suffix.split('?')[0]}: HTTP {exc.code}") from None
        except (OSError, ValueError) as exc:
            raise Error("GitHub API unavailable or invalid response") from exc

    def runner(self):
        found = []
        page = 1
        while True:
            response = self.api("GET", f"?per_page=100&page={page}")
            runners = response["runners"]
            found.extend(r for r in runners if r["name"] == self.name)
            if len(runners) < 100:
                break
            page += 1
        if len(found) > 1:
            raise Error("More than one registration has the configured runner name")
        return found[0] if found else None

    def container(self):
        result = self.docker("host", "container", "inspect", self.name, check=False)
        if result.returncode:
            # A failed daemon connection is not an absent container.
            self.docker("host", "info", "--format", "{{.ID}}")
            return None
        return json.loads(result.stdout)[0]

    def workers(self):
        container = self.container()
        if not container or not container["State"]["Running"]:
            return False
        result = self.docker("host", "top", self.name, "-eo", "comm")
        return any("Runner.Worker" in row for row in result.stdout.splitlines())

    def guard(self):
        if sys.platform != "linux" or os.geteuid() != 0:
            raise Error("Run on the configured Linux host as root")
        if socket.gethostname() != self.config["hostname"]:
            raise Error("Host name does not match; refusing Docker operations")
        if self.config.get("allow_host_wide_reset") is not True:
            raise Error("Host-wide CI reset must be explicitly enabled in host.json")
        account = pwd.getpwnam(self.user)
        if account.pw_uid != self.uid or account.pw_shell != "/usr/sbin/nologin":
            raise Error("Dedicated CI account does not match configuration")
        validate_local_accounts(self.user)
        self.docker("host", "info", "--format", "{{.ID}}")
        info = json.loads(self.docker("jobs", "info", "--format", "{{json .}}").stdout)
        if not any("rootless" in v for v in info.get("SecurityOptions", [])):
            raise Error("Job daemon is not rootless")
        if info.get("CgroupDriver") != "systemd" or str(info.get("CgroupVersion")) != "2":
            raise Error("Rootless daemon must use systemd and cgroup v2")
        group = self.command("/usr/bin/systemctl", "show", f"user@{self.uid}.service",
                             "--property=ControlGroup", "--value").stdout.strip()
        if not group.startswith("/ci.slice/ci-runner.slice/"):
            raise Error("Rootless daemon is outside the shared CI resource slice")
        limits = self.command("/usr/bin/systemctl", "show", "ci-runner.slice",
                              "--property=MemoryHigh,MemoryMax,MemorySwapMax").stdout
        configured = dict(line.split("=", 1) for line in limits.splitlines())
        if configured != {"MemoryHigh": "2684354560", "MemoryMax": "2952790016",
                          "MemorySwapMax": "2147483648"}:
            raise Error("Shared CI memory limits do not match the 4 GB host budget")
        parent = self.workspace.parent
        if parent.resolve() != parent or parent.stat().st_uid != 0 or parent.stat().st_mode & 0o022:
            raise Error("Workspace parent must be root-owned and not writable by jobs")

    def inventory(self):
        engines = {}
        for engine in ("host", "jobs"):
            engines[engine] = {
                "containers": self.docker(engine, "ps", "-a", "--format", "{{.Names}}").stdout.splitlines(),
                "images": self.docker(engine, "image", "ls", "-q").stdout.splitlines(),
            }
        return engines

    def resolve(self):
        manifest = json.loads(self.docker("host", "manifest", "inspect", self.image, timeout=120).stdout)
        return image_digest(manifest, self.image)

    def remove_route(self, runner):
        if runner and any(v["name"] == self.route for v in runner["labels"]):
            self.api("DELETE", f"/{runner['id']}/labels/{self.route}")

    def drain(self):
        log("Withdrawing routing label; waiting for assigned jobs without a deadline")
        idle_since = None
        while True:
            runner = self.runner()
            self.remove_route(runner)
            # Re-read after label withdrawal; already assigned jobs may start late.
            runner = self.runner()
            route_present = runner and any(v["name"] == self.route for v in runner["labels"])
            busy = bool(runner and runner["busy"]) or self.workers() or route_present
            if busy:
                idle_since = None
            elif idle_since is None:
                idle_since = self.clock()
            elif self.clock() - idle_since >= 65:
                log("Runner idle for 65 seconds; safe to stop")
                return
            self.sleep(5)

    def deregister(self):
        runner = self.runner()
        if runner:
            if runner["busy"]:
                raise Error("Runner became busy; refusing deregistration")
            self.api("DELETE", f"/{runner['id']}")

    def archive(self):
        if not self.container():
            return
        directory = pathlib.Path("/var/log/ci-runner")
        destination = directory / f"runner-{time.time_ns()}.log"
        result = self.docker("host", "logs", "--tail", "2000", self.name, check=False)
        destination.write_text((result.stdout + result.stderr)[-2_000_000:])
        os.chmod(destination, 0o600)
        for old in sorted(directory.glob("runner-*.log"))[:-7]:
            old.unlink()

    def mounted(self):
        return self.command("/usr/bin/mountpoint", "-q", str(self.workspace), check=False).returncode == 0

    def purge(self):
        """Only called after routing withdrawal and drain, including during recovery."""
        if self.workers():
            raise Error("Worker still present; refusing cleanup")
        self.archive()
        container = self.container()
        if container and container["State"]["Running"]:
            self.docker("host", "stop", "--time", "90", self.name, timeout=120)
        self.deregister()
        self.save(phase="purging")
        # Stop job containers before removing the shared workspace mount.
        for engine in ("jobs", "host"):
            ids = self.docker(engine, "ps", "-aq").stdout.split()
            if ids:
                self.docker(engine, "stop", "--time", "30", *ids, timeout=300)
                self.docker(engine, "rm", *ids)
            self.docker(engine, "builder", "prune", "--all", "--force", timeout=600)
            # Buildx's docker-container driver stores caches in named volumes.
            volumes = self.docker(engine, "volume", "ls", "--format", "{{.Name}}").stdout.splitlines()
            caches = [v for v in volumes if re.fullmatch(r"buildx_buildkit_.+_state", v)]
            if caches:
                self.docker(engine, "volume", "rm", *caches)
            self.docker(engine, "image", "prune", "--all", "--force", timeout=600)
        if self.mounted():
            self.command("/usr/bin/umount", str(self.workspace))
        volumes = self.docker("host", "volume", "ls", "--format", "{{.Name}}").stdout.splitlines()
        if self.volume in volumes:
            self.docker("host", "volume", "rm", self.volume)
        inventory = self.inventory()
        if any(v["containers"] or v["images"] for v in inventory.values()):
            raise Error("Cleanup left containers or images behind")
        log("Both engines have zero containers and images; workspace removed")

    def mount_workspace(self):
        self.docker("host", "volume", "create", "--label", "io.ci-runner.managed=ucsl", self.volume)
        volume = json.loads(self.docker("host", "volume", "inspect", self.volume).stdout)[0]
        if volume.get("Driver") != "local" or volume.get("Options"):
            raise Error("Workspace must be an ordinary host-managed local Docker volume")
        if (volume.get("Labels") or {}).get("io.ci-runner.managed") != "ucsl":
            raise Error("Refusing to adopt an unmanaged workspace volume")
        source = pathlib.Path(volume["Mountpoint"])
        # Only the trusted system daemon chooses this source; the job daemon
        # cannot trick this root process into chowning or mounting host files.
        if source.resolve() != source or not source.is_dir():
            raise Error("Workspace volume has an unsafe mountpoint")
        if not self.mounted():
            if any(self.workspace.iterdir()):
                raise Error("Refusing to hide existing files under the workspace mount")
            self.command("/usr/bin/mount", "--bind", str(source), str(self.workspace))
        current = self.workspace.stat()
        if current.st_dev != source.stat().st_dev or current.st_ino != source.stat().st_ino:
            raise Error("A different filesystem is mounted at the workspace path")
        os.chown(self.workspace, self.uid, self.uid)
        os.chmod(self.workspace, 0o700)

    def wait_online(self):
        deadline = self.clock() + 180
        while self.clock() < deadline:
            container = self.container()
            if not container or not container["State"]["Running"]:
                raise Error("Runner container exited before becoming ready")
            runner = self.runner()
            if runner and runner["status"] == "online":
                labels = {v["name"].lower() for v in runner["labels"]}
                if "ucsl" not in labels or not labels <= {"ucsl", self.route}:
                    raise Error("Runner registration has unexpected routing labels")
                if container["HostConfig"]["CgroupParent"] != "ci-runner.slice":
                    raise Error("Runner is outside the shared CI resource slice")
                self.docker("host", "exec", self.name, "docker", "info", "--format", "{{.ID}}")
                self.api("POST", f"/{runner['id']}/labels", {"labels": [self.route]})
                return
            self.sleep(5)
        raise Error("Runner did not become online within three minutes")

    def launch(self, digest):
        if not re.fullmatch(r"ghcr\.io/[a-z0-9_.-]+/[a-z0-9_.-]+@sha256:[0-9a-f]{64}", digest):
            raise Error("Refusing an unpinned runner image")
        self.save(phase="starting", target=digest)
        self.docker("host", "pull", digest, timeout=1200)
        self.mount_workspace()
        token = self.api("POST", "/registration-token")["token"]
        if not token or any(c.isspace() for c in token):
            raise Error("GitHub returned a malformed registration token")
        # stdin, never command arguments or the persistent host environment.
        environment = "\n".join([
            f"GITHUB_URL=https://github.com/{self.repo}", f"RUNNER_NAME={self.name}",
            "RUNNER_LABELS=ucsl", "NO_DEFAULT_LABELS=true", "EPHEMERAL=false",
            "DISABLE_AUTO_UPDATE=false", "CLEAN_WORKDIR_ON_EXIT=false",
            f"RUNNER_WORKDIR={self.workspace}", f"RUNNER_TOKEN={token}", "",
        ])
        self.docker("host", "run", "--detach", "--name", self.name,
                    "--restart=no", "--cgroup-parent=ci-runner.slice",
                    "--shm-size=512m", "--log-driver=json-file",
                    "--log-opt=max-size=10m", "--log-opt=max-file=3",
                    "--label=io.ci-runner.managed=ucsl", "--env-file=/dev/stdin",
                    "--mount", f"type=bind,src={self.workspace},dst={self.workspace}",
                    "--mount", f"type=bind,src=/run/user/{self.uid}/docker.sock,dst=/var/run/docker.sock",
                    digest, input_text=environment)
        self.wait_online()
        self.save(phase="active", image=digest, target=None, previous=None, rollback=False,
                  last_success=time.time(), next_retry=0, error=None)
        log(f"One runner online for {self.repo}: {digest}")

    def refresh(self):
        # Resolve before withdrawing labels or deleting anything. Recovery uses
        # the recorded digest, not a newly moved tag halfway through a reset.
        target = self.state.get("target") or self.resolve()
        previous = self.state.get("previous") or self.state.get("image")
        self.runner()  # verify credentials before starting maintenance
        self.save(phase="draining", target=target, previous=previous, next_retry=0)
        self.drain()
        self.purge()
        try:
            self.launch(target)
        except Error:
            if not previous or previous == target:
                raise
            log("New image could not start; recreating the last successful digest")
            self.save(target=previous)
            self.drain()
            self.purge()
            self.launch(previous)
            self.save(rollback=True)

    def start(self):
        if self.state.get("phase") not in (None, "active"):
            self.refresh()
            return
        container = self.container()
        if container:
            try:
                if not self.runner():
                    raise Error("Existing container lost its GitHub registration")
                self.mount_workspace()
                if not container["State"]["Running"]:
                    self.docker("host", "start", self.name)
                self.wait_online()
            except Error:
                # A daemon restart replaces its socket inode. Restarting the
                # same outer container can retain the stale bind mount; a
                # removed GitHub registration likewise cannot be reused.
                # Drain before replacing it, and reuse the known-good digest.
                self.save(target=self.state.get("image"), previous=self.state.get("image"))
                self.refresh()
                return
            self.save(phase="active", next_retry=0, error=None)
            return
        # Bootstrap must not accidentally run alongside the old dotagents set.
        if self.docker("host", "ps", "-aq").stdout.strip():
            raise Error("Retire existing host containers before starting the UCSL runner")
        self.launch(self.state.get("image") or self.resolve())

    def recover(self):
        if self.state.get("next_retry", 0) > time.time():
            return
        self.start()

    def execute(self, action, dry_run=False):
        self.guard()
        if dry_run or action == "status":
            print(json.dumps({"repository": self.repo, "runner": self.name,
                              "state": self.state, "engines": self.inventory(),
                              "reset": "all containers/images/build caches; ci-ucsl-work volume",
                              "other_volumes": "preserved"}, indent=2))
            return
        try:
            getattr(self, action)()
        except Error as exc:
            self.save(next_retry=time.time() + 600, error=str(exc))
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "status", "refresh", "recover"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--config", type=pathlib.Path, default=pathlib.Path("/etc/ci-runner/host.json"))
    args = parser.parse_args()
    os.umask(0o077)
    try:
        private_file(args.config)
        controller = Controller(json.loads(args.config.read_text()))
        with (controller.root / "controller.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                log("Another lifecycle operation is already running")
                return 0
            controller.execute(args.action, args.dry_run)
        return 0
    except (Error, OSError, KeyError, ValueError) as exc:
        # Values from Docker/GitHub are not printed; these are controller errors.
        log(str(exc) if isinstance(exc, Error) else f"Invalid configuration/state ({type(exc).__name__})")
        return 1


if __name__ == "__main__":
    sys.exit(main())
