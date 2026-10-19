#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/deploy-image-gate.sh
# PURPOSE (plain English):
#   Fail-closed pre-flight gate for the deploy workflow. Before the runner
#   triggers the remote install, this script waits until the sandbox image the
#   host will pull actually exists on GHCR. Without it, a deploy could race the
#   image-publishing workflow and start `install.sh` while the image's manifest
#   is still missing, which is what produced the "OpenHands workspace ACLs not
#   applied" warning on the 0b4cb53 deploy (its `docker pull` failed, so the
#   ACL step was skipped).
#
#   The tag is resolved from install.sh's STEP 8 defaults
#   (OPENHANDS_AGENT_IMAGE_REPOSITORY / OPENHANDS_AGENT_IMAGE_TAG), which is the
#   repository default pin written by install.sh. It is NOT the host's live
#   value: a host that customised OPENHANDS_AGENT_IMAGE_TAG in `.env` is not
#   covered by this gate. That is a known limitation, stated here on purpose.
#
#   The probe is anonymous. It fetches a pull-scoped token from GHCR and asks
#   for the manifest, exactly as a pull client would. No credential is read,
#   stored or printed, and the token value never leaves the shell variable.
#
#   FAIL CLOSED. It exits 0 only on HTTP 200. A timeout, a probe error or any
#   unexpected HTTP status exits non-zero, so the deploy stops. It never falls
#   back to a stock image and never proceeds on a guess.
#
# USAGE:
#   scripts/deploy-image-gate.sh
#
# ENVIRONMENT (all optional; defaults suit the deploy workflow):
#   GATE_INSTALL_SH         path to install.sh (fixtures point this elsewhere)
#   GATE_TIMEOUT_SECONDS    total wait budget        (default 2100, ~35 min)
#   GATE_INTERVAL_SECONDS   delay between probes     (default 30)
#   GATE_REGISTRY           registry host            (default ghcr.io)
#   GATE_PACKAGE            override the resolved `owner/name` package path
#   GATE_TAG                override the resolved tag
#
# EXIT CODES:
#   0  the manifest answers HTTP 200
#   1  timeout, probe error, unresolvable pin, or unexpected HTTP status
#   2  usage error (bad environment value)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPTPATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPTPATH/.." && pwd)"

INSTALL_SH="${GATE_INSTALL_SH:-$REPO_ROOT/install.sh}"
TIMEOUT_SECONDS="${GATE_TIMEOUT_SECONDS:-2100}"
INTERVAL_SECONDS="${GATE_INTERVAL_SECONDS:-30}"
REGISTRY="${GATE_REGISTRY:-ghcr.io}"

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "error: GATE_TIMEOUT_SECONDS must be a non-negative integer, got '$TIMEOUT_SECONDS'" >&2; exit 2 ;;
esac
case "$INTERVAL_SECONDS" in
  ''|*[!0-9]*|0) echo "error: GATE_INTERVAL_SECONDS must be a positive integer, got '$INTERVAL_SECONDS'" >&2; exit 2 ;;
esac

if [ ! -f "$INSTALL_SH" ]; then
  echo "error: install.sh not found at $INSTALL_SH" >&2
  exit 1
fi

# Pull the `default:` value out of a `${VAR:-default}` pin line in install.sh.
resolve_pin() {
  local var="$1" line default
  line="$(grep -E "^${var}=" "$INSTALL_SH" | head -n1 || true)"
  [ -n "$line" ] || return 1
  default="$(printf '%s\n' "$line" | sed -n 's/.*:-\([^}]*\)}.*/\1/p')"
  [ -n "$default" ] || return 1
  printf '%s' "$default"
}

REPOSITORY="${GATE_PACKAGE:-}"
TAG="${GATE_TAG:-}"
if [ -z "$REPOSITORY" ]; then
  REPOSITORY="$(resolve_pin OPENHANDS_AGENT_IMAGE_REPOSITORY)" || {
    echo "error: could not resolve OPENHANDS_AGENT_IMAGE_REPOSITORY from $INSTALL_SH" >&2
    exit 1
  }
fi
if [ -z "$TAG" ]; then
  TAG="$(resolve_pin OPENHANDS_AGENT_IMAGE_TAG)" || {
    echo "error: could not resolve OPENHANDS_AGENT_IMAGE_TAG from $INSTALL_SH" >&2
    exit 1
  }
fi

# The gate speaks the GHCR registry API, so the package path has no host prefix
# and the registry must be GHCR. Anything else is a configuration error.
case "$REPOSITORY" in
  "$REGISTRY"/*) PACKAGE="${REPOSITORY#"$REGISTRY"/}" ;;
  */*) echo "error: repository '$REPOSITORY' is not on $REGISTRY; refusing to probe." >&2; exit 1 ;;
  *) echo "error: repository '$REPOSITORY' is not a registry-qualified name; refusing to probe." >&2; exit 1 ;;
esac

echo "deploy-image-gate: waiting for ${REPOSITORY}:${TAG}"
echo "deploy-image-gate: budget ${TIMEOUT_SECONDS}s, probing every ${INTERVAL_SECONDS}s"

# Returns the HTTP status on stdout, or non-zero on a probe error (transport
# failure, missing token, malformed response). The bearer token stays in a
# local variable and is never printed.
probe_manifest() {
  local token code
  token="$(curl -fsS --max-time 20 \
    "https://${REGISTRY}/token?scope=repository:${PACKAGE}:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')" || return 1
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://${REGISTRY}/v2/${PACKAGE}/manifests/${TAG}")" || return 1
  printf '%s' "$code"
}

deadline=$(( SECONDS + TIMEOUT_SECONDS ))
attempt=0
while :; do
  attempt=$(( attempt + 1 ))

  if ! code="$(probe_manifest)"; then
    echo "deploy-image-gate: probe error on attempt ${attempt} (transport or token failure)." >&2
    echo "deploy-image-gate: refusing to proceed; the deploy must not run without a confirmed image." >&2
    exit 1
  fi

  case "$code" in
    200)
      echo "deploy-image-gate: ${REPOSITORY}:${TAG} is published (HTTP 200). Proceeding."
      exit 0
      ;;
    404)
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "deploy-image-gate: timed out after ${TIMEOUT_SECONDS}s waiting for ${REPOSITORY}:${TAG} (last HTTP ${code})." >&2
        echo "deploy-image-gate: the image was never published; refusing to deploy against a missing image." >&2
        exit 1
      fi
      echo "deploy-image-gate: attempt ${attempt}: not published yet (HTTP 404); retrying in ${INTERVAL_SECONDS}s."
      sleep "$INTERVAL_SECONDS"
      ;;
    *)
      echo "deploy-image-gate: unexpected HTTP ${code} probing ${REPOSITORY}:${TAG} on attempt ${attempt}." >&2
      echo "deploy-image-gate: refusing to proceed on an unexpected registry response." >&2
      exit 1
      ;;
  esac
done
