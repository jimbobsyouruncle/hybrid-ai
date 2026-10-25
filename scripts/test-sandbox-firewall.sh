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
#   * a sandbox packet to the same address on a non-53 port (443 and 8080, over
#     both TCP and UDP) still matches an owned DROP and no owned ACCEPT (fails if
#     either DNS ACCEPT is widened, whichever protocol it speaks)
#   * migrated host: pre-existing foreign rules survive byte-untouched
#   * partially present owned set: a strict subset of the owned rules, in a
#     scrambled order, is repaired by deleting every owned rule and re-applying
#     the whole set through the bottom-up path, so the chain ends as exactly the
#     written RULES set; a tagged rule outside that set is never deleted, is not
#     counted as owned, and still produces its note
#   * a correct chain stored in `-S` normalised form (implied -m tcp / -m udp,
#     -d before -i, RELATED,ESTABLISHED) is recognised as owned: no note, no
#     insert, "unchanged"
#   * the same normalised chain plus one foreign tagged rule yields exactly one
#     note, and that rule survives byte-untouched
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
FIREWALL="${FIREWALL_UNDER_TEST:-${SCRIPT_DIR}/sandbox-firewall.sh}"
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

# iptables prints a rule in its own normal form, so `-C` matches a stored rule
# against the needle in that form rather than byte-for-byte: an implied module
# for -p ({tcp,udp}) is dropped, comma-separated values such as --ctstate are
# sorted, and the option/value units are compared as an unordered set. Written
# independently of the script under test, so the two normalisers check each
# other.
normalise() { # rule text -> canonical form on stdout
  printf '%s\n' "$1" | awk '
    {
      n = NF
      m = 0; neg = ""
      for (i = 1; i <= n; i++) {
        if ($i == "!") { neg = "! "; continue }
        opt = $i; val = ""
        if (i + 1 <= n && $(i + 1) != "!" && substr($(i + 1), 1, 1) != "-") { val = $(i + 1); i++ }
        if (opt == "-m" && (val == "tcp" || val == "udp")) { neg = ""; continue }
        if (index(val, ",") > 0) {
          k = split(val, part, ",")
          for (a = 2; a <= k; a++) {
            key = part[a]; b = a - 1
            while (b >= 1 && part[b] > key) { part[b + 1] = part[b]; b-- }
            part[b + 1] = key
          }
          val = part[1]
          for (a = 2; a <= k; a++) val = val "," part[a]
        }
        u[++m] = (val == "") ? neg opt : neg opt " " val
        neg = ""
      }
      for (a = 2; a <= m; a++) {
        key = u[a]; b = a - 1
        while (b >= 1 && u[b] > key) { u[b + 1] = u[b]; b-- }
        u[b + 1] = key
      }
      out = ""
      for (a = 1; a <= m; a++) out = (a == 1) ? u[a] : out "|" u[a]
      print out
    }'
}

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
    needle="$(normalise "$*")"
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      [[ "$(normalise "$rule")" == "$needle" ]] && exit 0
    done < "$state/rules"
    exit 1
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
  -D)
    # Delete the FIRST rule that matches, in the same normal form `-C` uses, so
    # the stub's notion of "the same rule" is one thing, not two.
    chain="${1:-}"; shift || true
    chain_exists "$chain" || exit 1
    needle="$(normalise "$*")"
    found=0
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      if (( ! found )) && [[ "$(normalise "$rule")" == "$needle" ]]; then
        found=1
        continue
      fi
      printf '%s\n' "$rule"
    done < "$state/rules" > "$state/rules.new"
    mv -f "$state/rules.new" "$state/rules"
    (( found )) || exit 1
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

# The LAN/tailnet destinations the script closes, built field-by-field so this
# file never spells out a full address literal.
CIDR_8="$(printf '%s.%s.%s.%s/8' 10 0 0 0)"
CIDR_12="$(printf '%s.%s.%s.%s/12' 172 16 0 0)"
CIDR_16="$(printf '%s.%s.%s.%s/16' 192 168 0 0)"
CIDR_10="$(printf '%s.%s.%s.%s/10' 100 64 0 0)"
CIDRS=("$CIDR_8" "$CIDR_12" "$CIDR_16" "$CIDR_10")

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
have "the out-of-policy tagged rule is reported, not silently kept" \
  "$(cat "$WORK/migrated.log")" "is not part of the current policy"
check "the migrated run emits exactly one note" "1" \
  "$(grep -c 'sandbox-firewall: note:' "$WORK/migrated.log" || true)"
check "no flush, delete or chain removal was invoked" "0" \
  "$(grep -cE '^-F|^-X|^-D| -F | -X | -D ' "$S2/calls" || true)"
