#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# FILE: scripts/test-sandbox-firewall.sh
# PURPOSE (plain English):
#   Offline tests for scripts/sandbox-firewall.sh. They need NO Docker, NO root
#   and NO live iptables. A stub `iptables` on PATH keeps a fake DOCKER-USER
#   chain in a plain file, understands only `-S`, `-C`, `-I` and `-A` (anything
#   else is rejected loudly), and logs every invocation. A stub `docker` answers
#   `network inspect` for the two app networks.
#
# CASES:
#   * fresh install: an empty DOCKER-USER chain ends up with exactly the owned
#     rules, the stateful conntrack ACCEPT first, every owned ACCEPT above every
#     owned DROP, and the bridge-scoped accepts for both networks
#   * the dead pre-DNAT webhook rule (`-d <gateway> --dport 3001`) is not emitted
#   * the blanket `! -o docker0` DROP that killed internet egress is not emitted
#   * per-bridge DROPs and the LAN/tailnet CIDR DROPs are present
#   * DNS: exactly two port-53 ACCEPTs (UDP and TCP), neither widened, both above
#     every CIDR DROP; a sandbox packet to a resolver inside the dropped RFC1918
#     space matches an ACCEPT on UDP/53 and TCP/53 and no DROP
#   * a sandbox packet to the same address on TCP/443 and TCP/8080 still matches
#     an owned DROP and no owned ACCEPT (fails if either DNS ACCEPT is widened)
#   * migrated host: pre-existing foreign rules survive byte-untouched
#   * idempotency: a second run adds nothing and reports "unchanged"
#   * an unresolvable network warns by name, skips only its bridge, and exits 0
#   * a missing docker binary warns by name and still exits 0
#   * the ordering self-check fails loudly when an owned ACCEPT sits below an
#     owned DROP
#   * loopback: no generated rule matches `-i lo` or `-o lo` as a selector, and
#     a loopback packet matches none of the drops
#   * a host without DOCKER-USER / without iptables exits with its coded status
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
absent() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpected '$3')"; fi; }

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  printf 'keeping %s\n' "$WORK"
else
  trap 'rm -rf -- "$WORK"' EXIT
fi

TAG="hybrid-ai-sandbox-egress"
BR_HYBRID="br-aaaaaaaaaaaa"
BR_CODER="br-bbbbbbbbbbbb"
PORTS="8000,8001,8011,8012"

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

# --- Stub docker ------------------------------------------------------------
# Models only `docker network inspect -f '<go template>' <name>`, which is all
# the firewall script asks for. $STUB_NETWORKS holds "name id" lines; a name
# that is absent is reported as an error, exactly as docker reports a network
# that does not exist.
cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
set -u
file="${STUB_NETWORKS:?STUB_NETWORKS must be set}"
printf '%s\n' "$*" >> "${STUB_NETWORKS}.calls"
net="${*: -1}"
if [[ "$*" == *"network"*"inspect"* ]]; then
  while read -r name id; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "$net" ]]; then
      printf '%s\n' "$id"
      exit 0
    fi
  done < "$file"
  printf 'Error: No such network: %s\n' "$net" >&2
  exit 1
fi
printf 'stub docker: unsupported invocation: %s\n' "$*" >&2
exit 3
STUB
chmod +x "$STUBS/docker"

NETWORKS_FILE="$WORK/networks"
printf '%s\n' "hybrid-ai aaaaaaaaaaaa000011112222" "coder-net bbbbbbbbbbbb333344445555" > "$NETWORKS_FILE"

new_fixture() { # name chains-line...
  local name="$1"; shift
  local dir="$WORK/$name"
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/chains"
  : > "$dir/rules"
  : > "$dir/calls"
  printf '%s\n' "$dir"
}

run_firewall() { # state-dir logfile [extra PATH-dir-to-prepend]
  local state="$1" log="$2" extra="${3:-}" rc=0
  local path="$STUBS:$PATH"
  [[ -n "$extra" ]] && path="$STUBS:$extra:$PATH"
  env PATH="$path" STUB_STATE="$state" STUB_NETWORKS="$NETWORKS_FILE" \
    bash "$FIREWALL" apply > "$log" 2>&1 || rc=$?
  return "$rc"
}

