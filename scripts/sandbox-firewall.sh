#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# FILE: scripts/sandbox-firewall.sh
# PURPOSE (plain English):
#   Keeps the agent sandbox ports closed to the LAN and the tailnet while
#   leaving every control path the stack actually uses open.
#
#   THE TOPOLOGY. The OpenHands app is a container (hybrid-ai-openhands) joined
#   to two Docker networks, `hybrid-ai` and `coder-net` (see
#   openhands/docker-compose.openhands.yml). Each network shows up on the host
#   as a bridge interface `br-<first 12 hex of the network id>`. Agent sandboxes
#   run on `docker0`. DOCKER-USER sees forwarded packets AFTER DNAT, so a
#   sandbox call to the app arrives with the app container's address and the
#   container port 3000 -- never the docker0 gateway and never the published
#   host port 3001.
#
#   THE PATHS THAT MUST WORK:
#     1. app -> sandbox: the control ports in SANDBOX_CONTROL_PORTS, from each
#        app bridge into docker0 (agent-server, VSCode and the workers).
#     2. sandbox -> app: TCP 3000 from docker0 to each app bridge, for webhooks
#        and for the secret fetch (/api/v1/webhooks/secrets) that conversation
#        creation performs.
#     3. sandbox -> resolver: UDP/53 and TCP/53 from docker0. This ACCEPT must
#        sit ABOVE the CIDR DROPs: the resolver's answer arrives from an address
#        inside the dropped RFC1918 space, so a later DROP would swallow it and
#        the sandbox would lose DNS.
#     4. sandbox -> internet: the model endpoint, git and package mirrors. This
#        egress is DELIBERATELY PERMITTED. It is required, not an oversight:
#        without it a sandbox boots, reaches READY, then records
#        `prompt_tokens: 0` with no actions.
#     5. the stateful return path for all of the above.
#
#   THE PATHS THAT MUST NOT WORK:
#     * LAN and tailnet clients reaching a sandbox port (the inbound drop into
#       docker0, unchanged).
#     * a sandbox pivoting onto the stack networks that host the app.
#     * a sandbox reaching the LAN or the tailnet, closed explicitly by
#       destination rather than as a side effect of the stack drops.
#
#   LOOPBACK IS UNTOUCHED. No owned rule matches `-o lo`, and the only rule
#   without a positive `-i` match carries `! -i lo`. The SSH-tunnel and Tailscale
#   path to the loopback-only OpenHands UI keeps working, and its return traffic
#   is covered by the stateful ACCEPT.
#
#   IDEMPOTENT, AND IT NEVER TOUCHES A FOREIGN RULE. Each rule this script owns
#   carries the comment tag below. Before inserting, the script checks for the
#   exact rule with `-C`; if it is already there, nothing is added. There is no
#   flush, no delete and no chain removal anywhere. Rules inserted by Docker,
#   by another tool, or by hand survive byte-untouched.
#
#   ORDERING. Every owned ACCEPT is kept strictly above every owned DROP, so no
#   drop can swallow an accepted path. That matters most for the DNS ACCEPT: its
#   answer comes back from inside the dropped RFC1918 space. Rules are prepended,
#   which also keeps them above a foreign `-j RETURN`. After applying, the script
#   reads DOCKER-USER back and exits non-zero if that invariant does not hold.
#
#   DEGRADED PATHS. A missing `docker`, or a network whose id cannot be read,
#   skips that network's bridge rules with a warning naming the network, and
#   still exits 0: this script must never block a boot.
#
#   PERSISTENCE. This script is not persistent on its own. It is applied by the
#   privileged deploy path (install.sh and scripts/deploy-remote.sh) after the
#   compose stack is up, and re-applied on every boot by the enabled unit
#   deploy/hybrid-ai-firewall.service.
#
# USAGE:
#   ./scripts/sandbox-firewall.sh apply
#
#   Run as root. `apply` is the only verb: it adds missing rules and leaves
#   everything else alone.
#
# EXIT CODES:
#   0  rules present (some added, or all already present)
#   1  the ordering self-check found an owned ACCEPT below an owned DROP
#   2  bad usage
#   3  iptables is not installed
#   4  the DOCKER-USER chain does not exist (Docker is not up yet)
#   5  iptables refused an insert
# ---------------------------------------------------------------------------

