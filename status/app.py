#!/usr/bin/env python3
"""
FILE: status/app.py
PURPOSE (plain English):
    A small web page at http://<your-pi>/status that shows, at a glance,
    whether everything is working. It displays the state of every service,
    tails recent error logs, and has a button that builds a diagnostic
    bundle you can download and share.

    It is meant for the moment when something is wrong and you do not want to
    SSH in and start typing commands.

WHY THIS IS WRITTEN WITH ONLY THE PYTHON STANDARD LIBRARY:
    No Flask, no FastAPI, no pip install. Fewer dependencies means a smaller
    supply-chain surface and nothing to keep patched. It runs on the stock
    python:3.12-slim image with no build step, which also means no waiting
    for a Docker build on a Raspberry Pi.

SECURITY DESIGN -- please read before modifying:

    1. THIS SERVICE HOLDS NO SECRETS.
       It is deliberately NOT given the .env file, any API key, or any
       credential. It cannot leak what it does not have. If you find yourself
       wanting to add a credential here, reconsider.

    2. IT NEVER READS USER CONTENT.
       Chat databases, uploaded documents and vector stores are measured
       (file sizes, row counts) but never opened for their contents.

    3. IT IS READ-ONLY TOWARDS DOCKER.
       Only HTTP GET requests are issued to the Docker API. There is no code
       path in this file that starts, stops, or changes a container.
       See status/README.md for the important caveat about socket access.

    4. IT SERVES NO FILES FROM DISK.
       There is no static file handler and no user-controlled path is ever
       turned into a filesystem path, so path traversal is not possible.

    5. OUTPUT IS REDACTED ANYWAY.
       Log lines pass through the same redaction patterns as
       collect-diagnostics.sh, as defence in depth, in case a credential
       was written into a log by some upstream component.

    Access control is enforced in front of this service by Caddy, which
    restricts /status to private and Tailscale addresses. This app assumes
    it is never directly exposed to the internet.

ENDPOINTS:
    GET  /status               the HTML page
    GET  /hub                  the hub landing page
    GET  /status/api           the same data as JSON
    POST /status/diagnostic    build a bundle and return it as a download
    GET  /status/healthz       liveness probe for Docker
"""

from __future__ import annotations

import html
import http.client
import json
import os
import re
import socket
import sqlite3
import threading
import time
import urllib.parse
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

# --- Configuration (all non-secret) -----------------------------------------
LISTEN_PORT = int(os.getenv("STATUS_PORT", "8088"))
LOCAL_DOMAIN = os.getenv("LOCAL_DOMAIN", "yourhostname.com")
DOCKER_SOCK = os.getenv("DOCKER_SOCKET", "/var/run/docker.sock")

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://ollama:11434")
WEBUI_URL = os.getenv("WEBUI_URL", "http://open-webui:8080")
HERMES_URL = os.getenv("HERMES_URL", "http://hermes-agent:8501")
OPENHANDS_URL = os.getenv("OPENHANDS_URL", "http://openhands:3001")

TAILSCALE_IP = os.getenv("TAILSCALE_IP", "")
VLLM_PORT = os.getenv("VLLM_PORT", "8000")
WEBUI_DATA = os.getenv("WEBUI_DATA_PATH", "/data/webui_data")
BACKUP_LOG = os.getenv("BACKUP_LOG_PATH", "/data/backup.log")
INSTALL_LOG = os.getenv("INSTALL_LOG_PATH", "/data/install.log")

WATCHED = [
    "ollama",
    "open-webui",
    "hermes-agent",
    "hybrid-ai-openhands",
    "hybrid-ai-status",
    "hybrid-ai-proxy",
]

