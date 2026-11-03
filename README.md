# ci-runner

A Docker container that runs a self-hosted GitHub Actions runner. On start it
registers itself with a repository, organization or enterprise, applies your
labels and waits for jobs. On stop it deregisters again.

It builds on the official runner image
[`ghcr.io/actions/actions-runner`](https://github.com/actions/runner/pkgs/container/actions-runner)
(Ubuntu 24.04, `linux/amd64` and `linux/arm64`) and adds an entrypoint plus the
packages workflows written for `ubuntu-latest` assume (see
[Image baseline](#image-baseline)). CI publishes the result to
`ghcr.io/franzgollhammer/ci-runner`; hosts can pull instead of build.

## How it works

1. The entrypoint exchanges `ACCESS_TOKEN` for a short-lived registration token
   through the GitHub API (or takes a `RUNNER_TOKEN` you supply).
2. It runs `config.sh --unattended` with the runner name, labels, group and work
   directory.
3. It starts `run.sh`. The runner opens an outbound HTTPS connection and long-polls
   GitHub for jobs; no inbound port is needed.
4. On `docker stop` it stops the runner, or a registration still in progress, and
   removes the registration with a removal token, all within the 90 seconds compose
   allows. Ephemeral runners remove themselves after their job and exit; see
   [Ephemeral or persistent](#ephemeral-or-persistent) for what starts the next one.

## Quick start

1. Create a token. For a repository: a
   [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)
   limited to that repository, with **Repository permissions → Administration: Read
   and write**. For an organization: **Organization permissions → Self-hosted
   runners: Read and write**.

2. Configure:

   ```sh
   install -m 600 .env.example .env     # holds the token: yours only
   # set GITHUB_URL, ACCESS_TOKEN and RUNNER_LABELS
   ```

3. Start and watch it register:

   ```sh
   docker compose pull && docker compose up -d
   docker compose logs -f
   ```

   The log ends with `Listening for Jobs`. The runner also shows up under
   **Settings → Actions → Runners**, or:

   ```sh
   gh api repos/<owner>/<repo>/actions/runners \
     --jq '.runners[] | {name, status, labels: [.labels[].name]}'
   ```

   To build the image yourself instead of pulling it: `docker compose up -d --build`.

4. Send jobs to it. A job runs on a runner that has **all** labels listed in
   `runs-on`:

   ```yaml
   jobs:
     test:
       runs-on: [self-hosted, linux, containerized]
       steps:
         - uses: actions/checkout@v7
         - run: ./run-tests.sh
   ```

Stop with `docker compose down`; the runners deregister on the way out.

## Configuration

Set these in `.env`; `compose.yaml` passes them to the container. Switches take
`true`/`false` (also `1`/`0`, `yes`/`no`, `on`/`off`); anything else stops the
container with an error.

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_URL` | required | `https://github.com/<owner>/<repo>`, `https://github.com/<org>` or `https://github.com/enterprises/<name>`. GitHub Enterprise Server hosts work too. Only `https://`. |
| `ACCESS_TOKEN` | | Token used to fetch registration and removal tokens. Recommended. |
| `RUNNER_TOKEN` | | Registration token instead of `ACCESS_TOKEN`. Expires after an hour, so the runner cannot deregister on stop; a restarted container keeps using its registration. |
| `ACCESS_TOKEN_FILE`, `RUNNER_TOKEN_FILE` | | Read the token from a file instead; see [Token from a file](#token-from-a-file). |
| `RUNNER_LABELS` | | Extra labels, comma-separated. |
| `NO_DEFAULT_LABELS` | `false` | Drop the default labels `self-hosted`, `Linux`, `X64`/`ARM64`. |
| `RUNNER_NAME_PREFIX` | `docker` | Runners are named `<prefix>-<container id>`. |
| `RUNNER_NAME` | | Fixed name. Only for a single replica. |
| `RUNNER_GROUP` | `Default` | Runner group (organizations, enterprises). |
| `EPHEMERAL` | `true` (compose), `false` (plain `docker run`) | One job per registration, empty work directory for every job. |
| `RUNNER_WORKDIR` | `_work` | Work directory, relative to `/home/runner`. Absolute paths get a subdirectory per runner, removed when the runner exits. |
| `DISABLE_AUTO_UPDATE` | `false` | Stop the runner from updating itself. You then have to rebuild with a current image; GitHub stops sending jobs to runners that miss an update for 30 days. |
| `GITHUB_API_URL` | derived | API base URL, only needed for unusual Enterprise Server setups. Only `https://`. |
| `RUNNER_CPUS`, `RUNNER_MEMORY` | `2`, `4g` | Limits per runner container. |
| `RUNNER_IMAGE` | `ghcr.io/franzgollhammer/ci-runner:latest` | Image to run; pin a tag to roll back. |
| `EXTRA_APT_PACKAGES` | | apt packages on top of the [baseline](#image-baseline), for a local build only. |
| `RUNNER_DOCKER_LABELS` | `docker` | The only labels of runners started with `compose.docker.yml`, instead of `RUNNER_LABELS` and the defaults. |

### Token from a file

Put each runner set's token in its own file, named after the compose project
(`secrets/ucsl.token` for `-p ucsl`), and mount it with a `compose.override.yaml`
(both are ignored by git):

```yaml
services:
  runner:
    volumes:
      - ./secrets/${COMPOSE_PROJECT_NAME}.token:/run/secrets/access_token:ro
```

Then set `ACCESS_TOKEN_FILE=/run/secrets/access_token` in the env file. The token
stays out of `docker inspect`. The runner user (uid 1001) must be able to read the
file: `sudo chown 1001 secrets/ucsl.token && sudo chmod 400 secrets/ucsl.token`.

Compose reads `compose.override.yaml` on its own only when no file is named with
`-f` or `COMPOSE_FILE`. In Docker mode list it too:
`COMPOSE_FILE=compose.yaml:compose.docker.yml:compose.override.yaml`.

## Ephemeral or persistent

With `EPHEMERAL=true` each runner takes exactly one job, GitHub removes the
registration and the container exits. What happens next depends on how you started
it:

- **`docker compose up`**: Docker restarts the same container. The work directory
  is emptied, but everything else in the container survives, including changes a
  job made to the runner itself: jobs run as the runner's user and have `sudo`. One
  job can therefore affect every later one. Fine for workflows you trust; no
  isolation between jobs.
- **`systemd/actions-runner@.service`** (Linux): every job gets a new container
  from the image (`docker compose run --rm`), so what a job changes inside the
  runner container is gone. Use this when jobs must not be able to affect later
  ones. It does not hold in [Docker mode](#docker-in-jobs): with the host's daemon
  a job can change the host, this checkout included, and through it every later
  container.

  ```sh
  # repository checked out in /opt/ci-runner, ucsl.env next to it
  sudo cp systemd/actions-runner@.service /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now actions-runner@ucsl
  journalctl -fu actions-runner@ucsl
  ```

  The instance name is both the compose project and the env file (`ucsl.env`). A
  second runner for the same repository: `ln -s ucsl.env ucsl-2.env` (with a
  [token file](#token-from-a-file) also `ln -s ucsl.token secrets/ucsl-2.token`)
  and enable `actions-runner@ucsl-2`. The unit always runs ephemeral runners,
  whatever `EPHEMERAL` says, and needs `ACCESS_TOKEN`: a `RUNNER_TOKEN` lasts for
  one registration at most. It stays down instead of restarting when the env file
  is missing or incomplete, or the entrypoint exits with 78 (a setting that cannot
  work, a token GitHub turns down); `systemctl status actions-runner@ucsl` shows
  why.

### Persistent runners

With `EPHEMERAL=false` a runner stays registered and keeps its work directory, the
tool cache (`_work/_tool`, where `setup-node` and `setup-chrome` install), `~/.cache`
and the checkout with its dependencies between jobs. Faster, but jobs share state.
What survives which operation:

| Operation | Keeps |
|---|---|
| `docker compose restart` | everything above; running jobs are cut off; hung processes die; the runner keeps its name and re-registers |
| `docker compose up -d` after a change to `.env` or a new image | nothing: the container is recreated, the first job is cold |
| `docker compose down` | nothing, and the runners deregister |

A nightly restart from cron cleans up without losing caches and needs no compose
files:

```sh
docker restart $(docker ps -q --filter label=com.docker.compose.project=<project>)
```

Set `RUNNER_NAME_PREFIX` to the host name, so the runner list on GitHub tells where
a persistent runner lives. To go back to ephemeral runners, set `EPHEMERAL=true`
and run `docker compose up -d`; the caches are gone with the next job.

## Several runners, several repositories

Scale a runner set:

```sh
docker compose up -d --scale runner=3
```

Personal accounts have no account-wide runners, so each repository gets its own
set. Keep one env file per set and give each its own project name:

```sh
docker compose -p ucsl --env-file ucsl.env up -d
docker compose -p dotagents --env-file dotagents.env up -d
```

Organizations can register one set for all their repositories and steer access
with runner groups.

## Docker in jobs

Out of the box jobs cannot use Docker: `services:`, Docker container actions and
`docker build`/`docker run` steps fail. `compose.docker.yml` mounts the host's
Docker socket. Switch a runner set to it in its env file, which works for
`docker compose` and the systemd unit alike:

```sh
# Linux host: the group that owns the socket
echo "DOCKER_GID=$(stat -c %g /var/run/docker.sock)" >> .env
echo "COMPOSE_FILE=compose.yaml:compose.docker.yml" >> .env
docker compose up -d
```

These runners get only the labels in `RUNNER_DOCKER_LABELS` (default `docker`):
not `RUNNER_LABELS` and not the defaults `self-hosted`, `Linux`, `X64`, so no job
lands on them unless it asks for them by name:

```yaml
runs-on: docker
```

The daemon runs on the host and resolves bind mounts there, so the work directory
moves to `/var/lib/actions-runner/<compose project>/<runner name>`, mounted at the
same path in the container (`RUNNER_DOCKER_WORKDIR` changes the location). Docker
creates it as root. The runner refuses a mounted directory that other accounts can
write to or that someone other than root owns, since they could swap a runner's
directory for their own. Each runner's directory is readable only by the runner
user and removed when the runner exits. Runners of one compose project share the
parent directory; different projects do not. The runner user has uid 1001; if a
host account has that uid too, it can read the checkouts. On Docker Desktop set
`RUNNER_DOCKER_WORKDIR` to a shared path such as `/tmp/actions-runner/<project>`.

What works and what does not with the host's daemon:

| In a workflow | Works |
|---|---|
| `docker build`, `docker run`, also with `-v "$PWD:/src"` | yes |
| Docker container actions (`uses: docker://…`, Dockerfile actions) | yes |
| `services:` | yes, but they publish their ports on the host: use `host.docker.internal:<port>`, not `localhost:<port>` |
| `container:` jobs | no: the runner mounts its own `/home/runner/externals` into the job container, and that path exists only inside the runner container |

Published service ports are open on every host interface, and Docker's rules
bypass `ufw`. Let Docker pick the host port and read it from the job context, so
parallel jobs do not collide:

```yaml
services:
  db:
    image: postgres:17
    ports: ["5432"]
steps:
  - run: psql -h host.docker.internal -p ${{ job.services.db.ports['5432'] }} ...
```

and keep the host behind a firewall that drops inbound traffic.

**Access to the Docker socket is root on the host.** Any workflow that runs on such
a runner can mount `/`, start privileged containers and take over the machine. Use
it only on a host that does nothing else, for repositories whose workflows you
trust. Labels only route jobs; they do not stop a workflow from asking for
`docker`. A dedicated VM per runner set is the safer boundary.

## Image baseline

Jobs find in the image what `ubuntu-latest` would give them and what needs root to
install: the shared libraries for Chrome, Chromium, Cypress and Playwright (GTK,
NSS, GBM, ALSA and friends), `xvfb`, fonts, `build-essential` for native modules,
`python3-pip` and `python3-venv`, `gh`, `shellcheck`, `zip`, `rsync`, `file`,
`xz-utils`, `openssh-client`. The list lives in the `Dockerfile`; it adds about
0.9 GB to the 1.8 GB base image.

Toolchains with a version of their own are not in the image on purpose: Node,
Python, Chrome and the Cypress binary come from the workflows (`setup-node`,
`setup-python`, `setup-chrome`, `cypress install`) and land in the runner's tool
cache, so each repository keeps control of its versions. A version an action
brings wins over the image's: it is first in `PATH`.

For a local build, `EXTRA_APT_PACKAGES` adds packages; the published image ignores
it. For more, build your own image on top:

```dockerfile
FROM ghcr.io/franzgollhammer/ci-runner:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends redis-server \
    && rm -rf /var/lib/apt/lists/*
USER runner
```

Jobs run as user `runner`, which has passwordless `sudo`, so steps can also install
packages themselves; in a persistent container that costs time only once.

## Security

- A self-hosted runner executes whatever the workflows of its repository tell it
  to. Use it only for private repositories and code you trust: on a public
  repository a pull request from a fork can run on your machine.
- Jobs run as the same user as the runner and can use `sudo`. The entrypoint keeps
  `ACCESS_TOKEN` out of the job environment and off command lines, but a job that
  wants the token can still read it from the container. Give the token as little
  as possible: limit a fine-grained token to the repositories the runner serves.
  Repository **Administration** write access is broad; the organization permission
  **Self-hosted runners** is much narrower, so prefer organization runners where you
  can, or hand in a short-lived `RUNNER_TOKEN`.
- Jobs reach everything the host reaches: its LAN or tailnet, ports other
  containers publish, cloud metadata. Put the host where that is acceptable, for
  example tag it in your Tailscale ACLs so it cannot open connections to your own
  devices.
- `.env` and every `<set>.env` hold the token. They are ignored by git and
  excluded from the image build; keep them readable only by the account that runs
  compose (`chmod 600 *.env`). Otherwise every host account can read the token that
  the entrypoint keeps off process lists.
- For jobs that must not affect each other, run ephemeral runners through the
  systemd unit, not `docker compose up`.
- Mount the Docker socket only as described under [Docker in jobs](#docker-in-jobs).

## Publishing and updating

`.github/workflows/publish.yml` builds the image for `linux/amd64` and
`linux/arm64` on every push to `main` that touches the `Dockerfile` or the
entrypoint, and pushes it to `ghcr.io/franzgollhammer/ci-runner` with
the tags `latest`, the runner version from the `Dockerfile` (for example
`2.338.2`) and `sha-<commit>`. The package is public, so pulling needs no login.

Until 2026-11-03 the repository was called `actions-runner-docker`. GitHub redirects
the old repository URL. The old image `ghcr.io/franzgollhammer/actions-runner-docker`
keeps the tags it has but receives no new ones; hosts switch by pulling the new name
(the compose default, or `RUNNER_IMAGE`).

Dependabot opens a pull request when a new runner image is released. After
merging, CI publishes; hosts pick it up with `docker compose pull && docker compose
up -d`, which recreates the containers (the systemd unit builds on every start).
Without that, the runner updates itself on start, which costs a few seconds every
time a container is recreated, and GitHub stops sending jobs to runners that miss
an update for 30 days.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `GitHub refused a registration token ...: Not Found` | Wrong `GITHUB_URL`, the token lacks the permission (GitHub answers 404 then), or a personal account used as organization URL. |
| `... Resource not accessible by personal access token` | Fine-grained token without the permission listed under Quick start. |
| `... Bad credentials` | Token mistyped, expired or revoked. |
| `/var/run/docker.sock is mounted but unusable (... permission denied ...)` | `DOCKER_GID` does not match the socket's group; the message names the right value. |
| `EPHEMERAL must be true or false, got '...'` | Typo in a switch in `.env`. |
| Container exits with status 78 | A setting that cannot work, or a token GitHub turns down (HTTP 401/403/404, a refused `RUNNER_TOKEN`), named in the log; the systemd unit stops restarting. Exit status 1 (GitHub unavailable, rate limit, network) is retried. |
| `warning: could not remove <runner>` on stop | GitHub was unreachable within the 90 seconds a stop allows. The runner stays listed as offline until GitHub drops it (after a day for ephemeral runners, 14 days otherwise) or you delete it under **Settings → Actions → Runners**. |
| `ACCESS_TOKEN_FILE: ... is a directory` | The file to mount did not exist, so Docker created a directory in its place. Remove it and put the token file there. |
| `... is writable by others or not owned by root` | `RUNNER_DOCKER_WORKDIR` points into a directory other accounts can change; use one only root can. |
| `RUNNER_NAME may only contain ...` although the env file sets no name | Compose takes variables from the shell before the env file. Inside a GitHub Actions job `RUNNER_NAME` is already set to the job runner's name; unset it, and any other `RUNNER_*` from the job, before `docker compose`. |
| Job stays queued | No online runner carries all labels from `runs-on`. Labels are case-insensitive. |

## Development

```sh
docker build -t ci-runner:dev .
tests/smoke.sh ci-runner:dev
tests/compose.sh
tests/systemd.sh
shellcheck entrypoint.sh tests/*.sh tests/stubs/*
```

`tests/smoke.sh` and `tests/systemd.sh` replace `config.sh`, `run.sh` and `curl`
with the stubs in `tests/stubs`, so they need no GitHub access; `SMOKE_ONLINE=1`
adds three calls to the real API with made-up tokens. `tests/systemd.sh` runs the
unit's own commands in a temporary copy of the checkout. The scripts need bash 4.4
or newer and `timeout` (macOS: `brew install bash coreutils`). CI runs all of them,
plus ShellCheck, Hadolint and `systemd-analyze verify`, on every pull request.

## License

[MIT](LICENSE).
