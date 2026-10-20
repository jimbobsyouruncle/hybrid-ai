#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# FILE: scripts/test-sandbox-firewall.sh
# PURPOSE (plain English):
#   Offline tests for scripts/sandbox-firewall.sh. They need NO Docker, NO root
#   and NO live iptables. A stub `iptables` on PATH keeps a fake DOCKER-USER
#   chain in a plain file, understands only `-S`, `-C`, `-I` and `-A` (anything
#   else is rejected loudly), and logs every invocation.
#
# CASES:
#   * fresh install: an empty DOCKER-USER chain ends up with exactly the three
#     tagged rules, with the webhook ACCEPT before both drops
#   * migrated host: pre-existing foreign rules survive byte-untouched
#   * idempotency: a second run adds nothing and reports "unchanged"
#   * loopback: no generated rule matches `-i lo` or `-o lo` as a selector, and
#     a loopback packet matches none of the drops
#   * webhook: exactly one ACCEPT, pinned to the docker0 gateway on TCP 3001,
#     not widened to a subnet, a port range or another port
#   * a host without DOCKER-USER exits non-zero with a clear message
#
# USAGE:
#   bash scripts/test-sandbox-firewall.sh
#
# EXIT CODES:
#   0  every case passed
#   1  one or more cases failed
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
FIREWALL="${SCRIPT_DIR}/sandbox-firewall.sh"
[[ -f "$FIREWALL" ]] || { echo "FATAL: cannot find $FIREWALL" >&2; exit 1; }

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

TAG="hybrid-ai-sandbox-egress"
GATEWAY="172.17.0.1"
PORT="3001"

STUBS="$WORK/bin"
mkdir -p "$STUBS"

# --- Stub iptables ----------------------------------------------------------
# State lives in $STUB_STATE/rules (one rule per line, in chain order) and
# $STUB_STATE/chains (one chain name per line). Every call appends its argv to
# $STUB_STATE/calls so the test can assert on what the script actually asked
# for, including on the idempotent second run.
cat > "$STUBS/iptables" <<'STUB'
#!/usr/bin/env bash
set -u
state="${STUB_STATE:?STUB_STATE must be set}"
mkdir -p "$state"
[[ -f "$state/rules" ]] || : > "$state/rules"
[[ -f "$state/chains" ]] || printf 'DOCKER-USER\n' > "$state/chains"
printf '%s\n' "$*" >> "$state/calls"

# The real invocation always carries the lock wait: `-w 5`.
if [[ "${1:-}" == "-w" ]]; then
  shift 2
fi

chain_exists() { grep -qxF -- "$1" "$state/chains"; }

verb="${1:-}"; shift || true

case "$verb" in
  -S)
    chain="${1:-}"
    chain_exists "$chain" || {
      printf 'iptables: chain %s does not exist\n' "$chain" >&2
      exit 1
    }
    printf -- '-N %s\n' "$chain"
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      printf -- '-A %s %s\n' "$chain" "$rule"
    done < "$state/rules"
    ;;
  -C)
    chain="${1:-}"; shift || true
    chain_exists "$chain" || exit 1
    needle="$*"
    grep -qxF -- "$needle" "$state/rules"
    ;;
  -I)
    chain="${1:-}"; shift || true
    pos="${1:-}"; shift || true
    chain_exists "$chain" || {
      printf 'iptables: chain %s does not exist\n' "$chain" >&2
      exit 1
    }
    [[ "$pos" == "1" ]] || {
      printf 'stub iptables: only -I %s 1 is modelled (got %s)\n' "$chain" "$pos" >&2
      exit 3
    }
    rule="$*"
    printf '%s\n' "$rule" | cat - "$state/rules" > "$state/rules.new"
    mv -f "$state/rules.new" "$state/rules"
    ;;
  -A)
    chain="${1:-}"; shift || true
    chain_exists "$chain" || {
      printf 'iptables: chain %s does not exist\n' "$chain" >&2
      exit 1
    }
    printf '%s\n' "$*" >> "$state/rules"
    ;;
  *)
    printf 'stub iptables: unsupported invocation: %s\n' "$verb" >&2
    exit 3
    ;;
esac
STUB
chmod +x "$STUBS/iptables"

new_fixture() { # name chains-line rules...
  local name="$1"; shift
  local dir="$WORK/$name"
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/chains"
  : > "$dir/rules"
  : > "$dir/calls"
  printf '%s\n' "$dir"
}

run_firewall() { # state-dir logfile
  local state="$1" log="$2" rc=0
  env PATH="$STUBS:$PATH" STUB_STATE="$state" \
    bash "$FIREWALL" apply > "$log" 2>&1 || rc=$?
  return "$rc"
}

rules_of() { cat "$1/rules"; }

echo "== Running sandbox-firewall.sh tests =="

# ---------------------------------------------------------------------------
echo
echo "== fresh install =="
S1="$(new_fixture fresh DOCKER-USER)"
rc=0; run_firewall "$S1" "$WORK/fresh.log" || rc=$?
check "fresh install exits 0" "0" "$rc"
have "the run reports the rules it added" "$(cat "$WORK/fresh.log")" "added 3 rule(s)"

