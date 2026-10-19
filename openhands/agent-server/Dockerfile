FROM docker.openhands.dev/openhands/agent-server:1.37.1-python

# Derived agent-server image for the hybrid-ai sandbox.
#
# The published base image ships the SDK but not the tools the repository's own
# checks need. The ShellCheck job in .github/workflows/sast-checks.yml runs in
# CI; a sandbox on the stock image cannot reproduce it locally, so an agent
# working a ShellCheck failure cannot iterate on it. shellcheck closes that gap.
#
# VERSION PARITY IS THE POINT. The CI gate (ludeeus/action-shellcheck 2.0.0,
# track `stable`) runs ShellCheck 0.11.0. apt -- at this base image's snapshot --
# still ships 0.10.0, so `apt-get install shellcheck` would leave the sandbox's
# PATH resolving 0.10.0 and diverge from the gate. An agent trusting the PATH
# binary would then iterate against findings the gate does not raise, or miss
# ones it does, and still see a false-red gate. So the pinned 0.11.0 static
# binary is installed to /usr/local/bin instead of the apt package: PATH must
# resolve 0.11.0 to match the gate. Fix a future divergence by RAISING the image
# to the gate's version, never by lowering the gate.
#
# sqlite3, rsync and restic are the tools the agent needs to inspect and repair
# the repository's own state: the Open WebUI SQLite database, transfers into and
# out of the agent workspace, and backup verification. jq is already in the base
# image, so it is not reinstalled here. curl and xz-utils are the fetch and
# extract dependencies for the pinned ShellCheck download below.
#
# The base image start command (tini -- /usr/local/bin/openhands-agent-server)
# and its default command are inherited unchanged; this file overrides neither,
# so the sandbox still starts through tini exactly as before.

# Packages install as root, but the agent must never run as root: the sandbox
# processes untrusted text, so it stays the unprivileged openhands account.
# This is a single layer, and the apt list and temp cleanup are in the same RUN
# so neither the package lists nor the download are baked into the image.
USER root

# Pinned ShellCheck release. The static linux/arm64 build is verified against
# this digest before it is installed; a mismatch fails the build closed.
ARG SHELLCHECK_VERSION=0.11.0
ARG SHELLCHECK_SHA256=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588

RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 rsync restic curl xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
      -o /tmp/shellcheck.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.aarch64.tar.xz" \
 && echo "${SHELLCHECK_SHA256}  /tmp/shellcheck.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/shellcheck.tar.xz -C /tmp \
 && install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
 && rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}"

# Drop back to the unprivileged account the base image expects.
USER openhands
