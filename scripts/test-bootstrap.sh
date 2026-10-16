#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-bootstrap.sh
# PURPOSE (plain English):
#   Offline tests for scripts/bootstrap.sh. They need NO root, NO Docker and NO
#   network. Every privileged tool -- useradd, groupadd, getent, gpasswd, chown,
#   runuser, systemctl, docker, git, sshd and pkcheck/pkaction -- is stubbed on
#   PATH, and the whole run is pointed at a scratch filesystem prefix with
#   HYBRID_AI_BOOTSTRAP_ROOT, so the REAL /opt, /etc and /var are never touched.
#
#   HYBRID_AI_BOOTSTRAP_ROOT is UNSET by default and the script it tests then
#   uses the REAL "/" for the host root. This test proves that default.
#
# CASES:
#   * fresh install
#   * migration from a legacy fixture: renames preserve inodes, moved files are
#     byte-identical with the stated modes, only the matching authorized_keys
#     line is removed, and the docker group removal comes LAST
#   * idempotent re-run (nothing changes on the second run)
#   * every refusal class has its own exit code
#   * an install.sh failure stops the cut-off steps
#   * a sentinel value in .env / stack.env / r2.env / repo-password never
#     reaches stdout, stderr or the migration manifest
#
# USAGE:
#   bash scripts/test-bootstrap.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap.sh"
[[ -f "$BOOTSTRAP" ]] || { echo "FATAL: cannot find $BOOTSTRAP" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
have()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

# ---------------------------------------------------------------------------
# Kubernetes of stubs. Everything a bootstrap run must not really do.
# ---------------------------------------------------------------------------
STUBS="$WORK/bin"
mkdir -p "$STUBS"

pub_ed25519() {
  # A syntactically plausible ed25519 public key. NOT a generated key: the
  # base64 body is fixed test data. Nothing here is a credential.
  printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYBLOBAAAAAAAAAAAAAAAAAAAAAAAAAAA test@fixture'
}
OTHER_BLOB='AAAAC3NzaC1lZDI1NTE5AAAAIOTHERKEYBLOBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
priv_ed25519() {
  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'TESTFIXTURE' '-----END OPENSSH PRIVATE KEY-----'
}

PUBKEY="$WORK/deploy.pub"
pub_ed25519 > "$PUBKEY"
KEY_BLOB="$(awk '{print $2}' "$PUBKEY")"

# --- id ---------------------------------------------------------------------
cat > "$STUBS/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then printf '%s\n' "${FAKE_UID:-0}"; exit 0; fi
exec /usr/bin/id "$@"
EOF

# --- useradd / groupadd / getent / gpasswd / usermod / shadow ---------------
# A tiny passwd/group database in files so the script's getent reads see what
# the "creation" wrote. No real account is ever touched.
cat > "$STUBS/useradd" <<'EOF'
#!/usr/bin/env bash
set -u
acct="" home="" shell="" grp=""
while (( $# > 0 )); do
  case "$1" in
    --system) ;;
    --gid) grp="$2"; shift ;;
    --home-dir) home="$2"; shift ;;
    --no-create-home) ;;
    --shell) shell="$2"; shift ;;
    -*) ;;
    *) acct="$1" ;;
  esac
  shift
done
uid=$(( 999 - $(wc -l < "$STUB_STATE/passwd" 2>/dev/null || echo 0) ))
printf '%s:%s:%s:%s::%s:%s\n' "$acct" x "$uid" "$uid" "$home" "$shell" >> "$STUB_STATE/passwd"
printf '%s:!::0:::::\n' "$acct" >> "$STUB_STATE/shadow"
printf 'useradd %s\n' "$acct" >> "$EVENTS"
EOF

cat > "$STUBS/groupadd" <<'EOF'
#!/usr/bin/env bash
set -u
grp=""
while (( $# > 0 )); do
  case "$1" in
    --system) ;;
    -*) ;;
    *) grp="$1" ;;
  esac
  shift
done
if ! grep -q "^${grp}:" "$STUB_STATE/group" 2>/dev/null; then
  gid=$(( 999 - $(wc -l < "$STUB_STATE/group" 2>/dev/null || echo 0) ))
  printf '%s:%s:\n' "$grp" "$gid" >> "$STUB_STATE/group"
fi
printf 'groupadd %s\n' "$grp" >> "$EVENTS"
EOF

cat > "$STUBS/getent" <<'EOF'
#!/usr/bin/env bash
set -u
db="${1:-}"; key="${2:-}"
case "$db" in
  passwd) awk -F: -v k="$key" '$1==k { print; found=1; exit } END { exit !found }' "$STUB_STATE/passwd" ;;
  group)  awk -F: -v k="$key" '$1==k { print; found=1; exit } END { exit !found }' "$STUB_STATE/group" ;;
  shadow) awk -F: -v k="$key" '$1==k { print; found=1; exit } END { exit !found }' "$STUB_STATE/shadow" ;;
  hosts)  printf '%s\n' "[IP_ADDRESS] ${key}" ;;
esac
EOF

cat > "$STUBS/gpasswd" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "-d" ]]; then
  acct="$2"; grp="$3"
  printf 'gpasswd-docker %s %s\n' "$acct" "$grp" >> "$EVENTS"
  awk -F: -v g="$grp" -v a="$acct" 'BEGIN{OFS=":"} $1==g { n=""; c=split($4,m,","); for(i=1;i<=c;i++) if(m[i]!="" && m[i]!=a) n=(n==""?m[i]:n","m[i]); $4=n } {print}' \
    "$STUB_STATE/group" > "$STUB_STATE/group.tmp" && mv "$STUB_STATE/group.tmp" "$STUB_STATE/group"
fi
exit 0
EOF

printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/usermod"

# --- chown / chmod pass through? chmod is real; chown is stubbed -------------
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/chown"

# --- runuser -----------------------------------------------------------------
# Supports the two forms the bootstrap uses:
#   runuser -u <acct> -- test -r <file>
#   runuser -u <acct> -- env K=V ... <cmd> ...
cat > "$STUBS/runuser" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "-u" ]] && shift
shift   # the account
[[ "${1:-}" == "--" ]] && shift
printf 'runuser %s\n' "$*" >> "$EVENTS"
if [[ "${1:-}" == "test" ]]; then
  shift
  test "$@"; exit $?
fi
exec "$@"
EOF

# --- systemctl / docker / sshd / pkcheck / pkaction --------------------------
cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$EVENTS"
case "${1:-}" in
  "show") printf '%s\n' success ;;
esac
exit 0
EOF
# shellcheck disable=SC2016  # $* must expand inside the generated stub, not here
printf '#!/usr/bin/env bash\nprintf "docker %%s\\n" "$*" >> "$EVENTS"\nexit 0\n' > "$STUBS/docker"
cat > "$STUBS/sshd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SSHD_T_OUT:-}"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit %s\n' "${PKCHECK_RC:-0}" > "$STUBS/pkcheck"
cat > "$STUBS/pkaction" <<'EOF'
#!/usr/bin/env bash
printf 'pkaction version %s\n' "${POLKIT_VERSION:-122}"
exit 0
EOF

# --- git ---------------------------------------------------------------------
# clone copies a fixture tree; fetch/reset/config answer from the environment.
cat > "$STUBS/git" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$GIT_LOG"
verb=""; dir=""
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  a="${args[i]}"
  case "$a" in
    -C) i=$(( i + 1 )); dir="${args[i]}" ;;
    -c) i=$(( i + 1 )) ;;
    clone|fetch|reset|config|rev-parse|merge-base) verb="$a" ;;
  esac
  i=$(( i + 1 ))
done
case "$verb" in
  clone)
    dir="${args[${#args[@]}-1]}"
    mkdir -p "$dir/.git"
    cp -a "$GIT_FIXTURE_SRC/." "$dir"/
    exit 0 ;;
  config) printf '%s\n' "${GIT_ORIGIN_URL:-}"; exit 0 ;;
  rev-parse) printf '%s\n' "${GIT_HEAD_SHA:-0123456789abcdef0123456789abcdef01234567}"; exit 0 ;;
  fetch) exit "${GIT_FETCH_RC:-0}" ;;
  reset) exit "${GIT_RESET_RC:-0}" ;;
esac
exit 0
EOF

for f in id useradd groupadd getent gpasswd usermod chown runuser systemctl docker sshd pkcheck pkaction git; do
  chmod +x "$STUBS/$f"
done

