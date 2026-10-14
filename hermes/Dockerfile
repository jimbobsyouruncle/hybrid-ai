FROM python:3.11-slim

# Install system dependencies
# Add retry flags and quiet output to prevent mirror timeouts
RUN apt-get update -o Acquire::Retries=5 && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        coreutils \
        findutils \
        build-essential \
        libxi6 && \
    rm -rf /var/lib/apt/lists/*

# --- Pinned Hermes Agent, installed OUTSIDE the data volume ------------------
# The code must never live under /root/.hermes: that path is a bind-mount point
# for the hermes_data volume, and a mount hides whatever the image wrote there.
# On the Pi the image's own install only appeared to work because
# hermes_data/hermes-agent held a separate copy; a restore to a fresh host
# failed with
#   exec: /root/.hermes/hermes-agent/.hermes/bin/hermes: not found
# So the code is installed at a PINNED commit under /opt/hermes-agent. The
# installer bytes are verified BEFORE they run: the script is fetched to a FILE
# and its sha256 checked, never piped from the network into a shell.
#
# Upgrade = a PR that bumps HERMES_COMMIT and HERMES_INSTALL_SHA256 together and
# re-checks that patches/0001-kanban-prompt-body-chars.patch still applies.
ARG HERMES_COMMIT=3d0a61ac94e1181985177fdd975c4efeb478e9b7
ARG HERMES_INSTALL_SHA256=25d3c95550e5ed7c0eec180a7d78dde765721c4e33639ab257c154c0a6e7554f
ARG HERMES_INSTALL_DIR=/opt/hermes-agent

# The local patch ships in the build context (context is ./hermes).
COPY patches/0001-kanban-prompt-body-chars.patch /tmp/hermes-patch/0001-kanban-prompt-body-chars.patch

# One RUN: download and verify the installer; install at the pin with a
# THROWAWAY HOME and HERMES_HOME, while the pinned toolchain store is written
# straight to "${HERMES_INSTALL_DIR}/tools" (HERMES_RUNTIME_DIR) so the
# published launcher hardcodes its final path; apply the local patch; prove the
# pin; move the dependency tree from the throwaway home into the code dir and
# rewrite the throwaway prefix it baked in; record a payload manifest so the
# deps are found beside the code; mark the stamp external; byte-compile with the
# pinned interpreter; seal the tree; delete every throwaway path. The image's
# /root/.hermes is never created (the throwaway HOME guarantees it).
RUN set -eu; \
    curl -fsSL -o /tmp/hermes-install.sh \
      "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh" \
 && echo "${HERMES_INSTALL_SHA256}  /tmp/hermes-install.sh" | sha256sum -c - \
 && HOME=/tmp/hermes-home \
    HERMES_HOME=/tmp/hermes-home \
    HERMES_RUNTIME_DIR="${HERMES_INSTALL_DIR}/tools" \
    bash /tmp/hermes-install.sh \
      --commit "${HERMES_COMMIT}" \
      --dir "${HERMES_INSTALL_DIR}" \
      --hermes-home /tmp/hermes-home \
      --non-interactive --skip-computer-use \
 && git -C "${HERMES_INSTALL_DIR}" apply --check /tmp/hermes-patch/0001-kanban-prompt-body-chars.patch \
 && git -C "${HERMES_INSTALL_DIR}" apply /tmp/hermes-patch/0001-kanban-prompt-body-chars.patch \
 && test "$(git -C "${HERMES_INSTALL_DIR}" rev-parse HEAD)" = "${HERMES_COMMIT}" \
 && mv /tmp/hermes-home/installs "${HERMES_INSTALL_DIR}/installs" \
 && { grep -rlI '/tmp/hermes-home' "${HERMES_INSTALL_DIR}/installs" \
        | xargs -r sed -i "s#/tmp/hermes-home#${HERMES_INSTALL_DIR}#g" || true; } \
 && VENV="$(find "${HERMES_INSTALL_DIR}/installs" -type d -name venv | head -n1)" \
 && python3 -c 'import json,pathlib,sys; d=pathlib.Path(sys.argv[1]); v=pathlib.Path(sys.argv[2]); \
      (d.parent / "manifest.json").write_text(json.dumps({"schema": 1, "target": "linux", \
      "repo": d.name, "venv": str(v.relative_to(d.parent)), "store": d.name + "/tools", \
      "launchers": ["hermes", "hermes-acp"]}, indent=2) + "\n")' "${HERMES_INSTALL_DIR}" "${VENV}" \
 && python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]) / "install-stamp.json"; \
      s=json.loads(p.read_text()); s["updateMechanism"] = "external"; p.write_text(json.dumps(s) + "\n")' "${HERMES_INSTALL_DIR}" \
 && STORE_PY="$(find "${HERMES_INSTALL_DIR}/tools" -maxdepth 3 -type f -name 'python3.*' -path '*/bin/*' | head -n1)" \
 && "${STORE_PY}" -m compileall -q "${HERMES_INSTALL_DIR}" \
 && test "$(stat -c '%u' "${HERMES_INSTALL_DIR}")" = "0" \
 && rm -rf "${HERMES_INSTALL_DIR}/.git" \
 && rm -rf /tmp/hermes-home /tmp/hermes-install.sh /tmp/hermes-patch /root/.hermes

# Clone and build Hermes WebUI
WORKDIR /app
RUN git clone https://github.com/nesquena/hermes-webui.git .
RUN pip install --no-cache-dir -r requirements.txt

# Dedicated non-root service account. Created after the install and WORKDIR/pip
# steps, which run as root at build time; the image then runs as this uid.
# Defaults match the compose `build.args`, so a build with no args still gets a
# valid non-root uid.
ARG HYBRID_AI_UID=10001
ARG HYBRID_AI_GID=10001
RUN groupadd --gid "${HYBRID_AI_GID}" hermes && \
    useradd --uid "${HYBRID_AI_UID}" --gid "${HYBRID_AI_GID}" \
        --home-dir /root --no-create-home --shell /usr/sbin/nologin hermes && \
    chown -R "${HYBRID_AI_UID}:${HYBRID_AI_GID}" /root /app
# The Hermes code is root-owned and outside every mount, so it stays immutable
# to the runtime uid. The chown above makes /root writable by that uid, so the
# launcher MUST NOT live there: PATH resolves `hermes` to the install's own
# root-owned ${HERMES_INSTALL_DIR}/.hermes/bin/hermes. /opt is never chowned.

# HOME stays /root. Saved state under hermes_data/ holds absolute /root/...
# paths and the compose volume paths are unchanged, so this must not move.
ENV HOME=/root
# Put the root-owned launcher on PATH from the image environment so CMD needs no
# shell init, and `hermes` resolves outside /root/.hermes.
ENV PATH="${HERMES_INSTALL_DIR}/.hermes/bin:${PATH}"
# The image precompiles the tree and ships no .git, so the runtime uid never
# needs to write bytecode or a checkout fingerprint under the immutable install.
ENV PYTHONDONTWRITEBYTECODE=1

EXPOSE 8501 8642

USER ${HYBRID_AI_UID}:${HYBRID_AI_GID}

# The single start command. No compose `command:` overrides it. The gateway runs
# in the background as the default profile -- a sticky named active profile
# would otherwise be refused a gateway -- then bootstrap.py execs as PID 1. The
# port is POSITIONAL: bootstrap.py has no --port flag.
CMD ["bash", "-c", "hermes -p default gateway run --replace & exec python3 bootstrap.py --host 0.0.0.0 --foreground --no-browser 8501"]
