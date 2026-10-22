#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-uninstall.sh
# PURPOSE (plain English):
#   Offline tests for scripts/uninstall.sh. They need NO root, NO Docker and NO
#   network. Every privileged tool -- docker, systemctl, runuser, iptables,
#   getent, id and xargs -- is stubbed on PATH, and the whole run is pointed at
#   a scratch filesystem prefix with HYBRID_AI_UNINSTALL_ROOT, so the REAL
#   /opt, /etc and /var are never touched.
#
# CASES:
#   * full install  -> the compose "down --remove-orphans" call with the three
#     -f files (asserted as an exact argv)
#   * remnants only -> removal by container name, with NO compose call
#   * nothing found -> a no-op that exits 0
#   * --remove-data removes the fixture data; the default keeps it
#   * an out-of-allowlist layout value is refused, the path survives and the
#     message names the setting
#   * a mixed DOCKER-USER chain -> only the tagged rules are deleted, the
#     untagged rules survive, and nothing flushes or deletes the chain
#   * a hybrid-ai-* glob unit (e.g. hybrid-ai-docker-cache-prune.timer) is
#     removed
#   * --dry-run mutates neither the fixture tree nor the event log
#
# USAGE:
#   bash scripts/test-uninstall.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
UNINSTALL="${SCRIPT_DIR}/uninstall.sh"
[[ -f "$UNINSTALL" ]] || { echo "FATAL: cannot find $UNINSTALL" >&2; exit 1; }