# --- The cloned-app fixture --------------------------------------------------
# install.sh and doctor.sh are STUBS. install.sh writes the STACK env file (as
# the real one does) and records the layout file it was told to read; it must
# never write the layout file.
GIT_FIXTURE_SRC="$WORK/clone-src"
mkdir -p "$GIT_FIXTURE_SRC/deploy" "$GIT_FIXTURE_SRC/scripts"
cat > "$GIT_FIXTURE_SRC/install.sh" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'install.sh HYBRID_AI_ENV_FILE=%s STACK=%s args=%s\n' \
  "${HYBRID_AI_ENV_FILE:-}" "${HYBRID_AI_STACK_ENV_FILE:-}" "$*" >> "$EVENTS"
printf 'install.sh invoked\n'
[[ "${INSTALL_RC:-0}" == "0" ]] || exit "${INSTALL_RC}"
# Resolve the STACK file the way the real scripts/lib/hybrid-ai-env.sh does:
# the env var first, then the layout file it was handed, else fall back to the
# layout file itself. That keeps the stub a faithful stand-in.
stack="${HYBRID_AI_STACK_ENV_FILE:-}"
if [[ -z "$stack" && -n "${HYBRID_AI_ENV_FILE:-}" && -r "${HYBRID_AI_ENV_FILE}" ]]; then
  stack="$(grep -E '^HYBRID_AI_STACK_ENV_FILE=' "$HYBRID_AI_ENV_FILE" | tail -1 | cut -d= -f2-)"
fi
stack="${stack:-${HYBRID_AI_ENV_FILE:-}}"
# The real install.sh reads an existing stack file and keeps its values; it only
# creates it when absent. Model that, so a migrated stack file is not clobbered.
if [[ -n "$stack" && ! -e "$stack" ]]; then
  mkdir -p "$(dirname -- "$stack")"
  printf 'WEBUI_SECRET_KEY=%s\n' "${STACK_SENTINEL:-}" > "$stack"
  chmod 600 "$stack"
fi
exit 0
EOF
cat > "$GIT_FIXTURE_SRC/doctor.sh" <<'EOF'
#!/usr/bin/env bash
printf 'doctor.sh invoked\n'
exit "${DOCTOR_RC:-0}"
EOF
cat > "$GIT_FIXTURE_SRC/scripts/check-hermes-nonroot.sh" <<'EOF'
#!/usr/bin/env bash
printf 'check-hermes-nonroot uid=%s dir=%s\n' "${HYBRID_AI_UID:-}" "${HERMES_DATA_DIR:-}" >> "$EVENTS"
exit "${PREFLIGHT_RC:-0}"
EOF
printf '# fixture deploy unit\n[Service]\nUser=root\n' > "$GIT_FIXTURE_SRC/deploy/hybrid-ai-deploy@.service"
printf '// fixture polkit rule\n' > "$GIT_FIXTURE_SRC/deploy/50-hybrid-ai-deploy.rules"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GIT_FIXTURE_SRC/scripts/deploy-forced-command.sh"
chmod +x "$GIT_FIXTURE_SRC/install.sh" "$GIT_FIXTURE_SRC/doctor.sh" \
         "$GIT_FIXTURE_SRC/scripts/check-hermes-nonroot.sh" \
         "$GIT_FIXTURE_SRC/scripts/deploy-forced-command.sh"

# ---------------------------------------------------------------------------
# A fresh scratch host root.
# ---------------------------------------------------------------------------
new_root() {
  local r
  r="$(mktemp -d "$WORK/root.XXXXXX")"
  mkdir -p "$r/etc" "$r/usr/sbin" "$r/bin" "$r/home/pi" "$r/var/lib"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$r/usr/sbin/nologin"
  chmod +x "$r/usr/sbin/nologin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$r/bin/sh"
  chmod +x "$r/bin/sh"
  printf 'UID_MIN 1000\nGID_MIN 1000\n' > "$r/etc/login.defs"
  # polkit's .rules directory, so the polkit gate passes on a fresh scratch host.
  mkdir -p "$r/etc/polkit-1/rules.d"
  mkdir -p "$r/stubstate"
  : > "$r/stubstate/passwd"; : > "$r/stubstate/shadow"
  # The docker group already exists and already contains the login user, so the
  # cut-off has something to remove.
  printf 'docker:x:999:pi\n' > "$r/stubstate/group"
  # The login account, so getent can resolve its home for the migration.
  printf 'pi:x:1000:1000::/home/pi:/bin/bash\n' >> "$r/stubstate/passwd"
  printf 'pi:!:20000:0:99999:7:::\n' >> "$r/stubstate/shadow"
  printf 'pi:x:1000:\n' >> "$r/stubstate/group"
  printf '%s\n' "$r"
}

# Extra K=V assignments for a single run_bootstrap call (e.g. FAKE_UID=1000).
EXTRA_ENV=()

run_bootstrap() { # root logfile bootstrap-args...
  local r="$1" log="$2"; shift 2
  : > "$EVENTS"; : > "$GIT_LOG"
  env PATH="$STUBS:$PATH" \
      HYBRID_AI_BOOTSTRAP_ROOT="$r" \
      STUB_STATE="$r/stubstate" \
      EVENTS="$EVENTS" GIT_LOG="$GIT_LOG" \
      GIT_FIXTURE_SRC="$GIT_FIXTURE_SRC" \
      GIT_ORIGIN_URL="${GIT_ORIGIN_URL:-https://github.com/jimbobsyouruncle/hybrid-ai.git}" \
      SSH_ORIGINAL_COMMAND="" \
      "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
      bash "$BOOTSTRAP" "$@" >"$log" 2>&1
  local rc=$?
  EXTRA_ENV=()
  return $rc
}

EVENTS="$WORK/events.log"; GIT_LOG="$WORK/git.log"
: > "$EVENTS"; : > "$GIT_LOG"

# ---------------------------------------------------------------------------
echo "== the test-only prefix is UNSET by default and the default root is / =="
out="$(env -u HYBRID_AI_BOOTSTRAP_ROOT bash "$BOOTSTRAP" --print-paths 2>&1)"
have "print-paths default root is /" "$out" "root                     = /"
have "print-paths default app dir" "$out" "HYBRID_AI_APP_DIR        = /opt/hybrid-ai"
have "print-paths default stack file" "$out" "HYBRID_AI_STACK_ENV_FILE = /etc/hybrid-ai/stack.env"
if env -u HYBRID_AI_BOOTSTRAP_ROOT bash "$BOOTSTRAP" --print-paths >/dev/null 2>&1; then
  ok "print-paths needs no root and touches nothing"
else
  bad "print-paths failed"
fi
if env HYBRID_AI_BOOTSTRAP_ROOT=relative bash "$BOOTSTRAP" --print-paths >/dev/null 2>&1; then
  bad "a relative HYBRID_AI_BOOTSTRAP_ROOT must be refused"
else
  ok "a relative HYBRID_AI_BOOTSTRAP_ROOT is refused"
fi

# ---------------------------------------------------------------------------
echo
echo "== fresh install =="
R1="$(new_root)"
LEGACY="$R1/legacy"; mkdir -p "$LEGACY"
rc=0
run_bootstrap "$R1" "$WORK/fresh.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "fresh install exits 0" "0" "$rc"
if (( rc != 0 )); then sed 's/^/      /' "$WORK/fresh.log" >&2; fi

LAYOUT="$R1/etc/hybrid-ai/hybrid-ai.env"
check "layout file mode is 0644" "644" "$(stat -c '%a' "$LAYOUT" 2>/dev/null)"
check "app dir cloned" "yes" "$([[ -d "$R1/opt/hybrid-ai/.git" ]] && echo yes || echo no)"
check "data dir" "yes" "$([[ -d "$R1/var/lib/hybrid-ai" ]] && echo yes || echo no)"
check "agent workspace is a SIBLING of the data dir" "yes" "$([[ -d "$R1/var/lib/hybrid-ai-agent" ]] && echo yes)"
check "agent repos is a SIBLING of the data dir" "yes" "$([[ -d "$R1/var/lib/hybrid-ai-repos" ]] && echo yes)"
check "no agent-workspace child under the data dir" "no" "$([[ -e "$R1/var/lib/hybrid-ai/agent-workspace" ]] && echo yes || echo no)"
check "no agent-repos child under the data dir" "no" "$([[ -e "$R1/var/lib/hybrid-ai/agent-repos" ]] && echo yes || echo no)"
check "data subdir openhands" "yes" "$([[ -d "$R1/var/lib/hybrid-ai/openhands" ]] && echo yes)"
check "log dir" "yes" "$([[ -d "$R1/var/log/hybrid-ai" ]] && echo yes)"
check "etc dir mode" "755" "$(stat -c '%a' "$R1/etc/hybrid-ai" 2>/dev/null)"
check "credstore mode" "700" "$(stat -c '%a' "$R1/etc/credstore/hybrid-ai-backup" 2>/dev/null)"
check "deploy unit installed" "yes" "$([[ -f "$R1/etc/systemd/system/hybrid-ai-deploy@.service" ]] && echo yes)"
check "polkit rule installed" "yes" "$([[ -f "$R1/etc/polkit-1/rules.d/50-hybrid-ai-deploy.rules" ]] && echo yes)"
check "authorized_keys mode" "600" "$(stat -c '%a' "$R1/var/lib/hybrid-ai-deploy/.ssh/authorized_keys" 2>/dev/null)"
check "authorized_keys line is the forced command" "1" \
  "$(grep -c "restrict,command=\"$R1/opt/hybrid-ai/scripts/deploy-forced-command.sh\"" "$R1/var/lib/hybrid-ai-deploy/.ssh/authorized_keys" 2>/dev/null)"

