FROM docker.openhands.dev/openhands/agent-server:1.37.1-python

# Derived agent-server image for the hybrid-ai sandbox.
#
# The published base image ships the SDK but not the tools the repository's own
# checks need. The ShellCheck job in .github/workflows/sast-checks.yml runs in
# CI; a sandbox on the stock image cannot reproduce it locally, so an agent
# working a ShellCheck failure cannot iterate on it. shellcheck closes that gap.
#
# sqlite3, rsync and restic are the tools the agent needs to inspect and repair
# the repository's own state: the Open WebUI SQLite database, transfers into and
# out of the agent workspace, and backup verification. jq is already in the base
# image, so it is not reinstalled here.
#
# The base image start command (tini -- /usr/local/bin/openhands-agent-server)
# and its default command are inherited unchanged; this file overrides neither,
# so the sandbox still starts through tini exactly as before.

# Packages install as root, but the agent must never run as root: the sandbox
# processes untrusted text, so it stays the unprivileged openhands account.
# This is a single layer, and the apt list cleanup is in the same RUN so the
# package lists are never baked into the image.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends shellcheck sqlite3 rsync restic && rm -rf /var/lib/apt/lists/*

# Drop back to the unprivileged account the base image expects.
USER openhands