EXPECTED_1="! -i lo -o docker0 -m comment --comment $TAG -j DROP"
EXPECTED_2="-i docker0 ! -o docker0 -m comment --comment $TAG -j DROP"
EXPECTED_3="-i docker0 -p tcp -d $GATEWAY --dport $PORT -m comment --comment $TAG -j ACCEPT"

RULES1="$(rules_of "$S1")"
check "exactly three rules exist" "3" "$(grep -c . "$S1/rules")"
have "the external-to-docker0 drop is present" "$RULES1" "$EXPECTED_1"
have "the docker0-to-networks drop is present" "$RULES1" "$EXPECTED_2"
have "the webhook accept is present" "$RULES1" "$EXPECTED_3"
check "the webhook ACCEPT is line 1" "$EXPECTED_3" "$(sed -n '1p' "$S1/rules")"
check "the docker0 drop is line 2" "$EXPECTED_2" "$(sed -n '2p' "$S1/rules")"
check "the external drop is line 3" "$EXPECTED_1" "$(sed -n '3p' "$S1/rules")"

# ---------------------------------------------------------------------------
echo
echo "== migrated host: foreign rules survive =="
FOREIGN_1="-j RETURN"
FOREIGN_2="-s 192.0.2.0/24 -j ACCEPT"
S2="$(new_fixture migrated DOCKER-USER)"
printf '%s\n%s\n' "$FOREIGN_1" "$FOREIGN_2" > "$S2/rules"
rc=0; run_firewall "$S2" "$WORK/migrated.log" || rc=$?
check "migrated host exits 0" "0" "$rc"
check "both foreign rules are still present, in order" \
  "$FOREIGN_1|$FOREIGN_2" "$(grep -E '^-j RETURN|-s 192\.0\.2\.0/24' "$S2/rules" | paste -sd'|' -)"
check "no foreign rule was modified" "2" \
  "$(grep -cxF -e "$FOREIGN_1" -e "$FOREIGN_2" "$S2/rules")"
check "no flush, delete or chain removal was invoked" "0" \
  "$(grep -cE '^-F|^-X|^-D| -F | -X | -D ' "$S2/calls" || true)"
check "the three owned rules were added around them" "5" "$(grep -c . "$S2/rules")"
check "owned rules are prepended above the foreign RETURN" \
  "$EXPECTED_3" "$(sed -n '1p' "$S2/rules")"

# ---------------------------------------------------------------------------
echo
echo "== idempotency =="
: > "$S2/calls"
rc=0; run_firewall "$S2" "$WORK/second.log" || rc=$?
check "a second run exits 0" "0" "$rc"
have "the second run reports unchanged" "$(cat "$WORK/second.log")" "unchanged (3 rules already present)"
check "the second run added no rule" "0" \
  "$(grep -cE '^-I |^-A ' "$S2/calls" || true)"
check "the rule set is byte-identical after the second run" "5" "$(grep -c . "$S2/rules")"

S1_BEFORE="$(cat "$S1/rules")"
: > "$S1/calls"
rc=0; run_firewall "$S1" "$WORK/second-fresh.log" || rc=$?
check "the fresh fixture is also a no-op on re-run" "$S1_BEFORE" "$(cat "$S1/rules")"
check "and it added nothing" "0" "$(grep -cE '^-I |^-A ' "$S1/calls" || true)"

# ---------------------------------------------------------------------------
echo
echo "== loopback is untouched =="
# No rule may SELECT loopback: an un-negated `-i lo` or any `-o lo` match.
if grep -E '(^| )-i lo' "$S1/rules" | grep -qv '! -i lo'; then
  bad "a generated rule matches loopback as input"
else
  ok "no generated rule matches -i lo"
fi
if grep -qE '(^| )-o lo( |$)' "$S1/rules"; then
  bad "a generated rule matches -o lo"
else
  ok "no generated rule matches -o lo"
fi
# The external drop needs `! -i lo` because it has no positive -i match. The
# docker0 drop matches `-i docker0` and so can never see loopback traffic.
check "the external DROP carries the ! -i lo guard" "1" \
  "$(grep -- '! -i lo -o docker0' "$S1/rules" | grep -c -- '-j DROP')"
check "no DROP besides that one lacks an -i constraint" "0" \
  "$(grep -- '-j DROP' "$S1/rules" | grep -v -- '! -i lo' | grep -cv -- '-i docker0' || true)"

