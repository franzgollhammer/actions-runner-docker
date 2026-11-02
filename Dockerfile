# Self-registering GitHub Actions runner on top of the official runner image
# (Ubuntu 24.04, runner in /home/runner, user "runner" with passwordless sudo,
# Docker CLI and buildx). Dependabot keeps tag and digest current.
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232

# apt packages on top of the baseline below, space-separated, e.g. "redis-server".
ARG EXTRA_APT_PACKAGES=""

USER 0
# Baseline: what workflows written for ubuntu-latest assume is there and would
# otherwise have to install with sudo on every run. Toolchains with a version
# of their own (Node, Python, Chrome, the Cypress binary) are left to the
# workflows' setup actions, which cache them in the runner's tool cache.
#   tini                      reaps orphaned job processes, forwards docker stop
#   browser libraries, xvfb   Chrome, Chromium, Cypress, Playwright
#   fonts                     screenshots and PDF rendering
#   build-essential           native modules (node-gyp, pip wheels)
#   gh, shellcheck            scripts that assume ubuntu-latest
#   zip rsync file xz-utils   small tools scripts assume
# hadolint ignore=DL3008,SC2086
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        tini \
        xvfb xauth fonts-liberation fonts-noto-color-emoji \
        libgtk-3-0t64 libgtk2.0-0t64 libgbm1 libnotify4 libnss3 libxss1 libasound2t64 libxtst6 \
        libatk-bridge2.0-0t64 libcups2t64 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libpango-1.0-0 libcairo2 libatspi2.0-0t64 \
        build-essential python3-pip python3-venv \
        gh shellcheck \
        zip rsync file xz-utils openssh-client \
        ${EXTRA_APT_PACKAGES} \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# "runner" from the base image; numeric so Kubernetes can verify runAsNonRoot.
USER 1001
# tini reaps orphaned job processes and passes docker stop on to the entrypoint.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
