#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-doctor-sandbox-image.sh
# PURPOSE (plain English):
#   Proves doctor.sh's sandbox-image drift probe by RUNNING doctor.sh against a
#   stubbed docker -- it does not grep the text of doctor.sh.
#
#   The defect this guards: the stack has pinned the derived hybrid agent-server
#   image since 2026-10-19, yet a live sandbox was seen running the stock
#   `docker.openhands.dev/openhands/agent-server:1.33.0-python` (no shellcheck,
#   no semgrep). Two different faults look identical from the UI: the image env
#   never reaching the app-server, or the app-server build ignoring the
#   override. The probe compares the app-server container's
#   AGENT_SERVER_IMAGE_REPOSITORY / AGENT_SERVER_IMAGE_TAG pair AND every live
#   sandbox's real image against the resolved pin. It is WARNING-ONLY.
#
#   Fully OFFLINE. No Docker, no network, no root. The docker stub answers from
#   fixture variables, and the host commands doctor.sh probes are stubbed on
#   PATH so nothing else can move the verdict.
#
#   Proven here:
#     (i)   hybrid env pair on the app-server + a hybrid sandbox image
#             -> a pass for the env, a pass for the sandbox, no warning from
#                this probe, exit code identical to the probe-free baseline
#                (the fixture host has unrelated warnings of its own, so the
#                baseline is not 0 -- what matters is that nothing is added);
#     (ii)  hybrid env pair + a STOCK sandbox image
#             -> warn naming the container and its image, exit 1, never 2;
#     (iii) stock pair / half pair / missing keys on the app-server
#             -> warn naming both seen values, exit 1, never 2;
#     (iv)  docker absent, docker erroring, app-server container absent
#             -> a skip note, no pass and no warn from this probe, and every
#                summary count identical to the baseline;
#     (v)   the probe never prints a failure line in any of the above;
#     (vi)  an unreadable sandbox image is a skip for that sandbox, not a warn.
#
#   The baseline is the same doctor.sh with the probe's block removed, so
#   "unchanged" compares like with like. The same stripped copy is used at the
#   end to prove this harness FAILS against a doctor.sh without the probe.
#
# USAGE:
#   bash scripts/test-doctor-sandbox-image.sh [path-to-doctor.sh]
#
#   The path defaults to doctor.sh at the repository root, resolved from this
#   script's own location so the harness runs from anywhere. Point it at a copy
#   of the base doctor.sh to prove the harness fails without the probe.
#
# EXIT CODES:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  a required tool is missing, or doctor.sh was not found
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DOCTOR="${1:-$REPO_ROOT/doctor.sh}"
if [[ ! -f "$DOCTOR" ]]; then
  echo "FAIL: doctor.sh not found: $DOCTOR" >&2
  exit 2
fi

for t in mktemp date git bash timeout; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: ${t} is required" >&2; exit 2; }
done
REAL_JQ="$(command -v jq || true)"
# The host-side bind doctor.sh expects when it reads the port bindings. Taken
# from doctor.sh itself so the stub can never drift from the real check.
BRIDGE_IP="$(sed -n "s/.*\"\\\$BINDINGS\" == \\*\"\\([^:\"]*\\):\\\${OH_PORT}\".*/\\1/p" "$DOCTOR" | head -1)"
BRIDGE_IP="${BRIDGE_IP:-[IP_ADDRESS]}"

WORK="$(mktemp -d)"
if [[ -n "${IMG_KEEP:-}" ]]; then
  trap 'echo "kept: $WORK" >&2' EXIT
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

PASS=0
FAILURES=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

BIN="$WORK/bin"
APPD="$WORK/app"
mkdir -p "$BIN" "$APPD/scripts/lib" "$WORK/home" "$WORK/ws" "$WORK/ohstate"

# The stock image the live host was caught running, and the pin the stack
# resolves to by default. Both are image pins, not secrets.
STOCK_IMAGE="docker.openhands.dev/openhands/agent-server:1.33.0-python"
HYBRID_REPO="ghcr.io/jimbobsyouruncle/openhands-agent-server-hybrid"
HYBRID_TAG="1.37.1-python-hybrid.3"
HYBRID_IMAGE="${HYBRID_REPO}:${HYBRID_TAG}"

