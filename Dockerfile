# Self-registering GitHub Actions runner on top of the official runner image
# (Ubuntu 24.04, runner in /home/runner, user "runner" with passwordless sudo,
# Docker CLI and buildx). Dependabot keeps tag and digest current.
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232

# apt packages your jobs need, space-separated, e.g. "build-essential python3".
ARG EXTRA_APT_PACKAGES=""

USER 0
# hadolint ignore=DL3008,SC2086
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini ${EXTRA_APT_PACKAGES} \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# "runner" from the base image; numeric so Kubernetes can verify runAsNonRoot.
USER 1001
# tini reaps orphaned job processes and passes docker stop on to the entrypoint.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