# Each account: system uid, its own group, nologin (or /bin/sh for deploy).
for a in hybrid-ai hybrid-ai-backup; do
  line="$(grep "^${a}:" "$R1/stubstate/passwd")"
  uid="$(printf '%s' "$line" | cut -d: -f3)"
  grp="$(printf '%s' "$line" | cut -d: -f4)"
  sh="$(printf '%s' "$line" | cut -d: -f7)"
  if (( uid < 1000 && uid == grp )); then ok "${a} is a system account with its own group"; else bad "${a} uid/gid ${uid}/${grp}"; fi
  check "${a} has a nologin shell" "$R1/usr/sbin/nologin" "$sh"
done
dline="$(grep '^hybrid-ai-deploy:' "$R1/stubstate/passwd")"
check "hybrid-ai-deploy shell is /bin/sh" "$R1/bin/sh" "$(printf '%s' "$dline" | cut -d: -f7)"
duid="$(printf '%s' "$dline" | cut -d: -f3)"
if (( duid < 1000 )); then ok "hybrid-ai-deploy is a system account"; else bad "hybrid-ai-deploy uid ${duid}"; fi

# The layout file content.
for needle in \
  "HYBRID_AI_APP_DIR=$R1/opt/hybrid-ai" \
  "HYBRID_AI_ENV_FILE=$LAYOUT" \
  "HYBRID_AI_STACK_ENV_FILE=$R1/etc/hybrid-ai/stack.env" \
  "HYBRID_AI_DATA_DIR=$R1/var/lib/hybrid-ai" \
  "HYBRID_AI_LOG_DIR=$R1/var/log/hybrid-ai" \
  "HYBRID_AI_WORK_DIR=$R1/var/lib/hybrid-ai/work" \
  "OPENHANDS_WORKSPACE=$R1/var/lib/hybrid-ai-agent" \
  "AGENT_REPOS_DIR=$R1/var/lib/hybrid-ai-repos" \
  "OPENHANDS_STATE_DIR=$R1/var/lib/hybrid-ai/openhands" \
  "RESTIC_CACHE_DIR=$R1/var/cache/hybrid-ai-backup" \
  "HYBRID_AI_HERMES_HOME_DIR=$R1/var/lib/hybrid-ai/hermes-home" \
  "HYBRID_AI_BACKUP_MODE=system" \
  "BACKUP_CONTAINER_CONTROL=external"; do
  if grep -qxF "$needle" "$LAYOUT"; then ok "layout has: ${needle##*/}"; else bad "layout missing: $needle"; fi
done
if grep -qE "^HYBRID_AI_UID=$(grep '^hybrid-ai:' "$R1/stubstate/passwd" | cut -d: -f3)$" "$LAYOUT"; then
  ok "layout HYBRID_AI_UID is the hybrid-ai account uid"
else
  bad "layout HYBRID_AI_UID is not the hybrid-ai uid"
fi
if grep -qE "^HYBRID_AI_GID=[0-9]+$" "$LAYOUT"; then ok "layout HYBRID_AI_GID is numeric"; else bad "layout HYBRID_AI_GID"; fi
check "hermes-home owned by hybrid-ai" "700" "$(stat -c '%a' "$R1/var/lib/hybrid-ai/hermes-home" 2>/dev/null)"

# No SECRET KEY NAME from install.sh STEP 8 may appear in the layout file.
SECRET_NAMES="ENV_VERSION LOCAL_DOMAIN OLLAMA_MEM_LIMIT WEBUI_MEM_LIMIT OLLAMA_CPUS WEBUI_CPUS OLLAMA_CONTEXT_LENGTH OLLAMA_NUM_PARALLEL OLLAMA_MAX_LOADED_MODELS OLLAMA_KEEP_ALIVE OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_IMAGE WEBUI_IMAGE STATUS_UID DOCKER_GID WEBUI_SECRET_KEY WEBUI_AUTH RAG_EMBEDDING_MODEL ENABLE_OPENAI_API OPENROUTER_API_KEY OPENROUTER_MODEL RUNPOD_HOST PI_HOST TAILSCALE_IP PEER_HOSTNAME PEER_HOSTNAMES RUNPOD_API_KEY RUNPOD_POD_ID RUNPOD_AUTO_WAKE VLLM_PORT VLLM_MODEL_NAME POD_WARMUP_TIMEOUT"
leak=""
for n in $SECRET_NAMES; do grep -qE "^${n}=" "$LAYOUT" && leak="$leak $n"; done
check "the layout file holds no secret key name" "" "$leak"

# The layout survives an install.sh run: the stub never wrote it.
before="$(sha256sum < "$LAYOUT")"
run_bootstrap "$R1" "$WORK/fresh2.log" --deploy-pubkey "$PUBKEY" --login-user pi || true
after="$(sha256sum < "$LAYOUT")"
check "install.sh did not change the layout file" "$before" "$after"

# Idempotent re-run: nothing changes.
snap_before="$(find "$R1/var/lib/hybrid-ai" "$R1/etc" -type f -printf '%P %s\n' 2>/dev/null | sort | sha256sum)"
rc=0
run_bootstrap "$R1" "$WORK/rerun.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
snap_after="$(find "$R1/var/lib/hybrid-ai" "$R1/etc" -type f -printf '%P %s\n' 2>/dev/null | sort | sha256sum)"
check "a re-run exits 0" "0" "$rc"
check "a re-run changes nothing" "$snap_before" "$snap_after"
check "a re-run creates no account" "$(grep -c useradd "$EVENTS")" "0"
check "a re-run leaves exactly one authorized_keys line" "1" \
  "$(wc -l < "$R1/var/lib/hybrid-ai-deploy/.ssh/authorized_keys" | tr -d ' ')"

# install.sh gets the LAYOUT file by name.
have "install.sh was handed the layout file" "$(cat "$EVENTS")" \
  "install.sh HYBRID_AI_ENV_FILE=$LAYOUT STACK="

# ---------------------------------------------------------------------------
echo
echo "== migration from a legacy fixture =="
R2="$(new_root)"
LEGACY="$R2/legacy"; mkdir -p "$LEGACY/openhands" "$LEGACY/hermes"

mkdir -p "$R2/home/pi/.ssh" "$R2/home/pi/.config/hybrid-ai-backup"
# Two unrelated keys plus the deploy key. Only the deploy line may be removed.
{
  printf '%s\n' "ssh-ed25519 ${OTHER_BLOB} other@fixture"
  printf '%s\n' "restrict,command=\"/opt/hybrid-ai/scripts/deploy-forced-command.sh\" $(cat "$PUBKEY")"
  printf '%s\n' "ssh-ed25519 ${OTHER_BLOB} third@fixture"
} > "$R2/home/pi/.ssh/authorized_keys"
chmod 600 "$R2/home/pi/.ssh/authorized_keys"
LEGACY_ENV="$LEGACY/.env"
{
  printf 'ENV_VERSION=2\n'
  printf 'WEBUI_SECRET_KEY=%s\n' "__SENTINEL_ENVDOT__"
  printf 'OPENHANDS_WORKSPACE=%s\n' "$LEGACY/ws-key"
  printf 'AGENT_REPOS_DIR=%s\n' "$LEGACY/repos-key"
  printf 'OPENHANDS_STATE_DIR=%s\n' "$LEGACY/state-key"
  # The BASE install.sh STEP 8 writes these EMPTY. Model that exactly, so the
  # migration-side empty-uid proof below is faithful.
  printf 'HYBRID_AI_UID=\n'
  printf 'HYBRID_AI_GID=\n'
} > "$LEGACY_ENV"
chmod 600 "$LEGACY_ENV"
# Keep a copy BEFORE the migration: the move renames the original away, so a
# later comparison against "$LEGACY_ENV" would be against a missing file.
LEGACY_ENV_COPY="$WORK/legacy-env.copy"
cp -p "$LEGACY_ENV" "$LEGACY_ENV_COPY"
mkdir -p "$LEGACY/ws-key" "$LEGACY/repos-key" "$LEGACY/state-key"
printf 'key\n' > "$LEGACY/ws-key/KEY"; printf 'repo\n' > "$LEGACY/repos-key/REPO"
printf 'state\n' > "$LEGACY/state-key/STATE"
mkdir -p "$LEGACY/hermes_data" "$LEGACY/webui_data" "$LEGACY/ollama_data"
printf 'hermes\n' > "$LEGACY/hermes_data/HFILE"
printf 'webui\n' > "$LEGACY/webui_data/WFILE"
printf 'ollama\n' > "$LEGACY/ollama_data/OFILE"
printf 'install log\n' > "$LEGACY/install.log"
printf 'backup log\n' > "$LEGACY/backup.log"
printf 'RESTIC_REPOSITORY=__SENTINEL_R2__\n' > "$R2/home/pi/.config/hybrid-ai-backup/r2.env"
chmod 600 "$R2/home/pi/.config/hybrid-ai-backup/r2.env"
printf '__SENTINEL_PW__\n' > "$R2/home/pi/.config/hybrid-ai-backup/repo-password"
chmod 600 "$R2/home/pi/.config/hybrid-ai-backup/repo-password"
: > "$LEGACY/docker-compose.yml"
: > "$LEGACY/openhands/docker-compose.openhands.yml"
: > "$LEGACY/hermes/docker-compose.hermes.yml"