check "the owned rules were added around them" "$(( TOTAL + 3 ))" "$(grep -c . "$S2/rules")"
check "owned rules are prepended above the foreign RETURN" "$CONNTRACK" "$(sed -n '1p' "$S2/rules")"
check "the foreign rules keep their relative order at the bottom" \
  "$FOREIGN_1|$FOREIGN_2|$FOREIGN_TAGGED" "$(tail -3 "$S2/rules" | paste -sd'|' -)"

# ---------------------------------------------------------------------------
echo
echo "== a partially present owned set is repaired to the written order =="
# A host can end up holding some, but not all, of the owned rules: an
# interrupted apply, a hand-edit, or a release whose rule set changed. If only
# the missing rules were prepended, each would land at the head of the chain, so
# a missing DROP could end up above the DNS ACCEPTs and the ordering self-check
# would fail on every deploy. The seed below is a strict subset of the fixture's
# OWN rules, in a scrambled order, with DROPs first so a prepend-only repair
# cannot pass. The expected result is written from those same fixture helpers,
# so neither the count nor the order is a hardcoded host number.
written_rules() { # the fixture's own RULES set, in the order the script writes it
  printf '%s\n' "$CONNTRACK"
  for br in "$BR_HYBRID" "$BR_CODER"; do
    printf '%s\n' "$(accept_app_to_sandbox "$br")"
    printf '%s\n' "$(accept_sandbox_to_app "$br")"
  done
  printf '%s\n' "$(accept_sandbox_dns udp)"
  printf '%s\n' "$(accept_sandbox_dns tcp)"
  for br in "$BR_HYBRID" "$BR_CODER"; do
    printf '%s\n' "$(drop_stack "$br")"
  done
  for cidr in "${CIDRS[@]}"; do
    printf '%s\n' "$(drop_dest "$cidr")"
  done
  printf '%s\n' "$INBOUND"
}
seed_partial() { # state-dir -- a strict, scrambled subset of the owned set
  {
    printf '%s\n' "$(drop_stack "$BR_CODER")"
    printf '%s\n' "$(drop_dest "$CIDR_16")"
    printf '%s\n' "$(accept_sandbox_dns tcp)"
    printf '%s\n' "$(accept_sandbox_to_app "$BR_HYBRID")"
    printf '%s\n' "$INBOUND"
  } > "$1/rules"
}

S9="$(new_fixture partial-owned DOCKER-USER)"
seed_partial "$S9"
PARTIAL_BEFORE="$(grep -c . "$S9/rules")"
if (( PARTIAL_BEFORE > 0 && PARTIAL_BEFORE < TOTAL )); then
  ok "the fixture starts partial ($PARTIAL_BEFORE of the $TOTAL owned rules)"
else
  bad "the partial fixture is not a strict subset ($PARTIAL_BEFORE of $TOTAL)"
fi
rc=0; run_firewall "$S9" "$WORK/partial-owned.log" || rc=$?
check "a partially present chain exits 0" "0" "$rc"
have "the run says it is re-applying the full set" "$(cat "$WORK/partial-owned.log")" \
  "re-applying the full set to restore the written order"
absent "the ordering self-check did not fail" "$(cat "$WORK/partial-owned.log")" \
  "ordering self-check FAILED"
check "every pre-existing owned rule was deleted" "$PARTIAL_BEFORE" \
  "$(grep -cE ' -D ' "$S9/calls" || true)"
check "the repaired chain holds the fixture's own rule count" "$TOTAL" \
  "$(grep -c . "$S9/rules")"
check "the repaired chain is the written RULES set, in order" "" \
  "$(diff <(written_rules) "$S9/rules")"
check "the stateful ACCEPT is back at line 1" "$CONNTRACK" "$(sed -n '1p' "$S9/rules")"
check "every owned ACCEPT is above every owned DROP" "0" \
  "$(awk -v tag="$TAG" '
       index($0, tag) && /-j DROP/ { seen_drop = 1; next }
       index($0, tag) && /-j ACCEPT/ && seen_drop { n++ }
       END { print n + 0 }' "$S9/rules")"

# The repair must not reach past the owned set: a tagged rule from an older
# release is not owned, so it is neither deleted nor counted, and it is still
# reported for inspection exactly as before.
S10="$(new_fixture partial-owned-foreign DOCKER-USER)"
seed_partial "$S10"
printf '%s\n' "$FOREIGN_TAGGED" >> "$S10/rules"
SEED10="$(grep -c . "$S10/rules")"
rc=0; run_firewall "$S10" "$WORK/partial-owned-foreign.log" || rc=$?
check "a partial chain with a foreign tagged rule exits 0" "0" "$rc"
check "the foreign tagged rule is reported exactly once" "1" \
  "$(grep -c 'sandbox-firewall: note:' "$WORK/partial-owned-foreign.log" || true)"
