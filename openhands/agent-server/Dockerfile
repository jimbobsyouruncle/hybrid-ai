FROM docker.openhands.dev/openhands/agent-server:1.37.1-python

# Derived agent-server image for the hybrid-ai sandbox.
#
# The published base image ships the SDK but not the tools the repository's own
# checks need. The ShellCheck and Semgrep (SAST) jobs in
# .github/workflows/sast-checks.yml run in CI; a sandbox on the stock image cannot
# reproduce them locally, so an agent working a finding cannot iterate on it.
# shellcheck and semgrep close that gap.
#
# VERSION PARITY IS THE POINT. The CI ShellCheck gate (ludeeus/action-shellcheck
# 2.0.0, track `stable`) runs ShellCheck 0.11.0. apt -- at this base image's
# snapshot -- still ships 0.10.0, so `apt-get install shellcheck` would leave the
# sandbox's PATH resolving 0.10.0 and diverge from the gate. An agent trusting
# the PATH binary would then iterate against findings the gate does not raise, or
# miss ones it does, and still see a false-red gate. So the pinned 0.11.0 static
# binary is installed to /usr/local/bin instead of the apt package: PATH must
# resolve 0.11.0 to match the gate. Fix a future divergence by RAISING the image
# to the gate's version, never by lowering the gate.
#
# SEMGREP PARITY. The SAST job runs the semgrep/semgrep:1.179.0 image (pinned at
# sha256:93963d9295a366f59e4850127b1550400ee7b388f04fe144e4a1f6325d96e01b) with
# `--config auto --error`. The image must match that version, so the pinned
# 1.179.0 aarch64 wheel is installed with the base image's own python3 -m pip.
# Fix a future divergence by RAISING the image to the gate's version, never by
# lowering the gate.
#
# `--config auto` needs metrics/egress: semgrep refuses to run it with
# SEMGREP_SEND_METRICS=off. The auto rules are fetched remotely from the Semgrep
# registry and are NOT version-pinned to the binary, so a green local scan cannot
# guarantee a green gate -- CI stays the authority. The parity that matters here
# is the engine version, so findings behave the same.
#
# sqlite3, rsync and restic are the tools the agent needs to inspect and repair
# the repository's own state: the Open WebUI SQLite database, transfers into and
# out of the agent workspace, and backup verification. jq is already in the base
# image, so it is not reinstalled here. curl and xz-utils are the fetch and
# extract dependencies for the pinned downloads below.
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

# Pinned Semgrep wheel, matching the semgrep/semgrep:1.179.0 CI gate. The wheel
# is the aarch64 manylinux_2_34 build for cp310-cp314; it is verified against
# this digest before install and its reported version is asserted, so a wrong
# wheel or a wrong version fails the build closed.
ARG SEMGREP_VERSION=1.179.0
ARG SEMGREP_WHEEL=semgrep-1.179.0-cp310.cp311.cp312.cp313.cp314.py310.py311.py312.py313.py314-none-manylinux_2_34_aarch64.whl
ARG SEMGREP_SHA256=c23d79c4839540372acc39b59aad167c1c7f3dc21bacacb27f19aa2edd79d271
ARG SEMGREP_URL=https://files.pythonhosted.org/packages/e3/ba/b9f1afbed852a21b6f7e72c064343161c5ab249954c46db1796b59314290

RUN apt-get update \
 && apt-get install -y --no-install-recommends sqlite3 rsync restic curl xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
      -o /tmp/shellcheck.tar.xz \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.aarch64.tar.xz" \
 && echo "${SHELLCHECK_SHA256}  /tmp/shellcheck.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/shellcheck.tar.xz -C /tmp \
 && install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
 && rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}" \
 && curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
      -o "/tmp/${SEMGREP_WHEEL}" \
      "${SEMGREP_URL}/${SEMGREP_WHEEL}" \
 && echo "${SEMGREP_SHA256}  /tmp/${SEMGREP_WHEEL}" | sha256sum -c - \
 && python3 -m pip install --no-cache-dir --disable-pip-version-check "/tmp/${SEMGREP_WHEEL}" \
 && rm -f "/tmp/${SEMGREP_WHEEL}" \
 && semgrep --version | grep -qx "${SEMGREP_VERSION}"

# Drop back to the unprivileged account the base image expects.
USER openhands
