#!/usr/bin/env bash
# Check that the checked-in agent context maps are fresh.
#
# Compares the committed REPO_MAP.md and CODE_INDEX.md at the repository root
# against a freshly generated copy. Writes nothing to the repository.
#
# Usage:
#   bash scripts/check-agent-context.sh <path-to-generate.py>
#
# Exit codes:
#   0  both maps match a fresh run (fresh)
#   1  a map is stale or missing, or a retired CONSOLIDATED_*.md is tracked
#   2  usage error, or the generator itself failed (including a size overflow)
set -euo pipefail

TMP_DIR=""
trap 'rm -rf "${TMP_DIR:-}"' EXIT

if [ "$#" -ne 1 ]; then
  echo "usage: bash scripts/check-agent-context.sh <path-to-generate.py>" >&2
  exit 2
fi

GENERATOR="$1"
if [ ! -f "$GENERATOR" ]; then
  echo "error: generator not found: $GENERATOR" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d "$REPO_ROOT/.git" ]; then
  echo "error: repository root not found at $REPO_ROOT" >&2
  exit 2
fi

REGEN_CMD="python3 $GENERATOR --root . --output-dir . --max-bytes 20480"

# Retired consolidated dumps must not remain tracked; they are removed only
# through a reviewed PR.
tracked_consolidated="$(git -C "$REPO_ROOT" ls-files | grep 'CONSOLIDATED_' || true)"
if [ -n "$tracked_consolidated" ]; then
  echo "error: retired consolidated dump(s) are still tracked:" >&2
  echo "$tracked_consolidated" >&2
  echo "These files must be removed through a reviewed PR." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
tmp_out="$TMP_DIR/agent-context"
mkdir -p "$tmp_out"

if ! python3 "$GENERATOR" --root "$REPO_ROOT" --output-dir "$tmp_out" --max-bytes 20480 >/dev/null; then
  echo "error: generator failed (this includes a size overflow over --max-bytes 20480)" >&2
  exit 2
fi

status=0
for name in REPO_MAP.md CODE_INDEX.md; do
  root_file="$REPO_ROOT/$name"
  fresh_file="$tmp_out/$name"
  if [ ! -f "$root_file" ]; then
    echo "STALE: $name is missing at the repository root." >&2
    status=1
    continue
  fi
  if ! cmp -s "$fresh_file" "$root_file"; then
    echo "STALE: $name does not match a fresh generator run." >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  echo "Regenerate the maps with:" >&2
  echo "  $REGEN_CMD" >&2
  exit 1
fi

exit 0
