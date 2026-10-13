#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# FILE: scripts/check-git-remotes.sh
# PURPOSE (plain English):
#   Report any agent clone whose git config embeds a credential in a remote
#   URL. OpenHands' app-server clones with `https://<token>@github.com/...`
#   and git stores that URL in project/<repo>/.git/config. The token is
#   therefore written to disk in plain text. Until the agent-server upgrade
#   (>= 1.37.0, tracked separately) stops doing this, detecting it is the
#   control.
#
#   This script is DETECTION ONLY. It never rewrites, strips or re-clones a
#   remote, and it never modifies a file.
#
# WHAT IT FLAGS:
#   - remote.*.url or remote.*.pushurl whose value is a scheme URL carrying
#     userinfo (scheme://...@host), e.g. https://ghp_xxx@github.com/org/r.git
#   - url.<base>.insteadOf or url.<base>.pushInsteadOf where <base> carries
#     userinfo, e.g. url.https://ghp_xxx@github.com/.insteadOf
#   SSH forms are NOT flagged: `git@host:path` has no scheme, and
#   `ssh://git@host/...` is only userinfo, not a credential in the URL.
#
# OUTPUT:
#   One line per finding, exactly `<path>: <config key>`. The URL, the
#   userinfo and any part of a token never reach stdout or stderr. For an
#   url.<base>.* key the credential lives in the key itself, so the key is
#   reported with its base generalised to `url.<base>.insteadof`: the URL,
#   userinfo and token are never printed. A single token-free note about
#   unreadable files may go to stderr.
#
# USAGE:
#   scripts/check-git-remotes.sh <root> [<root>...]
#
# EXIT CODES:
#   0  every config read and clean  (no findings)
#   1  one or more findings
#   2  usage error, or a file the script cannot read
# ---------------------------------------------------------------------------
set -uo pipefail   # deliberately NOT -e: one bad file must not stop the scan

usage() {
  # The help text lives in the header comment (lines 2-38); print it without
  # leaking anything. Used on a usage error.
  sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if (( $# == 0 )); then
  usage >&2
  exit 2
fi

for root in "$@"; do
  case "$root" in
    -h|--help) usage; exit 0 ;;
    -*) echo "check-git-remotes.sh: unknown option: $root" >&2; usage >&2; exit 2 ;;
  esac
done

findings=0
unreadable=0

# True when a scheme URL (scheme://...) carries userinfo in its authority.
# The value is inspected here and never echoed. SSH schemes are excluded:
# `ssh://git@host/...` carries a username, not a credential, and the spec
# says SSH forms are not findings.
scheme_has_userinfo() {
  local v="$1"
  [[ "$v" == *://* ]] || return 1
  local scheme="${v%%://*}"
  local after="${v#*://}"
  local authority="${after%%/*}"
  case "$scheme" in
    ssh|ssh+git|git+ssh) return 1 ;;
  esac
  [[ "$authority" == *@* ]]
}

# Defensive: a normal config key never contains userinfo, but a hostile
# section name could smuggle one in (e.g. a remote named with a URL). If a
# scheme://userinfo@... run appears in a key, drop the userinfo before it can
# be printed. This is why report() only ever prints path and key.
sanitize_key() {
  local k="$1"
  if [[ "$k" == *://*@* ]]; then
    local pre="${k%%://*}"
    local rest="${k#*://}"
    local hostpart="${rest#*@}"   # everything after the FIRST @
    k="${pre}://<redacted>@${hostpart}"
  fi
  printf '%s' "$k"
}

# Report one finding. Emits the path and the sanitized config key only.
report() {
  printf '%s: %s\n' "$1" "$(sanitize_key "$2")"
  findings=$(( findings + 1 ))
}

# Note an unreadable/malformed file by path alone, never by contents.
note_unreadable() {
  printf '%s: unreadable\n' "$1"
  unreadable=$(( unreadable + 1 ))
}

# Scan one .git/config file. Never echoes the value.
scan_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  if [[ ! -r "$cfg" ]]; then
    note_unreadable "$cfg"
    return 0
  fi

  # Confirm the file parses. A malformed file makes git fail; git names only
  # the file on its parse error, and we replace that stderr with our own
  # token-free line regardless. Output is discarded here.
  if ! git config --file "$cfg" --list >/dev/null 2>&1; then
    note_unreadable "$cfg"
    return 0
  fi

  # Re-read as NUL-separated "key\nvalue\0" records via process substitution.
  # A shell variable would drop the NUL bytes, so the stream is read directly.
  local rec key value base suffix
  while IFS= read -r -d '' rec; do
    key="${rec%%$'\n'*}"
    value="${rec#*$'\n'}"

    case "$key" in
      remote.*.url|remote.*.pushurl)
        if scheme_has_userinfo "$value"; then
          report "$cfg" "$key"
        fi
        ;;
      url.*.insteadof|url.*.pushinsteadof)
        # git lower-cases the key but preserves any userinfo in <base>.
        # Reconstruct <base>, test it, and report a generalised key so the
        # credential in the key itself is never printed.
        base="${key#url.}"
        if [[ "$base" == *".pushinsteadof" ]]; then
          base="${base%.pushinsteadof}"; suffix="pushinsteadof"
        else
          base="${base%.insteadof}";     suffix="insteadof"
        fi
        if scheme_has_userinfo "$base"; then
          report "$cfg" "url.<base>.${suffix}"
        fi
        ;;
    esac
  done < <(git config --file "$cfg" --list -z 2>/dev/null)
}

# Collect every .git/config under each root: maxdepth 4, symlinks never
# followed (-P). A plain file argument is treated as a git config.
mapfile -t configs < <(
  for root in "$@"; do
    if [[ -d "$root" ]]; then
      find -P "$root" -maxdepth 4 -type f -path '*/.git/config' -print0
    elif [[ -f "$root" ]]; then
      printf '%s\0' "$root"
    fi
  done
)

for cfg in "${configs[@]}"; do
  scan_config "$cfg"
done

if (( unreadable > 0 )); then
  printf 'check-git-remotes.sh: %d unreadable config file(s)\n' "$unreadable" >&2
  exit 2
fi

if (( findings > 0 )); then
  exit 1
fi

exit 0