SKIP_RE='sandbox image check skipped'
PASS_ENV_RE='App-server carries the pinned sandbox image env'
PASS_SBX_RE='Every live sandbox runs the pinned image'
WARN_ENV_RE='OpenHands app-server does not carry the pinned sandbox image env'

# --- PATH stubs -------------------------------------------------------------
# One dispatcher, linked under every name doctor.sh probes. Each branch pins a
# fixed answer so an unrelated check cannot flip between runs and move the exit
# code the comparisons rely on. The docker branch is FIXTURE-DRIVEN: the four
# scenarios below differ only by the FIX_* variables they pass in.
cat > "$BIN/stub" <<'STUB'
#!/usr/bin/env bash
trap '' PIPE
me="$(basename "$0")"
case "$me" in
  docker)
    [[ "${FIX_DOCKER_MODE:-ok}" == "error" ]] && exit 1
    for a in "$@"; do [[ "$a" == "info" ]] && exit 0; done
    for a in "$@"; do [[ "$a" == "network" ]] && exit 1; done
    tmpl=""; prev=""
    for a in "$@"; do [[ "$prev" == "-f" ]] && tmpl="$a"; prev="$a"; done
    last="${*: -1}"
    case "$*" in
      *"top hermes-agent"*)  echo '7 hermes gateway run'; exit 0 ;;
      *"exec hermes-agent"*) exit 1 ;;
    esac
    if [[ "$*" == *"name=oh-agent-server"* ]]; then
      [[ -n "${FIX_SANDBOXES:-}" ]] || exit 0
      tr ' ' '\n' <<<"$FIX_SANDBOXES"
      exit 0
    fi
    case "$tmpl" in
      '{{.Id}}')
        [[ "$last" == "hybrid-ai-openhands" && "${FIX_APP_PRESENT:-1}" == "1" ]] || exit 1
        echo 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
        exit 0 ;;
      '{{.Config.Image}}')
        [[ "${FIX_SANDBOX_INSPECT:-ok}" == "error" ]] && exit 1
        echo "${FIX_SANDBOX_IMAGE:-docker.openhands.dev/openhands/agent-server:1.33.0-python}"
        exit 0 ;;
      *".Mounts"*)       echo 'false'; exit 0 ;;
      *".Config.User"*)  echo '10001'; exit 0 ;;
      *".State.Status"*) echo running; exit 0 ;;
      *".State.Health"*) echo none; exit 0 ;;
      *"RestartCount"*)  echo 0; exit 0 ;;
      *"PortBindings"*)  printf '%s:3001 %s:3001 ' "$BRIDGE_IP" "$BRIDGE_IP"; exit 0 ;;
      *"println ."*)
        if [[ "$last" == "hybrid-ai-openhands" ]]; then
          [[ -n "${FIX_APP_REPO+x}" ]] && printf 'AGENT_SERVER_IMAGE_REPOSITORY=%s\n' "$FIX_APP_REPO"
          [[ -n "${FIX_APP_TAG+x}" ]] && printf 'AGENT_SERVER_IMAGE_TAG=%s\n' "$FIX_APP_TAG"
          printf '%s\n' \
            'SANDBOX_HOST_PORT=3001' \
            'SANDBOX_CONTAINER_URL_PATTERN=http://example.test:{port}' \
            'OH_PERMITTED_CORS_ORIGINS_0=http://localhost:3001' \
            'OH_PERMITTED_CORS_ORIGINS_1=http://[IP_ADDRESS]:3001'
        else
          printf '%s\n' \
            'OH_WEBHOOKS_0_BASE_URL=http://example.test:3001/' \
            'SANDBOX_HOST_PORT=3001'
        fi
        exit 0 ;;
    esac
    exit 1 ;;
  curl)
    url="${*: -1}"
    case "$url" in
      *"/api/v1/app-conversations/start-tasks/search"*)
        printf '%s\n' '{"items":[],"next_page_id":null}'; exit 0 ;;
      *":11434/api/tags") printf '%s' '{"models":[{"name":"llama3.2:3b"},{"name":"qwen2.5:7b"}]}'; exit 0 ;;
      *":3000/health") exit 0 ;;
      *":80/status/healthz") exit 0 ;;
      *":80/openwebui") printf '302'; exit 0 ;;
      *":80/health") printf '200'; exit 0 ;;
      *":80/hub") printf '200'; exit 0 ;;
      *":80/app/") printf '200'; exit 0 ;;
      *":3001/"*) exit 0 ;;
      *) exit 7 ;;
    esac ;;
  jq)
    prog=""
    for a in "$@"; do
      case "$a" in -*) continue ;; *) prog="$a"; break ;; esac
    done
    case "$prog" in
      *'has("items")'*|*'@tsv'*|*'next_page_id'*) exit 0 ;;
      *) exec "$REAL_JQ" "$@" ;;
    esac ;;
  getfacl) printf 'user:10001:rwx\ndefault:user:10001:rwx\n'; exit 0 ;;
  iptables) printf '%s\n' '-P INPUT ACCEPT' '-A DOCKER-USER -j RETURN'; exit 0 ;;
  df) printf 'Use%%\n 41%%\n' ;;
  findmnt) echo '/dev/nvme0n1p2' ;;
  nvme|lsblk|vcgencmd|getent) exit 1 ;;
  dmesg|ip) exit 0 ;;
  hostname) for a in "$@"; do [[ "$a" == "-I" ]] && { echo '[IP_ADDRESS] '; exit 0; }; done; echo host ;;
  uname) for a in "$@"; do [[ "$a" == "-m" ]] && { echo aarch64; exit 0; }; done; echo Linux ;;
  nproc) echo 4 ;;
  tailscale)
    for a in "$@"; do
      case "$a" in
        status) echo '{"BackendState":"Running","Peer":{"k":{"HostName":"runpod-worker","Online":true}}}'; exit 0 ;;
        ip) echo '[IP_ADDRESS]'; exit 0 ;;
      esac
    done
    exit 0 ;;
  systemctl|journalctl|sqlite3|rsync|restic|mountpoint) exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/stub"