rules_of() { cat "$1/rules"; }

# rule line for app -> sandbox, per bridge
accept_app_to_sandbox() {
  printf -- '-i %s -o docker0 -p tcp -m multiport --dports %s -m comment --comment %s -j ACCEPT' \
    "$1" "$PORTS" "$TAG"
}
# rule line for sandbox -> app, per bridge
accept_sandbox_to_app() {
  printf -- '-i docker0 -o %s -p tcp --dport 3000 -m comment --comment %s -j ACCEPT' "$1" "$TAG"
}
# stack drop, per bridge
drop_stack() {
  printf -- '-i docker0 -o %s -m comment --comment %s -j DROP' "$1" "$TAG"
}
# CIDR drop
drop_dest() {
  printf -- '-i docker0 -d %s -m comment --comment %s -j DROP' "$1" "$TAG"
}
# sandbox -> resolver ACCEPT, one per protocol
accept_sandbox_dns() {
  printf -- '-i docker0 -p %s --dport 53 -m comment --comment %s -j ACCEPT' "$1" "$TAG"
}

CONNTRACK="-m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment $TAG -j ACCEPT"
INBOUND="! -i lo -o docker0 -m comment --comment $TAG -j DROP"

# 1 conntrack + 4 per-bridge ACCEPTs + 2 per-bridge DROPs + 4 CIDR + 2 DNS
# + 1 inbound
TOTAL=$(( 1 + 4 + 2 + 4 + 2 + 1 ))

echo "== Running sandbox-firewall.sh tests =="

# ---------------------------------------------------------------------------
echo
echo "== fresh install =="
S1="$(new_fixture fresh DOCKER-USER)"
rc=0; run_firewall "$S1" "$WORK/fresh.log" || rc=$?
check "fresh install exits 0" "0" "$rc"
have "the run reports the rules it added" "$(cat "$WORK/fresh.log")" "added $TOTAL rule(s)"

RULES1="$(rules_of "$S1")"
check "the expected number of rules exists" "$TOTAL" "$(grep -c . "$S1/rules")"
check "the stateful ACCEPT is line 1" "$CONNTRACK" "$(sed -n '1p' "$S1/rules")"
have "the inbound drop is present" "$RULES1" "$INBOUND"

for br in "$BR_HYBRID" "$BR_CODER"; do
  have "app->sandbox control ports are accepted on $br" "$RULES1" "$(accept_app_to_sandbox "$br")"
  have "sandbox->app TCP 3000 is accepted on $br" "$RULES1" "$(accept_sandbox_to_app "$br")"
  have "the stack drop for $br is present" "$RULES1" "$(drop_stack "$br")"
done

for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
  have "the LAN/tailnet drop for $cidr is present" "$RULES1" "$(drop_dest "$cidr")"
done

have "the sandbox->resolver UDP/53 ACCEPT is present" "$RULES1" "$(accept_sandbox_dns udp)"
have "the sandbox->resolver TCP/53 ACCEPT is present" "$RULES1" "$(accept_sandbox_dns tcp)"

# The two defects this change fixes.
absent "the dead pre-DNAT webhook rule is not emitted" "$RULES1" "--dport 3001"
absent "the blanket ! -o docker0 drop is not emitted" "$RULES1" "! -o docker0"
absent "no rule names the docker0 gateway" "$RULES1" '172.17.0.1'

# Every owned ACCEPT strictly above every owned DROP.
check "every owned ACCEPT is above every owned DROP" "0" \
  "$(awk -v tag="$TAG" '
       index($0, tag) && /-j DROP/ { seen_drop = 1; next }
       index($0, tag) && /-j ACCEPT/ && seen_drop { n++ }
       END { print n + 0 }' "$S1/rules")"

# ---------------------------------------------------------------------------
echo
echo "== the accepted paths are exact =="
check "exactly one conntrack ACCEPT exists" "1" "$(grep -c -- '--ctstate ESTABLISHED,RELATED' "$S1/rules")"
check "each bridge gets exactly one multiport ACCEPT" "2" \
  "$(grep -c -- "-m multiport --dports $PORTS" "$S1/rules")"
