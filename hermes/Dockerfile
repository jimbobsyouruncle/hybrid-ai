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

# --- Stable root-owned path to the pinned venv, from /opt/manifest.json -------
# discover_launcher_python() looks for <agent_dir>/venv or <agent_dir>/.venv, but
# /opt/hermes-agent has neither: its venv lives at
# /opt/hermes-agent/installs/<install_key>/venv (recorded in /opt/manifest.json).
# Create a fixed, root-owned symlink to it so HERMES_WEBUI_PYTHON is a stable path
# that never changes when the install key or Python patch changes. The build FAILS
# if the manifest has no venv or the venv has no interpreter.
RUN set -eu; \
    VENV="$(python3 -c 'import json,os,sys; m=json.load(open(sys.argv[1])); print(os.path.normpath(os.path.join(sys.argv[2], m["venv"])))' \
              "$(dirname "${HERMES_INSTALL_DIR}")/manifest.json" "$(dirname "${HERMES_INSTALL_DIR}")")" \
 && test -d "${VENV}" \
 && test -x "${VENV}/bin/python" \
 && ln -sfn "${VENV}" "${HERMES_INSTALL_DIR}/.hermes/venv" \
 && test -x "${HERMES_INSTALL_DIR}/.hermes/venv/bin/python" \
 && test "$(stat -Lc '%u' "${HERMES_INSTALL_DIR}/.hermes/venv")" = "0"

# Root-owned launcher under /usr/local/bin. The image ENV already prepends the
# install's own .hermes/bin, but a LOGIN shell rebuilds PATH from /etc/profile
# (where the old /root/.local/bin lives), so `bash -lc 'command -v hermes'` would
# miss it. /usr/local/bin is on every default PATH, so this one root-owned symlink
# makes `hermes` resolve in every shell, including non-interactive login shells.
RUN ln -sfn "${HERMES_INSTALL_DIR}/.hermes/bin/hermes" /usr/local/bin/hermes \
 && test "$(readlink /usr/local/bin/hermes)" = "${HERMES_INSTALL_DIR}/.hermes/bin/hermes"

# --- Pinned Hermes WebUI, immutable to the runtime uid -----------------------
# The WebUI is PID 1: it hosts every chat and its tools, so its code is pinned
# exactly like the agent. It is cloned, checked out at the pin, and asserted with
# `git rev-parse`; a mismatch fails the build. /app stays ROOT-OWNED and is not
# writable by the runtime uid, and its Python is byte-compiled here with the
# interpreter that runs it, so the server never writes bytecode at runtime (the
# WebUI's Python can run with -I, which ignores PYTHONDONTWRITEBYTECODE). The pin
# is the commit the Pi runs today. Upgrade = a PR bumping this commit.
ARG HERMES_WEBUI_COMMIT=1e2e4dde6520e5d96bb5b20dfb2f65aa890eeb5e
WORKDIR /app
RUN set -eu; \
    git clone --quiet https://github.com/nesquena/hermes-webui.git /app \
 && git -C /app checkout --quiet --detach "${HERMES_WEBUI_COMMIT}" \
 && test "$(git -C /app rev-parse HEAD)" = "${HERMES_WEBUI_COMMIT}" \
 && rm -rf /app/.git \
 && pip install --no-cache-dir -r /app/requirements.txt

# Dedicated non-root service account. Created after the install and WORKDIR/pip
# steps, which run as root at build time; the image then runs as this uid.
# Defaults match the compose `build.args`, so a build with no args still gets a
# valid non-root uid.
ARG HYBRID_AI_UID=10001
ARG HYBRID_AI_GID=10001
RUN groupadd --gid "${HYBRID_AI_GID}" hermes && \
    useradd --uid "${HYBRID_AI_UID}" --gid "${HYBRID_AI_GID}" \
        --home-dir /root --no-create-home --shell /usr/sbin/nologin hermes && \
    chown -R "${HYBRID_AI_UID}:${HYBRID_AI_GID}" /root
# Only /root (the data-volume mount point) becomes writable by the runtime uid.
# /app (the WebUI) and /opt/hermes-agent (the agent) are LEFT ROOT-OWNED, so the
# process that runs them cannot edit them. Byte-compile /app here, as root, with
# the interpreter that will run it, so the server never writes .pyc at runtime.
# The Hermes launcher therefore MUST NOT live under /root: PATH resolves `hermes`
# to the install's own root-owned ${HERMES_INSTALL_DIR}/.hermes/bin/hermes, plus
# the root-owned /usr/local/bin/hermes symlink. /opt is never chowned.
RUN "${HERMES_INSTALL_DIR}/.hermes/venv/bin/python" -m compileall -q /app \
 && test "$(stat -c '%u' /app)" = "0" \
 && ! find /app -user "${HYBRID_AI_UID}" -print -quit | grep -q .

# HOME stays /root. Saved state under hermes_data/ holds absolute /root/...
# paths and the compose volume paths are unchanged, so this must not move.
ENV HOME=/root
# Put the root-owned launcher on PATH from the image environment so CMD needs no
# shell init, and `hermes` resolves outside /root/.hermes. /usr/local/bin (the
# root-owned symlink above) is already on the default PATH, so a login shell
# resolves `hermes` too.
ENV PATH="${HERMES_INSTALL_DIR}/.hermes/bin:${PATH}"
# The image precompiles both trees and ships no .git, so the runtime uid never
# needs to write bytecode or a checkout fingerprint under the immutable install.
ENV PYTHONDONTWRITEBYTECODE=1