for n in docker curl jq getfacl iptables df findmnt nvme lsblk dmesg vcgencmd \
         hostname getent uname nproc tailscale systemctl journalctl sqlite3 \
         rsync restic mountpoint ip; do
  ln -sf "$BIN/stub" "$BIN/$n"
done

# A PATH without any docker: the "docker is not installed" flavour needs the
# binary genuinely absent, so directory symlinks to the tools doctor.sh probes
# are collected into one bin dir and docker is deliberately left out.
NODOCKER_BIN="$WORK/bin-nodocker"
mkdir -p "$NODOCKER_BIN"
for n in bash sh env timeout date stat find xargs dirname basename id ls rm mkdir \
         touch chmod sleep cat sed grep awk cut tr head tail sort wc uniq \
         expr tee readlink mktemp cmp od paste comm seq diff git jq getfacl \
         iptables df findmnt nvme lsblk dmesg vcgencmd hostname getent uname \
         nproc tailscale systemctl journalctl sqlite3 rsync restic mountpoint \
         ip curl; do
  if [[ -x "$BIN/$n" ]]; then
    ln -sf "$BIN/$n" "$NODOCKER_BIN/$n"
  elif real="$(command -v "$n" 2>/dev/null)"; then
    ln -sf "$real" "$NODOCKER_BIN/$n"
  fi
done

# --- scratch app ------------------------------------------------------------
cp "$REPO_ROOT/scripts/lib/hybrid-ai-env.sh" "$APPD/scripts/lib/"
cp "$DOCTOR" "$APPD/doctor.sh"
chmod +x "$APPD/doctor.sh"

# Baseline: the same doctor.sh with this probe's block deleted. Comparing
# against it, rather than against a skip run of the patched file, is what makes
# "the exit code is unchanged" a real statement.
# The call sites stay, so the baseline differs from the patched file in exactly
# one way: the probe counts nothing. That keeps the rest of doctor.sh -- and
# every line the probe's own presence could shift -- identical between the two.
awk '/^sandbox_image_probe\(\) \{/ { print "sandbox_image_probe() { :; }"; skip=1; next }
     skip && /^\}$/ { skip=0; next }
     !skip' "$APPD/doctor.sh" > "$APPD/doctor-base.sh"