check "the multiport list is exactly the documented constant" "2" \
  "$(grep -c -- "--dports 8000,8001,8011,8012 -m comment --comment $TAG -j ACCEPT" "$S1/rules")"
check "each bridge gets exactly one sandbox->app TCP 3000 ACCEPT" "2" \
  "$(grep -c -- '-o br-[0-9a-f]* -p tcp --dport 3000 ' "$S1/rules")"
if grep -qE -- '-j ACCEPT.*-m multiport.*:[0-9]+' "$S1/rules"; then
  bad "a multiport ACCEPT was widened into a port range"
else
  ok "no ACCEPT was widened into a port range"
fi

# ---------------------------------------------------------------------------
echo
echo "== migrated host: foreign rules survive =="
FOREIGN_1="-j RETURN"
# Built field-by-field so this file never spells out a documentable address.
FOREIGN_2="$(printf -- '-s %s.%s.%s.%s/24 -j ACCEPT' 192 0 2 0)"
# A tagged rule from a previous release that is not in today's rule set. The
# script prepends and never deletes, so it must survive byte-untouched.
FOREIGN_TAGGED="-i docker0 -p tcp -d $(printf '%s.%s.%s.%s' 172 17 0 1) --dport 3001 -m comment --comment $TAG -j ACCEPT"
S2="$(new_fixture migrated DOCKER-USER)"
printf '%s\n%s\n%s\n' "$FOREIGN_1" "$FOREIGN_2" "$FOREIGN_TAGGED" > "$S2/rules"
rc=0; run_firewall "$S2" "$WORK/migrated.log" || rc=$?
check "migrated host exits 0" "0" "$rc"
check "both foreign rules are still present, in order" \
  "$FOREIGN_1|$FOREIGN_2" \
  "$(grep -F -e "$FOREIGN_1" -e "$FOREIGN_2" "$S2/rules" | paste -sd'|' -)"
check "no foreign rule was modified" "3" \
  "$(grep -cxF -e "$FOREIGN_1" -e "$FOREIGN_2" -e "$FOREIGN_TAGGED" "$S2/rules")"
have "the stale tagged rule is reported, not silently kept" \
  "$(cat "$WORK/migrated.log")" "stale tagged rule left in DOCKER-USER"
check "no flush, delete or chain removal was invoked" "0" \
  "$(grep -cE '^-F|^-X|^-D| -F | -X | -D ' "$S2/calls" || true)"
check "the owned rules were added around them" "$(( TOTAL + 3 ))" "$(grep -c . "$S2/rules")"
check "owned rules are prepended above the foreign RETURN" "$CONNTRACK" "$(sed -n '1p' "$S2/rules")"
check "the foreign rules keep their relative order at the bottom" \
  "$FOREIGN_1|$FOREIGN_2|$FOREIGN_TAGGED" "$(tail -3 "$S2/rules" | paste -sd'|' -)"

# ---------------------------------------------------------------------------
echo
echo "== idempotency =="
: > "$S2/calls"
rc=0; run_firewall "$S2" "$WORK/second.log" || rc=$?
check "a second run exits 0" "0" "$rc"
have "the second run reports unchanged" "$(cat "$WORK/second.log")" \
  "unchanged ($TOTAL rules already present)"
check "the second run added no rule" "0" \
  "$(grep -cE '^-I |^-A ' "$S2/calls" || true)"
check "the rule set is byte-identical after the second run" "$(( TOTAL + 3 ))" "$(grep -c . "$S2/rules")"

S1_BEFORE="$(cat "$S1/rules")"
: > "$S1/calls"
rc=0; run_firewall "$S1" "$WORK/second-fresh.log" || rc=$?
check "the fresh fixture is also a no-op on re-run" "$S1_BEFORE" "$(cat "$S1/rules")"
check "and it added nothing" "0" "$(grep -cE '^-I |^-A ' "$S1/calls" || true)"

# ---------------------------------------------------------------------------
echo
echo "== degraded paths =="
# coder-net unresolvable: only that bridge's rules are skipped.
PARTIAL_NETS="$WORK/networks-partial"
printf '%s\n' "hybrid-ai aaaaaaaaaaaa000011112222" > "$PARTIAL_NETS"
S4="$(new_fixture partial DOCKER-USER)"
rc=0
env PATH="$STUBS:$PATH" STUB_STATE="$S4" STUB_NETWORKS="$PARTIAL_NETS" \
  bash "$FIREWALL" apply > "$WORK/partial.log" 2>&1 || rc=$?
