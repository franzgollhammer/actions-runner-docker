#!/usr/bin/env python3
"""Usage: sudo ci-host-set-token. Read and validate a repo-scoped PAT from the TTY."""
import getpass
import json
import os
import pathlib
import sys
import tempfile
import time
import urllib.error
import urllib.request


def main():
    if os.geteuid() != 0 or not sys.stdin.isatty():
        raise SystemExit("Run as root in an interactive terminal; never pass the PAT as an argument")
    os.umask(0o077)
    path = pathlib.Path("/etc/ci-runner/github.token")
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise SystemExit("Prepare /etc/ci-runner first")
    token = getpass.getpass("UCSL-only fine-grained PAT (Administration: read/write): ").strip()
    if not token or any(c.isspace() for c in token):
        raise SystemExit("Empty or malformed PAT")
    request = urllib.request.Request(
        "https://api.github.com/repos/franzgollhammer/ucsl-app/actions/runners/registration-token",
        method="POST", data=b"", headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "ci-host-token-setup",
        })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if not json.loads(response.read()).get("token"):
                raise ValueError("No registration token")
    except (OSError, ValueError):
        raise SystemExit("GitHub could not validate runner administration permission; old token unchanged") from None
    if path.exists():
        if path.is_symlink() or not path.is_file():
            raise SystemExit("Refusing an unsafe token path")
        backup = path.with_name(f"github.token.backup-{time.time_ns()}")
        backup.write_bytes(path.read_bytes())
        os.chmod(backup, 0o600)
    descriptor, temporary = tempfile.mkstemp(prefix=".token-", dir=path.parent)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(token + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    print("Validated and saved root-only. The PAT is never mounted in the runner.")


if __name__ == "__main__":
    main()