inode_hermes="$(stat -c '%i' "$LEGACY/hermes_data/HFILE")"
inode_ws="$(stat -c '%i' "$LEGACY/ws-key/KEY")"

rc=0
run_bootstrap "$R2" "$WORK/migrate.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY" --login-user pi || rc=$?
check "migration exits 0" "0" "$rc"
if (( rc != 0 )); then sed 's/^/      /' "$WORK/migrate.log" >&2; fi

# hermes_data landed on its real target; inode preserved.
check "hermes_data file preserved" "yes" "$([[ -f "$R2/var/lib/hybrid-ai/hermes_data/HFILE" ]] && echo yes)"
check "hermes_data inode preserved" "$inode_hermes" "$(stat -c '%i' "$R2/var/lib/hybrid-ai/hermes_data/HFILE" 2>/dev/null)"
check "the legacy hermes_data is gone (moved, not copied)" "no" "$([[ -e "$LEGACY/hermes_data" ]] && echo yes || echo no)"

# The relocated trees landed where the redirect points.
check "agent workspace file moved to the sibling" "yes" "$([[ -f "$R2/var/lib/hybrid-ai-agent/KEY" ]] && echo yes || echo no)"
check "agent workspace inode preserved" "$inode_ws" "$(stat -c '%i' "$R2/var/lib/hybrid-ai-agent/KEY" 2>/dev/null)"

# The legacy .env became the stack env file, byte-identical, 0600.
check "stack env mode 0600" "600" "$(stat -c '%a' "$R2/etc/hybrid-ai/stack.env" 2>/dev/null)"
check "stack env is byte-identical to the legacy .env" "yes" \
  "$(cmp -s "$R2/etc/hybrid-ai/stack.env" "$LEGACY_ENV_COPY" && printf '%s' 'yes' || printf '%s' 'no')"
if grep -qxF "WEBUI_SECRET_KEY=__SENTINEL_ENVDOT__" "$R2/etc/hybrid-ai/stack.env"; then
  ok "the sentinel survived the move"
else
  bad "the sentinel did not survive the move"
fi

# Credentials moved into the credstore, byte-identical, 0600.
check "r2.env mode 0600" "600" "$(stat -c '%a' "$R2/etc/credstore/hybrid-ai-backup/r2.env" 2>/dev/null)"
check "repo-password mode 0600" "600" "$(stat -c '%a' "$R2/etc/credstore/hybrid-ai-backup/repo-password" 2>/dev/null)"
check "r2.env byte-identical" "yes" \
  "$(grep -qxF 'RESTIC_REPOSITORY=__SENTINEL_R2__' "$R2/etc/credstore/hybrid-ai-backup/r2.env" && echo yes || echo no)"

# Logs moved.
check "install.log moved" "yes" "$([[ -f "$R2/var/log/hybrid-ai/install.log" ]] && echo yes || echo no)"
check "backup.log moved" "yes" "$([[ -f "$R2/var/log/hybrid-ai/backup.log" ]] && echo yes || echo no)"

# Only the matching authorized_keys line was removed.
ak="$R2/home/pi/.ssh/authorized_keys"
check "authorized_keys keeps two lines" "2" "$(wc -l < "$ak" | tr -d ' ')"
if grep -qF "$KEY_BLOB" "$ak"; then bad "the deploy key line was not removed"; else ok "the deploy key line was removed"; fi
check "the other two keys remain" "2" "$(grep -cF "$OTHER_BLOB" "$ak")"

# The docker group removal came LAST.
disable_line="$(grep -n 'systemctl --user disable --now hybrid-ai-check.timer' "$EVENTS" | tail -1 | cut -d: -f1)"
docker_line="$(grep -n 'gpasswd-docker' "$EVENTS" | tail -1 | cut -d: -f1)"
if [[ -n "$disable_line" && -n "$docker_line" && "$docker_line" -gt "$disable_line" ]]; then
  ok "the docker group removal comes after the user-unit disable"
else
  bad "docker group removal ordering (disable=$disable_line docker=$docker_line)"
fi
if grep -q 'runuser env XDG_RUNTIME_DIR' "$EVENTS"; then
  ok "the user units were disabled as the login account"
else
  bad "the user units were not disabled as the login account"
fi

# The manifest records PATHS ONLY and holds no sentinel.
# shellcheck disable=SC2012  # the manifest name has no spaces; ls glob is fine
manifest="$(ls "$R2/var/log/hybrid-ai/"bootstrap-*.manifest 2>/dev/null | head -1)"
if [[ -n "$manifest" ]]; then
  ok "a migration manifest was written"
  check "manifest mode is 0600" "600" "$(stat -c '%a' "$manifest")"
  if grep -q "hermes_data" "$manifest" && grep -q -- "->" "$manifest"; then
    ok "the manifest records move paths"
  else
    bad "the manifest does not record move paths"
  fi
else
  bad "no migration manifest was written"
fi

# The legacy .env carries EMPTY HYBRID_AI_UID=/HYBRID_AI_GID= (the base
# install.sh STEP 8 writes them blank). The bootstrap must still hand install.sh
# the layout file, whose ids are authoritative, and the Hermes preflight must be
# run with the hybrid-ai uid -- never an empty one. This is the migration-side
# proof for the empty-uid defect (AC1).
layout_uid="$(grep -E '^HYBRID_AI_UID=' "$R2/etc/hybrid-ai/hybrid-ai.env" | cut -d= -f2-)"
have "install.sh was handed the layout file during migration" "$(cat "$EVENTS")" \
  "install.sh HYBRID_AI_ENV_FILE=$R2/etc/hybrid-ai/hybrid-ai.env"
if [[ -n "$layout_uid" && "$layout_uid" != "0" ]]; then
  ok "the migrated layout file carries a non-zero HYBRID_AI_UID (${layout_uid})"
else
  bad "the migrated layout file HYBRID_AI_UID is empty or zero (${layout_uid})"
fi
have "the Hermes preflight ran with the layout uid (not empty)" "$(cat "$EVENTS")" \
  "check-hermes-nonroot uid=${layout_uid} "
if grep -qE 'check-hermes-nonroot uid= ' "$EVENTS"; then
  bad "the Hermes preflight ran with an EMPTY uid"
else
  ok "the Hermes preflight never ran with an empty uid"
fi
# The stack file the migration produced is the moved legacy .env: byte-identical
# and still carrying its own (empty) ids. install.sh rewrites it on the hand-off;
# this only proves the move itself was faithful.
check "the moved stack file is still byte-identical to the legacy .env" "yes" \
  "$(cmp -s "$R2/etc/hybrid-ai/stack.env" "$LEGACY_ENV_COPY" && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo
echo "== a second --from run after a completed migration reaches install.sh (D6) =="
# The first run MOVED the legacy .env to the stack env file. A second --from run
# must stop the stack with the resolved STACK env file, not the now-missing
# legacy .env. The docker stub fails on a missing --env-file path, exactly as
# real compose does, so a stale path fails the run.
cat > "$STUBS/docker" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'docker %s\n' "$*" >> "$EVENTS"
# Real compose refuses a --env-file path that does not exist.
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  if [[ "${args[i]}" == "--env-file" ]]; then
    i=$(( i + 1 ))
    if [[ ! -e "${args[i]}" ]]; then
      printf 'docker: --env-file %s does not exist\n' "${args[i]}" >&2
      exit 1
    fi
  fi
  i=$(( i + 1 ))