# ---------------------------------------------------------------------------
# Redaction -- mirrors the patterns in collect-diagnostics.sh
# ---------------------------------------------------------------------------
_REDACTIONS: List[Tuple[re.Pattern, str]] = [
    (re.compile(r"rpa_[A-Za-z0-9_-]{8,}"), "<REDACTED:runpod-key>"),
    (re.compile(r"sk-or-v1-[A-Za-z0-9_-]{8,}"), "<REDACTED:openrouter-key>"),
    (re.compile(r"tskey-[A-Za-z0-9_-]{8,}"), "<REDACTED:tailscale-key>"),
    (re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"), "<REDACTED:aws-key-id>"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "<REDACTED:github-token>"),
    (re.compile(r"\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
     "<REDACTED:jwt>"),
    (re.compile(r"([Bb]earer\s+)[A-Za-z0-9._~+/=-]{12,}"), r"\1<REDACTED:token>"),
    (re.compile(r"([Aa]uthorization:\s*)\S+"), r"\1<REDACTED>"),
    (re.compile(r"((?:api[_-]?key|secret|password|passwd|token)[\"']?\s*[=:]\s*[\"']?)"
                r"[A-Za-z0-9._~+/=-]{8,}", re.I), r"\1<REDACTED>"),
    (re.compile(r"(https?://)[^:@\s/]+:[^@\s]+@"), r"\1<REDACTED:userinfo>@"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "<REDACTED:private-key>"),
    (re.compile(r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.(\d{1,3})\b"),
     r"100.x.x.\1"),
    (re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"), "<REDACTED:mac>"),
]

def _http_get(url: str, timeout: float):
    """Open only http(s) URLs; urllib would otherwise honour file://."""
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ValueError(f"refusing non-http URL scheme: {url!r}")
    return urllib.request.urlopen(url, timeout=timeout)  # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected

def redact(text: str) -> str:
    """Strip anything credential-shaped. Applied to every log line we emit."""
    for pattern, replacement in _REDACTIONS:
        text = pattern.sub(replacement, text)
    return text


# ---------------------------------------------------------------------------
# Docker API over the unix socket
# ---------------------------------------------------------------------------
class _UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: float = 5.0):
        super().__init__("localhost", timeout=timeout)
        self._socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._socket_path)
        self.sock = sock


def docker_get(path: str, timeout: float = 5.0) -> Optional[bytes]:
    """Issue a GET against the Docker API. Returns None on any failure."""
    try:
        conn = _UnixHTTPConnection(DOCKER_SOCK, timeout=timeout)
        conn.request("GET", path)
        resp = conn.getresponse()
        if resp.status != 200:
            conn.close()
            return None
        body = resp.read()
        conn.close()
        return body
    except Exception:
        return None


def demux_docker_stream(raw: bytes) -> str:
    out: List[str] = []
    i, n = 0, len(raw)
    while i + 8 <= n:
        size = int.from_bytes(raw[i + 4:i + 8], "big")
        i += 8
        if size <= 0 or i + size > n:
            break
        out.append(raw[i:i + size].decode("utf-8", errors="replace"))
        i += size
    if not out:
        return raw.decode("utf-8", errors="replace")
    return "".join(out)


def container_logs(name: str, tail: int = 40) -> List[str]:
    raw = docker_get(
        f"/containers/{name}/logs?stdout=1&stderr=1&timestamps=0&tail={tail}",
        timeout=8.0,
    )
    if raw is None:
        return []
    text = demux_docker_stream(raw)
    return [redact(line) for line in text.splitlines() if line.strip()]


# ---------------------------------------------------------------------------
# Individual probes
# ---------------------------------------------------------------------------
def probe_http(name: str, url: str, hint: str) -> Dict[str, Any]:
    started = time.monotonic()
    try:
        with _http_get(url, timeout=5) as resp:
            ms = int((time.monotonic() - started) * 1000)
            if resp.status == 200:
                return {"name": name, "state": "ok",
                        "detail": f"responding in {ms} ms", "hint": ""}
            return {"name": name, "state": "warn",
                    "detail": f"HTTP {resp.status}", "hint": hint}
    except Exception as exc:
        return {"name": name, "state": "fail",
                "detail": type(exc).__name__, "hint": hint}


def probe_containers() -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for name in WATCHED:
        raw = docker_get(f"/containers/{name}/json")
        if raw is None:
            if name in ("hybrid-ai-status", "hybrid-ai-proxy"):
                continue
            results.append({"name": name, "state": "fail",
                            "detail": "container not found",
                            "hint": "Run ./install.sh to create it."})
            continue
        try:
            info = json.loads(raw)
        except json.JSONDecodeError:
            continue

        state = info.get("State", {})
        status = state.get("Status", "unknown")
        restarts = info.get("RestartCount", 0)
        health = (state.get("Health") or {}).get("Status")

        if status == "running":
            if health in (None, "healthy"):
                level, detail = "ok", "running"
            elif health == "starting":
                level, detail = "warn", "starting up"
            else:
                level, detail = "warn", f"running but {health}"
            if restarts > 5:
                level = "warn"
                detail += f" · {restarts} restarts"
            hint = ("" if level == "ok"
                    else f"docker compose --env-file .env logs --tail 50 {name}")
        elif status == "paused":
            level, detail = "warn", "paused"
            hint = (f"A backup was interrupted. Resume with: docker unpause {name}")
        else:
            level, detail = "fail", status
            hint = "Run ./install.sh to start it."

        results.append({"name": name, "state": level,
                        "detail": detail, "hint": hint})
    return results


def probe_pod() -> Dict[str, Any]:
    if not TAILSCALE_IP:
        return {"name": "GPU pod", "state": "warn",
                "detail": "TAILSCALE_IP not configured",
                "hint": "Start the pod once, then re-run ./install.sh."}
    mesh = re.match(r"^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.", TAILSCALE_IP)
    if not mesh:
        return {"name": "GPU pod", "state": "fail",
                "detail": "address is outside the Tailscale mesh range",
                "hint": "The pipe will refuse to send prompts. Re-run ./install.sh."}
    try:
        url = f"http://{TAILSCALE_IP}:{VLLM_PORT}/v1/models"
        with _http_get(url, timeout=6) as resp:
            body = json.loads(resp.read().decode("utf-8", errors="replace"))
            models = [m.get("id", "?") for m in body.get("data", [])]
            return {"name": "GPU pod", "state": "ok",
                    "detail": f"awake · serving {models[0] if models else 'a model'}",
                    "hint": ""}
    except Exception:
        return {"name": "GPU pod", "state": "info",
                "detail": "stopped (normal — wakes on demand)", "hint": ""}


def probe_resources() -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    try:
        st = os.statvfs("/data" if os.path.isdir("/data") else "/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        pct = int((1 - free / total) * 100) if total else 0
        gb_free = free / (1024 ** 3)
        if pct >= 90:
            lvl, hint = "fail", "docker system prune -a --volumes=false"
        elif pct >= 75:
            lvl, hint = "warn", "Consider pruning images and unused models."
        else:
            lvl, hint = "ok", ""
        out.append({"name": "Disk", "state": lvl,
                    "detail": f"{pct}% used · {gb_free:.1f} GB free", "hint": hint})
    except Exception:
        pass

    try:
        info: Dict[str, int] = {}
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2:
                    info[parts[0].rstrip(":")] = int(parts[1])
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", 0)
        if total:
            pct = int((1 - avail / total) * 100)
            lvl = "fail" if pct >= 95 else "warn" if pct >= 85 else "ok"
            hint = ("Use a smaller local model — the Pi is swapping."
                    if lvl != "ok" else "")
            out.append({"name": "Memory", "state": lvl,
                        "detail": f"{pct}% used · {avail // 1024} MiB available",
                        "hint": hint})
    except Exception:
        pass
    return out


def probe_models() -> Dict[str, Any]:
    try:
        with _http_get(f"{OLLAMA_URL}/api/tags", timeout=5) as resp:
            models = json.loads(resp.read()).get("models", [])
        if not models:
            return {"name": "Local models", "state": "warn",
                    "detail": "none installed",
                    "hint": "docker exec -it ollama ollama pull llama3.2:3b"}
        names = ", ".join(m.get("name", "?") for m in models[:3])
        extra = f" (+{len(models) - 3} more)" if len(models) > 3 else ""
        return {"name": "Local models", "state": "ok",
                "detail": f"{len(models)} · {names}{extra}", "hint": ""}
    except Exception:
        return {"name": "Local models", "state": "fail",
                "detail": "cannot query Ollama",
                "hint": "Check the ollama container logs."}


def probe_backups() -> Dict[str, Any]:
    if not os.path.exists(BACKUP_LOG):
        return {"name": "Backups", "state": "warn",
                "detail": "no backup log found",
                "hint": "Configure backups by re-running ./install.sh."}
    last: Optional[str] = None
    failures = 0
    try:
        with open(BACKUP_LOG, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "event=backup_success" in line:
                    match = re.search(r"ts=(\S+)", line)
                    if match:
                        last = match.group(1)
                elif "event=backup_failed" in line:
                    failures += 1
    except OSError:
        pass

    if not last:
        return {"name": "Backups", "state": "warn",
                "detail": "no successful backup recorded",
                "hint": "Run one now: ./backup/backup.sh"}
    try:
        when = datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        hours = int((datetime.now(timezone.utc) - when).total_seconds() // 3600)
    except ValueError:
        return {"name": "Backups", "state": "warn",
                "detail": f"last success {last}", "hint": ""}

    if hours <= 36:
        lvl, hint = "ok", ""
    elif hours <= 168:
        lvl, hint = "warn", "journalctl --user -u hybrid-ai-backup.service -n 50"
    else:
        lvl, hint = "fail", "Backups are not running. Try ./backup/backup.sh manually."
    detail = f"last success {hours}h ago"
    if failures:
        detail += f" · {failures} failure(s) logged"
    return {"name": "Backups", "state": lvl, "detail": detail, "hint": hint}


def probe_data() -> Dict[str, Any]:
    db_path = os.path.join(WEBUI_DATA, "webui.db")
    if not os.path.exists(db_path):
        return {"name": "Data", "state": "warn", "detail": "webui.db not found",
                "hint": "Has Open WebUI started at least once?"}
    try:
        size_mb = os.path.getsize(db_path) / (1024 ** 2)
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
        try:
            chats = conn.execute("SELECT COUNT(*) FROM chat").fetchone()[0]
            funcs = conn.execute(
                "SELECT COUNT(*) FROM function WHERE is_active=1").fetchone()[0]
        finally:
            conn.close()
        return {"name": "Data", "state": "ok",
                "detail": f"{chats} chats · {funcs} active function(s) · {size_mb:.1f} MB",
                "hint": ""}
    except Exception as exc:
        return {"name": "Data", "state": "warn",
                "detail": f"could not read ({type(exc).__name__})",
                "hint": "Check integrity: ./doctor.sh"}


# ---------------------------------------------------------------------------
# JOB HISTORY
# ---------------------------------------------------------------------------
_JOB_EVENTS: Dict[str, Tuple[str, str]] = {
    "backup_success":          ("Backup", "ok"),
    "backup_failed":           ("Backup", "fail"),
    "backup_run_complete":     ("Backup", "ok"),
    "check_success":           ("Integrity check", "ok"),
    "check_failed":            ("Integrity check", "fail"),
    "restore_success":         ("Restore", "ok"),
    "restore_failed":          ("Restore", "fail"),
    "restore_test_success":    ("Restore rehearsal", "ok"),
    "restore_test_failed":     ("Restore rehearsal", "fail"),
    "restore_test_unverified": ("Restore rehearsal", "warn"),
    "retention_applied":       ("Retention prune", "ok"),
    "retention_failed":        ("Retention prune", "fail"),
    "install_success":         ("Install / deploy", "ok"),
    "install_failed":          ("Install / deploy", "fail"),
    "install_aborted":         ("Install / deploy", "fail"),
    "repo_initialised":        ("Backup repo init", "ok"),
    "models_repulled":         ("Model re-pull", "ok"),
}

_JOB_MAX_AGE_H: Dict[str, Optional[int]] = {
    "Backup": 36,
    "Integrity check": 24 * 45,
    "Restore rehearsal": 24 * 120,
}

_EVENT_RE = re.compile(r"^EVENT\s+ts=(\S+)\s+event=(\S+)(.*)$")


def _parse_events(path: str, limit: int = 4000) -> List[Tuple[str, str, str]]:
    if not os.path.exists(path):
        return []
    out: List[Tuple[str, str, str]] = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh.readlines()[-limit:]:
                match = _EVENT_RE.match(line.strip())
                if match:
                    out.append((match.group(1), match.group(2), match.group(3).strip()))
    except OSError:
        return []
    return out


def _age_hours(stamp: str) -> Optional[int]:
    try:
        when = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        return int((datetime.now(timezone.utc) - when).total_seconds() // 3600)
    except ValueError:
        return None


def _humanise(hours: Optional[int]) -> str:
    if hours is None:
        return "unknown"
    if hours < 1:
        return "just now"
    if hours < 24:
        return f"{hours}h ago"
    days = hours // 24
    return f"{days}d ago" if days < 14 else f"{days // 7}w ago"


def probe_jobs() -> List[Dict[str, Any]]:
    events: List[Tuple[str, str, str]] = []
    for path in (BACKUP_LOG, INSTALL_LOG):
        events.extend(_parse_events(path))
    events.sort(key=lambda item: item[0])

    latest: Dict[str, Dict[str, Any]] = {}
    for stamp, name, rest in events:
        mapped = _JOB_EVENTS.get(name)
        if not mapped:
            continue
        label, outcome = mapped
        latest[label] = {"ts": stamp, "outcome": outcome,
                         "event": name, "detail": redact(rest)[:160]}

    jobs: List[Dict[str, Any]] = []
    for label in ("Backup", "Integrity check", "Restore rehearsal",
                  "Retention prune", "Install / deploy"):
        entry = latest.get(label)
        if not entry:
            if label in ("Backup", "Integrity check"):
                jobs.append({"name": label, "state": "warn",
                             "detail": "never run",
                             "hint": "./backup/backup.sh" if label == "Backup"
                                     else "./backup/backup.sh --check"})
            continue

        hours = _age_hours(entry["ts"])
        when = _humanise(hours)
        state = {"ok": "ok", "fail": "fail", "warn": "warn"}.get(entry["outcome"], "info")
        wording = {"ok": "succeeded", "fail": "FAILED", "warn": "incomplete"}
        detail = f"{wording.get(entry['outcome'], entry['outcome'])} {when}"

        hint = ""
        if state == "fail":
            hint = "grep 'event=' backup.log | tail -20"
        else:
            max_age = _JOB_MAX_AGE_H.get(label)
            if max_age and hours is not None and hours > max_age:
                state = "warn"
                detail += " — overdue"
                hint = ("journalctl --user -u hybrid-ai-backup.service -n 50"
                        if label == "Backup" else "./backup/backup.sh --check")
        jobs.append({"name": label, "state": state, "detail": detail, "hint": hint})

    jobs.extend(_probe_timers())
    return jobs


def _probe_timers() -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    events = _parse_events(INSTALL_LOG)
    scheduled = any(name == "backup_schedule_installed" for _, name, _ in events)
    disabled = any(name in ("backup_setup_skipped", "backup_setup_declined")
                   for _, name, _ in events)
    if scheduled:
        out.append({"name": "Backup schedule", "state": "ok",
                    "detail": "nightly timer installed (03:15)", "hint": ""})
    elif disabled:
        out.append({"name": "Backup schedule", "state": "warn",
                    "detail": "not configured",
                    "hint": "Re-run ./install.sh to enable nightly backups."})
    return out


# ---------------------------------------------------------------------------
# Aggregation
# ---------------------------------------------------------------------------
def _safe(fn, fallback_name: str):
    try:
        return fn()
    except Exception as exc:
        return {"name": fallback_name, "state": "warn",
                "detail": f"check failed ({type(exc).__name__})", "hint": ""}


_CACHE: Dict[str, Any] = {"at": 0.0, "data": None}
_CACHE_TTL = float(os.getenv("STATUS_CACHE_TTL", "10"))
_CACHE_LOCK = threading.Lock()


def collect_status(force: bool = False) -> Dict[str, Any]:
    if not force and _CACHE_TTL > 0:
        with _CACHE_LOCK:
            if _CACHE["data"] is not None and (time.monotonic() - _CACHE["at"]) < _CACHE_TTL:
                return _CACHE["data"]
    data = _collect_status_uncached()
    if _CACHE_TTL > 0:
        with _CACHE_LOCK:
            _CACHE["at"] = time.monotonic()
            _CACHE["data"] = data
    return data


def _collect_status_uncached() -> Dict[str, Any]:
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = {
            "webui": pool.submit(_safe, lambda: probe_http(
                "Open WebUI", f"{WEBUI_URL}/health",
                "docker compose --env-file .env logs --tail 50 open-webui"), "Open WebUI"),
            "ollama": pool.submit(_safe, lambda: probe_http(
                "Ollama", f"{OLLAMA_URL}/api/tags",
                "docker compose --env-file .env logs --tail 50 ollama"), "Ollama"),
            "hermes": pool.submit(_safe, lambda: probe_http(
                "Hermes Agent", HERMES_URL,
                "docker compose --env-file .env logs --tail 50 hermes-agent"), "Hermes Agent"),
            "openhands": pool.submit(_safe, lambda: probe_http(
                "OpenHands", OPENHANDS_URL,
                "docker compose --env-file .env logs --tail 50 openhands"), "OpenHands"),
            "pod": pool.submit(_safe, probe_pod, "GPU pod"),
            "containers": pool.submit(_safe, probe_containers, "Containers"),
            "resources": pool.submit(_safe, probe_resources, "Resources"),
            "models": pool.submit(_safe, probe_models, "Local models"),
            "backups": pool.submit(_safe, probe_backups, "Backups"),
            "data": pool.submit(_safe, probe_data, "Data"),
            "jobs": pool.submit(_safe, probe_jobs, "Jobs"),
            "logs": pool.submit(lambda: {
                name: container_logs(name, 40) for name in ("open-webui", "ollama", "hermes-agent", "openhands")}),
            "errors": pool.submit(_safe, recent_errors, "Errors"),
        }

        def get(key, default):
            try:
                return futures[key].result(timeout=25)
            except Exception:
                return default

        services = [get("webui", {}), get("ollama", {}), get("hermes", {}), get("openhands", {}), get("pod", {})]
        containers = get("containers", [])
        resources = get("resources", [])
        checks = (containers if isinstance(containers, list) else [containers])
        checks += (resources if isinstance(resources, list) else [resources])
        checks += [get("models", {}), get("backups", {}), get("data", {})]
        jobs_result = get("jobs", [])
        jobs = jobs_result if isinstance(jobs_result, list) else [jobs_result]
        logs = get("logs", {})
        errors = get("errors", [])

    services = [item for item in services if item]
    checks = [item for item in checks if item]

    worst = "ok"
    for item in services + checks + jobs:
        if item["state"] == "fail":
            worst = "fail"
            break
        if item["state"] == "warn":
            worst = "warn"

    return {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "overall": worst,
        "services": services,
        "checks": checks,
        "jobs": jobs,
        "logs": logs if isinstance(logs, dict) else {},
        "errors": errors if isinstance(errors, list) else [],
    }


def recent_errors() -> List[Dict[str, str]]:
    pattern = re.compile(
        r"\b(error|exception|traceback|critical|fatal|refused|timeout|denied|"
        r"failed|request_failed|request_degraded)\b", re.I)
    ignore = re.compile(r"(GET /health|/api/tags|0 failed|failures=0)", re.I)
    found: List[Dict[str, str]] = []
    for name in ("open-webui", "ollama", "hermes-agent", "openhands"):
        for line in container_logs(name, 120):
            if pattern.search(line) and not ignore.search(line):
                found.append({"source": name, "line": line[:400]})
    return found[-25:]


# ---------------------------------------------------------------------------
# Diagnostic bundle
# ---------------------------------------------------------------------------
def build_diagnostic() -> str:
    data = collect_status()
    lines: List[str] = []
    add = lines.append

    add("=" * 63)
    add("  hybrid-ai DIAGNOSTIC BUNDLE (generated from the status page)")
    add("=" * 63)
    add(f"generated : {data['generated']}")
    add(f"overall   : {data['overall'].upper()}")
    add("")
    add("ABOUT THIS FILE")
    add("---------------")
    add("Diagnostics for a self-hosted AI stack: Open WebUI, Hermes, OpenHands,")
    add("and Ollama in Docker on a Raspberry Pi, with cloud inference fallback.")
    add("")
    add("This bundle contains NO credentials. Log lines are additionally passed")
    add("through a redaction filter. No chat content or documents were read.")
    add("")
    add("=" * 63)
    add("  SERVICES")
    add("=" * 63)
    for item in data["services"] + data["checks"]:
        add(f"  [{item['state'].upper():4}] {item['name']:<18} {item['detail']}")
        if item["hint"]:
            add(f"         fix: {item['hint']}")

    add("")
    add("=" * 63)
    add("  SCHEDULED JOBS (last run)")
    add("=" * 63)
    for item in data.get("jobs", []):
        add(f"  [{item['state'].upper():4}] {item['name']:<18} {item['detail']}")
        if item["hint"]:
            add(f"         fix: {item['hint']}")
    if not data.get("jobs"):
        add("  (no job history found)")

    add("")
    add("=" * 63)
    add("  RECENT ERRORS")
    add("=" * 63)
    if data["errors"]:
        for entry in data["errors"]:
            add(f"  [{entry['source']}] {entry['line']}")
    else:
        add("  (none detected)")

    for name, log_lines in data["logs"].items():
        add("")
        add("=" * 63)
        add(f"  LOG TAIL — {name}")
        add("=" * 63)
        for line in log_lines[-40:]:
            add(f"  {line}")

    add("")
    add("=" * 63)
    add("  END OF BUNDLE")
    add("=" * 63)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------
_CSS = """
:root{--bg:#0f1419;--card:#1a212b;--line:#2a3441;--fg:#e6edf3;--dim:#8b949e;
--ok:#3fb950;--warn:#d29922;--fail:#f85149;--info:#58a6ff;--accent:#58a6ff}
@media(prefers-color-scheme:light){:root{--bg:#f6f8fa;--card:#fff;--line:#d8dee4;
--fg:#1f2328;--dim:#656d76;--ok:#1a7f37;--warn:#9a6700;--fail:#cf222e;--info:#0969da}}
*{box-sizing:border-box}
body{margin:0;padding:24px;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:1000px;margin:0 auto}
header{display:flex;align-items:center;justify-content:space-between;
flex-wrap:wrap;gap:12px;margin-bottom:8px}
h1{font-size:20px;margin:0;font-weight:600}
.sub{color:var(--dim);font-size:13px;margin-bottom:20px}
.banner{padding:14px 18px;border-radius:8px;margin-bottom:20px;font-weight:600;
display:flex;align-items:center;gap:10px}
.banner.ok{background:rgba(63,185,80,.12);color:var(--ok);border:1px solid rgba(63,185,80,.3)}
.banner.warn{background:rgba(210,153,34,.12);color:var(--warn);border:1px solid rgba(210,153,34,.3)}
.banner.fail{background:rgba(248,81,73,.12);color:var(--fail);border:1px solid rgba(248,81,73,.3)}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;
padding:18px;margin-bottom:18px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);
margin:0 0 14px;font-weight:600}
.row{display:flex;align-items:flex-start;gap:12px;padding:9px 0;
border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.dot{width:9px;height:9px;border-radius:50%;margin-top:7px;flex:none}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}
.dot.fail{background:var(--fail)}.dot.info{background:var(--info)}
.nm{font-weight:500;min-width:150px}
.dt{color:var(--dim);flex:1}
.hint{display:block;margin-top:5px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
font-size:12px;color:var(--accent);word-break:break-all}
pre{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:12px;
overflow-x:auto;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
font-size:12px;line-height:1.55;margin:0;max-height:340px}
.err{color:var(--fail)}
button{background:var(--accent);color:#fff;border:0;border-radius:6px;
padding:9px 16px;font-size:14px;font-weight:500;cursor:pointer;font-family:inherit}
button:hover{filter:brightness(1.1)}
button:disabled{opacity:.6;cursor:wait}
button.ghost{background:transparent;color:var(--fg);border:1px solid var(--line)}
.btns{display:flex;gap:10px;flex-wrap:wrap}
.note{color:var(--dim);font-size:12px;margin-top:10px}
details summary{cursor:pointer;color:var(--dim);font-size:13px;margin-bottom:10px}
footer{color:var(--dim);font-size:12px;text-align:center;margin-top:28px}
a{color:var(--accent)}
nav{display:flex;gap:6px;margin-bottom:18px;flex-wrap:wrap}
nav a{padding:6px 12px;border-radius:6px;text-decoration:none;font-size:13px;
border:1px solid var(--line);color:var(--fg)}
nav a.on{background:var(--accent);color:#fff;border-color:var(--accent)}
nav a:hover:not(.on){background:var(--card)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
.tile{display:block;text-decoration:none;color:var(--fg);background:var(--card);
border:1px solid var(--line);border-radius:8px;padding:18px}
.tile:hover{border-color:var(--accent)}
.tile h3{margin:0 0 6px;font-size:15px;display:flex;align-items:center;gap:8px}
.tile p{margin:0;color:var(--dim);font-size:13px}
.tile code{font-size:12px;color:var(--accent)}
"""

_BANNER = {
    "ok": "All systems operational",
    "warn": "Running, but some checks need attention",
    "fail": "Something is broken — see the failures below",
}


def _rows(items: List[Dict[str, Any]]) -> str:
    out = []
    for item in items:
        hint = (f"<span class='hint'>{html.escape(item['hint'])}</span>"
                if item.get("hint") else "")
        out.append(
            f"<div class='row'><span class='dot {item['state']}'></span>"
            f"<span class='nm'>{html.escape(item['name'])}</span>"
            f"<span class='dt'>{html.escape(item['detail'])}{hint}</span></div>"
        )
    return "".join(out)


def render_html(data: Dict[str, Any]) -> str:
    errors = "".join(
        f"<span class='err'>[{html.escape(e['source'])}]</span> {html.escape(e['line'])}\n"
        for e in data["errors"]
    ) or "No errors detected in recent logs.\n"

    tails = "".join(
        f"<details><summary>{html.escape(name)} — last 40 lines</summary>"
        f"<pre>{html.escape(chr(10).join(lines[-40:])) or '(no output)'}</pre></details>"
        for name, lines in data["logs"].items()
    )

    return f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>hybrid-ai status</title><style>{_CSS}</style></head><body><div class="wrap">

<nav>
  <a href="/hub">Hub</a>
  <a href="/status" class="on">Status</a>
  <a href="http://{html.escape(LOCAL_DOMAIN)}">Open WebUI</a>
</nav>
<header>
  <h1>hybrid-ai status</h1>
  <div class="btns">
    <button id="dl">Download diagnostic</button>
    <button class="ghost" onclick="location.reload()">Refresh</button>
  </div>
</header>
<div class="sub">Generated {html.escape(data['generated'])} · auto-refreshes every 60s while visible</div>

<div class="banner {data['overall']}">{_BANNER[data['overall']]}</div>

<div class="card"><h2>Services</h2>{_rows(data['services'])}</div>
<div class="card"><h2>System checks</h2>{_rows(data['checks'])}</div>

<div class="card"><h2>Scheduled jobs — last run</h2>{_rows(data['jobs'])}
  <div class="note">Parsed from structured event logs written by
  <code>backup.sh</code> and <code>install.sh</code>.</div>
</div>

<div class="card"><h2>Recent errors</h2>
  <pre>{errors}</pre>
  <div class="note">Filtered from recent log lines of each service.</div>
</div>

<div class="card"><h2>Log tails</h2>{tails}</div>

<div class="card"><h2>Diagnostics</h2>
  <p style="margin:0 0 12px">Download a shareable bundle of the status above,
  recent errors, and log tails. Contains no credentials or chat content.</p>
  <div class="btns"><button id="dl2">Download diagnostic bundle</button></div>
</div>

<footer>hybrid-ai · <a href="/hub">Hub</a> · <a href="http://{html.escape(LOCAL_DOMAIN)}">Open WebUI</a></footer>
</div>
<script>
async function download(btn){{
  const original = btn.textContent;
  btn.disabled = true; btn.textContent = 'Building…';
  try {{
    const resp = await fetch('/status/diagnostic', {{method:'POST'}});
    if(!resp.ok) throw new Error('HTTP ' + resp.status);
    const blob = await resp.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const stamp = new Date().toISOString().replace(/[:.]/g,'-').slice(0,19);
    a.href = url; a.download = 'hybrid-ai-diagnostic-' + stamp + '.txt';
    document.body.appendChild(a); a.click(); a.remove();
    URL.revokeObjectURL(url);
    btn.textContent = 'Downloaded';
  }} catch (err) {{
    btn.textContent = 'Failed — see console';
    console.error(err);
  }}
  setTimeout(() => {{ btn.disabled = false; btn.textContent = original; }}, 2500);
}}
document.getElementById('dl').onclick  = e => download(e.target);
document.getElementById('dl2').onclick = e => download(e.target);

let timer = null;
function schedule(){{
  clearInterval(timer);
  timer = setInterval(() => {{
    if(document.hidden) return;
    if(document.querySelector('button:disabled')) return;
    location.reload();
  }}, 60000);
}}
schedule();
document.addEventListener('visibilitychange', () => {{ if(!document.hidden) schedule(); }});
</script></body></html>"""


def render_hub(data: Dict[str, Any]) -> str:
    """
    The landing page at http://<LOCAL_DOMAIN>/hub — directory of available services
    rendered with live status indicators and clickable subdomain URLs.
    """
    by_name = {item["name"]: item for item in data["services"] + data["checks"]}

    def badge(name: str) -> str:
        state = by_name.get(name, {}).get("state", "info")
        detail = by_name.get(name, {}).get("detail", "")
        return (f"<span class='dot {state}'></span>"
                f"<span style='color:var(--dim);font-size:13px'>{html.escape(detail)}</span>")

    tiles = [
        (f"http://{LOCAL_DOMAIN}", "Open WebUI", "Chat, local RAG, and document workspace.",
         badge("Open WebUI")),
        ("http://127.0.0.1:3001", "OpenHands", "Available through the authenticated SSH tunnel.",
         badge("OpenHands")),
        (f"http://hermes.{LOCAL_DOMAIN}", "Hermes Agent", "System orchestrator & memory engine.",
         badge("Hermes Agent")),
        (f"http://status.{LOCAL_DOMAIN}", "Status Dashboard", "System diagnostics, health checks, and logs.",
         f"<span class='dot {data['overall']}'></span>"
         f"<span style='color:var(--dim);font-size:13px'>{_BANNER[data['overall']]}</span>"),
    ]

    cards = "".join(
        f"<a class='tile' href='{href}' target='_blank'><h3>{html.escape(title)}</h3>"
        f"<p>{html.escape(desc)}</p><p style='margin-top:10px'>{state}</p>"
        f"<code style='display:block;margin-top:8px'>{html.escape(href)}</code></a>"
        for href, title, desc, state in tiles
    )

    return f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>hybrid-ai hub</title><style>{_CSS}</style></head><body><div class="wrap">
<nav>
  <a href="/hub" class="on">Hub</a>
  <a href="http://status.{html.escape(LOCAL_DOMAIN)}">Status</a>
  <a href="http://{html.escape(LOCAL_DOMAIN)}">Open WebUI</a>
</nav>
<header><h1>hybrid-ai service hub</h1></header>
<div class="sub">Local Domain: <strong>{html.escape(LOCAL_DOMAIN)}</strong> · {html.escape(data['generated'])}</div>
<div class="banner {data['overall']}">{_BANNER[data['overall']]}</div>
<div class="tiles">{cards}</div>
<div class="card" style="margin-top:18px"><h2>Addresses</h2>
  <div class="row"><span class="nm">Open WebUI</span><span class="dt"><code>http://{html.escape(LOCAL_DOMAIN)}</code></span></div>
  <div class="row"><span class="nm">OpenHands</span><span class="dt"><code>http://127.0.0.1:3001 via SSH tunnel</code></span></div>
  <div class="row"><span class="nm">Hermes Agent</span><span class="dt"><code>http://hermes.{html.escape(LOCAL_DOMAIN)}</code></span></div>
  <div class="row"><span class="nm">Status Page</span><span class="dt"><code>http://status.{html.escape(LOCAL_DOMAIN)}</code></span></div>
  <div class="row"><span class="nm">Ollama API</span><span class="dt"><code>http://{html.escape(LOCAL_DOMAIN)}/ollama/</code></span></div>
  <div class="row"><span class="nm">Health Summary</span><span class="dt"><code>http://{html.escape(LOCAL_DOMAIN)}/health</code></span></div>
</div>
<footer>hybrid-ai</footer>
</div></body></html>"""


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "hybrid-ai-status"
    sys_version = ""

    def log_message(self, fmt: str, *args: Any) -> None:
        if os.getenv("STATUS_ACCESS_LOG", "0") == "1":
            super().log_message(fmt, *args)

    def _send(self, code: int, body: bytes, ctype: str,
              extra: Optional[Dict[str, str]] = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; "
                         "script-src 'unsafe-inline'; connect-src 'self'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/hub"
        if path == "/status/healthz":
            self._send(200, b"ok", "text/plain; charset=utf-8")
        elif path == "/status/health-summary":
            try:
                overall = collect_status()["overall"]
            except Exception:
                overall = "fail"
            code = 200 if overall == "ok" else 503
            self._send(code, overall.encode(), "text/plain; charset=utf-8")
        elif path == "/status/api":
            body = json.dumps(collect_status(), indent=2).encode()
            self._send(200, body, "application/json; charset=utf-8")
        elif path in ("/hub", "/"):
            try:
                body = render_hub(collect_status()).encode()
                self._send(200, body, "text/html; charset=utf-8")
            except Exception as exc:
                msg = (f"<h1>Hub error</h1><pre>{html.escape(type(exc).__name__)}: "
                       f"{html.escape(redact(str(exc)))}</pre>").encode()
                self._send(500, msg, "text/html; charset=utf-8")
        elif path == "/status":
            try:
                body = render_html(collect_status()).encode()
                self._send(200, body, "text/html; charset=utf-8")
            except Exception as exc:
                msg = (f"<h1>Status page error</h1><pre>{html.escape(type(exc).__name__)}: "
                       f"{html.escape(redact(str(exc)))}</pre>").encode()
                self._send(500, msg, "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/status/diagnostic":
            try:
                body = build_diagnostic().encode()
            except Exception as exc:
                body = f"Diagnostic generation failed: {type(exc).__name__}".encode()
                self._send(500, body, "text/plain; charset=utf-8")
                return
            stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            self._send(200, body, "text/plain; charset=utf-8",
                       {"Content-Disposition":
                        f'attachment; filename="hybrid-ai-diagnostic-{stamp}.txt"'})
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    server.daemon_threads = True
    print(f"[status] listening on :{LISTEN_PORT}", flush=True)
    print(f"[status] watching docker socket {DOCKER_SOCK}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