# --- Pin the WebUI to the /opt agent, never the data-volume copy -------------
# The bootstrap picks the Agent dir and Python in this order:
#   agent dir:  HERMES_WEBUI_AGENT_DIR -> $HERMES_HOME/hermes-agent (the data
#               volume) -> ... -> /opt/hermes-agent (late fallback)
#   python:     HERMES_WEBUI_PYTHON -> <agent_dir>/venv or .venv
# A data volume that still holds the old /root/.hermes/hermes-agent copy (kept
# for rollback until the migration) would therefore win, so BOTH are pinned here:
#   HERMES_WEBUI_AGENT_DIR   forces the code to /opt/hermes-agent
#   HERMES_WEBUI_PYTHON      forces the interpreter through the stable root-owned
#                            /opt/hermes-agent/.hermes/venv symlink
#   HERMES_WEBUI_SERVER_CWD  the server cwd defaults to the agent dir, which is
#                            now read-only to the runtime uid; point it at a
#                            runtime-writable path inside the data volume.
ENV HERMES_WEBUI_AGENT_DIR="${HERMES_INSTALL_DIR}"
ENV HERMES_WEBUI_PYTHON="${HERMES_INSTALL_DIR}/.hermes/venv/bin/python"
ENV HERMES_WEBUI_SERVER_CWD="/root/.hermes/webui"
# HERMES_HOME is pinned to the DATA VOLUME, never the install dir.
#
# Runtime dependency state -- pm/environments.py::install_state_dir(project) ->
# dependency_home_root()/installs/<install_key> -- resolves under
# get_default_hermes_root(), i.e. $HERMES_HOME when set, else $HOME/.hermes. The
# dependency lease that pins the selected venv generation is written at runtime
# as <install_state_dir>/environments/<uuid>/.leases by
# hermes_cli/runtime_state.py::lease_directory (called from
# pm/environments.py::activate_dependencies and pm/runtime.py
# ::lease_current_runtime). It MUST land on the writable volume.
#
# This ENV is load-bearing, not a default. The launchers Hermes publishes honour
# an explicit HERMES_HOME first and only fall back to a baked default:
# hermes_cli/_launchers.py::_launcher_script does
#   os.environ['HERMES_HOME'] = os.environ.get('HERMES_HOME') or <baked home>
# The build's path rewrite (the /tmp/hermes-home -> ${HERMES_INSTALL_DIR} sed
# above) can bake that default as /opt/hermes-agent, which would then resolve
# installs_root under the READ-ONLY install tree -- exactly the
# /opt/hermes-agent/installs/ffad.../environments/..../.leases write seen in the
# live container. Setting HERMES_HOME here makes the runtime path win over any
# baked default. The supported setting for this routing is HERMES_HOME; the smoke
# job asserts it is the data volume, alongside the `docker diff` check that the
# runtime never writes under /opt. install_state_dir('/opt/hermes-agent') is then
# /root/.hermes/installs/ffad2f5543956651 -- the data volume.
ENV HERMES_HOME="/root/.hermes"
# Fail closed if the pinned interpreter cannot run both the WebUI and the Agent.
# bootstrap.py::ensure_python_has_webui_deps would otherwise create /app/.venv at
# RUNTIME, which is a write into the read-only /app tree (and would trip the smoke
# job's `docker diff`). With this set it raises a clear error instead. The pinned
# /opt venv ships the Agent and ruamel.yaml, which the WebUI's api/yaml_compat.py
# accepts in place of PyYAML, so this only ever fires on a broken image.
ENV HERMES_WEBUI_DISABLE_LOCAL_VENV=1

EXPOSE 8501 8642

USER ${HYBRID_AI_UID}:${HYBRID_AI_GID}

# The single start command. No compose `command:` overrides it. The gateway runs
# in the background as the default profile -- a sticky named active profile
# would otherwise be refused a gateway -- then bootstrap.py execs as PID 1. The
# port is POSITIONAL: bootstrap.py has no --port flag.
#
# --skip-agent-install makes a missing Agent FAIL CLOSED: bootstrap raises
# "Hermes Agent was not found and auto-install was disabled." instead of running
# the UNPINNED installer from NousResearch main. The image always ships the
# pinned Agent, so the flag only ever fires on a broken image.
#
# The WebUI interpreter is passed explicitly (the pinned /opt venv symlink) rather
# than resolved by `python3` from PATH, so a login shell's PATH cannot change it.
#
# The server cwd is created here, at start, because bootstrap.py `os.chdir`s to it
# but never creates it, and the image cannot pre-create it: HERMES_WEBUI_SERVER_CWD
# lives under /root/.hermes, the data-volume mount point, so anything the image
# wrote there would be hidden by the volume. `;` (not `&&`) keeps the mkdir ahead
# of the backgrounded gateway and the foregrounded bootstrap.
CMD ["bash", "-c", "mkdir -p \"${HERMES_WEBUI_SERVER_CWD:-/root/.hermes/webui}\"; hermes -p default gateway run --replace & exec \"${HERMES_WEBUI_PYTHON}\" bootstrap.py --host 0.0.0.0 --foreground --no-browser --skip-agent-install 8501"]