done
exit 0
EOF
chmod +x "$STUBS/docker"
R6="$(new_root)"
LEGACY6="$R6/legacy"; mkdir -p "$LEGACY6/openhands" "$LEGACY6/hermes"
printf '# legacy env\n' > "$LEGACY6/.env"
chmod 600 "$LEGACY6/.env"
: > "$LEGACY6/docker-compose.yml"
: > "$LEGACY6/openhands/docker-compose.openhands.yml"
: > "$LEGACY6/hermes/docker-compose.hermes.yml"
mkdir -p "$R6/home/pi/.ssh"
printf '%s\n' "restrict,command=\"/opt/hybrid-ai/scripts/deploy-forced-command.sh\" $(cat "$PUBKEY")" \
  > "$R6/home/pi/.ssh/authorized_keys"
# Run 1 completes the migration and MOVES the legacy .env away.
rc=0
run_bootstrap "$R6" "$WORK/rerun-from-1.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY6" --login-user pi || rc=$?
check "the first --from run exits 0" "0" "$rc"
check "the legacy .env was moved away by the first run" "no" \
  "$([[ -e "$LEGACY6/.env" ]] && echo yes || echo no)"
# Run 2 must reach the install.sh hand-off with the STACK env file.
rc=0
run_bootstrap "$R6" "$WORK/rerun-from-2.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY6" --login-user pi || rc=$?
check "a second --from run exits 0" "0" "$rc"
if (( rc != 0 )); then sed 's/^/      /' "$WORK/rerun-from-2.log" >&2; fi
have "the re-run stopped the stack with the stack env file" "$(cat "$EVENTS")" \
  "docker compose -p hybrid-ai --env-file $R6/etc/hybrid-ai/stack.env"
have "the re-run reached the install.sh hand-off" "$(cat "$EVENTS")" "install.sh HYBRID_AI_ENV_FILE="
if grep -q 'could not stop the stack' "$WORK/rerun-from-2.log"; then
  bad "the second --from run died at the stop step"
else
  ok "the second --from run did not die at the stop step"
fi
# Restore the real docker stub for the remaining cases.
# shellcheck disable=SC2016  # $* must expand inside the generated stub, not here
printf '#!/usr/bin/env bash\nprintf "docker %%s\\n" "$*" >> "$EVENTS"\nexit 0\n' > "$STUBS/docker"
chmod +x "$STUBS/docker"

# ---------------------------------------------------------------------------
echo
echo "== D8 repair: a re-run relocates the wrong child agent dirs =="
# An earlier bad run may have moved the agent trees to ${DATA_DIR}/agent-*.
# A re-run must rename them to the siblings when the sibling is absent, and
# refuse (exit 6, before any move) when both copies hold data.
R8="$(new_root)"
mkdir -p "$R8/var/lib/hybrid-ai/agent-workspace" "$R8/var/lib/hybrid-ai/agent-repos"
printf 'ws\n' > "$R8/var/lib/hybrid-ai/agent-workspace/KEY"
printf 'repos\n' > "$R8/var/lib/hybrid-ai/agent-repos/REPO"
LEGACY8="$R8/legacy"; mkdir -p "$LEGACY8/openhands" "$LEGACY8/hermes"
printf '# legacy env\n' > "$LEGACY8/.env"; chmod 600 "$LEGACY8/.env"
: > "$LEGACY8/docker-compose.yml"
: > "$LEGACY8/openhands/docker-compose.openhands.yml"
: > "$LEGACY8/hermes/docker-compose.hermes.yml"
inode8_ws="$(stat -c '%i' "$R8/var/lib/hybrid-ai/agent-workspace/KEY")"
rc=0
run_bootstrap "$R8" "$WORK/repair.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY8" --login-user pi || rc=$?
check "the repair re-run exits 0" "0" "$rc"
if (( rc != 0 )); then sed 's/^/      /' "$WORK/repair.log" >&2; fi
check "the child agent-workspace was relocated to the sibling" "yes" \
  "$([[ -f "$R8/var/lib/hybrid-ai-agent/KEY" ]] && echo yes || echo no)"
check "the repair preserved the inode (a rename)" "$inode8_ws" \
  "$(stat -c '%i' "$R8/var/lib/hybrid-ai-agent/KEY" 2>/dev/null)"
check "the old child agent-workspace is gone" "no" \
  "$([[ -e "$R8/var/lib/hybrid-ai/agent-workspace" ]] && echo yes || echo no)"
check "the child agent-repos was relocated to the sibling" "yes" \
  "$([[ -f "$R8/var/lib/hybrid-ai-repos/REPO" ]] && echo yes || echo no)"
# shellcheck disable=SC2012  # the manifest name has no spaces; ls glob is fine
manifest8="$(ls "$R8/var/log/hybrid-ai/"bootstrap-*.manifest 2>/dev/null | head -1)"
if [[ -n "$manifest8" ]] && grep -q -- 'agent-workspace ->' "$manifest8"; then
  ok "the repair move is recorded in the manifest"
else
  bad "the repair move is not recorded in the manifest"
fi
# The layout file must now carry the SIBLING paths, never the old child paths.
LAYOUT8="$R8/etc/hybrid-ai/hybrid-ai.env"
check "the repaired layout names the sibling OPENHANDS_WORKSPACE" \
  "$R8/var/lib/hybrid-ai-agent" \
  "$(grep -E '^OPENHANDS_WORKSPACE=' "$LAYOUT8" | cut -d= -f2-)"
check "the repaired layout names the sibling AGENT_REPOS_DIR" \
  "$R8/var/lib/hybrid-ai-repos" \
  "$(grep -E '^AGENT_REPOS_DIR=' "$LAYOUT8" | cut -d= -f2-)"
if grep -qE '^OPENHANDS_WORKSPACE=.*/agent-workspace$|^AGENT_REPOS_DIR=.*/agent-repos$' "$LAYOUT8"; then
  bad "the repaired layout still names an old child agent path"
else
  ok "the repaired layout names no old child agent path"
fi

# Both copies non-empty: refuse with exit 6 BEFORE any move.
R9="$(new_root)"
mkdir -p "$R9/var/lib/hybrid-ai/agent-workspace" "$R9/var/lib/hybrid-ai-agent"
printf 'old\n' > "$R9/var/lib/hybrid-ai/agent-workspace/KEY"
printf 'new\n' > "$R9/var/lib/hybrid-ai-agent/KEY"
LEGACY9="$R9/legacy"; mkdir -p "$LEGACY9/openhands" "$LEGACY9/hermes"
printf '# legacy env\n' > "$LEGACY9/.env"; chmod 600 "$LEGACY9/.env"
: > "$LEGACY9/docker-compose.yml"
: > "$LEGACY9/openhands/docker-compose.openhands.yml"
: > "$LEGACY9/hermes/docker-compose.hermes.yml"
rc=0
run_bootstrap "$R9" "$WORK/repair-both.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY9" --login-user pi || rc=$?
check "both copies non-empty is refused with 6" "6" "$rc"
check "the refusal left the old child copy untouched" "yes" \
  "$([[ -f "$R9/var/lib/hybrid-ai/agent-workspace/KEY" ]] && echo yes || echo no)"
check "the refusal left the sibling copy untouched" "yes" \
  "$([[ -f "$R9/var/lib/hybrid-ai-agent/KEY" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo
echo "== no secret value reaches stdout, stderr or the manifest =="
# The credential files seeded by this test are also checked: the bootstrap must
# never copy their contents into a stubstate scratch file (the stub accounts
# would otherwise accumulate secrets). Names only, never a value.
for sentinel in __SENTINEL_ENVDOT__ __SENTINEL_R2__ __SENTINEL_PW__ "__SENTINEL_STACK__"; do
  found=0
  for f in "$WORK/migrate.log" "$manifest"; do
    [[ -f "$f" ]] || continue
    grep -qF "$sentinel" "$f" && found=1
  done
  if (( found )); then bad "the sentinel ${sentinel} leaked into output or the manifest"; else ok "the sentinel ${sentinel} is absent from output and the manifest"; fi
done
# No sentinel may appear anywhere under the migration scratch host root either.
for sentinel in __SENTINEL_ENVDOT__ __SENTINEL_R2__ __SENTINEL_PW__; do
  if grep -rqF "$sentinel" "$R2/stubstate" 2>/dev/null; then
    bad "the sentinel ${sentinel} leaked into the scratch stubstate"
  else
    ok "the sentinel ${sentinel} is absent from the scratch stubstate"
  fi
done

# A stack sentinel, written by the install.sh stub, must not leak either.
R3="$(new_root)"
EXTRA_ENV=(STACK_SENTINEL="__SENTINEL_STACK__")
run_bootstrap "$R3" "$WORK/sentinel.log" --deploy-pubkey "$PUBKEY" --login-user pi || true
if grep -qF "__SENTINEL_STACK__" "$WORK/sentinel.log"; then
  bad "the stack sentinel leaked into bootstrap output"
