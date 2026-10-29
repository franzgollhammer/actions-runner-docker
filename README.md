# actions-runner-docker

A Docker container that runs a self-hosted GitHub Actions runner. On start it
registers itself with a repository, organization or enterprise, applies your
labels and waits for jobs. On stop it deregisters again.

It builds on the official runner image
[`ghcr.io/actions/actions-runner`](https://github.com/actions/runner/pkgs/container/actions-runner)
(Ubuntu 24.04, `linux/amd64` and `linux/arm64`) and adds only an entrypoint.

## How it works

1. The entrypoint exchanges `ACCESS_TOKEN` for a short-lived registration token
   through the GitHub API (or takes a `RUNNER_TOKEN` you supply).
2. It runs `config.sh --unattended` with the runner name, labels, group and work
   directory.
3. It starts `run.sh`. The runner opens an outbound HTTPS connection and long-polls
   GitHub for jobs; no inbound port is needed.
4. On `docker stop` it stops the runner and removes the registration with a removal
   token. Ephemeral runners remove themselves after their job, exit, and Docker
   restarts the container, which registers a fresh runner.

## Quick start

1. Create a token. For a repository: a
   [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)
   limited to that repository, with **Repository permissions → Administration: Read
   and write**. For an organization: **Organization permissions → Self-hosted
   runners: Read and write**.

2. Configure:

   ```sh
   cp .env.example .env
   # set GITHUB_URL, ACCESS_TOKEN and RUNNER_LABELS
   ```

3. Start and watch it register:

   ```sh
   docker compose up -d --build
   docker compose logs -f
   ```

   The log ends with `Listening for Jobs`. The runner also shows up under
   **Settings → Actions → Runners**, or:

   ```sh
   gh api repos/<owner>/<repo>/actions/runners \
     --jq '.runners[] | {name, status, labels: [.labels[].name]}'
   ```

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

Set these in `.env`; `compose.yaml` passes them to the container.

| Variable | Default | Meaning |
|---|---|---|
| `GITHUB_URL` | required | `https://github.com/<owner>/<repo>`, `https://github.com/<org>` or `https://github.com/enterprises/<name>`. GitHub Enterprise Server hosts work too. |
| `ACCESS_TOKEN` | | Token used to fetch registration and removal tokens. Recommended. |
| `RUNNER_TOKEN` | | Registration token instead of `ACCESS_TOKEN`. Expires after an hour; the runner can then neither re-register nor deregister. |
| `ACCESS_TOKEN_FILE`, `RUNNER_TOKEN_FILE` | | Read the token from a file instead, e.g. a Docker secret. |
| `RUNNER_LABELS` | | Extra labels, comma-separated. |
| `NO_DEFAULT_LABELS` | `false` | Drop the default labels `self-hosted`, `Linux`, `X64`/`ARM64`. |
| `RUNNER_NAME_PREFIX` | `docker` | Runners are named `<prefix>-<container id>`. |
| `RUNNER_NAME` | | Fixed name. Only for a single replica. |
| `RUNNER_GROUP` | `Default` | Runner group (organizations, enterprises). |
| `EPHEMERAL` | `true` (compose), `false` (plain `docker run`) | One job per registration, clean work directory every time. |
| `RUNNER_WORKDIR` | `_work` | Work directory, relative to `/home/runner`. Absolute paths get a subdirectory per runner. |
| `DISABLE_AUTO_UPDATE` | `false` | Stop the runner from updating itself. You then have to rebuild with a current image; GitHub stops sending jobs to runners that miss an update for 30 days. |
| `GITHUB_API_URL` | derived | API base URL, only needed for unusual Enterprise Server setups. |
| `RUNNER_CPUS`, `RUNNER_MEMORY` | `2`, `4g` | Limits per runner container. |
| `EXTRA_APT_PACKAGES` | | apt packages baked into the image at build time. |

## Ephemeral or persistent

With `EPHEMERAL=true` each runner takes exactly one job. GitHub removes the
registration, the container exits and restarts, its work directory is wiped and a
new runner registers. Jobs cannot see each other's checkouts or build output.
Everything else in the container (home directory, `/tmp`, packages a job installed
with `sudo`) survives the restart; `docker compose up -d --force-recreate` resets
that too.

With `EPHEMERAL=false` a runner stays registered and keeps its work directory and
tool cache between jobs. Faster, but jobs share state.

## Several runners, several repositories

Scale a runner set:

```sh
docker compose up -d --scale runner=3
```

Personal accounts have no account-wide runners, so each repository gets its own
set. Keep one env file per set and give each its own project name:

```sh
docker compose -p ucsl --env-file ucsl.env up -d --build
docker compose -p dotagents --env-file dotagents.env up -d --build
```

Organizations can register one set for all their repositories and steer access
with runner groups.

## Docker in jobs

Out of the box jobs cannot use Docker: `services:`, Docker container actions and
`docker build`/`docker run` steps fail. `compose.docker.yml`
mounts the host's Docker socket and adds the label `docker`:

```sh
# Linux host: the group that owns the socket
echo "DOCKER_GID=$(stat -c %g /var/run/docker.sock)" >> .env
docker compose -f compose.yaml -f compose.docker.yml up -d --build
```

The daemon runs on the host and resolves bind mounts there, so the work directory
moves to `/var/tmp/actions-runner/<runner name>` and is mounted at the same path in
the container (`RUNNER_DOCKER_WORKDIR` changes the location).

What works and what does not with the host's daemon:

| In a workflow | Works |
|---|---|
| `docker build`, `docker run`, also with `-v "$PWD:/src"` | yes |
| Docker container actions (`uses: docker://…`, Dockerfile actions) | yes |
| `services:` | yes, but they publish their ports on the host: use `host.docker.internal:<port>`, not `localhost:<port>` |
| `container:` jobs | no: the runner mounts its own `/home/runner/externals` into the job container, and that path exists only inside the runner container |

**Access to the Docker socket is root on the host.** Any workflow that runs on such
a runner can mount `/`, start privileged containers and take over the machine. Use
it only on a host that does nothing else, for repositories whose workflows you
trust, and keep those runners on their own label so other jobs do not land there.
A dedicated VM per runner set is the safer boundary.

## Extending the image

For a few packages set `EXTRA_APT_PACKAGES` and rebuild. For more, build your own
image on top:

```dockerfile
# after: docker build -t actions-runner-docker .
FROM actions-runner-docker
USER root
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
USER runner
```

Jobs run as user `runner`, which has passwordless `sudo`, so steps can also install
packages themselves.

## Security

- A self-hosted runner executes whatever the workflows of its repository tell it
  to. Use it only for private repositories and code you trust: on a public
  repository a pull request from a fork can run on your machine.
- Jobs run as the same user as the runner and can use `sudo`. The entrypoint keeps
  `ACCESS_TOKEN` out of the job environment, but a job that wants the token can
  still read it from the container. Give the token as little as possible: limit a
  fine-grained token to the repositories the runner serves. Repository
  **Administration** write access is broad; the organization permission
  **Self-hosted runners** is much narrower, so prefer organization runners where you
  can, or hand in a short-lived `RUNNER_TOKEN`.
- `.env` holds the token. It is ignored by git and excluded from the image build.
- Keep `EPHEMERAL=true` unless you need caches between jobs.
- Mount the Docker socket only as described under [Docker in jobs](#docker-in-jobs).

## Updating

Dependabot opens a pull request when a new runner image is released. After merging,
rebuild with `docker compose up -d --build`. Without a rebuild the runner updates
itself on start, which costs a few seconds every time a container is recreated.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `GitHub refused a registration token ...: Not Found` | Wrong `GITHUB_URL`, the token lacks the permission (GitHub answers 404 then), or a personal account used as organization URL. |
| `... Resource not accessible by personal access token` | Fine-grained token without the permission listed under Quick start. |
| `... Bad credentials` | Token mistyped, expired or revoked. |
| `/var/run/docker.sock is mounted but runner cannot use it` | `DOCKER_GID` does not match the socket's group; the log prints the right value. |
| Job stays queued | No online runner carries all labels from `runs-on`. Labels are case-insensitive. |

## Development

```sh
docker build -t actions-runner-docker:dev .
tests/smoke.sh actions-runner-docker:dev
shellcheck entrypoint.sh tests/smoke.sh tests/stubs/*.sh
```

CI runs ShellCheck, Hadolint, the compose checks, the image build and the smoke
tests on every pull request.