chmod +x "$APPD/doctor-base.sh"
if ! grep -q 'sandbox image check skipped' "$APPD/doctor.sh"; then
  fail "the doctor.sh under test has no sandbox-image probe (unpatched base)"
fi
if grep -q 'sandbox image check skipped' "$APPD/doctor-base.sh"; then
  fail "could not build the baseline: the probe body was not removed"
fi

( cd "$WORK/ws" && git init -q && touch .keep ) >/dev/null 2>&1
chmod 700 "$WORK/ohstate"

# Minimal env so the Configuration checks pass rather than fail. Placeholders
# only; none is a real credential and none is printed.
cat > "$APPD/.env" <<EOF
WEBUI_SECRET_KEY=fixture
RUNPOD_API_KEY=fixture
RUNPOD_POD_ID=fixture
PEER_HOSTNAME=fixture
OPENROUTER_API_KEY=fixture
OPENHANDS_PORT=3001
OPENHANDS_WORKSPACE=$WORK/ws
OPENHANDS_SANDBOX_HOST=example.test
OPENHANDS_STATE_DIR=$WORK/ohstate
EOF
chmod 600 "$APPD/.env"

summary_count() { # <outfile> <passed|warning|failure>
  case "$2" in
    passed) sed -n 's/^ *\([0-9][0-9]*\) passed.*/\1/p' "$1" | tail -1 ;;
    *)      sed -n "s/.*[^0-9]\([0-9][0-9]*\) $2(s).*/\1/p" "$1" | tail -1 ;;
  esac
}

# run_doctor <tag> <doctor path> [env assignments...]
# Sets RC, OUT, PASSED, WARNED, FAILED.
run_doctor() {
  local tag="$1" doc="$2"
  shift 2
  OUT="$WORK/out.$tag"
  (
    cd "$APPD" || exit 1
    env "$@" \
      PATH="$BIN:$PATH" HOME="$WORK/home" SHELL=/bin/bash \
      REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
      HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$APPD/.env" \
      HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
      HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
      timeout 120 bash "$doc" --no-cloud
  ) > "$OUT" 2>&1
  RC=$?
  PASSED="$(summary_count "$OUT" passed)"; PASSED="${PASSED:-0}"
  WARNED="$(summary_count "$OUT" warning)"; WARNED="${WARNED:-0}"
  FAILED="$(summary_count "$OUT" failure)"; FAILED="${FAILED:-0}"
}

echo "== Running doctor.sh sandbox-image tests =="

# --- baseline: the probe's block removed -----------------------------------
# The docker fixture here is the healthy one, so the only difference between
# this run and (i) is the probe itself.
run_doctor base "$APPD/doctor-base.sh" \
  FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG="$HYBRID_TAG" \
  FIX_SANDBOXES='oh-agent-server-fixture1' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
RC_BASE=$RC; BASE_PASSED=$PASSED; BASE_WARNED=$WARNED; BASE_FAILED=$FAILED

# --- (i) hybrid env + hybrid sandbox image ---------------------------------
run_doctor hybrid "$APPD/doctor.sh" \
  FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG="$HYBRID_TAG" \
  FIX_SANDBOXES='oh-agent-server-fixture1' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
RC_HYBRID=$RC
if grep -q "${PASS_ENV_RE} (${HYBRID_IMAGE})" "$OUT"; then
  pass "hybrid env: the pass line names the resolved pin (${HYBRID_IMAGE})"
else
  fail "hybrid env: no pass line naming the resolved pin"
fi
if grep -q "${PASS_SBX_RE} ${HYBRID_IMAGE}" "$OUT"; then
  pass "hybrid env: the sandbox-image pass names the pinned image"
else
  fail "hybrid env: no pass line for the matching sandbox"
fi
if ! grep -q "$WARN_ENV_RE" "$OUT" && ! grep -q "not the pinned" "$OUT"; then
  pass "hybrid env: no warning from the probe"
else
  fail "hybrid env: the probe warned on a fully hybrid stack"
fi
if [[ "$RC_HYBRID" == "$RC_BASE" ]]; then
  pass "hybrid env: exit code matches the probe-free baseline (${RC_BASE})"