else
  ok "the stack sentinel is absent from bootstrap output"
fi
check "the stack sentinel really was written by install.sh" "yes" \
  "$(grep -qxF 'WEBUI_SECRET_KEY=__SENTINEL_STACK__' "$R3/etc/hybrid-ai/stack.env" && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo
echo "== refusals (one exit code per class) =="

# 2 -- not root.
R="$(new_root)"
EXTRA_ENV=(FAKE_UID=1000)
rc=0; run_bootstrap "$R" "$WORK/r_notroot.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "not root exits 2" "2" "$rc"

# 3 -- bad public key: a private key.
R="$(new_root)"
priv_ed25519 > "$WORK/priv.pub"
rc=0; run_bootstrap "$R" "$WORK/r_priv.log" --deploy-pubkey "$WORK/priv.pub" --login-user pi || rc=$?
check "a private key is refused with 3" "3" "$rc"

# 3 -- more than one key.
{ pub_ed25519; pub_ed25519; } > "$WORK/two.pub"
R="$(new_root)"
rc=0; run_bootstrap "$R" "$WORK/r_two.log" --deploy-pubkey "$WORK/two.pub" --login-user pi || rc=$?
check "two keys are refused with 3" "3" "$rc"

# 3 -- a line that already carries options.
printf 'command="id" ssh-ed25519 %s x@y\n' "$OTHER_BLOB" > "$WORK/opts.pub"
R="$(new_root)"
rc=0; run_bootstrap "$R" "$WORK/r_opts.log" --deploy-pubkey "$WORK/opts.pub" --login-user pi || rc=$?
check "an option-bearing key line is refused with 3" "3" "$rc"

# 4 -- an existing /opt/hybrid-ai that is not a git clone.
R="$(new_root)"
mkdir -p "$R/opt/hybrid-ai"
rc=0; run_bootstrap "$R" "$WORK/r_notclone.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "a non-clone /opt/hybrid-ai is refused with 4" "4" "$rc"

# 4 -- a credential-bearing origin.
R="$(new_root)"
mkdir -p "$R/opt/hybrid-ai/.git"
EXTRA_ENV=(GIT_ORIGIN_URL="https://user:pass@github.com/jimbobsyouruncle/hybrid-ai.git")
rc=0; run_bootstrap "$R" "$WORK/r_cred.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "a credential-bearing origin is refused with 4" "4" "$rc"

# 4 -- a foreign origin.
R="$(new_root)"
mkdir -p "$R/opt/hybrid-ai/.git"
EXTRA_ENV=(GIT_ORIGIN_URL="https://github.com/someone/other.git")
rc=0; run_bootstrap "$R" "$WORK/r_foreign.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "a foreign origin is refused with 4" "4" "$rc"

# 5 -- polkit too old.
R="$(new_root)"; mkdir -p "$R/etc/polkit-1/rules.d"
EXTRA_ENV=(POLKIT_VERSION=0.105)
rc=0; run_bootstrap "$R" "$WORK/r_polkit.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "an old polkit is refused with 5" "5" "$rc"

# 6 -- a non-empty move target.
R="$(new_root)"
LEGACY="$R/legacy"; mkdir -p "$LEGACY/hermes_data"
printf 'x\n' > "$LEGACY/hermes_data/HFILE"
mkdir -p "$R/var/lib/hybrid-ai/hermes_data"
printf 'y\n' > "$R/var/lib/hybrid-ai/hermes_data/EXISTING"
: > "$LEGACY/.env"; : > "$LEGACY/docker-compose.yml"
mkdir -p "$LEGACY/openhands" "$LEGACY/hermes"
: > "$LEGACY/openhands/docker-compose.openhands.yml"
: > "$LEGACY/hermes/docker-compose.hermes.yml"
rc=0; run_bootstrap "$R" "$WORK/r_nonempty.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY" --login-user pi || rc=$?
check "a non-empty move target is refused with 6" "6" "$rc"
if [[ -f "$R/var/lib/hybrid-ai/hermes_data/EXISTING" ]]; then
  ok "nothing was moved before the refusal"
else
  bad "the refusal happened after a partial move"
fi

# 6 -- a pre-existing FILE move target (the moved legacy .env / stack file) is
# the same "non-empty target" class, NOT the generic exit 1, and nothing moves.
R="$(new_root)"
LEGACY="$R/legacy"; mkdir -p "$LEGACY/hermes_data" "$LEGACY/openhands" "$LEGACY/hermes"
printf 'x\n' > "$LEGACY/hermes_data/HFILE"
: > "$LEGACY/.env"; : > "$LEGACY/docker-compose.yml"
: > "$LEGACY/openhands/docker-compose.openhands.yml"
: > "$LEGACY/hermes/docker-compose.hermes.yml"
mkdir -p "$R/etc/hybrid-ai"
printf 'preexisting\n' > "$R/etc/hybrid-ai/stack.env"
rc=0; run_bootstrap "$R" "$WORK/r_filetgt.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY" --login-user pi || rc=$?
check "a pre-existing stack-file target is refused with 6" "6" "$rc"
if [[ -e "$LEGACY/hermes_data" ]]; then
  ok "no data dir moved before the file-target refusal"
else
  bad "a data dir moved before the file-target refusal"
fi

# 6 -- a cross-device move is refused with 6. /dev/shm is a different filesystem
# from the scratch root, so the rename would not be atomic.
if [[ -d /dev/shm && "$(stat -c '%d' /dev/shm)" != "$(stat -c '%d' "$WORK")" ]]; then
  R="$(new_root)"
  LEGACY="/dev/shm/hyb-legacy-$$"; mkdir -p "$LEGACY/hermes_data" "$LEGACY/openhands" "$LEGACY/hermes"
  printf 'x\n' > "$LEGACY/hermes_data/HFILE"
  : > "$LEGACY/.env"; : > "$LEGACY/docker-compose.yml"
  : > "$LEGACY/openhands/docker-compose.openhands.yml"
  : > "$LEGACY/hermes/docker-compose.hermes.yml"
  rc=0; run_bootstrap "$R" "$WORK/r_xdev.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY" --login-user pi || rc=$?
  check "a cross-device move is refused with 6" "6" "$rc"
  if [[ -e "$LEGACY/hermes_data/HFILE" ]]; then
    ok "the cross-device source was left in place"
  else
    bad "the cross-device source was moved anyway"
  fi
  rm -rf "$LEGACY"
else
  printf 'ok   skip cross-device refusal assertion (no separate filesystem)\n'
fi

# ---------------------------------------------------------------------------
echo
echo "== install.sh failure stops the cut-off =="
R="$(new_root)"
LEGACY="$R/legacy"; mkdir -p "$LEGACY/openhands" "$LEGACY/hermes"
: > "$LEGACY/.env"; : > "$LEGACY/docker-compose.yml"
: > "$LEGACY/openhands/docker-compose.openhands.yml"
: > "$LEGACY/hermes/docker-compose.hermes.yml"
mkdir -p "$R/home/pi/.ssh"
{ printf '%s\n' "ssh-ed25519 ${OTHER_BLOB} other@fixture"
  printf '%s\n' "restrict,command=\"/opt/hybrid-ai/scripts/deploy-forced-command.sh\" $(cat "$PUBKEY")"
} > "$R/home/pi/.ssh/authorized_keys"
rc=0
EXTRA_ENV=(INSTALL_RC=1)
run_bootstrap "$R" "$WORK/r_install.log" --deploy-pubkey "$PUBKEY" --from "$LEGACY" --login-user pi || rc=$?
check "an install.sh failure exits 7" "7" "$rc"
if grep -q 'gpasswd-docker' "$EVENTS"; then
  bad "the docker group was changed despite the install.sh failure"
else
  ok "the docker group was NOT changed after the install.sh failure"
fi
check "the deploy key line was NOT removed" "1" \
  "$(grep -cF "$KEY_BLOB" "$R/home/pi/.ssh/authorized_keys")"
if grep -q 'systemctl --user disable' "$EVENTS"; then
  bad "the user units were disabled despite the install.sh failure"
else
  ok "the user units were NOT disabled after the install.sh failure"
fi