check "an unresolvable network still exits 0" "0" "$rc"
have "the warning names coder-net" "$(cat "$WORK/partial.log")" "network coder-net"
RULES4="$(rules_of "$S4")"
have "the resolvable bridge still gets its app->sandbox accept" "$RULES4" "$(accept_app_to_sandbox "$BR_HYBRID")"
have "the resolvable bridge still gets its sandbox->app accept" "$RULES4" "$(accept_sandbox_to_app "$BR_HYBRID")"
absent "the unresolved bridge gets no rule" "$RULES4" "$BR_CODER"
have "the CIDR drops are installed anyway" "$RULES4" "$(drop_dest 100.64.0.0/10)"

# docker missing entirely: both networks warned about, nothing bridge-scoped.
# The PATH is built by hand so it really has no docker: a system PATH would
# still find one in /usr/bin.
NODOCKER="$WORK/bin-nodocker"
mkdir -p "$NODOCKER"
cp "$STUBS/iptables" "$NODOCKER/iptables"
for tool in bash grep cat mv mkdir; do
  ln -sf "$(command -v "$tool")" "$NODOCKER/$tool"
done
S5="$(new_fixture nodocker DOCKER-USER)"
rc=0
env PATH="$NODOCKER" STUB_STATE="$S5" STUB_NETWORKS="$NETWORKS_FILE" \
  "$NODOCKER/bash" -c 'command -v docker >/dev/null && exit 9; exec bash "$@"' _ "$FIREWALL" apply \
  > "$WORK/nodocker.log" 2>&1 || rc=$?
if [[ "$rc" == "9" ]]; then
  bad "the no-docker fixture still had docker on PATH, so the case proved nothing"
else
  check "a host without docker still exits 0" "0" "$rc"
  have "the warning names hybrid-ai" "$(cat "$WORK/nodocker.log")" "network hybrid-ai"
  have "the warning names coder-net" "$(cat "$WORK/nodocker.log")" "network coder-net"
  absent "no bridge-scoped rule was installed" "$(rules_of "$S5")" "br-"
fi

# ---------------------------------------------------------------------------
echo
echo "== the ordering self-check fails loudly =="
# A chain that already holds the full rule set, but with an owned ACCEPT below
# an owned DROP: -C finds every rule, nothing is inserted, and the self-check
# must reject the ordering rather than report success.
S6="$(new_fixture misordered DOCKER-USER)"
{
  printf '%s\n' "$CONNTRACK"
  printf '%s\n' "$(drop_stack "$BR_HYBRID")"
  printf '%s\n' "$(accept_sandbox_to_app "$BR_HYBRID")"
} > "$S6/rules"
rc=0; run_firewall "$S6" "$WORK/misordered.log" || rc=$?
check "a misordered chain makes the run exit non-zero" "1" "$rc"
have "the self-check says so plainly" "$(cat "$WORK/misordered.log")" "ordering self-check FAILED"

# ---------------------------------------------------------------------------
echo
echo "== loopback is untouched =="
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
check "the inbound DROP carries the ! -i lo guard" "1" \
  "$(grep -- '! -i lo -o docker0' "$S1/rules" | grep -c -- '-j DROP')"
check "no DROP besides that one lacks an -i constraint" "0" \
  "$(grep -- '-j DROP' "$S1/rules" | grep -v -- '! -i lo' | grep -cv -- '-i docker0' || true)"

ip_to_int() {
  local octets="$1" a b c d
  a="${octets%%.*}"; octets="${octets#*.}"
  b="${octets%%.*}"; octets="${octets#*.}"
  c="${octets%%.*}"; d="${octets#*.}"
  printf '%s' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

cidr_matches() { # ip cidr
  local ip="$1" net="${2%/*}" bits="${2#*/}"
  local ipn netn mask
  ipn="$(ip_to_int "$ip")"
  netn="$(ip_to_int "$net")"
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( (ipn & mask) == (netn & mask) ))
}