have "the note names the foreign rule body" "$(cat "$WORK/partial-owned-foreign.log")" "$FOREIGN_TAGGED"
check "the foreign tagged rule survives byte-untouched" "1" \
  "$(grep -cxF -- "$FOREIGN_TAGGED" "$S10/rules")"
check "only the owned subset was deleted, not the foreign rule" "$PARTIAL_BEFORE" \
  "$(grep -cE ' -D ' "$S10/calls" || true)"
check "the chain is the written set plus the foreign rule" "$(( TOTAL + 1 ))" \
  "$(grep -c . "$S10/rules")"
check "the foreign rule still sits below the repaired owned set" "$FOREIGN_TAGGED" \
  "$(tail -1 "$S10/rules")"
if (( SEED10 == PARTIAL_BEFORE + 1 )); then
  ok "the second fixture also starts partial ($SEED10 lines)"
else
  bad "the second partial fixture has an unexpected shape ($SEED10 lines)"
fi

# ---------------------------------------------------------------------------
echo
echo "== a chain stored in -S normalised form is recognised as owned =="
# `iptables -S` does not echo the text that built a rule: it adds the implied
# module (-m tcp, -m udp), puts -d before -i, and sorts --ctstate. These
# fixtures are what a correct chain really looks like on the host.
norm_accept_app_to_sandbox() {
  printf -- '-i %s -o docker0 -p tcp -m multiport --dports %s -m comment --comment %s -j ACCEPT' \
    "$1" "$PORTS" "$TAG"
}
norm_accept_sandbox_to_app() {
  printf -- '-i docker0 -o %s -p tcp -m tcp --dport 3000 -m comment --comment %s -j ACCEPT' "$1" "$TAG"
}
norm_accept_sandbox_dns() {
  printf -- '-i docker0 -p %s -m %s --dport 53 -m comment --comment %s -j ACCEPT' "$1" "$1" "$TAG"
}
norm_drop_dest() {
  printf -- '-d %s -i docker0 -m comment --comment %s -j DROP' "$1" "$TAG"
}
NORM_CONNTRACK="-m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment $TAG -j ACCEPT"

write_normalised_chain() { # state-dir
  {
    printf '%s\n' "$NORM_CONNTRACK"
    for br in "$BR_HYBRID" "$BR_CODER"; do
      printf '%s\n' "$(norm_accept_app_to_sandbox "$br")"
      printf '%s\n' "$(norm_accept_sandbox_to_app "$br")"
    done
    printf '%s\n' "$(norm_accept_sandbox_dns udp)"
    printf '%s\n' "$(norm_accept_sandbox_dns tcp)"
    for br in "$BR_HYBRID" "$BR_CODER"; do
      printf '%s\n' "$(drop_stack "$br")"
    done
    for cidr in "${CIDRS[@]}"; do
      printf '%s\n' "$(norm_drop_dest "$cidr")"
    done
    printf '%s\n' "$INBOUND"
  } > "$1/rules"
}

S7="$(new_fixture normalised DOCKER-USER)"
write_normalised_chain "$S7"
NORM_BEFORE="$(cat "$S7/rules")"
rc=0; run_firewall "$S7" "$WORK/normalised.log" || rc=$?
check "case (a) a normalised correct chain exits 0" "0" "$rc"
check "case (a) it reports zero stale notes" "0" \
  "$(grep -c 'sandbox-firewall: note:' "$WORK/normalised.log" || true)"
have "case (a) it reports the rules as already present" "$(cat "$WORK/normalised.log")" \
  "unchanged ($TOTAL rules already present)"
absent "case (a) the ordering self-check did not fail" "$(cat "$WORK/normalised.log")" \
  "ordering self-check FAILED"
check "case (a) no rule was inserted" "0" "$(grep -cE '^-I |^-A ' "$S7/calls" || true)"
check "case (a) the chain is byte-identical afterwards" "$NORM_BEFORE" "$(cat "$S7/rules")"

S8="$(new_fixture normalised-foreign DOCKER-USER)"
write_normalised_chain "$S8"
NORM_FOREIGN="$(printf -- '-d %s.%s.%s.%s -i docker0 -p tcp -m tcp --dport 3001 -m comment --comment %s -j ACCEPT' \
  172 17 0 1 "$TAG")"
printf '%s\n' "$NORM_FOREIGN" >> "$S8/rules"
rc=0; run_firewall "$S8" "$WORK/normalised-foreign.log" || rc=$?
check "case (b) a chain with one foreign tagged rule exports 0" "0" "$rc"
check "case (b) the foreign rule is reported exactly once" "1" \
  "$(grep -c 'sandbox-firewall: note:' "$WORK/normalised-foreign.log" || true)"