# Model a packet against the DROP rules: does any of them match (in, out)?
# The token list is walked in order so `! -o docker0` is never read as `-o`.
drop_matches() { # in out
  local in="$1" out="$2" rule
  local -a t
  local i iface val neg matched
  while IFS= read -r rule; do
    [[ "$rule" == *"-j DROP"* ]] || continue
    read -r -a t <<< "$rule"
    matched=1
    for (( i = 0; i < ${#t[@]}; i++ )); do
      [[ "${t[i]}" == "-i" || "${t[i]}" == "-o" ]] || continue
      iface="${t[i+1]}"
      neg=0
      (( i > 0 )) && [[ "${t[i-1]}" == "!" ]] && neg=1
      val="$in"
      [[ "${t[i]}" == "-o" ]] && val="$out"
      if (( neg )); then
        [[ "$val" == "$iface" ]] && matched=0
      else
        [[ "$val" != "$iface" ]] && matched=0
      fi
    done
    (( matched )) && return 0
  done < "$S1/rules"
  return 1
}

if drop_matches lo docker0; then
  bad "a loopback packet matches a DROP rule (the SSH-tunnel path would break)"
else
  ok "a loopback packet matches none of the drops"
fi
if drop_matches lo br-hybrid; then
  bad "a loopback packet to another bridge matches a DROP rule"
else
  ok "a loopback packet to another bridge matches no drop"
fi
if drop_matches eth0 docker0; then
  ok "a LAN packet into docker0 is dropped"
else
  bad "a LAN packet into docker0 is not dropped"
fi
if drop_matches docker0 br-hybrid; then
  ok "a sandbox packet to another Docker network is dropped"
else
  bad "a sandbox packet to another Docker network is not dropped"
fi
# iptables allows only one -i match per rule, so the external-to-docker0 drop
# cannot also negate docker0 as input. A same-bridge frame (docker0 to docker0)
# therefore matches it too. That is the stricter direction -- sandbox ports stay
# closed either way -- and it is the only form the ticket's two-drop rule set
# can express. Loopback, the path that matters, is unaffected.
if drop_matches docker0 docker0; then
  ok "docker0-to-docker0 is also covered by the external drop (single -i limit)"
else
  bad "docker0-to-docker0 unexpectedly bypasses both drops"
fi
if drop_matches lo docker0 || drop_matches lo lo; then
  bad "a loopback packet matches a drop"
else
  ok "no loopback packet matches any drop"
fi

# ---------------------------------------------------------------------------
echo
echo "== the webhook exception is exact =="
check "exactly one ACCEPT rule exists" "1" "$(grep -c -- '-j ACCEPT' "$S1/rules")"
WEBHOOK="$(grep -- '-j ACCEPT' "$S1/rules")"
check "the ACCEPT targets the docker0 gateway on TCP 3001" "$EXPECTED_3" "$WEBHOOK"
if [[ "$WEBHOOK" == *"/0"* || "$WEBHOOK" == *"--dport 3000"* || \
      "$WEBHOOK" == *"--dport 3001:"* || "$WEBHOOK" == *":3001"* || \
      "$WEBHOOK" == *"-m multiport"* || "$WEBHOOK" == *"0.0.0.0"* ]]; then
  bad "the webhook ACCEPT is widened (subnet, range or extra port)"
else
  ok "the webhook ACCEPT is not widened"
fi
check "the ACCEPT carries the ownership tag" "1" "$(grep -c -- "--comment $TAG" <<< "$WEBHOOK")"
check "the ACCEPT comes before the docker0-to-networks drop" "1" \
  "$(grep -n -- '-p tcp -d 172\.17\.0\.1 --dport 3001' "$S1/rules" | cut -d: -f1)"

# ---------------------------------------------------------------------------
echo
echo "== a host without DOCKER-USER =="
S3="$WORK/no-chain"
mkdir -p "$S3"; printf 'INPUT\n' > "$S3/chains"; : > "$S3/rules"; : > "$S3/calls"
rc=0; run_firewall "$S3" "$WORK/no-chain.log" || rc=$?
check "the run exits non-zero" "4" "$rc"
have "the message explains the DOCKER-USER ordering" "$(cat "$WORK/no-chain.log")" \
  "DOCKER-USER chain does not exist"
check "nothing was written to the fake chain" "0" "$(grep -c . "$S3/rules")"

# ---------------------------------------------------------------------------
echo
echo "== static checks =="
# The privileged paths must call the script, and install.sh must never sudo.
for f in install.sh scripts/deploy-remote.sh scripts/bootstrap.sh; do
  if grep -q 'sandbox-firewall.sh' "$REPO/$f"; then
    ok "$f calls sandbox-firewall.sh"
  else
    bad "$f does not call sandbox-firewall.sh"
  fi
done
if grep -qE 'sudo.*sandbox-firewall' "$REPO/install.sh"; then
  bad "install.sh calls the firewall through sudo"
else
  ok "install.sh never calls the firewall through sudo"
fi
if grep -qE 'iptables[^|]*-F|iptables[^|]*-X' "$FIREWALL"; then
  bad "the script flushes or deletes a chain"
else
  ok "the script never flushes or deletes a chain"
fi
check "every iptables call goes through the lock wait" "0" \
  "$(grep -cE 'iptables -[SICADF]' "$FIREWALL" || true)"
# Built from pieces so this test never contains the redacted placeholder itself.
placeholder="[IP""_ADDRESS]"
if grep -qF -- "$placeholder" "$FIREWALL"; then
  bad "the script contains the redacted ticket placeholder"
else
  ok "the script contains no redacted placeholder"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