# doctor.sh reported failures: exit 8, and the cut-off must not run at all.
# A migration root primed with the deploy key line, so the cut-off has a key
# line to remove if it wrongly runs.
setup_doctor_migration_root() {
  local r="$1" legacy="$1/legacy"
  mkdir -p "$legacy/openhands" "$legacy/hermes"
  : > "$legacy/.env"; : > "$legacy/docker-compose.yml"
  : > "$legacy/openhands/docker-compose.openhands.yml"
  : > "$legacy/hermes/docker-compose.hermes.yml"
  mkdir -p "$r/home/pi/.ssh"
  printf '%s\n' "restrict,command=\"/opt/hybrid-ai/scripts/deploy-forced-command.sh\" $(cat "$PUBKEY")" \
    > "$r/home/pi/.ssh/authorized_keys"
}
assert_no_cutoff() { # label
  if grep -q 'gpasswd-docker' "$EVENTS"; then
    bad "the docker group was changed despite $1"
  else
    ok "the docker group was NOT changed after $1"
  fi
  check "the deploy key line was NOT removed ($1)" "1" \
    "$(grep -cF "$KEY_BLOB" "$R/home/pi/.ssh/authorized_keys")"
  if grep -q 'systemctl --user disable' "$EVENTS"; then
    bad "the user units were disabled despite $1"
  else
    ok "the user units were NOT disabled after $1"
  fi
}

R="$(new_root)"
setup_doctor_migration_root "$R"
rc=0
EXTRA_ENV=(DOCTOR_RC=2)
run_bootstrap "$R" "$WORK/r_doctor.log" --deploy-pubkey "$PUBKEY" --from "$R/legacy" --login-user pi || rc=$?
check "a doctor.sh failure (exit 2) exits 8" "8" "$rc"
assert_no_cutoff "the doctor.sh failure (exit 2)"

# Any other non-zero doctor.sh code is a failure too: exit 8, no cut-off.
R="$(new_root)"
setup_doctor_migration_root "$R"
rc=0
EXTRA_ENV=(DOCTOR_RC=3)
run_bootstrap "$R" "$WORK/r_doctor3.log" --deploy-pubkey "$PUBKEY" --from "$R/legacy" --login-user pi || rc=$?
check "an unexpected doctor.sh code (exit 3) exits 8" "8" "$rc"
assert_no_cutoff "the unexpected doctor.sh code (exit 3)"

# doctor.sh warnings only (exit 1) in migration mode: exit 0, warning printed,
# and the cut-off runs exactly as on a healthy exit.
R="$(new_root)"
setup_doctor_migration_root "$R"
rc=0
EXTRA_ENV=(DOCTOR_RC=1)
run_bootstrap "$R" "$WORK/r_doctorwarn.log" --deploy-pubkey "$PUBKEY" --from "$R/legacy" --login-user pi || rc=$?
check "a doctor.sh warning (exit 1) in migration mode exits 0" "0" "$rc"
have "the doctor warning is reported and the run continues" "$(cat "$WORK/r_doctorwarn.log")" \
  "doctor.sh reported warnings"
if grep -q 'gpasswd-docker' "$EVENTS"; then
  ok "the docker group was changed after a doctor.sh warning"
else
  bad "the docker group was NOT changed after a doctor.sh warning"
fi
check "the deploy key line was removed after a doctor.sh warning" "0" \
  "$(grep -cF "$KEY_BLOB" "$R/home/pi/.ssh/authorized_keys")"
if grep -q 'systemctl --user disable' "$EVENTS"; then
  ok "the user units were disabled after a doctor.sh warning"
else
  bad "the user units were NOT disabled after a doctor.sh warning"
fi

# doctor.sh warnings only (exit 1) in fresh-install mode: exit 0, no cut-off.
R="$(new_root)"
rc=0
EXTRA_ENV=(DOCTOR_RC=1)
run_bootstrap "$R" "$WORK/r_doctorwarn_fresh.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
check "a doctor.sh warning (exit 1) in fresh-install mode exits 0" "0" "$rc"

# 1 -- a usage error.
R="$(new_root)"
rc=0; run_bootstrap "$R" "$WORK/r_usage.log" --login-user pi || rc=$?
check "a missing --deploy-pubkey is a usage error (1)" "1" "$rc"

# ---------------------------------------------------------------------------
echo
echo "== the AllowUsers/AllowGroups guidance is printed, sshd_config untouched =="
R="$(new_root)"
EXTRA_ENV=(SSHD_T_OUT=$'allowusers pi\n')
rc=0; run_bootstrap "$R" "$WORK/allow.log" --deploy-pubkey "$PUBKEY" --login-user pi || rc=$?
have "the exact AllowUsers line is printed" "$(cat "$WORK/allow.log")" "AllowUsers hybrid-ai-deploy"
check "bootstrap still exits 0" "0" "$rc"
check "sshd_config was not created" "no" "$([[ -e "$R/etc/ssh/sshd_config" ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo
echo "== install.sh writes ONLY the stack file, never the layout file (AC2) =="
# A fixture app holding the REAL install.sh plus the layout/stack split. Every
# host dependency is stubbed on PATH, so nothing real is touched and no network
# is used. install.sh must write the STACK file and leave the LAYOUT file
# byte-identical, because with the two paths different the layout file is never
# the installer's output.
INST="$WORK/install-fixture"
INST_APP="$INST/app"
INST_BIN="$INST/bin"
mkdir -p "$INST_APP/scripts/lib" "$INST_BIN" \
         "$INST/etc/hybrid-ai" "$INST/data" "$INST/log" "$INST/work" \
         "$INST/ws" "$INST/repos" "$INST/ohstate" "$INST/conf" "$INST/restic"
cp "$REPO/install.sh" "$INST_APP/install.sh"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$INST_APP/scripts/lib/"
cp "$REPO/scripts/setup-agent-workspace.sh" "$REPO/scripts/sync-agent-repos.sh" "$INST_APP/scripts/"

for d in docker git jq curl openssl sqlite3 rsync tailscale; do
  # shellcheck disable=SC2016  # $0 must expand inside the generated stub, not here
  printf '#!/usr/bin/env bash\nprintf "%%s stub\\n" "$0"\nexit 0\n' > "$INST_BIN/$d"