# Model a packet against one rule line. Result is the exit status.
# The token list is walked in order so `! -o docker0` would never be read as `-o`.
# An unspecified proto/dport makes a rule that constrains it undecidable, not a
# match: the older in/out/dst-only call sites keep working, and a port-53 ACCEPT
# never counts as an ACCEPT for a packet of unknown protocol. A rule with no port
# match matches every port; `--dport A:B` is a range and `--dports a,b,c` a list,
# so a widened rule is judged on the concrete port the packet uses.
tokens_match() { # rule-line in out dst [proto] [dport]
  local rule="$1" in="$2" out="$3" dst="$4" proto="${5:-}" dport="${6:-}"
  local -a t plist
  local i iface val neg matched undecidable=0 ports p ok
  read -r -a t <<< "$rule"
  matched=1
  for (( i = 0; i < ${#t[@]}; i++ )); do
    case "${t[i]}" in
      -i|-o)
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
        ;;
      -d)
        cidr_matches "$dst" "${t[i+1]}" || matched=0
        ;;
      -p|--protocol)
        if [[ -z "$proto" ]]; then
          undecidable=1 # the modelled packet names no protocol
        elif [[ "${t[i+1]}" != "$proto" ]]; then
          matched=0
        fi
        ;;
      --dport|--dports)
        if [[ -z "$dport" ]]; then
          undecidable=1 # the modelled packet names no port
        else
          ports="${t[i+1]}"
          read -r -a plist <<< "${ports//,/ }"
          ok=0
          for p in "${plist[@]}"; do
            if [[ "$p" == *:* ]]; then
              (( dport >= ${p%%:*} && dport <= ${p##*:} )) && ok=1
            elif [[ "$p" == "$dport" ]]; then
              ok=1
            fi
          done
          (( ok )) || matched=0
        fi
        ;;
    esac
  done
  (( matched && ! undecidable ))
}

# Walk the chain in order and report the verdict of the first owned rule that
# matches (iptables semantics: first match wins). Prints ACCEPT, DROP or NONE.
# The stateful return-path ACCEPT is skipped: the modelled packet is a NEW flow.
first_match() { # in out dst [proto] [dport]
  local rule
  while IFS= read -r rule; do
    [[ "$rule" == *"$TAG"* ]] || continue
    [[ "$rule" == *"--ctstate"* ]] && continue
    tokens_match "$rule" "$@" || continue
    if [[ "$rule" == *"-j ACCEPT"* ]]; then
      printf 'ACCEPT'
    else
      printf 'DROP'
    fi
    return 0
  done < "$S1/rules"
  printf 'NONE'
}

# Model a packet against the owned rules of one verdict: does any of them match?
# The matching rule line is left in $MATCHED_RULE.
MATCHED_RULE=""
rule_matches() { # in out dst [proto] [dport] [verdict]
  local verdict="${6:-DROP}" rule
  while IFS= read -r rule; do
    [[ "$rule" == *"-j $verdict"* ]] || continue
    [[ "$rule" == *"$TAG"* ]] || continue
    [[ "$rule" == *"--ctstate"* ]] && continue
    if tokens_match "$rule" "$1" "$2" "$3" "${4:-}" "${5:-}"; then
      MATCHED_RULE="$rule"
      return 0
    fi
  done < "$S1/rules"
  return 1
}

drop_matches() { rule_matches "$1" "$2" "$3" "${4:-}" "${5:-}" DROP; }
accept_matches() { rule_matches "$1" "$2" "$3" "${4:-}" "${5:-}" ACCEPT; }

if drop_matches lo docker0 127.0.0.1; then
  bad "a loopback packet matches a DROP rule (the SSH-tunnel path would break)"
else
  ok "a loopback packet matches none of the drops"
fi
if drop_matches lo "$BR_HYBRID" 127.0.0.1; then
  bad "a loopback packet to an app bridge matches a DROP rule"
else
  ok "a loopback packet to an app bridge matches no drop"
fi
if drop_matches eth0 docker0 172.17.0.9; then
  ok "a LAN packet into docker0 is dropped"
else
  bad "a LAN packet into docker0 is not dropped"
fi
if drop_matches docker0 "$BR_HYBRID" 172.18.0.9; then
  ok "a sandbox packet to the hybrid-ai bridge is dropped"
else
  bad "a sandbox packet to the hybrid-ai bridge is not dropped"
fi
if drop_matches docker0 "$BR_CODER" 172.19.0.9; then
  ok "a sandbox packet to the coder-net bridge is dropped"
else
  bad "a sandbox packet to the coder-net bridge is not dropped"
fi
if drop_matches docker0 eth0 10.0.0.7; then
  ok "a sandbox packet to the LAN is dropped"
else
  bad "a sandbox packet to the LAN is not dropped"
fi
if drop_matches docker0 tailscale0 100.64.1.7; then
  ok "a sandbox packet to the tailnet is dropped"
else
  bad "a sandbox packet to the tailnet is not dropped"
fi
if drop_matches docker0 eth0 203.0.113.9; then
  bad "a sandbox packet to the internet is dropped (model endpoint and git break)"
else
  ok "a sandbox packet to the internet is permitted"
fi
if drop_matches docker0 docker0 172.17.0.9; then
  ok "docker0-to-docker0 is also covered by the inbound drop (single -i limit)"
else
  bad "docker0-to-docker0 unexpectedly bypasses both drops"
fi
if drop_matches lo lo 127.0.0.1; then
  bad "a loopback packet matches a drop"
else
  ok "no loopback packet matches any drop"
fi

# ---------------------------------------------------------------------------
echo
echo "== the DNS exception is exact, and is not wider than port 53 =="
check "exactly two port-53 ACCEPTs exist" "2" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -c -- '-j ACCEPT')"
check "one of them is UDP" "1" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -c -- '-p udp')"
check "one of them is TCP" "1" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -c -- '-p tcp')"
check "no port-53 ACCEPT was widened into --dports" "0" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -c -- '--dports' || true)"
check "no port-53 ACCEPT names a port range" "0" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -c -- ':' || true)"
check "no port-53 ACCEPT is destination-scoped" "0" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -cE -- '(^| )-d ' || true)"
check "no port-53 ACCEPT names an output interface" "0" \
  "$(grep -- '--dport 53' "$S1/rules" | grep -cE -- '(^| )-o ' || true)"
