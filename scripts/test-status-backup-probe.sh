#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/test-status-backup-probe.sh
# PURPOSE (plain English):
#   Thin wrapper so the CI job can run the Backups-tile fixture test in the
#   same `run: bash scripts/test-*.sh` style as every other suite. The test
#   itself (status/test_backup_probe.py) is offline: fixture log files in a
#   scratch directory, no Docker, no network, no root.
#
#   WHY THE TILE IS PINNED: the status mount now derives its source from
#   BACKUP_LOG, the same path the backup units write. This suite keeps the
#   reader's half of that contract honest -- an absent, empty or unreadable log
#   degrades to a warn instead of raising, and a fresh success genuinely shows
#   as `Backup: ok`.
#
# USAGE:
#   bash scripts/test-status-backup-probe.sh
#
# EXIT CODES:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  python3 is missing
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 2; }
exec python3 "${REPO}/status/test_backup_probe.py"
