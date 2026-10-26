FROM python:3.11-slim@sha256:cce12316475d7d56d605f76e1d811d0dc4e7227f2d4afd29951521264f504ff8

# Recorded so a deploy can tell whether the build inputs changed since this
# image was built (install.sh passes it; see scripts/lib/build-gate.sh). The
# default keeps a hand-run `docker build` working.
ARG BUILD_INPUTS_SHA=unknown
LABEL org.hybrid-ai.build-inputs-sha="$BUILD_INPUTS_SHA"

# Install system dependencies
# Add retry flags and quiet output to prevent mirror timeouts
# sqlite3, jq, rsync and restic are base CLI tools the image's own harnesses
# require (scripts/test-backup.sh, backup/backup.sh, backup/restore.sh,
# collect-diagnostics.sh). A runtime `apt-get install` cannot supply them: this
# RUN cleans the apt lists, and the runtime uid has no root.
RUN apt-get update -o Acquire::Retries=5 && \
    apt-get install -y --no-install-recommends \
        git \
        curl \
        coreutils \
        findutils \
        build-essential \
        libxi6 \
        sqlite3 \
        jq \
        rsync \
        restic && \
    rm -rf /var/lib/apt/lists/*

# --- Pinned GitHub CLI (`gh`) for the kanban PR-acceptance gate --------------
# hermes_cli/kanban_pr_acceptance.py shells out to `gh api ...` at card
# completion, and fails closed (gh exit 4 -> "GitHub acceptance evidence
# unavailable") when gh is missing or unauthenticated. A runtime install cannot
# supply it: the runtime uid has no root and this image cleans the apt lists, and
# gh is not in the Debian repos. So it is a pinned upstream release tarball,
# fetched TO A FILE and sha256-verified BEFORE extraction; the tarball is never
# piped from the network into a shell or into tar. The layer runs as root, before
# USER, and installs ONLY bin/gh at /usr/local/bin/gh, root-owned and 0755. It
# reads no credential and no token environment variable.
ARG GH_VERSION=2.103.0
ARG GH_SHA256_ARM64=7f322df34e624d14f5ec0c4acb121fd6dfa14392fdbbd1066aa8e0a05ac3721e
ARG GH_SHA256_AMD64=fdd768eb70f6409f80fcfa9f3a1c0adf0fc98d827ab3ce0bed2ac22762c5d786
ARG TARGETARCH
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        arm64) gh_sha256="${GH_SHA256_ARM64}" ;; \
        amd64) gh_sha256="${GH_SHA256_AMD64}" ;; \
        *) echo "unsupported architecture for gh: ${arch}" >&2; exit 1 ;; \
    esac; \
    gh_asset="gh_${GH_VERSION}_linux_${arch}"; \
    gh_tar="/tmp/${gh_asset}.tar.gz"; \
    curl -fsSL --retry 5 --retry-all-errors -o "$gh_tar" \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${gh_asset}.tar.gz" \
 && echo "${gh_sha256}  ${gh_tar}" | sha256sum -c - \
 && mkdir -p /tmp/gh-extract \
 && tar -xzf "$gh_tar" -C /tmp/gh-extract \
 && install -m 0755 "/tmp/gh-extract/${gh_asset}/bin/gh" /usr/local/bin/gh \
 && test "$(stat -c '%u' /usr/local/bin/gh)" = "0" \
 && test "$(stat -c '%a' /usr/local/bin/gh)" = "755" \
 && test "$(gh --version | head -n1 | awk '{print $3}')" = "${GH_VERSION}" \
 && rm -rf /tmp/gh-extract "$gh_tar"

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
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o /tmp/hermes-install.sh \
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
      s=json.loads(p.read_text()); s["updateMechanism"] = "external"; s["distribution"] = "docker"; p.write_text(json.dumps(s) + "\n")' "${HERMES_INSTALL_DIR}" \
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

# --- Redirect dependency leases onto the data volume -------------------------
# The runtime writes a lease file into the .leases directory BESIDE the venv
# generation it pins (installs/<key>/environments/<uuid>/.leases and
# installs/<key>/pm-runtime/generations/<uuid>/.leases). Those directories live
# in the root-owned /opt tree, so the runtime uid got
#   [Errno 13] Permission denied: '/opt/hermes-agent/installs/.../.leases/...'
# and crash-looped. ENV HERMES_HOME (below) does NOT reroute these: the lease
# path follows the venv's location, not HERMES_HOME.
#
# Fix without making /opt writable: replace each (empty) .leases directory with a
# root-owned symlink into the data volume, mirroring its relative path under
# ${HERMES_LEASE_ROOT}. The symlinks dangle in the image (the volume is not
# mounted at build time); CMD creates their targets at start. /opt stays
# immutable, so lease writes land on the volume and `docker diff` stays clean.
# The build FAILS if no lease dirs are found or any of them is non-empty.
ARG HERMES_LEASE_ROOT=/root/.hermes/opt-leases
RUN set -eu; \
    find "${HERMES_INSTALL_DIR}/installs" -type d -name .leases -prune -print > /tmp/leases.txt; \
    test -s /tmp/leases.txt; \
    while read -r d; do \
        test -z "$(ls -A "$d")"; \
        rel="${d#${HERMES_INSTALL_DIR}/installs/}"; \
        rmdir "$d"; \
        ln -s "${HERMES_LEASE_ROOT}/${rel}" "$d"; \
        test "$(stat -c '%u' "$d")" = "0"; \
    done < /tmp/leases.txt; \
    rm -f /tmp/leases.txt; \
    ! find "${HERMES_INSTALL_DIR}/installs" -type d -name .leases -print -quit | grep -q .

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
 && ! find /app -user "${HYBRID_AI_UID}" -print -quit | grep -q . \
 && ! find "${HERMES_INSTALL_DIR}" -user "${HYBRID_AI_UID}" -print -quit | grep -q .

# --- PM install state: readable by the runtime uid, still root-owned ----------
# The Hermes PM writes install-state files into the sealed /opt tree as mode
# 0600/0700 (install-stamp.json, tools/facts.json, installs/<key>/facts.json,
# installs/<key>/pm-runtime and its generations). The runtime uid cannot read
# them, so every dispatch prints the install-out-of-sync banner, `hermes pm
# doctor` refuses, and the bundled tools (ffmpeg/node/npm/rg under
# tools/) are not put on PATH.
#
# Fix with chmod ONLY: `a+rX` adds read everywhere and execute on directories
# (never on plain files), so the state files become 0644 and the pm-runtime /
# generation directories 0755. Ownership is untouched: /opt/hermes-agent stays
# ROOT-OWNED and gets no group/other WRITE bit, so the assertion above stays
# green and /opt stays immutable to the runtime uid. The chmod runs at BUILD
# time, so it causes no runtime write under /opt (the `docker diff` smoke check
# stays clean).
#
# The final assertion tolerates pre-existing 0666 `.lock` files created by the
# install step (they are root-owned and out of this change's scope), but every
# directory and every non-lock state file must still be free of group/other
# write bits: a writable dir or state file would let uid 10001 replace or
# rewrite root-owned state.
RUN set -eu; \
    for f in \
        "${HERMES_INSTALL_DIR}/install-stamp.json" \
        "${HERMES_INSTALL_DIR}/tools/facts.json" \
        "${HERMES_INSTALL_DIR}/installs" \
    ; do test -e "$f" || { echo "missing PM state: $f" >&2; exit 1; }; done; \
    chmod -R a+rX \
        "${HERMES_INSTALL_DIR}/install-stamp.json" \
        "${HERMES_INSTALL_DIR}/tools" \
        "${HERMES_INSTALL_DIR}/installs"; \
    test -r "${HERMES_INSTALL_DIR}/install-stamp.json"; \
    test -r "${HERMES_INSTALL_DIR}/tools/facts.json"; \
    pmrt="$(find "${HERMES_INSTALL_DIR}/installs" -type d -name pm-runtime -print -quit)"; \
    test -n "$pmrt"; \
    test -r "$pmrt"; \
    test "$(stat -c '%u' "${HERMES_INSTALL_DIR}")" = "0"; \
    test -z "$(find \
        "${HERMES_INSTALL_DIR}/install-stamp.json" \
        "${HERMES_INSTALL_DIR}/tools" \
        "${HERMES_INSTALL_DIR}/installs" \
        \( -type d -o \( -type f ! -name '.lock' \) \) -perm /022 -print -quit)"

# --- Packaged PM runtime marker: /opt/pm-runtime/pm-runtime.json --------------
# pm/runtime.py resolves the dependency runtime before it can run anything. When
# <project.parent>/manifest.json exists (this image writes /opt/manifest.json),
# the payload root is /opt and the runtime dir is /opt/pm-runtime, and it reads
# /opt/pm-runtime/pm-runtime.json for two keys, "python" and "sitePackages". The
# image shipped no such marker, so PM died with
#   InstallError("pm-runtime", "packaged PM runtime is missing or invalid")
# and `hermes pm doctor` refused to run.
#
# The marker is generated here from the install state, never hardcoded: the
# generation comes from installs/<key>/pm-runtime/selected.json, so a rebuild
# with a different install key or Python patch keeps working.
#   python       absolute real path of the generation's interpreter, a FILE
#                under /opt (the resolver requires it inside the payload)
#   sitePackages "site-packages", a real DIRECTORY under /opt/pm-runtime. It is
#                a build-time COPY, not a symlink: the resolver calls .resolve()
#                before checking containment, so a symlink into the install tree
#                would resolve outside /opt/pm-runtime and fail that check.
#
# Permissions are chmod only (marker 0644, dirs 0755), never chown: /opt stays
# ROOT-OWNED with no group/other write bit, so the runtime uid can read the
# runtime it runs but cannot edit it, and the immutability assertions above stay
# green. Nothing is written under /opt at runtime, so `docker diff` stays clean.
# The build fails closed when the install state is ambiguous, the generation is
# missing, the interpreter falls outside /opt, or the copy lacks a package the
# PM runtime imports.
ARG PM_RUNTIME_DIR=/opt/pm-runtime
RUN set -eu; \
    pm_runtimes="$(find "${HERMES_INSTALL_DIR}/installs" -type d -name pm-runtime -print)"; \
    set -- ${pm_runtimes}; \
    test "$#" -eq 1 || { echo "expected exactly one pm-runtime install state, found $#" >&2; exit 1; }; \
    pm_state="$1"; \
    test -f "$pm_state/selected.json" || { echo "missing $pm_state/selected.json" >&2; exit 1; }; \
    generation="$(python3 -c 'import json,os,sys; s=json.load(open(sys.argv[1])); print(os.path.normpath(os.path.join(sys.argv[2], s["generation"])))' "$pm_state/selected.json" "$pm_state")"; \
    test -d "$generation" || { echo "PM runtime generation is missing: $generation" >&2; exit 1; }; \
    site="$(find "$generation" -maxdepth 4 -type d -path '*/lib/python*/site-packages' -print)"; \
    test -n "$site" || { echo "no site-packages under $generation" >&2; exit 1; }; \
    test "$(printf '%s\n' "$site" | wc -l)" -eq 1 || { echo "several site-packages under $generation" >&2; exit 1; }; \
    pm_python="$(readlink -f "$generation/bin/python")"; \
    test -f "$pm_python" || { echo "PM runtime interpreter is not a file: $pm_python" >&2; exit 1; }; \
    case "$pm_python" in \
        "${HERMES_INSTALL_DIR}"/*) : ;; \
        *) echo "PM runtime interpreter escapes the payload: $pm_python" >&2; exit 1 ;; \
    esac; \
    mkdir -p "${PM_RUNTIME_DIR}"; \
    cp -a "$site" "${PM_RUNTIME_DIR}/site-packages"; \
    python3 -c 'import json,sys; f=open(sys.argv[2],"w"); json.dump({"python": sys.argv[1], "sitePackages": "site-packages"}, f, indent=2); f.write("\n"); f.close()' "$pm_python" "${PM_RUNTIME_DIR}/pm-runtime.json"; \
    chmod -R a+rX "${PM_RUNTIME_DIR}"; \
    test -f "${PM_RUNTIME_DIR}/pm-runtime.json"; \
    test -d "${PM_RUNTIME_DIR}/site-packages"; \
    test "$(stat -c '%a' "${PM_RUNTIME_DIR}/pm-runtime.json")" = "644"; \
    test "$(stat -c '%a' "${PM_RUNTIME_DIR}")" = "755"; \
    test "$(stat -c '%u' "${PM_RUNTIME_DIR}/pm-runtime.json")" = "0"; \
    test "$(stat -c '%u' "${PM_RUNTIME_DIR}")" = "0"; \
    test -z "$(find "${PM_RUNTIME_DIR}" \( -type d -o -type f \) -perm /022 -print -quit)"; \
    for dep in packaging tomli_w truststore ruamel; do \
        test -e "${PM_RUNTIME_DIR}/site-packages/$dep" || { echo "PM runtime site-packages lacks $dep" >&2; exit 1; }; \
    done

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