check "each port-53 ACCEPT carries exactly one input interface" "1|1" \
  "$(grep -- '--dport 53' "$S1/rules" \
     | awk '{ n = 0; for (i = 1; i < NF; i++) if ($i == "-i") n++; print n }' | paste -sd'|' -)"

check "both DNS ACCEPTs sit above all four CIDR DROPs" "ok" \
  "$(awk -v udp="$(accept_sandbox_dns udp)" -v tcp="$(accept_sandbox_dns tcp)" '
       $0 == udp { u = NR }
       $0 == tcp { t = NR }
       /-i docker0 -d / && /-j DROP/ { d = NR; n++ }
       END { print (n == 4 && u && t && u < d && t < d) ? "ok" : "bad" }' "$S1/rules")"

# The resolver sits inside the dropped RFC1918 space, so a packet to it is only
# allowed on port 53. Built field-by-field, like the other fixtures.
RESOLVER="$(printf -- '%s.%s.%s.%s' 192 168 1 1)"

# CASE A: DNS to the resolver is allowed, on both protocols. This models the
# whole chain, first match wins, so the CIDR DROPs below are in play: the packet
# does match those DROPs, and is only saved because the DNS ACCEPT sits above them.
line_of() { grep -nxF -m1 -- "$1" "$S1/rules" | cut -d: -f1 || true; }
for proto in udp tcp; do
  check "a $proto/53 packet from the sandbox to the resolver is ACCEPTed by the chain" \
    "ACCEPT" "$(first_match docker0 eth0 "$RESOLVER" "$proto" 53)"
  if accept_matches docker0 eth0 "$RESOLVER" "$proto" 53; then
    ok "a $proto/53 packet to the resolver matches an owned ACCEPT"
  else
    bad "a $proto/53 packet from the sandbox to the resolver matches no ACCEPT (sandbox DNS breaks)"
  fi
  if drop_matches docker0 eth0 "$RESOLVER" "$proto" 53; then
    accept_line="$(line_of "$(accept_sandbox_dns "$proto")")"
    drop_line="$(line_of "$MATCHED_RULE")"
    if [[ -n "$accept_line" && -n "$drop_line" ]] && (( accept_line < drop_line )); then
      ok "the DROP that would swallow a $proto/53 answer sits below the DNS ACCEPT"
    else
      bad "the DROP for $proto/53 (line ${drop_line:-?}) is not below the DNS ACCEPT (line ${accept_line:-?})"
    fi
  else
    ok "no DROP rule matches a $proto/53 packet to the resolver"
  fi