readonly TAG="hybrid-ai-sandbox-egress"
readonly CHAIN="DOCKER-USER"
readonly IPT_LOCK_WAIT="5"

# The Docker networks the app container is attached to. Each resolves to a host
# bridge interface: `br-` + the first 12 hex characters of its network id.
readonly APP_NETWORKS=(hybrid-ai coder-net)

# Sandbox ports the app must reach: 8000 is the agent-server (doctor.sh:854),
# 8001 is VSCode, and 8011 / 8012 are the workers (live observation on the host).
readonly SANDBOX_CONTROL_PORTS="8000,8001,8011,8012"

# The app container's own HTTP port, as DOCKER-USER sees it after DNAT.
readonly APP_WEB_PORT="3000"

# Destinations a sandbox may never reach. The three RFC1918 supernets cover
# docker0, both app bridges, the LAN and any operator subnet; 100.64.0.0/10 is
# the Tailscale/CGNAT range, i.e. the tailnet. Everything else -- the model
# endpoint, GitHub, package mirrors -- is deliberately allowed.
readonly SANDBOX_BLOCKED_DESTS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10")

usage() {
  printf 'usage: %s apply\n' "${0##*/}" >&2
}

if [[ "${1:-}" != "apply" ]]; then
  usage
  exit 2
fi
if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

if ! command -v iptables >/dev/null 2>&1; then
  printf 'sandbox-firewall: iptables is not installed; cannot apply the sandbox rules.\n' >&2
  exit 3
fi

IPT=(iptables -w "$IPT_LOCK_WAIT")

if ! "${IPT[@]}" -S "$CHAIN" >/dev/null 2>&1; then
  printf 'sandbox-firewall: the %s chain does not exist. Docker has not started yet; the boot unit hybrid-ai-firewall.service will apply these rules once it has.\n' "$CHAIN" >&2
  exit 4
fi

# -- Bridge discovery -------------------------------------------------------
# A degraded resolution is a warning, never a failure: the rest of the rules
# are still worth installing, and a boot must not stop here.
resolve_bridge() { # network-name -> bridge interface on stdout, non-zero if unknown
  local net="$1" id
  id="$(docker network inspect -f '{{.Id}}' "$net" 2>/dev/null)" || return 1
  [[ -n "$id" ]] || return 1
  printf 'br-%s\n' "${id:0:12}"
}

BRIDGES=()
for net in "${APP_NETWORKS[@]}"; do
  if ! command -v docker >/dev/null 2>&1; then
    printf 'sandbox-firewall: docker is not installed; skipping the bridge rules for network %s.\n' "$net" >&2
    continue
  fi
  br="$(resolve_bridge "$net" || true)"
  if [[ -z "$br" ]]; then
    printf 'sandbox-firewall: could not resolve network %s; skipping its bridge rules.\n' "$net" >&2
    continue
  fi
  BRIDGES+=("$br")
done

# -- Rule set, top to bottom ------------------------------------------------
# The stateful ACCEPT is first: it is the return path for every accepted flow.
RULES=("-m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment $TAG -j ACCEPT")

# App -> sandbox control ports, and sandbox -> app webhooks and secret fetches.
for br in "${BRIDGES[@]}"; do
  RULES+=("-i $br -o docker0 -p tcp -m multiport --dports $SANDBOX_CONTROL_PORTS -m comment --comment $TAG -j ACCEPT")
  RULES+=("-i docker0 -o $br -p tcp --dport $APP_WEB_PORT -m comment --comment $TAG -j ACCEPT")
done