PASS=0
FAIL=0
ok()   { PASS=$(( PASS + 1 )); printf 'ok   %s\n' "$*"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL %s\n' "$*" >&2; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
have()  { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing '$3')"; fi; }
have_not() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpected '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

# ---------------------------------------------------------------------------
# The stub bin directory. Everything an uninstall run must not really do.
# ---------------------------------------------------------------------------
STUBS="$WORK/bin"
mkdir -p "$STUBS"

cat > "$STUBS/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then printf '%s\n' "${FAKE_UID:-0}"; exit 0; fi
exec /usr/bin/id "$@"
EOF

# getent: a tiny passwd database so account_uid() resolves the login user.
cat > "$STUBS/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "passwd" ]]; then
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$2" "${FAKE_UID:-0}" "${FAKE_UID:-0}" "$2"
  exit 0
fi
exit 2
EOF

cat > "$STUBS/docker" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'docker %s\n' "$*" >> "$EVENTS"
# A sandbox sweep prints one id; anything else prints nothing.
if [[ "${1:-}" == "ps" ]]; then
  printf 'sandboxdeadbeef\n'
  exit 0
fi
exit 0
EOF

cat > "$STUBS/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'systemctl %s\n' "$*" >> "$EVENTS"
exit 0
EOF

cat > "$STUBS/runuser" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'runuser %s\n' "$*" >> "$EVENTS"
exit 0
EOF

# iptables: -S prints a fixture chain; -D logs the delete. A flush or chain
# delete is logged too, so the harness can prove neither ever happens.
cat > "$STUBS/iptables" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "-w" ]]; then shift 2; fi
case "${1:-}" in
  -S) cat "$IPT_FIXTURE"; exit 0 ;;
  -D) shift; printf 'iptables -D %s\n' "$*" >> "$EVENTS"; exit 0 ;;
  -F|-X) printf 'iptables %s %s\n' "$1" "${2:-}" >> "$EVENTS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUBS"/*

export PATH="$STUBS:$PATH"
export FAKE_UID=0

# ---------------------------------------------------------------------------
# A fixture host tree. ROOT is the HYBRID_AI_UNINSTALL_ROOT prefix.
# ---------------------------------------------------------------------------
new_root() { # name -> prints the prefix
  local r="$WORK/root-$1"
  mkdir -p "$r"
  printf '%s' "$r"
}

# Write a layout env file naming the fixture data directories. Names and paths
# only, exactly like scripts/bootstrap.sh writes. Never a secret.
write_layout() { # root
  local r="$1"
  mkdir -p "$r/etc/hybrid-ai"
  cat > "$r/etc/hybrid-ai/hybrid-ai.env" <<EOF
HYBRID_AI_APP_DIR=${r}/opt/hybrid-ai
HYBRID_AI_STACK_ENV_FILE=${r}/etc/hybrid-ai/stack.env
HYBRID_AI_DATA_DIR=${r}/var/lib/hybrid-ai
HYBRID_AI_LOG_DIR=${r}/var/log/hybrid-ai
HYBRID_AI_WORK_DIR=${r}/var/lib/hybrid-ai/work
RESTIC_CACHE_DIR=${r}/var/cache/hybrid-ai-backup
HYBRID_AI_BACKUP_CRED_DIR=${r}/etc/credstore/hybrid-ai-backup
OPENHANDS_WORKSPACE=${r}/var/lib/hybrid-ai-agent
AGENT_REPOS_DIR=${r}/var/lib/hybrid-ai-repos
BACKUP_LOG=${r}/var/log/hybrid-ai-backup/backup.log
EOF
}

# A full install: the three compose files and a copy of the env library, so
# uninstall.sh takes the SOURCING path.
write_full_install() { # root
  local r="$1"
  mkdir -p "$r/opt/hybrid-ai/scripts/lib" \
           "$r/opt/hybrid-ai/openhands" "$r/opt/hybrid-ai/hermes"
  : > "$r/opt/hybrid-ai/docker-compose.yml"
  : > "$r/opt/hybrid-ai/openhands/docker-compose.openhands.yml"
  : > "$r/opt/hybrid-ai/hermes/docker-compose.hermes.yml"
  cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$r/opt/hybrid-ai/scripts/lib/hybrid-ai-env.sh"
}

# The data directories a full or remnant fixture can carry.
write_data_dirs() { # root
  local r="$1"
  mkdir -p "$r/var/lib/hybrid-ai/work" "$r/var/log/hybrid-ai" \
           "$r/var/cache/hybrid-ai-backup" "$r/etc/credstore/hybrid-ai-backup"
  : > "$r/var/lib/hybrid-ai/keepme.txt"
}

# The five bootstrapped sibling trees a bootstrap creates beside the data dir:
# the agent workspace, the repo reference tree, the two account homes and the
# backup log directory. Each gets a file so its removal is provable.
SIBLING_DIRS=( var/lib/hybrid-ai-agent var/lib/hybrid-ai-repos \
               var/lib/hybrid-ai-deploy var/lib/hybrid-ai-backup \
               var/log/hybrid-ai-backup )
write_siblings() { # root
  local r="$1" d
  for d in "${SIBLING_DIRS[@]}"; do
    mkdir -p "$r/$d"
    : > "$r/$d/sibling.txt"
  done
}

# ===========================================================================
# 1. Full install: compose down with the three -f files (exact argv).
# ===========================================================================
R="$(new_root full)"
write_layout "$R"; write_full_install "$R"; write_data_dirs "$R"
touch "$R/etc/hybrid-ai/stack.env"
EV="$WORK/ev-full"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes 2>&1)"; RC=$?
check "full install: exit 0" "0" "$RC"
have "full install: reports the existing install" "$OUT" "existing install"
have "full install: runs the container removal step" "$OUT" "Removing the containers"
EVLOG="$(cat "$EV")"
EXPECT_DOWN="docker compose --env-file ${R}/etc/hybrid-ai/stack.env --project-directory ${R}/opt/hybrid-ai -f ${R}/opt/hybrid-ai/docker-compose.yml -f ${R}/opt/hybrid-ai/openhands/docker-compose.openhands.yml -f ${R}/opt/hybrid-ai/hermes/docker-compose.hermes.yml down --remove-orphans"
have "full install: exact compose argv in the event log" "$EVLOG" "$EXPECT_DOWN"
have "full install: firewall unit stopped first" "$EVLOG" "systemctl disable --now hybrid-ai-firewall.service"
have "full install: the app dir is gone" "$( [[ -e "$R/opt/hybrid-ai" ]] && echo present || echo gone )" "gone"
have "full install: the data is kept" "$( [[ -e "$R/var/lib/hybrid-ai/keepme.txt" ]] && echo kept || echo lost )" "kept"

# ===========================================================================
# 2. Remnants only: remove by container name, NO compose call.
# ===========================================================================
R="$(new_root remnants)"
write_layout "$R"; write_data_dirs "$R"
EV="$WORK/ev-rem"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes 2>&1)"; RC=$?
check "remnants: exit 0" "0" "$RC"
have "remnants: reports remnants only" "$OUT" "remnants only"
EVLOG="$(cat "$EV")"
have "remnants: removes by name (ollama ... hybrid-ai-openhands)" "$EVLOG" \
  "docker rm -f ollama open-webui hybrid-ai-status hybrid-ai-proxy hermes-agent hybrid-ai-openhands"
have "remnants: sweeps the sandboxes by filter" "$EVLOG" "docker ps -aq --filter name=oh-agent-server"
have_not "remnants: NO compose call" "$EVLOG" "compose"

# ===========================================================================
# 3. Nothing found: a no-op that exits 0.
# ===========================================================================
R="$(new_root empty)"
EV="$WORK/ev-none"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes 2>&1)"; RC=$?
check "nothing found: exit 0" "0" "$RC"
have "nothing found: says so" "$OUT" "nothing found"
check "nothing found: event log empty" "" "$(cat "$EV")"

# ===========================================================================
# 4. Data: default KEEPS it, --remove-data removes it.
# ===========================================================================
R="$(new_root keepdata)"
write_layout "$R"; write_data_dirs "$R"
EV="$WORK/ev-keep"; : > "$EV"
EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes >/dev/null 2>&1
check "default keeps the data dirs" "kept" "$( [[ -e "$R/var/lib/hybrid-ai" ]] && echo kept || echo lost )"

R="$(new_root rmdata)"
write_layout "$R"; write_data_dirs "$R"
EV="$WORK/ev-rm"; : > "$EV"
EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes --remove-data >/dev/null 2>&1
check "--remove-data removes the data dir" "gone" "$( [[ -e "$R/var/lib/hybrid-ai" ]] && echo present || echo gone )"
check "--remove-data removes the log dir" "gone" "$( [[ -e "$R/var/log/hybrid-ai" ]] && echo present || echo gone )"
check "--remove-data removes /etc/hybrid-ai" "gone" "$( [[ -e "$R/etc/hybrid-ai" ]] && echo present || echo gone )"

# ===========================================================================
# 5. Out-of-allowlist layout value: refused, path survives, setting named.
# ===========================================================================
R="$(new_root evil)"
write_layout "$R"; write_data_dirs "$R"
mkdir -p "$R/opt/hybrid-ai/openhands" "$R/opt/hybrid-ai/hermes" \
         "$R/opt/hybrid-ai/scripts/lib"
: > "$R/opt/hybrid-ai/docker-compose.yml"
: > "$R/opt/hybrid-ai/openhands/docker-compose.openhands.yml"
: > "$R/opt/hybrid-ai/hermes/docker-compose.hermes.yml"
cp "$REPO/scripts/lib/hybrid-ai-env.sh" "$R/opt/hybrid-ai/scripts/lib/hybrid-ai-env.sh"
mkdir -p "$R/tmp/evil-data"; : > "$R/tmp/evil-data/precious.txt"
touch "$R/etc/hybrid-ai/stack.env"
# Name an out-of-allowlist data dir in the layout file. One line only: the env
# library concatenates duplicate matches, so a fixture must not carry two.
cat > "$R/etc/hybrid-ai/hybrid-ai.env" <<EOF
HYBRID_AI_APP_DIR=${R}/opt/hybrid-ai
HYBRID_AI_STACK_ENV_FILE=${R}/etc/hybrid-ai/stack.env
HYBRID_AI_DATA_DIR=${R}/tmp/evil-data
HYBRID_AI_LOG_DIR=${R}/var/log/hybrid-ai
HYBRID_AI_WORK_DIR=${R}/var/lib/hybrid-ai/work
RESTIC_CACHE_DIR=${R}/var/cache/hybrid-ai-backup
HYBRID_AI_BACKUP_CRED_DIR=${R}/etc/credstore/hybrid-ai-backup
EOF
EV="$WORK/ev-evil"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes --remove-data 2>&1)"; RC=$?
check "out-of-allowlist: exit 0" "0" "$RC"
have "out-of-allowlist: refusal names the setting" "$OUT" "HYBRID_AI_DATA_DIR"
have "out-of-allowlist: refusal says outside the allowlist" "$OUT" "outside the allowlist"
check "out-of-allowlist: the path survives" "present" \
  "$( [[ -e "$R/tmp/evil-data/precious.txt" ]] && echo present || echo gone )"

# ===========================================================================
# 6. Mixed DOCKER-USER: only tagged rules deleted; nothing flushed.
# ===========================================================================
R="$(new_root fw)"
write_layout "$R"; write_data_dirs "$R"
IPT_FIXTURE="$WORK/ipt.txt"
cat > "$IPT_FIXTURE" <<'EOF'
-P DOCKER-USER ACCEPT
-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment hybrid-ai-sandbox-egress -j ACCEPT
-A DOCKER-USER -i br-abc -o docker0 -p tcp -m multiport --dports 8000,8001,8011,8012 -m comment --comment hybrid-ai-sandbox-egress -j ACCEPT
-A DOCKER-USER ! -i lo -o docker0 -m comment --comment hybrid-ai-sandbox-egress -j DROP
-A DOCKER-USER -s 10.0.0.0/8 -j RETURN
-A DOCKER-USER -j ACCEPT
EOF
EV="$WORK/ev-fw"; : > "$EV"
EVENTS="$EV" IPT_FIXTURE="$IPT_FIXTURE" HYBRID_AI_UNINSTALL_ROOT="$R" \
  bash "$UNINSTALL" --yes >/dev/null 2>&1
EVLOG="$(cat "$EV")"
have "firewall: deletes the conntrack tagged rule" "$EVLOG" \
  "iptables -D DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment hybrid-ai-sandbox-egress -j ACCEPT"
have "firewall: preserves the negation on the tagged DROP" "$EVLOG" \
  "iptables -D DOCKER-USER ! -i lo -o docker0 -m comment --comment hybrid-ai-sandbox-egress -j DROP"
have_not "firewall: never deletes the untagged RETURN rule" "$EVLOG" "-s 10.0.0.0/8"
have_not "firewall: never flushes the chain" "$EVLOG" "iptables -F"
have_not "firewall: never deletes the chain" "$EVLOG" "iptables -X"

# ===========================================================================
# 7. The hybrid-ai-* glob unit is removed without editing the script.
# ===========================================================================
R="$(new_root glob)"
write_layout "$R"; write_data_dirs "$R"
mkdir -p "$R/etc/systemd/system"
: > "$R/etc/systemd/system/hybrid-ai-docker-cache-prune.timer"
: > "$R/etc/systemd/system/hybrid-ai-docker-cache-prune.service"
: > "$R/etc/systemd/system/unrelated.service"
EV="$WORK/ev-glob"; : > "$EV"
EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes >/dev/null 2>&1
check "glob unit: hybrid-ai-docker-cache-prune.timer removed" "gone" \
  "$( [[ -e "$R/etc/systemd/system/hybrid-ai-docker-cache-prune.timer" ]] && echo present || echo gone )"
check "glob unit: hybrid-ai-docker-cache-prune.service removed" "gone" \
  "$( [[ -e "$R/etc/systemd/system/hybrid-ai-docker-cache-prune.service" ]] && echo present || echo gone )"
check "glob unit: an unrelated unit survives" "present" \
  "$( [[ -e "$R/etc/systemd/system/unrelated.service" ]] && echo present || echo gone )"

# ===========================================================================
# 8. Re-runnable: a second run after a software-only uninstall takes the
#    remnants path and can then remove the data.
# ===========================================================================
R="$(new_root rerun)"
write_layout "$R"; write_full_install "$R"; write_data_dirs "$R"
touch "$R/etc/hybrid-ai/stack.env"
EV="$WORK/ev-rerun1"; : > "$EV"
EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes >/dev/null 2>&1
check "re-run: the app dir is gone after the first run" "gone" \
  "$( [[ -e "$R/opt/hybrid-ai" ]] && echo present || echo gone )"
check "re-run: the data survives the first run" "kept" \
  "$( [[ -e "$R/var/lib/hybrid-ai/keepme.txt" ]] && echo kept || echo lost )"
EV="$WORK/ev-rerun2"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes --remove-data 2>&1)"; RC=$?
check "re-run: second run exits 0" "0" "$RC"
have "re-run: second run takes the remnants path" "$OUT" "remnants only"
have_not "re-run: second run makes NO compose call" "$(cat "$EV")" "compose"
check "re-run: second run removes the data" "gone" \
  "$( [[ -e "$R/var/lib/hybrid-ai" ]] && echo present || echo gone )"

# ===========================================================================
# 9. --dry-run mutates nothing.
# ===========================================================================
R="$(new_root dry)"
write_layout "$R"; write_full_install "$R"; write_data_dirs "$R"
mkdir -p "$R/etc/systemd/system"
: > "$R/etc/systemd/system/hybrid-ai-prune.timer"
BEFORE="$(cd "$R" && find . | sort)"
EV="$WORK/ev-dry"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --dry-run --remove-data 2>&1)"; RC=$?
check "dry-run: exit 0" "0" "$RC"
have "dry-run: prints the plan" "$OUT" "[plan]"
have "dry-run: prints the compose plan" "$OUT" "down --remove-orphans"
AFTER="$(cd "$R" && find . | sort)"
check "dry-run: the fixture tree is unchanged" "$BEFORE" "$AFTER"
check "dry-run: the event log is unchanged" "" "$(cat "$EV")"

# ===========================================================================
# 10. Sibling trees: --remove-data removes all five bootstrapped directories.
# ===========================================================================
R="$(new_root siblings-full)"
write_layout "$R"; write_full_install "$R"; write_data_dirs "$R"; write_siblings "$R"
touch "$R/etc/hybrid-ai/stack.env"
EV="$WORK/ev-sib-full"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes --remove-data 2>&1)"; RC=$?
check "siblings: --remove-data exit 0" "0" "$RC"
for d in "${SIBLING_DIRS[@]}"; do
  check "siblings: ${d} is gone" "gone" \
    "$( [[ -e "$R/$d" ]] && echo present || echo gone )"
done

# ===========================================================================
# 11. Siblings only: remnants path names all five, with no /opt install.
# ===========================================================================
R="$(new_root siblings-only)"
write_layout "$R"; write_siblings "$R"
EV="$WORK/ev-sib-only"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes 2>&1)"; RC=$?
check "siblings-only: exit 0" "0" "$RC"
have "siblings-only: reports remnants only" "$OUT" "remnants only"
for d in "${SIBLING_DIRS[@]}"; do
  have "siblings-only: names ${d}" "$OUT" "$R/$d"
done

# ===========================================================================
# 12. Siblings kept by default (no --remove-data).
# ===========================================================================
R="$(new_root siblings-keep)"
write_layout "$R"; write_siblings "$R"
EV="$WORK/ev-sib-keep"; : > "$EV"
EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes >/dev/null 2>&1
for d in "${SIBLING_DIRS[@]}"; do
  check "siblings kept: ${d} survives" "present" \
    "$( [[ -e "$R/$d/sibling.txt" ]] && echo present || echo gone )"
done

# ===========================================================================
# 13. Legacy layout: an out-of-allowlist OPENHANDS_WORKSPACE is refused.
# ===========================================================================
R="$(new_root legacy-ws)"
write_layout "$R"; write_data_dirs "$R"
mkdir -p "$R/home/pi/hybrid-ai-agent"; : > "$R/home/pi/hybrid-ai-agent/precious.txt"
cat > "$R/etc/hybrid-ai/hybrid-ai.env" <<EOF
HYBRID_AI_APP_DIR=${R}/opt/hybrid-ai
HYBRID_AI_STACK_ENV_FILE=${R}/etc/hybrid-ai/stack.env
HYBRID_AI_DATA_DIR=${R}/var/lib/hybrid-ai
HYBRID_AI_LOG_DIR=${R}/var/log/hybrid-ai
HYBRID_AI_WORK_DIR=${R}/var/lib/hybrid-ai/work
RESTIC_CACHE_DIR=${R}/var/cache/hybrid-ai-backup
HYBRID_AI_BACKUP_CRED_DIR=${R}/etc/credstore/hybrid-ai-backup
OPENHANDS_WORKSPACE=${R}/home/pi/hybrid-ai-agent
EOF
EV="$WORK/ev-legacy-ws"; : > "$EV"
OUT="$(EVENTS="$EV" HYBRID_AI_UNINSTALL_ROOT="$R" bash "$UNINSTALL" --yes --remove-data 2>&1)"; RC=$?
check "legacy workspace: exit 0" "0" "$RC"
have "legacy workspace: refusal names the setting" "$OUT" "OPENHANDS_WORKSPACE"
have "legacy workspace: refusal says outside the allowlist" "$OUT" "outside the allowlist"
check "legacy workspace: the path survives" "present" \
  "$( [[ -e "$R/home/pi/hybrid-ai-agent/precious.txt" ]] && echo present || echo gone )"

# ===========================================================================
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