else
  fail "hybrid env: exit code ${RC_HYBRID} differs from the baseline (${RC_BASE})"
fi
if [[ "$PASSED" == "$(( BASE_PASSED + 2 ))" \
   && "$WARNED" == "$BASE_WARNED" && "$FAILED" == "$BASE_FAILED" ]]; then
  pass "hybrid env: exactly two extra passes, and no extra warning or failure"
else
  fail "hybrid env: summary counts (${PASSED}/${WARNED}/${FAILED}) are not baseline plus two passes (${BASE_PASSED}/${BASE_WARNED}/${BASE_FAILED})"
fi
# This fixture host carries unrelated warnings of its own (no backups, no
# Hermes data), so the absolute code is the baseline's, not 0. What matters is
# that a fully hybrid stack adds nothing and never fails.
if [[ "$RC_HYBRID" != "2" && "$RC_HYBRID" == "$RC_BASE" ]]; then
  pass "hybrid env: a fully hybrid stack leaves the exit code where the baseline had it (${RC_HYBRID})"
else
  fail "hybrid env: exit code is ${RC_HYBRID}, baseline ${RC_BASE}; a healthy stack must not fail"
fi

# --- (ii) hybrid env + STOCK sandbox image ---------------------------------
run_doctor stock "$APPD/doctor.sh" \
  FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG="$HYBRID_TAG" \
  FIX_SANDBOXES='oh-agent-server-fixture1' FIX_SANDBOX_IMAGE="$STOCK_IMAGE"
RC_STOCK=$RC
if grep -q "oh-agent-server-fixture1 runs image ${STOCK_IMAGE}, not the pinned ${HYBRID_IMAGE}" "$OUT"; then
  pass "stock sandbox: the warn names the container, its image and the pin"
else
  fail "stock sandbox: no warn naming the container, its image and the pin"
fi
if grep -q "start a NEW conversation" "$OUT"; then
  pass "stock sandbox: the warn says sandboxes keep their creation config"
else
  fail "stock sandbox: the warn does not explain that sandboxes keep their config"
fi
if grep -q "does not honour the override" "$OUT" && grep -q "report that finding" "$OUT"; then
  pass "stock sandbox: the remedy names the app-server-ignores-the-override branch"
else
  fail "stock sandbox: the remedy does not name the app-server-override branch"
fi
if [[ "$RC_STOCK" == "1" ]]; then
  pass "stock sandbox: exit code is 1"
else
  fail "stock sandbox: exit code is ${RC_STOCK}, expected 1"
fi
if [[ "$RC_STOCK" != "2" ]] && ! grep -q '✗' "$OUT" && grep -q '0 failure(s)' "$OUT"; then
  pass "stock sandbox: exit code is never 2 and no failure line is printed"
else
  fail "stock sandbox: exit code is 2 or a failure line was printed"
fi
if [[ "$WARNED" == "$(( BASE_WARNED + 1 ))" ]]; then
  pass "stock sandbox: exactly one extra warning, and the pass count is unchanged"
else
  fail "stock sandbox: warnings ${WARNED} are not baseline plus one (${BASE_WARNED})"
fi

# --- (iii) the app-server env pair is wrong or absent ----------------------
# Three flavours: the OLD stock pair (the pre-cutover .env values), a HALF pair
# (only the repository), and both keys absent.
check_env_flavour() { # tag label expected-repo expected-tag
  local tag="$1" label="$2" erepo="$3" etag="$4"
  if grep -q "$WARN_ENV_RE" "$WORK/out.$tag"; then
    pass "${label}: the warn uses the required subject"
  else
    fail "${label}: no warn with the required subject"
  fi
  if grep -q "AGENT_SERVER_IMAGE_REPOSITORY=${erepo:-unset}" "$WORK/out.$tag" \
     && grep -q "AGENT_SERVER_IMAGE_TAG=${etag:-unset}" "$WORK/out.$tag"; then
    pass "${label}: the warn names both seen values"
  else
    fail "${label}: the warn does not name both seen values"
  fi
  if grep -q "re-run ./install.sh" "$WORK/out.$tag"; then
    pass "${label}: the remedy is to re-run ./install.sh"
  else
    fail "${label}: the remedy does not say to re-run ./install.sh"
  fi
  if [[ "$RC" == "1" ]]; then
    pass "${label}: exit code is 1"
  else
    fail "${label}: exit code is ${RC}, expected 1"
  fi
  if [[ "$RC" != "2" ]] && ! grep -q '✗' "$WORK/out.$tag"; then
    pass "${label}: exit code is never 2 and no failure line is printed"
  else
    fail "${label}: exit code is 2 or a failure line was printed"
  fi
}