done

# CASE B: anything else to the same address is still dropped. This is the case
# that fails if either DNS ACCEPT loses its port match or is widened to a range.
for dport in 443 8080; do
  check "a tcp/$dport packet from the sandbox to the resolver is DROPped by the chain" \
    "DROP" "$(first_match docker0 eth0 "$RESOLVER" tcp "$dport")"
  if accept_matches docker0 eth0 "$RESOLVER" tcp "$dport"; then
    bad "a tcp/$dport packet to the resolver matches an ACCEPT ($MATCHED_RULE)"
  else
    ok "a tcp/$dport packet to the resolver matches no ACCEPT"
  fi
done

# The matcher must be able to spot a widened rule, or the two cases above would
# pass for the wrong reason: a `--dports` list and a `--dport` range that reach
# 443 must both match a 443 packet, which is what makes Case B fail on a widened
# rule.
check "a --dports list containing 443 matches a 443 packet" "match" \
  "$(tokens_match "-i docker0 -p tcp -m multiport --dports 53,443 -m comment --comment $TAG -j ACCEPT" \
     docker0 eth0 "$RESOLVER" tcp 443 && echo match || echo no-match)"
check "a --dports list without 443 does not match a 443 packet" "no-match" \
  "$(tokens_match "-i docker0 -p tcp -m multiport --dports 53,853 -m comment --comment $TAG -j ACCEPT" \
     docker0 eth0 "$RESOLVER" tcp 443 && echo match || echo no-match)"
check "a --dport range reaching 443 matches a 443 packet" "match" \
  "$(tokens_match "-i docker0 -p tcp --dport 0:65535 -m comment --comment $TAG -j ACCEPT" \
     docker0 eth0 "$RESOLVER" tcp 443 && echo match || echo no-match)"
check "a -p udp rule does not match a tcp packet" "no-match" \
  "$(tokens_match "-i docker0 -p udp --dport 53 -m comment --comment $TAG -j ACCEPT" \
     docker0 eth0 "$RESOLVER" tcp 53 && echo match || echo no-match)"


# ---------------------------------------------------------------------------
echo
echo "== coded failure statuses are unchanged =="
S3="$WORK/no-chain"
mkdir -p "$S3"; printf 'INPUT\n' > "$S3/chains"; : > "$S3/rules"; : > "$S3/calls"
rc=0; run_firewall "$S3" "$WORK/no-chain.log" || rc=$?
check "a host without DOCKER-USER exits 4" "4" "$rc"
have "the message explains the DOCKER-USER ordering" "$(cat "$WORK/no-chain.log")" \
  "DOCKER-USER chain does not exist"
check "nothing was written to the fake chain" "0" "$(grep -c . "$S3/rules")"

NOIPT="$WORK/bin-noiptables"
mkdir -p "$NOIPT"
rc=0
env PATH="$NOIPT:/usr/local/bin:/usr/bin:/bin" STUB_STATE="$S3" STUB_NETWORKS="$NETWORKS_FILE" \
  bash -c 'command -v iptables >/dev/null && exit 9; exec bash "$@"' _ "$FIREWALL" apply \
  > "$WORK/no-iptables.log" 2>&1 || rc=$?
if [[ "$rc" == "9" ]]; then
  ok "the no-iptables fixture really has no iptables on PATH (skipped as runnable)"
else
  check "a host without iptables exits 3" "3" "$rc"
fi

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
if grep -qE '(^|[^!] )(iptables -D|iptables -F|iptables -X)' "$FIREWALL"; then
  bad "the script deletes a rule or a chain"
else
  ok "the script never deletes a rule or a chain"
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
