#!/usr/bin/env bash
# Fixture test for scripts/check-agent-context.sh.
#
# Builds a throwaway git repository under a temp dir and asserts the exit
# codes of the check script. Needs no network. The real repository is never
# modified; a copy of the check script is placed inside the temp repo.
#
# Usage:
#   bash scripts/test-check-agent-context.sh <path-to-generate.py>
#
# Exit 0 when every case passes, non-zero otherwise. Exit 2 on usage error.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: bash scripts/test-check-agent-context.sh <path-to-generate.py>" >&2
  exit 2
fi

GENERATOR="$1"
if [ ! -f "$GENERATOR" ]; then
  echo "error: generator not found: $GENERATOR" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/check-agent-context.sh"
if [ ! -f "$CHECK_SCRIPT" ]; then
  echo "error: check script not found: $CHECK_SCRIPT" >&2
  exit 2
fi

TMP_DIR=""
trap 'rm -rf "${TMP_DIR:-}"' EXIT

TMP_DIR="$(mktemp -d)"
TMP_REPO="$TMP_DIR/repo"
mkdir -p "$TMP_REPO/scripts" "$TMP_REPO/.github/workflows"

cat > "$TMP_REPO/DOCS.md" <<'EOF'
# Fixture documentation

A small markdown file used by the fixture test.
EOF

cat > "$TMP_REPO/tool.sh" <<'EOF'
#!/usr/bin/env bash
# Fixture shell tool.
set -euo pipefail

greet() {
  echo "hello"
}
EOF

cat > "$TMP_REPO/module.py" <<'EOF'
"""Fixture Python module."""


def add(a, b):
    """Return the sum of a and b."""
    return a + b
EOF

cat > "$TMP_REPO/.github/workflows/ci.yml" <<'EOF'
name: Fixture CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
EOF

cp "$CHECK_SCRIPT" "$TMP_REPO/scripts/check-agent-context.sh"

git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.name "fixture"
git -C "$TMP_REPO" config user.email "fixture@example.com"
python3 "$GENERATOR" --root "$TMP_REPO" --output-dir "$TMP_REPO" --max-bytes 20480 >/dev/null
git -C "$TMP_REPO" add -A
git -C "$TMP_REPO" commit -q -m "fixture: init"

regen_into_repo() {
  python3 "$GENERATOR" --root "$TMP_REPO" --output-dir "$TMP_REPO" --max-bytes 20480 >/dev/null
}

commit_if_staged() {
  if ! git -C "$TMP_REPO" diff --cached --quiet; then
    git -C "$TMP_REPO" commit -q -m "fixture: update"
  fi
}

restore_fresh() {
  git -C "$TMP_REPO" reset -q --hard HEAD
  git -C "$TMP_REPO" clean -qfd
  regen_into_repo
  git -C "$TMP_REPO" add -A
  commit_if_staged
}

run_check() {
  local rc=0
  bash "$TMP_REPO/scripts/check-agent-context.sh" "$1" >"$TMP_DIR/out.txt" 2>&1 || rc=$?
  echo "$rc"
}

FAILURES=0
check_case() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $name (exit $actual)"
  else
    echo "FAIL: $name (expected $expected, got $actual)"
    sed 's/^/      /' "$TMP_DIR/out.txt" || true
    FAILURES=$((FAILURES + 1))
  fi
}

# Initial fresh state.
restore_fresh

# Case 1: fresh -> 0
check_case "fresh maps" 0 "$(run_check "$GENERATOR")"

# Case 2: docs-only change -> 1
sed -i 's/^# Fixture documentation$/# Fixture documentation (edited)/' "$TMP_REPO/DOCS.md"
check_case "docs-only change" 1 "$(run_check "$GENERATOR")"
restore_fresh

# Case 3: code-only change -> 1
cat >> "$TMP_REPO/tool.sh" <<'EOF'

extra_fn() {
  echo "extra"
}
EOF
check_case "code-only change" 1 "$(run_check "$GENERATOR")"
restore_fresh

# Case 4: new workflow file -> 1
cat > "$TMP_REPO/.github/workflows/extra.yml" <<'EOF'
name: Fixture Extra
on: push
jobs:
  extra:
    runs-on: ubuntu-latest
EOF
git -C "$TMP_REPO" add .github/workflows/extra.yml
check_case "new workflow file" 1 "$(run_check "$GENERATOR")"
restore_fresh

# Case 5: missing map -> 1
rm -f "$TMP_REPO/REPO_MAP.md"
check_case "missing map" 1 "$(run_check "$GENERATOR")"
restore_fresh

# Case 6: tracked CONSOLIDATED_DOCS.md -> 1
printf '# Consolidated\n' > "$TMP_REPO/CONSOLIDATED_DOCS.md"
git -C "$TMP_REPO" add CONSOLIDATED_DOCS.md
git -C "$TMP_REPO" commit -q -m "fixture: add consolidated dump"
check_case "tracked CONSOLIDATED dump" 1 "$(run_check "$GENERATOR")"
git -C "$TMP_REPO" rm -q -f CONSOLIDATED_DOCS.md
git -C "$TMP_REPO" commit -q -m "fixture: remove consolidated dump"
restore_fresh

# Case 7: bad generator path -> 2
check_case "bad generator path" 2 "$(run_check "$TMP_DIR/does-not-exist.py")"

if [ "$FAILURES" -ne 0 ]; then
  echo "FAILURES: $FAILURES" >&2
  exit 1
fi
echo "All fixture cases passed."
exit 0