run_doctor stockenv "$APPD/doctor.sh" \
  FIX_APP_REPO='docker.openhands.dev/openhands/agent-server' \
  FIX_APP_TAG='1.37.1-python' \
  FIX_SANDBOXES='' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
check_env_flavour stockenv "stock env pair" \
  'docker.openhands.dev/openhands/agent-server' '1.37.1-python'
if grep -q "no live sandbox to compare yet" "$OUT"; then
  pass "stock env pair: no live sandbox is reported by a pass naming the probe"
else
  fail "stock env pair: the empty sandbox list is not reported"
fi

run_doctor halfenv "$APPD/doctor.sh" \
  FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG='' \
  FIX_SANDBOXES='' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
check_env_flavour halfenv "half env pair" "$HYBRID_REPO" ''

run_doctor noenv "$APPD/doctor.sh" \
  FIX_APP_REPO='' FIX_APP_TAG='' \
  FIX_SANDBOXES='' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
check_env_flavour noenv "no env pair" '' ''

# --- (iv) probe unavailable -------------------------------------------------
# Each flavour is compared with the SAME fixture run against the probe-free
# baseline: a docker outage also breaks other checks, so comparing against the
# healthy baseline would blame this probe for them.
run_pair() { # tag env-assignments...
  local tag="$1"
  shift
  run_doctor "$tag" "$APPD/doctor.sh" "$@"
  RC_P=$RC; P_P=$PASSED; W_P=$WARNED; F_P=$FAILED
  run_doctor "$tag-base" "$APPD/doctor-base.sh" "$@"
  RC_B2=$RC; P_B2=$PASSED; W_B2=$WARNED; F_B2=$FAILED
}

check_skip_flavour() { # tag label
  local tag="$1" label="$2"
  if grep -q "$SKIP_RE" "$WORK/out.$tag"; then
    pass "${label}: a skip note is printed"
  else
    fail "${label}: no skip note printed"
  fi
  if ! grep -q "$PASS_ENV_RE" "$WORK/out.$tag" \
     && ! grep -q "$PASS_SBX_RE" "$WORK/out.$tag" \
     && ! grep -q "$WARN_ENV_RE" "$WORK/out.$tag"; then
    pass "${label}: no pass and no warn from the probe"
  else
    fail "${label}: the probe counted a pass or a warn it could not justify"
  fi
  if [[ "$RC_P" == "$RC_B2" ]]; then
    pass "${label}: exit code is identical to the same-fixture baseline (${RC_B2})"
  else
    fail "${label}: exit code ${RC_P} differs from the same-fixture baseline (${RC_B2})"
  fi
  if [[ "$P_P" == "$P_B2" && "$W_P" == "$W_B2" && "$F_P" == "$F_B2" ]]; then
    pass "${label}: every summary count matches the same-fixture baseline"
  else
    fail "${label}: summary counts differ from the same-fixture baseline, so the skip counted something"
  fi
  if [[ "$RC_P" != "2" ]] || [[ "$RC_B2" == "2" ]]; then
    pass "${label}: the skip added no path to exit 2"
  else
    fail "${label}: exit code is 2 where the baseline was ${RC_B2}"
  fi
}

# (iv-a) docker erroring: every docker call fails.
run_pair dockererror \
  FIX_DOCKER_MODE=error FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG="$HYBRID_TAG" \
  FIX_SANDBOXES='' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
check_skip_flavour dockererror "docker erroring"

# (iv-b) the app-server container is absent.
run_pair noapp \
  FIX_APP_PRESENT=0 FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG="$HYBRID_TAG" \
  FIX_SANDBOXES='' FIX_SANDBOX_IMAGE="$HYBRID_IMAGE"