# Sandbox -> resolver, port 53, both protocols. This must sit ABOVE the CIDR
# DROPs below: the resolver's answer arrives from an address inside the dropped
# RFC1918 space, so a later DROP would swallow it. The exception is deliberately
# port-scoped, not destination-scoped: a sandbox can reach any resolver on
# port 53. That is the accepted residual.
RULES+=("-i docker0 -p udp --dport 53 -m comment --comment $TAG -j ACCEPT")
RULES+=("-i docker0 -p tcp --dport 53 -m comment --comment $TAG -j ACCEPT")

# Stack containment: one drop per app bridge. A blanket `! -o docker0` would
# also cut the sandbox off from the internet, which agents require.
for br in "${BRIDGES[@]}"; do
  RULES+=("-i docker0 -o $br -m comment --comment $TAG -j DROP")
done

# Sandbox -> LAN and sandbox -> tailnet, closed explicitly.
for dest in "${SANDBOX_BLOCKED_DESTS[@]}"; do
  RULES+=("-i docker0 -d $dest -m comment --comment $TAG -j DROP")
done

# Inbound into docker0 from anywhere but loopback. `-i docker0` cannot be added
# as a second negative interface match (iptables allows one -i), and docker0 to
# docker0 is not a routable path, so `! -i lo` is the whole guard.
RULES+=("! -i lo -o docker0 -m comment --comment $TAG -j DROP")

added=0
present=0

apply_rule() {
  local -a rule=("$@")
  if "${IPT[@]}" -C "$CHAIN" "${rule[@]}" >/dev/null 2>&1; then
    present=$(( present + 1 ))
    return 0
  fi
  if ! "${IPT[@]}" -I "$CHAIN" 1 "${rule[@]}" >/dev/null; then
    printf 'sandbox-firewall: iptables refused to insert a rule into %s.\n' "$CHAIN" >&2
    exit 5
  fi
  added=$(( added + 1 ))
}

# Insert bottom-up, so the chain ends in the order RULES was written.
for (( idx = ${#RULES[@]} - 1; idx >= 0; idx-- )); do
  read -r -a rule <<< "${RULES[idx]}"
  apply_rule "${rule[@]}"
done

# -- Ordering self-check ----------------------------------------------------
# Read the chain back: no ACCEPT this run installed may sit below a DROP it
# installed, because a drop above an accept silently swallows the path the
# accept was there to open. Only rules in the current set count: a tagged rule
# left by a previous release is not ours to judge and is never deleted, so it is
# reported for hand removal instead of failing every boot.
is_owned() { # rule-line with the "-A CHAIN " prefix already stripped
  local candidate="$1" own
  for own in "${RULES[@]}"; do
    [[ "$candidate" == "$own" ]] && return 0
  done
  return 1
}

listing="$("${IPT[@]}" -S "$CHAIN" 2>/dev/null || true)"
pos=0
first_drop=0
last_accept=0
line_prefix="-A $CHAIN "
while IFS= read -r line; do
  pos=$(( pos + 1 ))
  [[ "$line" == *"$TAG"* ]] || continue
  body="${line#"$line_prefix"}"
  if ! is_owned "$body"; then
    printf 'sandbox-firewall: note: stale tagged rule left in %s by a previous release (this script never deletes; remove it by hand if unwanted): %s\n' "$CHAIN" "$body"
    continue
  fi
  if [[ "$body" == *"-j ACCEPT"* ]]; then
    last_accept=$pos
  elif [[ "$body" == *"-j DROP"* ]] && (( first_drop == 0 )); then
    first_drop=$pos
  fi
done <<< "$listing"

if (( first_drop > 0 && last_accept > first_drop )); then
  printf 'sandbox-firewall: ordering self-check FAILED: an ACCEPT tagged %s sits at position %d, below a DROP tagged %s at position %d.\n' \
    "$TAG" "$last_accept" "$TAG" "$first_drop" >&2
  exit 1
fi

total=$(( added + present ))
if (( added == 0 )); then
  printf 'sandbox-firewall: unchanged (%d rules already present)\n' "$total"
else
  printf 'sandbox-firewall: added %d rule(s) (%d already present)\n' "$added" "$present"
fi
