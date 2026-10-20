#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# FILE: scripts/sandbox-firewall.sh
# PURPOSE (plain English):
#   Closes the sandbox port exposure. OpenHands publishes each sandbox agent
#   server on a random host port, and those ports currently answer on every
#   interface. This script puts two DROP rules in Docker's DOCKER-USER chain so
#   the sandbox ports are reachable from the Docker bridge only:
#
#     1. Traffic forwarded INTO docker0 from any interface other than loopback
#        is dropped, so a LAN or tailnet client cannot reach a sandbox port.
#     2. Traffic FROM docker0 to any other Docker network is dropped, so a
#        sandbox cannot pivot onto the stack networks.
#
#   THE ONE EXCEPTION. The OpenHands app server is published on the docker0
#   gateway at 172.17.0.1:${OPENHANDS_PORT:-3001} for sandbox webhooks (see
#   openhands/docker-compose.openhands.yml). Exactly one ACCEPT rule keeps that
#   path open. It is inserted immediately before the docker0-to-networks DROP,
#   so the DROP cannot swallow it. Nothing else is excepted.
#
#   LOOPBACK IS UNTOUCHED. Every rule that could match loopback carries
#   `! -i lo`, and no rule matches `-o lo`. The SSH-tunnel and Tailscale path to
#   the loopback-only OpenHands UI (127.0.0.1:${OPENHANDS_PORT:-3001}) therefore
#   keeps working. The only rule without an `! -i lo` guard is the docker0-to-
#   networks DROP, which matches `-i docker0` and so can never match loopback.
#
#   IDEMPOTENT, AND IT NEVER TOUCHES A FOREIGN RULE. Each rule this script owns
#   carries the comment tag below. Before inserting, the script checks for the
#   exact rule with `-C`; if it is already there, nothing is added. There is no
#   flush, no delete and no chain removal anywhere. Rules inserted by Docker,
#   by another tool, or by hand survive byte-untouched.
#
#   WHY `-I DOCKER-USER 1`. Rules are prepended rather than appended so a
#   foreign `-j RETURN` earlier in the chain cannot bypass the drops. Docker
#   keeps DOCKER-USER for rules it does not manage, so this is safe to repeat.
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
#   2  bad usage
#   3  iptables is not installed
#   4  the DOCKER-USER chain does not exist (Docker is not up yet)
#   5  iptables refused an insert
# ---------------------------------------------------------------------------

readonly TAG="hybrid-ai-sandbox-egress"
readonly CHAIN="DOCKER-USER"
readonly DOCKER0_GATEWAY="172.17.0.1"
readonly SANDBOX_PORT="${OPENHANDS_PORT:-3001}"
readonly IPT_LOCK_WAIT="5"

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
  printf 'sandbox-firewall: iptables is not installed; cannot apply the sandbox drops.\n' >&2
  exit 3
fi

IPT=(iptables -w "$IPT_LOCK_WAIT")

if ! "${IPT[@]}" -S "$CHAIN" >/dev/null 2>&1; then
  printf 'sandbox-firewall: the %s chain does not exist. Docker has not started yet; the boot unit hybrid-ai-firewall.service will apply these rules once it has.\n' "$CHAIN" >&2
  exit 4
fi

# External interfaces into docker0. `-i docker0` cannot be added as a second
# negative interface match (iptables allows one -i), and docker0 to docker0 is
# not a routable path, so `! -i lo` is the whole guard.
RULE_EXTERNAL_TO_DOCKER0=(! -i lo -o docker0 -m comment --comment "$TAG" -j DROP)

# The single webhook exception: the docker0 gateway on the OpenHands port.
RULE_WEBHOOK_ACCEPT=(-i docker0 -p tcp -d "$DOCKER0_GATEWAY" --dport "$SANDBOX_PORT"
                     -m comment --comment "$TAG" -j ACCEPT)

# docker0 out to any bridge that is not docker0.
RULE_DOCKER0_TO_NETWORKS=(-i docker0 ! -o docker0 -m comment --comment "$TAG" -j DROP)

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

# Insert in reverse so the final order is:
#   1. ACCEPT docker0 gateway:${SANDBOX_PORT}
#   2. DROP docker0 -> other networks
#   3. DROP external -> docker0
apply_rule "${RULE_EXTERNAL_TO_DOCKER0[@]}"
apply_rule "${RULE_DOCKER0_TO_NETWORKS[@]}"
apply_rule "${RULE_WEBHOOK_ACCEPT[@]}"

total=$(( added + present ))
if (( added == 0 )); then
  printf 'sandbox-firewall: unchanged (%d rules already present)\n' "$total"
else
  printf 'sandbox-firewall: added %d rule(s) (%d already present)\n' "$added" "$present"
fi
