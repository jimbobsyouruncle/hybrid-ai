#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-tls-check.sh
# PURPOSE (plain English):
#   Proves scripts/tls-check.sh and scripts/tls-alert.sh behave as documented,
#   using throwaway certificates this script generates with openssl and serves
#   on loopback with `openssl s_server`.
#
#   No docker, no root, no network beyond 127.0.0.1, no access to the live
#   deployment. Everything is created in a mktemp directory and removed on exit.
#
#   Each case runs the REAL script against a REAL TLS handshake and asserts the
#   exact exit code from the fixed table. A missing tool is a printed [skip],
#   never a silent pass.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/tls-check.sh"
ALERT="${SCRIPT_DIR}/tls-alert.sh"
AUDIT="${SCRIPT_DIR}/tls-audit.sh"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

pass=0
fail=0
skip=0
ok()   { printf 'ok   %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$(( fail + 1 )); }
skipped() { printf '[skip] %s\n' "$1"; skip=$(( skip + 1 )); }

for tool in openssl date; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'FAIL required tool missing: %s\n' "$tool"
    exit 1
  fi
done
if [[ ! -f "$CHECK" ]]; then printf 'FAIL missing %s\n' "$CHECK"; exit 1; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hybrid-ai-tls-test.XXXXXX")" || exit 1
SRV_PID=""
# Idempotent: called on the normal exit path AND from the trap.
cleanup() {
  if [[ -n "${SRV_PID:-}" ]]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
    SRV_PID=""
  fi
  [[ -n "${WORK:-}" ]] || return 0
  rm -rf "$WORK"
  WORK=""
}
trap cleanup EXIT

HOSTNAME_TEST="tls-test.example"
LOOPBACK="127.0.0.1"

# --- build a throwaway CA and a set of leaf certificates -------------------
CA1_DIR="$WORK/ca1"; CA2_DIR="$WORK/ca2"
mkdir -p "$CA1_DIR" "$CA2_DIR"

make_ca() {
  local dir="$1" cn="$2"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "${dir}/ca.key" -out "${dir}/ca.crt" \
    -subj "/CN=${cn}" >/dev/null 2>&1
}

# make_leaf DIR CA_DIR SAN DAYS|EXPIRED
make_leaf() {
  local out="$1" ca="$2" san="$3" days="$4"
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "${out}.key" -out "${out}.csr" \
    -subj "/CN=${HOSTNAME_TEST}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1

  local ext="$WORK/ext.$$.cnf"
  {
    printf 'basicConstraints=CA:FALSE\n'
    printf 'subjectAltName=%s\n' "$san"
    printf 'keyUsage=digitalSignature,keyEncipherment\n'
    printf 'extendedKeyUsage=serverAuth\n'
  } > "$ext"

  if [[ "$days" == "expired" ]]; then
    # A negative -days is not accepted, so write the validity window directly.
    if openssl x509 -req -in "${out}.csr" -CA "${ca}/ca.crt" -CAkey "${ca}/ca.key" \
         -CAcreateserial -sha256 -extfile "$ext" \
         -not_before 20200101000000Z -not_after 20200201000000Z \
         -out "${out}.crt" >/dev/null 2>&1; then
      rm -f "$ext"
      return 0
    fi
    # Older openssl: sign through `ca`, which has always taken explicit dates.
    local cadb="$WORK/cadb.$$"
    rm -rf "$cadb"; mkdir -p "$cadb/newcerts"
    : > "$cadb/index.txt"; printf '1000\n' > "$cadb/serial"
    cat > "$cadb/openssl.cnf" <<EOF
[ca]
default_ca = CA_default
[CA_default]
dir = $cadb
database = \$dir/index.txt
serial = \$dir/serial
new_certs_dir = \$dir/newcerts
certificate = ${ca}/ca.crt
private_key = ${ca}/ca.key
default_md = sha256
policy = policy_any
x509_extensions = ext
copy_extensions = none
[policy_any]
commonName = optional
[ext]
$(cat "$ext")
EOF
    openssl ca -batch -config "$cadb/openssl.cnf" -in "${out}.csr" \
      -startdate 20200101000000Z -enddate 20200201000000Z \
      -out "${out}.crt" >/dev/null 2>&1
    local rc=$?
    rm -f "$ext"
    return $rc
  fi

  openssl x509 -req -in "${out}.csr" -CA "${ca}/ca.crt" -CAkey "${ca}/ca.key" \
    -CAcreateserial -sha256 -extfile "$ext" -days "$days" \
    -out "${out}.crt" >/dev/null 2>&1
  local rc=$?
  rm -f "$ext"
  return $rc
}

if ! make_ca "$CA1_DIR" "TLS Test CA One" || ! make_ca "$CA2_DIR" "TLS Test CA Two"; then
  printf 'FAIL could not generate a throwaway CA\n'
  exit 1
fi
CA1="${CA1_DIR}/ca.crt"

declare -A LEAF=()
build_leaf() {
  local name="$1" ca="$2" san="$3" days="$4"
  LEAF["$name"]="$WORK/$name"
  if ! make_leaf "${LEAF[$name]}" "$ca" "$san" "$days"; then
    printf 'FAIL could not generate certificate %s\n' "$name"
    fail=$(( fail + 1 ))
    return 1
  fi
  return 0
}

build_leaf good       "$CA1_DIR" "DNS:${HOSTNAME_TEST}"            90
build_leaf ten_day    "$CA1_DIR" "DNS:${HOSTNAME_TEST}"            10
build_leaf five_day   "$CA1_DIR" "DNS:${HOSTNAME_TEST}"            5
build_leaf expired    "$CA1_DIR" "DNS:${HOSTNAME_TEST}"            expired
build_leaf wrong_san  "$CA1_DIR" "DNS:other.example"               90
build_leaf other_ca   "$CA2_DIR" "DNS:${HOSTNAME_TEST}"            90
build_leaf wildcard_san "$CA1_DIR" "DNS:*.${HOSTNAME_TEST}" 90

# --- free port + server ----------------------------------------------------
free_port() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
    return 0
  fi
  local p
  for p in $(seq 41000 41999); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

start_server() {
  local base="$1" port
  stop_server
  port="$(free_port)" || return 1
  openssl s_server -quiet -accept "${LOOPBACK}:${port}" \
    -cert "${base}.crt" -key "${base}.key" -www >/dev/null 2>&1 &
  SRV_PID=$!
  local tries=0
  while (( tries < 100 )); do
    if (exec 3<>"/dev/tcp/${LOOPBACK}/${port}") 2>/dev/null; then
      exec 3<&- 2>/dev/null
      printf '%s' "$port"
      return 0
    fi
    tries=$(( tries + 1 ))
    sleep 0.1
  done
  return 1
}

stop_server() {
  if [[ -n "$SRV_PID" ]]; then
    kill "$SRV_PID" 2>/dev/null
    wait "$SRV_PID" 2>/dev/null
    SRV_PID=""
  fi
}

# Resolve the STACK file the shared resolver names, in a SUBSHELL: sourcing the
# helper here would export repo-default paths and shadow the fixture env files
# the cases below pass with --env-file.
STACK_ENV_FILE="$(bash -c '
  # shellcheck source=scripts/lib/hybrid-ai-env.sh
  source "$1/lib/hybrid-ai-env.sh" >/dev/null 2>&1 || exit 1
  printf "%s" "$HYBRID_AI_STACK_ENV_FILE"
' _ "$SCRIPT_DIR" 2>/dev/null || true)"
[[ -n "$STACK_ENV_FILE" ]] || STACK_ENV_FILE=""

ENV_FILE="$WORK/env"
printf 'TLS_ENABLED=yes\nLOCAL_DOMAIN=%s\n' "$HOSTNAME_TEST" > "$ENV_FILE"

run_check() {
  local port="$1"; shift
  bash "$CHECK" --host "$HOSTNAME_TEST" --probe-addr "${LOOPBACK}:${port}" \
    --env-file "$ENV_FILE" --ca-file "$CA1" --warn-days 14 --crit-days 7 "$@"
}

assert_exit() {
  local label="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    ok "$label -> exit $got"
  else
    bad "$label -> want exit $want, got $got"
  fi
}

# --- case 1: a healthy 90-day certificate ---------------------------------
port="$(start_server "${LEAF[good]}")"
if [[ -z "$port" ]]; then
  skipped "could not start openssl s_server"
else
  out="$(run_check "$port" 2>&1)"; rc=$?
  assert_exit "90-day certificate" 0 "$rc"
  days="$(printf '%s\n' "$out" | sed -n 's/.*days=\([0-9-]*\).*/\1/p' | head -1)"
  if [[ "$days" =~ ^[0-9]+$ ]] && (( days >= 80 )); then
    ok "90-day certificate reports enough days left (${days})"
  else
    bad "90-day certificate days_to_expiry was '${days}', expected >= 80"
  fi
  if printf '%s\n' "$out" | grep -q 'thresholds: warn<14d crit<7d'; then
    ok "output states both thresholds"
  else
    bad "output does not state both thresholds"
  fi

  # JSON mode
  json_out="$(run_check "$port" --json 2>/dev/null)"
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$json_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["overall"]=="ok"; assert d["exit_code"]==0; assert d["warn_days"]==14; assert d["crit_days"]==7; assert d["hosts"][0]["hostname"]=="tls-test.example"; assert d["hosts"][0]["certificate"] is True; assert d["hosts"][0]["san_match"] is True; assert d["hosts"][0]["days_to_expiry"] >= 80' 2>/dev/null; then
      ok "--json parses and carries the documented fields"
    else
      bad "--json did not parse or carried wrong values"
    fi
  else
    if printf '%s' "$json_out" | grep -q '"overall": "ok"\|"overall":"ok"'; then
      ok "--json looks like JSON (python3 absent, grep only)"
    else
      skipped "--json validation (python3 absent)"
    fi
  fi
fi

# --- case 2: 10 days -> WARN (exit 1) ------------------------------------
port="$(start_server "${LEAF[ten_day]}")"
if [[ -z "$port" ]]; then
  skipped "could not serve the 10-day fixture"
else
  port10="$port"
  out="$(run_check "$port10" 2>&1)"; rc=$?
  assert_exit "10-day certificate" 1 "$rc"
  if printf '%s\n' "$out" | grep -q 'warn'; then
    ok "10-day certificate is reported as warn"
  else
    bad "10-day certificate was not reported as warn"
  fi

  # --- alert path -------------------------------------------------------
  if [[ -f "$ALERT" ]]; then
    sink="$WORK/sink"
    run_check "$port10" --alert --sink-dir "$sink" >/dev/null 2>&1
    if [[ -f "$sink/tls-alert-test.log" ]] && grep -q 'severity=warn' "$sink/tls-alert-test.log"; then
      ok "tls-check --alert --sink-dir wrote a severity=warn alert"
    else
      bad "tls-check --alert --sink-dir did not write a severity=warn alert"
    fi
  else
    skipped "alert path (scripts/tls-alert.sh absent)"
  fi
fi

# --- case 3: 5 days -> CRITICAL (exit 2) ---------------------------------
port="$(start_server "${LEAF[five_day]}")"
if [[ -z "$port" ]]; then
  skipped "could not serve the 5-day fixture"
else
  out="$(run_check "$port" 2>&1)"; rc=$?
  assert_exit "5-day certificate" 2 "$rc"
  if printf '%s\n' "$out" | grep -q 'critical'; then
    ok "5-day certificate is reported as critical"
  else
    bad "5-day certificate was not reported as critical"
  fi
fi

# --- case 4: expired -> CRITICAL (exit 2) -------------------------------
port="$(start_server "${LEAF[expired]}")"
if [[ -z "$port" ]]; then
  skipped "could not serve the expired fixture"
else
  out="$(run_check "$port" 2>&1)"; rc=$?
  assert_exit "expired certificate" 2 "$rc"
fi

# --- case 5: wrong SAN -> exit 3 ----------------------------------------
port="$(start_server "${LEAF[wrong_san]}")"
if [[ -z "$port" ]]; then
  skipped "could not serve the wrong-SAN fixture"
else
  out="$(run_check "$port" 2>&1)"; rc=$?
  assert_exit "certificate with the wrong SAN" 3 "$rc"
fi

# --- case 6: signed by a different CA -> exit 3 -------------------------
port="$(start_server "${LEAF[other_ca]}")"
if [[ -z "$port" ]]; then
  skipped "could not serve the other-CA fixture"
else
  out="$(run_check "$port" 2>&1)"; rc=$?
  assert_exit "certificate from an untrusted CA" 3 "$rc"
fi

# --- case 6c: wildcard SAN covers exactly one label ---------------------
# One *.HOSTNAME_TEST cert must serve sub.HOSTNAME_TEST, but never the apex
# and never a two-label name. run_check() hardcodes --host, so call the REAL
# script directly here.
port="$(start_server "${LEAF[wildcard_san]}")"
if [[ -z "$port" ]]; then
  skipped "could not serve the wildcard-SAN fixture"
else
  out="$(bash "$CHECK" --host "sub.${HOSTNAME_TEST}" --probe-addr "${LOOPBACK}:${port}" \
           --env-file "$ENV_FILE" --ca-file "$CA1" --warn-days 14 --crit-days 7 2>&1)"; rc=$?
  assert_exit "wildcard SAN covers one label" 0 "$rc"

  json_out="$(bash "$CHECK" --host "sub.${HOSTNAME_TEST}" --probe-addr "${LOOPBACK}:${port}" \
           --env-file "$ENV_FILE" --ca-file "$CA1" --warn-days 14 --crit-days 7 --json 2>/dev/null)"
  if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$json_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hosts"][0]["san_match"] is True' 2>/dev/null; then
      ok "wildcard SAN reports san_match=true in --json"
    else
      bad "wildcard SAN did not report san_match=true in --json"
    fi
  else
    skipped "wildcard SAN --json san_match assertion (python3 absent)"
  fi

  out="$(bash "$CHECK" --host "${HOSTNAME_TEST}" --probe-addr "${LOOPBACK}:${port}" \
           --env-file "$ENV_FILE" --ca-file "$CA1" --warn-days 14 --crit-days 7 2>&1)"; rc=$?
  assert_exit "wildcard SAN does not cover the apex" 3 "$rc"

  out="$(bash "$CHECK" --host "a.b.${HOSTNAME_TEST}" --probe-addr "${LOOPBACK}:${port}" \
           --env-file "$ENV_FILE" --ca-file "$CA1" --warn-days 14 --crit-days 7 2>&1)"; rc=$?
  assert_exit "wildcard SAN covers one label only" 3 "$rc"
  stop_server
fi

stop_server

# --- case 6b: staging issuer while production is configured -> exit 3 ------
# A staging-signed leaf served after ACME_CA was switched to production means
# the re-render never took effect. The watchdog must say so and exit 3.
STAGING_CA_DIR="$WORK/ca-staging"
mkdir -p "$STAGING_CA_DIR"
if make_ca "$STAGING_CA_DIR" "Fake LE Intermediate X1 (STAGING)" \
   && build_leaf staging_cert "$STAGING_CA_DIR" "DNS:${HOSTNAME_TEST}" 90; then
  PROD_ENV="$WORK/env-production"
  printf 'TLS_ENABLED=yes\nLOCAL_DOMAIN=%s\nACME_CA=production\n' "$HOSTNAME_TEST" > "$PROD_ENV"
  STAGING_ENV="$WORK/env-staging"
  printf 'TLS_ENABLED=yes\nLOCAL_DOMAIN=%s\nACME_CA=staging\n' "$HOSTNAME_TEST" > "$STAGING_ENV"

  port="$(start_server "${LEAF[staging_cert]}")"
  if [[ -z "$port" ]]; then
    skipped "could not serve the staging-issuer fixture"
  else
    out="$(bash "$CHECK" --host "$HOSTNAME_TEST" --probe-addr "${LOOPBACK}:${port}" \
             --env-file "$PROD_ENV" --ca-file "$STAGING_CA_DIR/ca.crt" 2>&1)"; rc=$?
    assert_exit "staging issuer with ACME_CA=production" 3 "$rc"
    if printf '%s\n' "$out" | grep -q 'staging issuer while ACME_CA is production'; then
      ok "staging issuer with a production CA names the mismatch"
    else
      bad "staging issuer with a production CA did not name the mismatch"
    fi

    # Same certificate, staging configured: no new failure. The chain is
    # trusted here through --ca-file, so the documented 0 path is unchanged.
    out="$(bash "$CHECK" --host "$HOSTNAME_TEST" --probe-addr "${LOOPBACK}:${port}" \
             --env-file "$STAGING_ENV" --ca-file "$STAGING_CA_DIR/ca.crt" 2>&1)"; rc=$?
    assert_exit "staging issuer with ACME_CA=staging" 0 "$rc"
    if printf '%s\n' "$out" | grep -q 'staging issuer while ACME_CA is production'; then
      bad "staging issuer with a staging CA still reported a production mismatch"
    else
      ok "staging issuer with a staging CA adds no failure"
    fi

    # No ACME_CA at all must never add a failure either.
    out="$(bash "$CHECK" --host "$HOSTNAME_TEST" --probe-addr "${LOOPBACK}:${port}" \
             --env-file "$ENV_FILE" --ca-file "$STAGING_CA_DIR/ca.crt" 2>&1)"; rc=$?
    assert_exit "staging issuer with no ACME_CA configured" 0 "$rc"
    stop_server
  fi
else
  skipped "staging-issuer fixtures (could not generate the certificate)"
fi

# --- case 7: alert self-test -------------------------------------------
if [[ -f "$ALERT" ]]; then
  sink="$WORK/sink-selftest"
  bash "$ALERT" --test --sink-dir "$sink" >/dev/null 2>&1; rc=$?
  assert_exit "tls-alert.sh --test" 0 "$rc"
  if [[ -f "$sink/tls-alert-test.log" ]] && grep -q 'severity=test' "$sink/tls-alert-test.log"; then
    ok "tls-alert.sh --test wrote a severity=test line"
  else
    bad "tls-alert.sh --test did not write a severity=test line"
  fi
else
  skipped "tls-alert.sh self-test (script absent)"
fi

# --- case 8: TLS disabled -> exit 3 and SKIPPED -------------------------
OFF_ENV="$WORK/env-off"
printf 'TLS_ENABLED=no\n' > "$OFF_ENV"
out="$(bash "$CHECK" --quiet --env-file "$OFF_ENV" 2>&1)"; rc=$?
assert_exit "TLS disabled" 3 "$rc"
if printf '%s\n' "$out" | grep -q 'SKIPPED'; then
  ok "TLS disabled prints SKIPPED"
else
  bad "TLS disabled did not print SKIPPED"
fi

# --- case 9: the audit log is append-only ------------------------------
if [[ -n "${port10:-}" ]]; then
  audit_log="$WORK/logs/tls-check.log"
  port="$(start_server "${LEAF[ten_day]}")"
  if [[ -n "$port" ]]; then
    run_check "$port" --audit-log "$audit_log" >/dev/null 2>&1
    first_lines="$(wc -l < "$audit_log" 2>/dev/null || echo 0)"
    run_check "$port" --audit-log "$audit_log" >/dev/null 2>&1
    second_lines="$(wc -l < "$audit_log" 2>/dev/null || echo 0)"
    if [[ "${first_lines:-0}" -eq 1 && "${second_lines:-0}" -eq 2 ]]; then
      ok "audit log appends one line per host per run (never truncates)"
    else
      bad "audit log line counts were ${first_lines} then ${second_lines}, expected 1 then 2"
    fi
    mode="$(stat -c '%a' "$audit_log" 2>/dev/null || echo unknown)"
    if [[ "$mode" == "600" ]]; then
      ok "audit log is mode 0600"
    else
      bad "audit log mode was ${mode}, expected 600"
    fi
    if grep -q 'event=' "$audit_log" 2>/dev/null; then
      bad "tls-check audit log must not carry tls-audit event= fields"
    else
      ok "tls-check audit line uses the documented field set"
    fi
    stop_server
  else
    skipped "audit append check (could not serve the fixture)"
  fi
fi

# --- case 10: tls-audit.sh resolves its paths from the env file --------
# Neither --cert-root nor --log-dir is passed: HYBRID_AI_DATA_DIR and
# HYBRID_AI_LOG_DIR come from the env file, exactly as they would on the host.
# A changed serial in the same host directory must be recorded as a renewal,
# which is the proof-of-renewal logic and had no automated test before this.
if [[ -x "${AUDIT}" || -f "${AUDIT}" ]]; then
  data_dir="$WORK/deploy-data"
  log_dir="$WORK/deploy-logs"
  host_dir="${data_dir}/caddy/caddy/certificates/acme-staging/tls-test.example"
  mkdir -p "$host_dir"
  cp "${LEAF[good]}.crt" "${host_dir}/tls-test.example.crt"

  audit_env="$WORK/audit.env"
  {
    printf 'HYBRID_AI_DATA_DIR=%s\n' "$data_dir"
    printf 'HYBRID_AI_LOG_DIR=%s\n' "$log_dir"
  } > "$audit_env"

  bash "$AUDIT" --env-file "$audit_env" >/dev/null 2>&1; audit_rc=$?
  audit_log="$log_dir/tls-audit.log"
  if [[ "$audit_rc" -eq 0 ]] && grep -q 'event=issue' "$audit_log" 2>/dev/null; then
    ok "tls-audit.sh resolves cert root and log dir from the env file (event=issue)"
  else
    bad "tls-audit.sh did not record event=issue from the env-file paths (rc=${audit_rc})"
  fi

  # Same env file, but a DIFFERENT certificate (new serial) in the same host
  # directory: this is what a Caddy renewal looks like from the outside.
  sleep 1
  cp "${LEAF[ten_day]}.crt" "${host_dir}/tls-test.example.crt"
  bash "$AUDIT" --env-file "$audit_env" >/dev/null 2>&1; audit_rc=$?
  if [[ "$audit_rc" -eq 0 ]] && grep -q 'event=renew' "$audit_log" 2>/dev/null; then
    ok "tls-audit.sh records event=renew when the certificate serial changes"
  else
    bad "tls-audit.sh did not record event=renew after a serial change (rc=${audit_rc})"
  fi
else
  skipped "tls-audit.sh env-file resolution (script absent)"
fi

# --- case 11: the daily unit runs the audit as well as the check -------
SERVICE="${REPO_ROOT}/deploy/hybrid-ai-tls-check.service"
if [[ -f "$SERVICE" ]]; then
  # The '-' prefix matters: without it a failing audit (exit 3 before first
  # issuance, 1 on unreadable storage) aborts the unit and the health check
  # never runs, which is the very failure the watchdog exists to catch.
  if grep -qE '^ExecStart=-/usr/bin/env bash .*scripts/tls-audit\.sh' "$SERVICE"; then
    ok "tls-check service runs scripts/tls-audit.sh with a tolerating '-' prefix"
  else
    bad "tls-check service audit ExecStart must start with '-/usr/bin/env bash .../tls-audit.sh'"
  fi
  if grep -qE '^ReadWritePaths=-?/var/log/hybrid-ai$' "$SERVICE"; then
    ok "tls-check service permits writes to /var/log/hybrid-ai"
  else
    bad "tls-check service has no ReadWritePaths= for /var/log/hybrid-ai"
  fi
else
  skipped "tls-check service audit ExecStart (unit absent)"
fi

# --- case 12: the logrotate file carries a substitutable placeholder ---
LOGROTATE="${REPO_ROOT}/deploy/logrotate/hybrid-ai-tls"
if [[ -f "$LOGROTATE" ]]; then
  # logrotate does not expand shell variables, so a "${VAR}" path silently
  # rotates nothing. The shipped file must use the plain placeholder instead.
  # shellcheck disable=SC2016  # searching for a literal ${ in the file
  if grep -q '\${' "$LOGROTATE"; then
    bad "logrotate file still contains a \${...} literal, which logrotate will not expand"
  else
    ok "logrotate file contains no \${...} literal path"
  fi
  # Look only at the path line (config lines, not the header's sed example).
  path_lines="$(grep -c '^__HYBRID_AI_LOG_DIR__/' "$LOGROTATE" 2>/dev/null || echo 0)"
  path_ph="$(grep '^__HYBRID_AI_LOG_DIR__/' "$LOGROTATE" 2>/dev/null \
             | grep -o '__HYBRID_AI_LOG_DIR__' | wc -l)"
  if [[ "$path_lines" -eq 1 && "$path_ph" -eq 2 ]]; then
    ok "logrotate path line names both logs with the placeholder twice"
  else
    bad "logrotate path line count=${path_lines}, placeholder count=${path_ph}; expected 1 line, 2 placeholders"
  fi
else
  skipped "logrotate placeholder check (config absent)"
fi

printf '\n%d/%d checks pass\n' "$pass" "$(( pass + fail ))"
cleanup
if (( fail > 0 )); then
  printf '%d failed, %d skipped\n' "$fail" "$skip"
  exit 1
fi
[[ "$skip" -gt 0 ]] && printf '%d skipped\n' "$skip"
exit 0
