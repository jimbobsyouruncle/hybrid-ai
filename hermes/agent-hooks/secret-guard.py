#!/usr/bin/env python3
"""pre_tool_call guard: treat the model as adversarial.

Blocks tool calls that would read secret material, dump the process
environment, or reach another profile's credentials.
Escalates (instead of blocking) edits to controls that grant persistence.

Fail-closed posture: unrecognised state is a BLOCK (exit 2), never an allow --
a malformed, empty or unexpected payload can never buy a tool call.

Contract: JSON on stdin -> JSON on stdout.
  {"action":"block","message":"..."} | {"action":"approve","message":"...","rule_key":"..."} | {}
Never prints file contents or secret values.
"""
import json
import os
import re
import sys

# --- secret-bearing files -------------------------------------------------
SECRET_PATH = re.compile(
    r"""(?xi)
    (?: ^|/ ) \.env (?: \.[\w.-]+ )? $        # .env, .env.bak, .env.local
    | (?: ^|/ ) [\w.-]*\.env\. [\w.-]+ $
    | /\.hermes/ \.env $
    | /\.hermes/ profiles/ [\w-]+/ \.env
    | (?: ^|/ ) auth\.json $
    | (?: ^|/ ) state\.db $
    | /proc/ \d+ /environ $
    | (?: ^|/ ) credentials (?:\.json)? $
    | (?: ^|/ ) id_(?:rsa|ed25519|ecdsa|dsa) $
    | (?: ^|/ ) \.netrc $
    | (?: ^|/ ) \.git-credentials $
    | /proxy/ (?: ca\.key | mappings\.json ) $
    """,
)

# Commands that turn a file into model-visible text.
READERS = re.compile(
    r"(?i)\b(cat|tac|head|tail|less|more|strings|xxd|od|base64|nl|sed|awk|"
    r"grep|egrep|rg|cut|jq|sort|uniq|cp|scp|rsync|tar|zip|gzip|openssl|"
    r"python3?|perl|ruby|node|source|\.|eval|exec|dd|curl|wget|nc|ncat|socat)\b"
)

# Environment / secret enumeration.
ENV_DUMP = re.compile(
    r"""(?xi)
    \bprintenv\b | ^ \s* env \s* $ | \benv\s*\| | /proc/self/environ
    | \bset\s*$ | \bexport\s*$ | \bdeclare\s+-x\b
    | \bgetenv\b | os\.environ | process\.env
    | \bhermes\b [^\n]* \b( secrets | auth | vault ) \b
    """,
)

# Tools that persist code or change controls (privilege retention).
PERSIST_TOOLS = {"cronjob_manage", "skill_manage", "memory", "delegate_task"}
CONTROL_PATH = re.compile(
    r"""(?xi)
    (?: ^|/ ) config\.yaml $
    | (?: ^|/ ) agent-hooks/
    | (?: ^|/ ) skills/ .* SKILL\.md $
    | (?: ^|/ ) plugins/
    | (?: ^|/ ) \.hermes/ cron/
    | (?: ^|/ ) systemd/ .* \.service $
    | /etc/ (?: passwd | shadow | sudoers )
    """,
)


def flatten(value, out):
    if isinstance(value, dict):
        for v in value.values():
            flatten(v, out)
    elif isinstance(value, (list, tuple)):
        for v in value:
            flatten(v, out)
    elif isinstance(value, str):
        out.append(value)


def decide(payload):
    tool = payload.get("tool_name") or ""
    args = payload.get("tool_input") or {}
    parts = []
    flatten(args, parts)

    # 1. Any tool argument naming a secret file.
    for text in parts:
        if SECRET_PATH.search(text):
            return {
                "action": "block",
                "message": (
                    "Blocked: this call targets secret material (credential or "
                    "session file). Secrets are not readable through tools. If a "
                    "task needs a credential, the service must read it directly "
                    "from its own config, not expose it to the model."
                ),
            }

    # 2. Shell-based enumeration / indirect reads.
    if tool == "terminal":
        cmd = str(args.get("command", ""))
        if ENV_DUMP.search(cmd):
            return {
                "action": "block",
                "message": (
                    "Blocked: process-environment or credential-store "
                    "enumeration is not permitted from an agent shell."
                ),
            }
        if READERS.search(cmd) and re.search(r"(?i)\.env|keepass|keyring|secret", cmd):
            return {
                "action": "block",
                "message": "Blocked: attempt to harvest secrets via shell reader.",
            }

    # 3. Persistence / control-plane changes need a human.
    if tool in PERSIST_TOOLS:
        return {
            "action": "approve",
            "message": "Control-plane change (cron/skill/memory/subagent). Confirm.",
            "rule_key": "guard:" + tool,
        }
    for text in parts:
        if CONTROL_PATH.search(text) and tool in ("write_file", "patch", "terminal"):
            return {
                "action": "approve",
                "message": "Write into a control path (config/hooks/skills). Confirm.",
                "rule_key": "guard:control-path",
            }

    return {}


def fail_closed(reason):
    """Block the call and exit 2. Names the failure class, never the payload."""
    print("guard: %s" % reason, file=sys.stderr)
    json.dump({"action": "block", "message": "Blocked: %s." % reason}, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(2)


def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        fail_closed("unparseable payload")
    if not raw.strip():
        fail_closed("unparseable payload")
    try:
        payload = json.loads(raw)
    except Exception:
        fail_closed("unparseable payload")
    if not isinstance(payload, dict):
        fail_closed("unexpected payload shape")
    if payload.get("hook_event_name", "pre_tool_call") != "pre_tool_call":
        fail_closed("unexpected event")
    tool = payload.get("tool_name")
    if not isinstance(tool, str) or not tool.strip():
        fail_closed("unexpected payload shape")
    if "tool_input" in payload and not isinstance(payload["tool_input"], dict):
        fail_closed("unexpected payload shape")
    try:
        decision = decide(payload)
    except Exception:
        fail_closed("guard error")
    json.dump(decision, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