check_skip_flavour noapp "app-server container absent"

# (iv-c) no docker binary on PATH at all.
run_no_docker() { # tag doctor-path
  (
    cd "$APPD" || exit 1
    env -u FIX_APP_REPO -u FIX_APP_TAG -u FIX_SANDBOXES -u FIX_SANDBOX_IMAGE \
      PATH="$NODOCKER_BIN" HOME="$WORK/home" SHELL=/bin/bash \
      REAL_JQ="$REAL_JQ" BRIDGE_IP="$BRIDGE_IP" \
      HYBRID_AI_APP_DIR="$APPD" HYBRID_AI_ENV_FILE="$APPD/.env" \
      HYBRID_AI_DATA_DIR="$APPD" HYBRID_AI_LOG_DIR="$APPD" HYBRID_AI_WORK_DIR="$APPD" \
      HYBRID_AI_HERMES_DATA_DIR="$APPD/hermes_data" \
      "${NODOCKER_BIN}/bash" "$2" --no-cloud
  ) > "$WORK/out.$1" 2>&1
  RC=$?
  PASSED="$(summary_count "$WORK/out.$1" passed)"; PASSED="${PASSED:-0}"
  WARNED="$(summary_count "$WORK/out.$1" warning)"; WARNED="${WARNED:-0}"
  FAILED="$(summary_count "$WORK/out.$1" failure)"; FAILED="${FAILED:-0}"
}

if ! PATH="$NODOCKER_BIN" command -v docker >/dev/null 2>&1; then
  run_no_docker nodocker "$APPD/doctor.sh"
  RC_P=$RC; P_P=$PASSED; W_P=$WARNED; F_P=$FAILED
  run_no_docker nodocker-base "$APPD/doctor-base.sh"
  RC_B2=$RC; P_B2=$PASSED; W_B2=$WARNED; F_B2=$FAILED
  check_skip_flavour nodocker "no docker binary"
  if grep -q 'sandbox image check skipped (docker is not installed)' "$WORK/out.nodocker"; then
    pass "no docker binary: the skip reason is the missing binary"
  else
    fail "no docker binary: the skip reason is not the missing binary"
  fi
else
  fail "no docker binary: the harness PATH still resolves docker, so the flavour proves nothing"
fi

# --- (vi) an unreadable sandbox image is a skip for that sandbox ------------
run_pair unreadable \
  FIX_APP_REPO="$HYBRID_REPO" FIX_APP_TAG="$HYBRID_TAG" \
  FIX_SANDBOXES='oh-agent-server-fixture1' FIX_SANDBOX_INSPECT=error
if grep -q 'sandbox image check skipped for 1 sandbox' "$WORK/out.unreadable"; then
  pass "unreadable sandbox image: a skip note names the sandbox"
else
  fail "unreadable sandbox image: no skip note for the sandbox"
fi
if ! grep -q "not the pinned" "$WORK/out.unreadable"; then
  pass "unreadable sandbox image: no drift warning is invented"
else
  fail "unreadable sandbox image: a drift warning was invented"
fi
if [[ "$RC_P" == "$RC_B2" ]]; then
  pass "unreadable sandbox image: exit code is identical to the same-fixture baseline (${RC_B2})"
else
  fail "unreadable sandbox image: exit code ${RC_P} differs from the baseline (${RC_B2})"
fi

# --- proof that the harness rejects a doctor.sh without the probe -----------
if [[ -z "${IMG_HARNESS_NESTED:-}" ]]; then
  IMG_HARNESS_NESTED=1 bash "$0" "$APPD/doctor-base.sh" > "$WORK/nested.log" 2>&1
  NESTED_RC=$?
  if [[ "$NESTED_RC" != "0" ]]; then
    pass "unpatched doctor.sh: this harness fails against a copy without the probe"
  else
    fail "unpatched doctor.sh: the harness passed, so its assertions prove nothing"
  fi
fi

echo "---"
if (( FAILURES != 0 )); then
  echo "FAILURES: ${FAILURES}" >&2
  exit 1
fi
echo "All sandbox-image assertions passed (${PASS})."
exit 0