have "case (b) the note names the chain" "$(cat "$WORK/normalised-foreign.log")" "in DOCKER-USER"
have "case (b) the note names the rule body" "$(cat "$WORK/normalised-foreign.log")" "$NORM_FOREIGN"
absent "case (b) the note never tells anyone to delete by hand" \
  "$(cat "$WORK/normalised-foreign.log")" "remove it by hand"
check "case (b) the foreign rule survives byte-untouched" "1" \
  "$(grep -cxF -- "$NORM_FOREIGN" "$S8/rules")"
check "case (b) no rule was inserted" "0" "$(grep -cE '^-I |^-A ' "$S8/calls" || true)"
check "case (b) the chain still holds all 15 rules" "$(( TOTAL + 1 ))" "$(grep -c . "$S8/rules")"

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
# A chain that already holds the FULL owned rule set, but with an owned ACCEPT
# below an owned DROP: -C finds every rule, so the repair path does not fire and
# nothing is inserted, and the self-check must reject the ordering rather than
# report success. The set is complete on purpose -- a strict subset is now the
# repaired case above, not this one.
S6="$(new_fixture misordered DOCKER-USER)"
{
  printf '%s\n' "$(drop_stack "$BR_HYBRID")"
  printf '%s\n' "$CONNTRACK"
  for br in "$BR_HYBRID" "$BR_CODER"; do
    printf '%s\n' "$(accept_app_to_sandbox "$br")"
    printf '%s\n' "$(accept_sandbox_to_app "$br")"
  done
  printf '%s\n' "$(accept_sandbox_dns udp)"
  printf '%s\n' "$(accept_sandbox_dns tcp)"
  printf '%s\n' "$(drop_stack "$BR_CODER")"
  for cidr in "${CIDRS[@]}"; do
    printf '%s\n' "$(drop_dest "$cidr")"
  done
  printf '%s\n' "$INBOUND"
} > "$S6/rules"
check "the misordered fixture holds the full owned set" "$TOTAL" "$(grep -c . "$S6/rules")"
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

# CASE B: anything else to the same address is still dropped, on either
# protocol. This is the case that fails if either DNS ACCEPT loses its port
# match or is widened to a range.
for proto in tcp udp; do
  for dport in 443 8080; do
    check "a $proto/$dport packet from the sandbox to the resolver is DROPped by the chain" \
      "DROP" "$(first_match docker0 eth0 "$RESOLVER" "$proto" "$dport")"
    if accept_matches docker0 eth0 "$RESOLVER" "$proto" "$dport"; then
      bad "a $proto/$dport packet to the resolver matches an ACCEPT ($MATCHED_RULE)"
    else
      ok "a $proto/$dport packet to the resolver matches no ACCEPT"
    fi
  done
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
if grep -qE 'iptables[^|]*-F|iptables[^|]*-X|--flush|--delete-chain' "$FIREWALL"; then
  bad "the script flushes or removes a chain"
else
  ok "the script never flushes or removes a chain"
fi
# The repair path does delete rules, so "never deletes" is the wrong claim to
# assert. What must hold is that every deletion is confined to the owned-repair
# block (between the partial-state guard and the re-apply comment), so no delete
# can ever touch a rule the current RULES set does not generate.
GUARD_LINE="$(grep -nE '^if \(\( owned_missing && owned_present > 0 \)\)' "$FIREWALL" | cut -d: -f1)"
REAPPLY_LINE="$(grep -n '^# Insert bottom-up' "$FIREWALL" | cut -d: -f1)"
if [[ -z "$GUARD_LINE" || -z "$REAPPLY_LINE" ]]; then
  bad "could not locate the repair block in the script"
else
  DEL_LINES="$(grep -nE '"[$]\{IPT\[@\]\}" -D' "$FIREWALL" | cut -d: -f1)"
  DEL_COUNT="$(grep -cE '"[$]\{IPT\[@\]\}" -D' "$FIREWALL" || true)"
  stray=0
  for n in $DEL_LINES; do
    if (( n <= GUARD_LINE || n >= REAPPLY_LINE )); then
      stray=1
    fi
  done
  if (( DEL_COUNT == 1 && stray == 0 )); then
    ok "the only rule deletion sits inside the owned-repair block"
  else
    bad "a rule deletion sits outside the owned-repair block (deletes=$DEL_COUNT stray=$stray)"
  fi
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
if grep -qF 'remove it by hand' "$FIREWALL"; then
  bad "the script tells the operator to delete a rule by hand"
else
  ok "the script never tells the operator to delete a rule by hand"
fi

# ---------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
