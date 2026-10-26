#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/lib/tailscale-resolve.sh
# PURPOSE (plain English):
#   The ONE place that turns the GPU pod's MagicDNS NAME into the IPv4 address
#   a probe needs. Source it; do not run it.
#
# WHY A NAME AND NOT A STORED ADDRESS:
#   The deployment used to record the pod's mesh address in .env as
#   TAILSCALE_IP. A RunPod worker's address changes whenever the pod is
#   recreated, so the stored copy silently went stale and every consumer kept
#   dialling a peer that was no longer there. The single stored value is now the
#   MagicDNS name (RUNPOD_HOST). It is resolved HERE, at use time, so a consumer
#   always dials the address the tailnet answers with right now.
#
# WHAT THIS PROVIDES:
#   resolve_mesh_address <name>   print the resolved IPv4 on stdout, and return
#       0  resolved  -- exactly one IPv4 was printed
#       1  UNRESOLVED -- a resolver ran and the name did not resolve
#       2  UNAVAILABLE -- no resolver could answer at all (neither the
#          `tailscale` CLI nor `getent` is installed, or both failed to run)
#   mesh_range_ok <ip>            return 0 when the IPv4 is inside
#                                 [IP_ADDRESS]/10 (the tailnet mesh range)
#
# RESOLUTION ORDER (the same pattern .github/workflows/deploy.yml uses):
#   1. tailscale ip -4 <name>        first line that is a 100.x address
#   2. getent ahostsv4 <name>        the first field of the first line
#   The tailscale CLI is authoritative because it answers from the local
#   tailnet state, so it works even when the host resolver has no MagicDNS.
#   getent is the fallback for a host whose resolver does answer.
#
# SECURITY: this file never prints the name or the address in a diagnostic. A
#   caller decides what to show; the helper only answers on stdout.
# ---------------------------------------------------------------------------

# Match an IPv4 inside the tailnet mesh range 100.64.0.0/10, i.e. a 100.x
# address whose second octet is 64-127. This is the SAME octet test the rest of
# the repository uses (deploy.yml, doctor.sh, status/app.py, the Open WebUI
# pipe); keep it in step with them.
_mesh_octet_re='^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.'

# True (0) when $1 is an IPv4 address inside [IP_ADDRESS]/10.
mesh_range_ok() {
  local ip="${1:-}"
  [[ "$ip" =~ $_mesh_octet_re ]]
}

# Resolve a MagicDNS name to one IPv4 address. Prints the address on stdout and
# returns 0/1/2 as documented above. Never echoes the name.
resolve_mesh_address() {
  local name="${1:-}" out="" line="" ran=0 rc=0

  [[ -n "$name" ]] || return 1

  if command -v tailscale >/dev/null 2>&1; then
    out="$(tailscale ip -4 "$name" 2>/dev/null)"; rc=$?
    # 126/127 mean the CLI could not be executed at all, so it resolved
    # nothing and it is not a resolver that answered.
    (( rc == 126 || rc == 127 )) || ran=1
    if (( rc == 0 )); then
      while IFS= read -r line; do
        line="${line//[[:space:]]/}"
        [[ "$line" =~ ^100\. ]] && { printf '%s\n' "$line"; return 0; }
      done <<< "$out"
      # Any IPv4 the CLI volunteers is better than nothing: the caller
      # validates the range, so an out-of-mesh answer still reaches it and
      # fails there as a range error rather than a resolution error.
      while IFS= read -r line; do
        line="${line//[[:space:]]/}"
        if [[ "$line" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
          printf '%s\n' "$line"; return 0
        fi
      done <<< "$out"
    fi
  fi

  if command -v getent >/dev/null 2>&1; then
    out="$(getent ahostsv4 "$name" 2>/dev/null)"; rc=$?
    (( rc == 126 || rc == 127 )) || ran=1
    if (( rc == 0 )); then
      line="${out%%$'\n'*}"
      line="${line%%[[:space:]]*}"
      if [[ -n "$line" ]]; then
        printf '%s\n' "$line"; return 0
      fi
    fi
  fi

  # A resolver existed, so "the name did not resolve" is a real answer. With no
  # resolver at all there is nothing to say about the name.
  (( ran )) && return 1
  return 2
}