done
# `id` must answer without a real account, and setfacl/chown are no-ops.
# shellcheck disable=SC2016  # $@ must expand inside the generated stub, not here
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then printf "1000\\n"; exit 0; fi\nif [[ "${1:-}" == "-g" ]]; then printf "1000\\n"; exit 0; fi\nexec /usr/bin/id "$@"\n' > "$INST_BIN/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$INST_BIN/chown"
printf '#!/usr/bin/env bash\nexit 0\n' > "$INST_BIN/setfacl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$INST_BIN/apt-get"
chmod +x "$INST_BIN"/*

# Run the REAL install.sh with every host dependency stubbed. $1 app dir,
# $2 layout file, $3 log. HYBRID_AI_ENV_FILE is the layout file; install.sh
# learns HYBRID_AI_STACK_ENV_FILE from it and writes that stack file.
run_real_install() { # app layout log
  local app="$1" layout="$2" log="$3" rc=0
  env -u HYBRID_AI_APP_DIR -u HYBRID_AI_DATA_DIR -u HYBRID_AI_LOG_DIR \
      -u HYBRID_AI_WORK_DIR -u HYBRID_AI_STACK_ENV_FILE \
      -u OPENHANDS_WORKSPACE -u AGENT_REPOS_DIR -u OPENHANDS_STATE_DIR \
      -u BACKUP_CONF_DIR -u RESTIC_CACHE_DIR -u HYBRID_AI_HERMES_HOME_DIR \
      -u HYBRID_AI_BACKUP_MODE -u BACKUP_CONTAINER_CONTROL \
      -u HYBRID_AI_UID -u HYBRID_AI_GID -u HYBRID_AI_LAYOUT_UID -u HYBRID_AI_LAYOUT_GID \
      PATH="$INST_BIN:$PATH" \
      HYBRID_AI_ENV_FILE="$layout" \
      LOCAL_DOMAIN=example.test OPENROUTER_API_KEY=stub RUNPOD_API_KEY=stub \
      RUNPOD_POD_ID=stub RUNPOD_HOST=stub PI_HOST=stub \
      OPENHANDS_SANDBOX_HOST=example.test PEER_HOSTNAMES="none" \
      USER=fixture \
      bash "$app/install.sh" --no-start --non-interactive >> "$log" 2>&1 || rc=$?
  return "$rc"
}

INST_LAYOUT="$INST/etc/hybrid-ai/hybrid-ai.env"
INST_STACK="$INST/etc/hybrid-ai/stack.env"
cat > "$INST_LAYOUT" <<EOF
HYBRID_AI_APP_DIR=${INST_APP}
HYBRID_AI_ENV_FILE=${INST_LAYOUT}
HYBRID_AI_STACK_ENV_FILE=${INST_STACK}
HYBRID_AI_DATA_DIR=${INST}/data
HYBRID_AI_LOG_DIR=${INST}/log
HYBRID_AI_WORK_DIR=${INST}/work
OPENHANDS_WORKSPACE=${INST}/ws
AGENT_REPOS_DIR=${INST}/repos
OPENHANDS_STATE_DIR=${INST}/ohstate
BACKUP_CONF_DIR=${INST}/conf
RESTIC_CACHE_DIR=${INST}/restic
HYBRID_AI_HERMES_HOME_DIR=${INST}/hermes
HYBRID_AI_BACKUP_MODE=system
BACKUP_CONTAINER_CONTROL=external
HYBRID_AI_UID=1000
HYBRID_AI_GID=1000
EOF
chmod 644 "$INST_LAYOUT"
LAYOUT_SHA_BEFORE="$(sha256sum "$INST_LAYOUT" | awk '{print $1}')"

rc=0
run_real_install "$INST_APP" "$INST_LAYOUT" "$INST/out.log" || rc=$?
check "install.sh --no-start exits 0 with stubbed dependencies" "0" "$rc"
check "install.sh wrote the STACK env file" "yes" \
  "$([[ -f "$INST_STACK" ]] && echo yes || echo no)"
check "the STACK env file is 0600" "600" "$(stat -c '%a' "$INST_STACK" 2>/dev/null)"
check "the LAYOUT env file is byte-identical after install.sh ran" \
  "$LAYOUT_SHA_BEFORE" "$(sha256sum "$INST_LAYOUT" | awk '{print $1}')"
# install.sh writes secrets; with the split they must land in the STACK file and
# never in the LAYOUT file.
if grep -q '^WEBUI_SECRET_KEY=' "$INST_STACK"; then
  ok "the generated secret is in the stack file"
else
  bad "the generated secret is missing from the stack file"
fi
if grep -q 'WEBUI_SECRET_KEY' "$INST_LAYOUT"; then
  bad "a secret key name leaked into the layout file"
else
  ok "no secret key name was written to the layout file"
fi
# The layout-only settings must survive the write untouched.
for k in HYBRID_AI_STACK_ENV_FILE HYBRID_AI_DATA_DIR HYBRID_AI_BACKUP_MODE; do
  if grep -q "^${k}=" "$INST_LAYOUT"; then
    ok "the layout file still holds ${k}"
  else
    bad "the layout file lost ${k}"
  fi
done

# ---------------------------------------------------------------------------
echo
echo "== a legacy stack file with EMPTY ids cannot drop the stack to uid 0 (AC1) =="
# Reproduces the migration shape: the layout file carries the account ids, but
# the PRE-EXISTING stack file (the moved legacy .env) carries empty
# HYBRID_AI_UID=/HYBRID_AI_GID=. The real install.sh MUST keep the layout ids
# and write them, with a non-zero STATUS_UID. Before the fix it wrote empty ids
# back and STATUS_UID=0, so the stack ran as root.
rm -rf "$INST_STACK"
STACK_SENTINEL_VAL="__SENTINEL_LEGACY_STACK__"
{
  printf 'STATUS_UID=0\nHYBRID_AI_UID=\nHYBRID_AI_GID=\nWEBUI_SECRET_KEY=legacy\n'
  # Legacy paths that point AWAY from the layout, as a real Pi .env would once
  # the migration moved the trees: the layout must win, not these.
  printf 'OPENHANDS_WORKSPACE=/home/pi/hybrid-ai-agent\n'
  printf 'AGENT_REPOS_DIR=/home/pi/hybrid-ai-repos\n'
  printf 'OPENHANDS_STATE_DIR=/home/pi/.openhands\n'
  # A sentinel in the legacy stack file must never reach the output.
  printf 'RUNPOD_API_KEY=%s\n' "$STACK_SENTINEL_VAL"
} > "$INST_STACK"
chmod 600 "$INST_STACK"

rc=0
run_real_install "$INST_APP" "$INST_LAYOUT" "$INST/empty-ids.log" || rc=$?
check "install.sh exits 0 with a legacy empty-id stack file" "0" "$rc"

check "the stack file carries the layout uid (1000)" "1000" \
  "$(grep -E '^HYBRID_AI_UID=' "$INST_STACK" | tail -1 | cut -d= -f2-)"
check "the stack file carries the layout gid (1000)" "1000" \
  "$(grep -E '^HYBRID_AI_GID=' "$INST_STACK" | tail -1 | cut -d= -f2-)"
status_uid="$(grep -E '^STATUS_UID=' "$INST_STACK" | tail -1 | cut -d= -f2-)"
if [[ -n "$status_uid" && "$status_uid" != "0" ]]; then
  ok "STATUS_UID is non-zero (${status_uid})"
else
  bad "STATUS_UID is empty or zero (${status_uid})"
fi
# The rewritten stack file must carry the LAYOUT paths, never the legacy ones.
check "OPENHANDS_WORKSPACE is the layout path" "${INST}/ws" \
  "$(grep -E '^OPENHANDS_WORKSPACE=' "$INST_STACK" | tail -1 | cut -d= -f2-)"
check "AGENT_REPOS_DIR is the layout path" "${INST}/repos" \
  "$(grep -E '^AGENT_REPOS_DIR=' "$INST_STACK" | tail -1 | cut -d= -f2-)"
check "OPENHANDS_STATE_DIR is the layout path" "${INST}/ohstate" \
  "$(grep -E '^OPENHANDS_STATE_DIR=' "$INST_STACK" | tail -1 | cut -d= -f2-)"
if grep -q '^OPENHANDS_WORKSPACE=/home/pi/' "$INST_STACK" \
   || grep -q '^AGENT_REPOS_DIR=/home/pi/' "$INST_STACK" \
   || grep -q '^OPENHANDS_STATE_DIR=/home/pi/' "$INST_STACK"; then
  bad "a legacy /home/pi path survived into the rewritten stack file"
else
  ok "no legacy /home/pi path survived into the rewritten stack file"
fi
if grep -qF "$STACK_SENTINEL_VAL" "$INST/empty-ids.log"; then
  bad "the legacy stack-file value leaked into install.sh output"
else
  ok "no value from the legacy stack file leaked into output"
fi
# The layout file is still authoritative and untouched.
check "the layout file is still byte-identical" \
  "$LAYOUT_SHA_BEFORE" "$(sha256sum "$INST_LAYOUT" | awk '{print $1}')"

# ---------------------------------------------------------------------------
echo
echo "== static checks =="
if grep -qE 'ssh-keygen|openssl[[:space:]]+rand|restic[[:space:]]+key' "$BOOTSTRAP"; then
  bad "scripts/bootstrap.sh contains a key or credential generation command"
else
  ok "scripts/bootstrap.sh generates no key or credential"
fi
if grep -qE 'ssh-keygen|openssl[[:space:]]+rand' "$REPO/deploy/hybrid-ai-deploy@.service"; then
  bad "the deploy unit contains a key generation command"
else
  ok "the deploy unit contains no key generation command"
fi
# The deploy unit is installed but never enabled by the bootstrap.
if grep -qE 'systemctl[[:space:]]+enable' "$BOOTSTRAP"; then
  bad "scripts/bootstrap.sh enables a unit (the deploy unit must never be enabled)"
else
  ok "scripts/bootstrap.sh never enables a unit"
fi
# The bootstrap must never call ssh-keygen or write an sshd_config.
if grep -qE 'sshd_config' "$BOOTSTRAP" && ! grep -q 'does not edit' "$BOOTSTRAP"; then
  : # informational only
fi
if grep -qE '>\s*[^ ]*sshd_config|tee[^|]*sshd_config' "$BOOTSTRAP"; then
  bad "scripts/bootstrap.sh writes sshd_config"
else
  ok "scripts/bootstrap.sh never writes sshd_config"
fi

# Byte-identical files (AC15), when origin/main is available.
if git -C "$REPO" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  # Keep this list equal to the out-of-scope paths in the job brief. `backup/`
  # is intentionally NOT here: this card changes backup/backup.sh and
  # backup/restore.sh, so it can no longer be byte-identical to origin/main.
  diff_out="$(git -C "$REPO" diff --stat origin/main -- \
    docker-compose.yml hermes/docker-compose.hermes.yml \
    openhands/docker-compose.openhands.yml doctor.sh status/Caddyfile \
    .github/workflows/deploy.yml scripts/deploy-instance.sh \
    deploy/hybrid-ai-deploy@.service deploy/50-hybrid-ai-deploy.rules 2>/dev/null)"
  check "the out-of-scope files are byte-identical to origin/main" "" "$diff_out"
else
  printf 'skip: origin/main is not available; the byte-identical check is a no-op here\n'
fi

# The refusal codes are documented in the header AND in the troubleshooting doc.
for code in 2 3 4 5 6 7 8; do
  have "the bootstrap header documents exit ${code}" "$(head -80 "$BOOTSTRAP")" "  ${code}  "
done

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