# HERMES_HOME is pinned to the DATA VOLUME, never the install dir. The launchers
# Hermes publishes honour an explicit HERMES_HOME before any baked default, and
# the build's /tmp/hermes-home -> ${HERMES_INSTALL_DIR} rewrite can bake that
# default as /opt/hermes-agent. Setting it here keeps profiles, sessions and
# other runtime state on the volume. NOTE: this does NOT move the dependency
# leases (they follow the venv location); the .leases symlinks above do that.
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

# --- Fail the build if the packaged PM runtime does not resolve ---------------
# Runs the same resolver pm/runtime.py uses at runtime, as the RUNTIME uid, so a
# marker the container could not use (wrong key names, a path escaping the
# payload, an unreadable file) breaks the build instead of the deployed agent.
# `hermes pm doctor` is deliberately not used here: it re-hashes the whole store
# and is far too slow for a build step. The `cd` is what puts the install's own
# pm/ on sys.path, which is why this must not pass -I.
RUN set -eu; \
    cd "${HERMES_INSTALL_DIR}"; \
    resolved="$("${HERMES_INSTALL_DIR}/.hermes/venv/bin/python" -B -c 'import json; from pm.runtime import _resident_runtime; p, s = _resident_runtime(); print(json.dumps({"python": str(p), "sitePackages": str(s)}))')"; \
    echo "packaged PM runtime resolves: ${resolved}"

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
# Start-time directory creation, all on the data volume (anything the image wrote
# under /root/.hermes would be hidden by the mount):
#   - the server cwd, because bootstrap.py `os.chdir`s to it but never creates it;
#   - the target of every .leases symlink, so lease writes resolve.
# `;` (not `&&`) keeps these ahead of the backgrounded gateway and the
# foregrounded bootstrap.
CMD ["bash", "-c", "mkdir -p \"${HERMES_WEBUI_SERVER_CWD:-/root/.hermes/webui}\"; for l in $(find /opt/hermes-agent/installs -type l -name .leases); do mkdir -p \"$(readlink \"$l\")\"; done; hermes -p default gateway run --replace & exec \"${HERMES_WEBUI_PYTHON}\" bootstrap.py --host 0.0.0.0 --foreground --no-browser --skip-agent-install 8501"]
