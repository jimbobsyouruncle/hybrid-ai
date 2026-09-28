"""
title: RunPod vLLM (Tailscale, on-demand)
author: hybrid-ai
version: 1.1.0
license: MIT
description: >
    Routes prompts to a vLLM server on a RunPod GPU pod over a Tailscale mesh
    address. Resumes the pod on demand, waits for the model to warm, streams
    OpenAI-compatible chunks back, and lets the pod's own idle watchdog handle
    shutdown. No prompt content is logged anywhere in this module.
requirements: httpx
"""
# ===========================================================================
#  GENERATED FILE -- DO NOT EDIT
#
#  Built by openwebui/build_pipe.py from:
#      openwebui/runpod_core.py      wake / validate / poll / stream
#      openwebui/pipe_wrapper.py    Open WebUI presentation layer
#
#  Edit those files and re-run:  python3 openwebui/build_pipe.py
#  Editing this file directly means your change is lost on the next build.
#
#  This concatenation exists because Open WebUI functions are pasted as a
#  single file and cannot import sibling modules.
# ===========================================================================
# ---------------------------------------------------------------------------
# FILE: openwebui/runpod_core.py
# PURPOSE (plain English):
#   Everything needed to talk to a vLLM server on an on-demand RunPod GPU pod,
#   with NO dependency on Open WebUI.
#
#   This file knows how to:
#     1. VALIDATE  -- confirm a destination is inside the Tailscale mesh, and
#        refuse to transmit if it is not.
#     2. WAKE      -- ask RunPod to resume a pod that is normally switched off.
#     3. POLL      -- wait until vLLM reports the model is loaded and ready.
#     4. STREAM    -- send a chat-completions request and yield events.
#
#   It knows nothing about chat windows, model dropdowns, valves, or status
#   emitters. That separation is deliberate.
#
# WHY THIS FILE EXISTS SEPARATELY:
#   This logic has one consumer today (the Open WebUI pipe) and will soon have
#   two: a waking shim that fronts every RunPod endpoint so other tools can
#   reach a pod that is currently stopped.
#
#   If it stayed tangled with the Open WebUI Pipe class, building that shim
#   would mean rewriting it -- and then maintaining two implementations of pod
#   lifecycle that drift apart.
#
#   THE RULE: nothing in this file may import or reference Open WebUI, pydantic
#   valves, or event emitters. Progress is reported through the on_status
#   callback, which any caller can implement however it likes.
#
# HOW IT IS DEPLOYED:
#   Open WebUI functions are pasted into the UI as a SINGLE file, so a pipe
#   cannot import this module at runtime. build_pipe.py concatenates this file
#   with pipe_wrapper.py to produce the pasteable runpod_pipe.py.
#
# PRIVACY:
#   Prompts travel only over Tailscale (100.x.x.x, WireGuard-encrypted). Every
#   log line here is metadata only -- timings, status, HTTP codes, counts.
#   Never add message content to a log line.
# ---------------------------------------------------------------------------
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from dataclasses import dataclass
from typing import Any, AsyncGenerator, Awaitable, Callable, Dict, List, Optional

import httpx

# RunPod's control API. Used to start and query pods -- never to send prompts.
RUNPOD_GRAPHQL = "https://api.runpod.io/graphql"

# Credential shapes that must never reach a chat window or a log line, even
# inside an exception message. Some libraries helpfully include the full
# request (headers and all) in their error text.
_SECRET_PATTERNS = [
    re.compile(r"rpa_[A-Za-z0-9]+"),                    # RunPod API key
    re.compile(r"tskey-[A-Za-z0-9\-]+"),                # Tailscale auth key
    # Authorization headers. The optional "Bearer " must be consumed TOGETHER
    # with the token that follows it. An earlier version of this pattern ended
    # at \S+, which matched the word "Bearer" and stopped -- leaving the actual
    # credential in the string. Order matters: this must precede the bare rule.
    re.compile(r"(?i)authorization\s*[:=]\s*(bearer\s+)?\S+"),
    re.compile(r"(?i)bearer\s+\S+"),
    re.compile(r"(?i)api[_-]?key\s*[:=]\s*\S+"),
]


def scrub(text: str) -> str:
    """Replace anything credential-shaped with [REDACTED]."""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    return text


# ---------------------------------------------------------------------------
# OUTCOME LOGGING
#   Every request ends in exactly one of three states, and all three are
#   recorded: success, degraded (partial answer), failure. Without this, a
#   report of "it was slow yesterday" leaves nothing to investigate -- the chat
#   UI keeps no record of why a request behaved the way it did.
#
#   PRIVACY: metadata only -- durations, counts, state names, HTTP codes.
#   Never log message content. Every value additionally passes through scrub()
#   as a second line of defence, in case an exception carries a credential.
# ---------------------------------------------------------------------------
logger = logging.getLogger("hybrid_ai.runpod_core")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s [runpod_core] %(message)s")
    )
    logger.addHandler(_handler)
    logger.setLevel(os.getenv("PIPE_LOG_LEVEL", "INFO").upper())
    # Do not also hand these records to the root logger, which may be
    # configured more verbosely than we want for something on a privacy path.
    logger.propagate = False


def log_event(level: int, event: str, **fields: Any) -> None:
    """Emit one structured, metadata-only line: event=<name> key=value ..."""
    parts = [f"event={event}"]
    for key, value in fields.items():
        parts.append(f"{key}={scrub(str(value))}")
    logger.log(level, " ".join(parts))


# ---------------------------------------------------------------------------
# CONFIGURATION
#   A plain dataclass, not a pydantic model. The Open WebUI wrapper builds one
#   from its Valves; a shim would build one per endpoint from its own config.
#   Neither framework's types leak in here.
# ---------------------------------------------------------------------------
@dataclass
class EndpointConfig:
    """Everything needed to reach one RunPod vLLM endpoint."""

    runpod_api_key: str = ""
    runpod_pod_id: str = ""
    runpod_host: str = ""
    vllm_port: int = 8000
    model_name: str = ""
    # Peer hostname this endpoint registers under on the tailnet. Used only to
    # make error messages actionable.
    peer_hostname: str = "runpod-worker"
    warmup_timeout: int = 600
    poll_interval: float = 5.0
    request_timeout: int = 900
    max_tokens: int = 4096
    # Refuse to send prompts to any address outside 100.64.0.0/10.
    enforce_mesh_only: bool = True


# Progress callback. Any caller implements this however it likes: the pipe
# forwards to Open WebUI's event emitter, a shim would log or update state.
StatusCallback = Callable[[str, bool], Awaitable[None]]


async def _noop_status(_description: str, _done: bool = False) -> None:
    """Default callback for callers that do not care about progress."""
    return None


def is_mesh_address(ip: str) -> bool:
    """
    Return True only if the address is inside 100.64.0.0/10, the range
    Tailscale uses for private mesh addresses.

    WHY THIS MATTERS: if the address were ever wrong -- a typo, a stale value,
    a pasted public address -- prompts would cross the open internet
    unencrypted. This check makes that impossible.

    The range covers 100.64.x.x through 100.127.x.x.

    Parsing is deliberately strict. int() accepts surrounding whitespace and a
    leading sign, so "  100.64.0.1" and "+100.64.0.1" would otherwise pass and
    then be used to build a URL -- a value that LOOKED validated but was never
    really the address we thought it was. On a control whose entire job is
    keeping prompts inside the tunnel, permissive parsing is not a kindness.
    """
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    if not all(p.isdigit() for p in parts):
        return False
    try:
        octets = [int(p) for p in parts]
    except ValueError:
        return False
    if any(o < 0 or o > 255 for o in octets):
        return False
    return octets[0] == 100 and 64 <= octets[1] <= 127


class RunPodEndpoint:
    """
    One on-demand vLLM endpoint on a RunPod GPU pod.

    Framework-agnostic. Owns validation, wake, readiness polling, and
    streaming. Shutdown is NOT handled here -- the pod turns itself off via the
    idle watchdog in runpod/start.sh.
    """

    def __init__(self, config: EndpointConfig) -> None:
        self.config = config

        # After a successful readiness check we skip re-checking for 60
        # seconds, avoiding a pointless round trip on every message during an
        # active conversation.
        self._warm_until: float = 0.0

        # AVAILABILITY: if two callers arrive at once, both would try to resume
        # the pod and both would poll. A lock serialises the wake-and-warm
        # phase so only one does the work; the second waits, then finds it warm.
        #
        # Created lazily rather than here, because an asyncio primitive binds to
        # the event loop it is first used on. A host may construct this object
        # once and serve it from a different loop, producing intermittent
        # "attached to a different loop" errors that are horrible to diagnose.
        self._wake_lock: Optional[asyncio.Lock] = None
        self._wake_lock_loop: Any = None

    # -- Helpers -------------------------------------------------------------

    def _get_wake_lock(self) -> asyncio.Lock:
        """Return a lock belonging to the currently running event loop."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if self._wake_lock is None or self._wake_lock_loop is not loop:
            self._wake_lock = asyncio.Lock()
            self._wake_lock_loop = loop
        return self._wake_lock

    @property
    def base_url(self) -> str:
        """Root URL of the vLLM server, e.g. http://runpod-worker.tailXXXX.ts.net:8000"""
        return f"http://{self.config.runpod_host}:{self.config.vllm_port}"

    def preflight(self) -> Optional[str]:
        """
        Check configuration before doing anything.

        Returns an error message if something is wrong, or None if all is well.
        Callers should run this first so problems surface as a readable message
        instead of a stack trace.
        """
        c = self.config
        if not c.runpod_api_key:
            return "RUNPOD_API_KEY is not set. Re-run ./install.sh on the Pi."
        if not c.runpod_pod_id:
            return "RUNPOD_POD_ID is not set. Re-run ./install.sh on the Pi."
        if not c.runpod_host:
            return (
                "RUNPOD_HOST is empty. The pod has not registered on the tailnet yet. "
                "Start it once manually, then re-run ./install.sh to discover the peer."
            )

        # Validate numeric bounds. These come from environment variables, which
        # on a misconfigured host could be absent, zero, or absurd. A zero
        # poll_interval would busy-loop; an unbounded max_tokens would let one
        # request hold the GPU -- and the billing meter -- open indefinitely.
        if not (1 <= c.warmup_timeout <= 3600):
            return f"WARMUP_TIMEOUT must be between 1 and 3600 (got {c.warmup_timeout})."
        if not (0.5 <= c.poll_interval <= 60):
            return f"POLL_INTERVAL must be between 0.5 and 60 (got {c.poll_interval})."
        if not (1 <= c.max_tokens <= 32768):
            return f"MAX_TOKENS must be between 1 and 32768 (got {c.max_tokens})."
        if not (1 <= c.vllm_port <= 65535):
            return f"VLLM_PORT must be a valid port (got {c.vllm_port})."

        # SECURITY: validated here, at the point of use, rather than only at
        # install time. The address is resolved from live tailnet state.
        if c.enforce_mesh_only:
            is_secure = is_mesh_address(c.runpod_host) or c.runpod_host.endswith(".ts.net")
            if not is_secure:
                return (
                    f"Refusing to transmit: {c.runpod_host} is outside the Tailscale mesh. "
                    f"Prompts would leave the encrypted tunnel. "
                    f"Fix RUNPOD_HOST, or disable ENFORCE_MESH_ONLY if this is intentional."
                )
        return None

    # -- RunPod control plane ------------------------------------------------

    async def _graphql(
        self, client: httpx.AsyncClient, query: str, variables: dict
    ) -> dict:
        """
        Send one GraphQL request to RunPod and return its "data" section.

        GraphQL returns errors with a 200 OK status inside an "errors" key, so
        we check for that explicitly rather than trusting the HTTP status alone.

        SECURITY: the API key goes in an Authorization header, NOT a ?api_key=
        query parameter. RunPod's docs show the query-string form, but
        credentials in URLs are written into proxy logs, server access logs,
        and Referer headers. Headers are not logged by default.

        AVAILABILITY: transient transport failures and 5xx/429 responses are
        retried with exponential backoff. 4xx responses other than 429 are NOT
        retried -- a bad key or unknown pod id fails identically every time,
        and retrying only delays a clear error message.
        """
        last_exc: Optional[Exception] = None
        for attempt in range(1, 4):
            try:
                resp = await client.post(
                    RUNPOD_GRAPHQL,
                    json={"query": query, "variables": variables},
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {self.config.runpod_api_key}",
                    },
                    timeout=30.0,
                )
                if resp.status_code == 429 or resp.status_code >= 500:
                    if attempt < 3:
                        log_event(
                            logging.WARNING, "runpod_api_retry",
                            attempt=attempt, status=resp.status_code,
                        )
                        await asyncio.sleep(2 ** attempt)
                        continue
                resp.raise_for_status()
                payload = resp.json()
                if payload.get("errors"):
                    msgs = "; ".join(
                        e.get("message", "unknown") for e in payload["errors"]
                    )
                    raise RuntimeError(f"RunPod API error: {msgs}")
                return payload.get("data") or {}
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout) as exc:
                last_exc = exc
                if attempt < 3:
                    log_event(
                        logging.WARNING, "runpod_api_retry",
                        attempt=attempt, reason=type(exc).__name__,
                    )
                    await asyncio.sleep(2 ** attempt)
                    continue
                raise

        if last_exc:
            raise last_exc
        raise RuntimeError("RunPod API unreachable after 3 attempts.")

    async def pod_status(self, client: httpx.AsyncClient) -> str:
        """
        Ask RunPod whether the pod is RUNNING, EXITED, etc.

        Returns "UNKNOWN" on any failure -- we would rather attempt a resume
        that turns out to be unnecessary than refuse to try.
        """
        query = """
        query pod($input: PodFilter) {
          pod(input: $input) { id desiredStatus runtime { uptimeInSeconds } }
        }
        """
        try:
            data = await self._graphql(
                client, query, {"input": {"podId": self.config.runpod_pod_id}}
            )
            pod = data.get("pod") or {}
            return pod.get("desiredStatus") or "UNKNOWN"
        except Exception:
            return "UNKNOWN"

    async def start_pod(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> None:
        """
        Resume the pod if it is not already running. Safe to call every time --
        if the pod is already up, this returns immediately.
        """
        status = await self.pod_status(client)
        if status == "RUNNING":
            await on_status("Pod already running - checking model...", False)
            return

        await on_status(f"Pod is {status} - sending resume request...", False)

        mutation = """
        mutation resume($input: PodResumeInput!) {
          podResume(input: $input) { id desiredStatus imageName }
        }
        """
        # gpuCount is required by RunPod's schema. 1 matches the single-GPU
        # default; multi-GPU pods resume with their own configured count
        # regardless of what we pass.
        variables = {"input": {"podId": self.config.runpod_pod_id, "gpuCount": 1}}

        try:
            data = await self._graphql(client, mutation, variables)
            new_status = (data.get("podResume") or {}).get("desiredStatus", "?")
            await on_status(f"Resume accepted (status: {new_status}).", False)
        except RuntimeError as exc:
            # If the pod was already starting, RunPod rejects the resume.
            # Harmless -- carry on to the readiness check.
            if "already" in str(exc).lower():
                await on_status("Pod was already starting.", False)
                return
            raise

    async def wait_for_vllm(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> None:
        """
        Poll /v1/models until vLLM reports the model is loaded.

        Connection errors during this loop are normal and expected: the pod is
        still booting and nothing is listening yet. We only give up once
        warmup_timeout seconds have elapsed.

        NOTE: we poll the MODEL LISTING, not the TCP port. A listening socket is
        not a loaded model, and treating it as one converts a clean "still
        warming up" wait into a confusing mid-stream failure minutes later.
        """
        if time.monotonic() < self._warm_until:
            return  # confirmed ready less than 60 seconds ago

        # time.monotonic() only ever moves forward. Unlike wall-clock time it
        # cannot jump if the system clock is adjusted, which makes it the
        # correct choice for measuring elapsed time.
        deadline = time.monotonic() + self.config.warmup_timeout
        probe_url = f"{self.base_url}/v1/models"
        attempt = 0

        while time.monotonic() < deadline:
            attempt += 1
            elapsed = int(
                self.config.warmup_timeout - (deadline - time.monotonic())
            )
            try:
                resp = await client.get(probe_url, timeout=10.0)
                if resp.status_code == 200:
                    body = resp.json()
                    served = [m.get("id") for m in body.get("data", [])]
                    if served:
                        self._warm_until = time.monotonic() + 60.0
                        await on_status(
                            f"Model ready after {elapsed}s - streaming...", True
                        )
                        return
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout):
                pass  # expected while the pod boots and weights load
            except Exception:
                pass

            await on_status(
                f"Waiting for vLLM to load weights... {elapsed}s elapsed "
                f"(probe #{attempt})",
                False,
            )
            await asyncio.sleep(self.config.poll_interval)

        raise TimeoutError(
            f"vLLM did not become ready within {self.config.warmup_timeout}s at "
            f"{probe_url}. Check that the pod started, joined the tailnet as "
            f"'{self.config.peer_hostname}', and that start.sh did not exit early."
        )

    def invalidate_warm_cache(self) -> None:
        """
        Forget that the endpoint was recently confirmed ready.

        AVAILABILITY: callers must do this on any wake/warm failure. A stale
        warm flag would make the next request skip the readiness probe and fail
        immediately against a pod that is not actually up.
        """
        self._warm_until = 0.0

    async def ensure_ready(
        self,
        client: httpx.AsyncClient,
        on_status: StatusCallback = _noop_status,
    ) -> float:
        """
        Wake the pod if needed and block until the model is serving.

        Returns seconds spent waking. Serialised so concurrent callers do not
        both resume the same pod -- the second waits here, then finds it warm.
        """
        async with self._get_wake_lock():
            await on_status("Contacting RunPod control plane...", False)
            wake_started = time.monotonic()
            try:
                await self.start_pod(client, on_status)
                await self.wait_for_vllm(client, on_status)
            except Exception:
                self.invalidate_warm_cache()
                raise
            return round(time.monotonic() - wake_started, 1)

    # -- Inference -----------------------------------------------------------

    def build_payload(
        self, messages: List[Dict[str, Any]], options: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Build an OpenAI chat-completions request body, which vLLM understands
        natively.

        Client-supplied max_tokens is never trusted above our own ceiling: an
        oversized value holds the GPU, and the billing meter, open.
        """
        try:
            requested = int(options.get("max_tokens") or self.config.max_tokens)
        except (TypeError, ValueError):
            requested = self.config.max_tokens
        effective = max(1, min(requested, self.config.max_tokens))

        payload: Dict[str, Any] = {
            "model": self.config.model_name,
            "messages": messages,
            "stream": True,
            "max_tokens": effective,
            "temperature": options.get("temperature", 0.7),
            "top_p": options.get("top_p", 0.9),
        }
        # Pass through optional tuning parameters only if the caller supplied them.
        for opt in ("frequency_penalty", "presence_penalty", "stop", "seed"):
            if options.get(opt) is not None:
                payload[opt] = options[opt]
        return payload

    def timeout(self) -> httpx.Timeout:
        """
        Separate timeouts per phase. "read" is generous because generating a
        long answer legitimately takes minutes.
        """
        return httpx.Timeout(
            connect=15.0,
            read=float(self.config.request_timeout),
            write=30.0,
            pool=15.0,
        )

    def client(self) -> httpx.AsyncClient:
        """
        Build an HTTP client for this endpoint.

        SECURITY: trust_env=False ignores HTTP_PROXY and friends. A stray proxy
        setting could silently reroute prompts somewhere we did not intend, so
        we refuse to honour them at all.
        """
        return httpx.AsyncClient(timeout=self.timeout(), trust_env=False)

    async def stream_completion(
        self,
        client: httpx.AsyncClient,
        payload: Dict[str, Any],
    ) -> AsyncGenerator[Dict[str, Any], None]:
        """
        Stream a chat completion, yielding STRUCTURED EVENTS rather than raw
        text. Callers decide how to render them.

        Event shapes:
            {"type": "error",   "status": int, "detail": str}
            {"type": "content", "text": str}
            {"type": "done",    "saw_done": bool, "chunks": int,
             "malformed": int, "finish_reason": str | None}

        Yielding events rather than strings is what keeps this reusable: the
        Open WebUI pipe renders them as markdown, while a shim would re-emit
        them as server-sent events.
        """
        chunks = 0        # content fragments delivered
        malformed = 0     # chunks that failed to parse
        saw_done = False  # did the server send its end-of-stream marker
        finish_reason: Optional[str] = None

        async with client.stream(
            "POST",
            f"{self.base_url}/v1/chat/completions",
            json=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "text/event-stream",
            },
        ) as response:
            if response.status_code != 200:
                # SECURITY: do not echo the raw upstream body onward. Error
                # bodies routinely contain internal paths, library versions,
                # and occasionally fragments of the request. Surface the status
                # code and a short, scrubbed excerpt only.
                raw = await response.aread()
                detail = scrub(raw.decode("utf-8", errors="replace"))[:200]
                yield {
                    "type": "error",
                    "status": response.status_code,
                    "detail": detail,
                }
                return

            # Server-Sent Events: every line looks like
            #   data: {...json...}
            # and the stream finishes with the literal  data: [DONE]
            async for line in response.aiter_lines():
                if not line or not line.startswith("data: "):
                    continue
                data = line[6:].strip()

                if data == "[DONE]":
                    saw_done = True
                    break

                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    malformed += 1
                    continue  # skip a malformed chunk rather than dying

                choices = chunk.get("choices") or []
                if not choices:
                    continue

                # finish_reason tells us HOW generation ended. "length" means it
                # hit the token ceiling and was cut off -- the caller deserves
                # to know that rather than silently receiving a truncated answer.
                if choices[0].get("finish_reason"):
                    finish_reason = choices[0]["finish_reason"]

                delta = choices[0].get("delta") or {}
                content = delta.get("content")
                if content:
                    chunks += 1
                    yield {"type": "content", "text": content}

        yield {
            "type": "done",
            "saw_done": saw_done,
            "chunks": chunks,
            "malformed": malformed,
            "finish_reason": finish_reason,
        }


# -------------------------------------------------------------------------
# OPEN WEBUI PRESENTATION LAYER  (from pipe_wrapper.py)
# -------------------------------------------------------------------------
# --- imports used only by the wrapper --------------------------------------
# (runpod_core.py, prepended by build_pipe.py, supplies asyncio, logging, os,
#  time, httpx, the typing names, and its own helpers.)
import uuid

from pydantic import BaseModel, Field


class Pipe:
    """On-demand RunPod vLLM backend for Open WebUI."""

    class Valves(BaseModel):
        """
        Settings you can change from the Open WebUI settings panel.

        Each default reads from an environment variable first, falling back to
        a hardcoded value. Those variables come from the .env that install.sh
        generated on the Pi, passed in by docker-compose.yml. In short: you
        should not need to edit this file to configure it.
        """

        RUNPOD_API_KEY: str = Field(
            default=os.getenv("RUNPOD_API_KEY", ""),
            description="RunPod API key. Used for podResume / status queries only.",
        )
        RUNPOD_POD_ID: str = Field(
            default=os.getenv("RUNPOD_POD_ID", ""),
            description="Target RunPod pod ID.",
        )
        RUNPOD_HOST: str = Field(
            default=os.getenv("RUNPOD_HOST", ""),
            description="MagicDNS hostname of the pod. Resolved by install.sh.",
        )
        PEER_HOSTNAME: str = Field(
            default=os.getenv("PEER_HOSTNAME", "runpod-worker"),
            description="Tailnet hostname of the pod. Used in error messages.",
        )
        VLLM_PORT: int = Field(
            default=int(os.getenv("VLLM_PORT", "8000")),
            description="Port vLLM listens on inside the pod.",
        )
        MODEL_NAME: str = Field(
            default=os.getenv("VLLM_MODEL_NAME", "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ"),
            description="Model identifier as served by vLLM.",
        )
        MODEL_DISPLAY_NAME: str = Field(
            default=os.getenv("VLLM_DISPLAY_NAME", "Qwen2.5-Coder-32B (RunPod)"),
            description="Label shown in the Open WebUI model picker.",
        )
        WARMUP_TIMEOUT: int = Field(
            default=int(os.getenv("POD_WARMUP_TIMEOUT", "600")),
            description="Seconds to wait for the readiness probe before failing.",
        )
        POLL_INTERVAL: float = Field(
            default=5.0, description="Seconds between readiness probes."
        )
        REQUEST_TIMEOUT: int = Field(
            default=int(os.getenv("VLLM_REQUEST_TIMEOUT", "900")),
            description="Read timeout for a single completion stream.",
        )
        MAX_TOKENS: int = Field(
            default=int(os.getenv("VLLM_MAX_TOKENS", "4096")),
            description="Default completion cap when the client sends none.",
        )
        EMIT_STATUS: bool = Field(
            default=True, description="Show wake/warm progress in the chat UI."
        )
        ENFORCE_MESH_ONLY: bool = Field(
            default=True,
            description="Refuse to send prompts to any address outside 100.64.0.0/10.",
        )

    def __init__(self) -> None:
        # "manifold" tells Open WebUI this pipe can offer one or more models in
        # the dropdown, rather than being a single fixed endpoint.
        self.type = "manifold"
        self.id = "runpod_vllm"
        self.name = "runpod/"
        self.valves = self.Valves()

        # The endpoint's config is refreshed per request from current Valves, so
        # changes in the settings panel take effect without restarting Open
        # WebUI. The warm-cache and wake-lock live on it, so we keep ONE
        # instance and refresh its config rather than constructing a new one.
        self._endpoint = RunPodEndpoint(self._config())

    # -- Configuration -------------------------------------------------------

    def _config(self) -> EndpointConfig:
        """Translate Open WebUI Valves into a framework-agnostic config."""
        v = self.valves
        return EndpointConfig(
            runpod_api_key=v.RUNPOD_API_KEY,
            runpod_pod_id=v.RUNPOD_POD_ID,
            runpod_host=v.RUNPOD_HOST,
            vllm_port=v.VLLM_PORT,
            model_name=v.MODEL_NAME,
            peer_hostname=v.PEER_HOSTNAME,
            warmup_timeout=v.WARMUP_TIMEOUT,
            poll_interval=v.POLL_INTERVAL,
            request_timeout=v.REQUEST_TIMEOUT,
            max_tokens=v.MAX_TOKENS,
            enforce_mesh_only=v.ENFORCE_MESH_ONLY,
        )

    # -- Open WebUI model registration --------------------------------------

    def pipes(self) -> List[Dict[str, str]]:
        """Open WebUI calls this to ask which models to show in the dropdown."""
        return [{"id": "vllm-cloud", "name": self.valves.MODEL_DISPLAY_NAME}]

    # -- Presentation --------------------------------------------------------

    def _status_callback(
        self, emitter: Optional[Callable[[dict], Awaitable[None]]]
    ) -> StatusCallback:
        """
        Adapt Open WebUI's event emitter to the core's StatusCallback shape.

        Wrapped in try/except because a cosmetic status update must never crash
        an in-flight response.
        """

        async def _emit(description: str, done: bool = False) -> None:
            if emitter and self.valves.EMIT_STATUS:
                try:
                    await emitter(
                        {
                            "type": "status",
                            "data": {"description": description, "done": done},
                        }
                    )
                except Exception:
                    pass

        return _emit

    # -- Main entrypoint -----------------------------------------------------

    async def pipe(
        self,
        body: Dict[str, Any],
        __event_emitter__: Optional[Callable[[dict], Awaitable[None]]] = None,
        **kwargs: Any,
    ) -> AsyncGenerator[str, None]:
        """
        The function Open WebUI calls for every message sent to this model.

        "body" holds the conversation and settings. The double-underscore
        argument is injected by Open WebUI and lets us push status updates.

        This is an async generator: instead of returning once at the end, it
        yields pieces of text as they arrive, producing the typewriter effect.
        """
        emit = self._status_callback(__event_emitter__)

        # Pick up any Valves changes made since the last request.
        self._endpoint.config = self._config()
        endpoint = self._endpoint

        # Correlation id: ties a "it failed at 3pm" report to exact log lines.
        # Short random hex, no user data.
        req_id = uuid.uuid4().hex[:8]
        started = time.monotonic()
        chunks = 0

        # -- Step 1: validate configuration before touching the network ------
        config_error = endpoint.preflight()
        if config_error:
            # WARNING, not ERROR: a misconfiguration to fix, not a system fault.
            log_event(
                logging.WARNING, "request_rejected",
                request_id=req_id, reason="preflight_failed",
                detail=config_error[:120],
            )
            yield f"**Configuration error**\n\n{config_error}"
            return

        messages = body.get("messages", [])
        if not messages:
            log_event(
                logging.WARNING, "request_rejected",
                request_id=req_id, reason="empty_messages",
            )
            yield "**Error**: no messages in request body."
            return

        payload = endpoint.build_payload(messages, body)

        # Metadata only: how many turns, not what is in them.
        log_event(
            logging.INFO, "request_started", request_id=req_id,
            message_count=len(messages), max_tokens=payload["max_tokens"],
        )

        try:
            async with endpoint.client() as client:
                # -- Steps 2 and 3: wake, then wait ---------------------------
                wake_seconds = await endpoint.ensure_ready(client, emit)
                log_event(
                    logging.INFO, "pod_ready",
                    request_id=req_id, wake_seconds=wake_seconds,
                )

                # -- Step 4: stream the answer -------------------------------
                async for event in endpoint.stream_completion(client, payload):
                    if event["type"] == "content":
                        chunks += 1
                        yield event["text"]

                    elif event["type"] == "error":
                        yield (
                            f"\n\n**vLLM returned HTTP {event['status']}**\n\n"
                            f"```\n{event['detail']}\n```\n\n"
                            f"Full detail is in the pod's logs in the RunPod console."
                        )
                        return

                    elif event["type"] == "done":
                        # --- Classify the outcome ---------------------------
                        # A stream that ends without [DONE] was cut short: the
                        # pod was stopped, the tunnel dropped, or the server
                        # died. Without this check that looks identical to
                        # success from the user's side.
                        duration = round(time.monotonic() - started, 1)

                        if not event["saw_done"]:
                            log_event(
                                logging.WARNING, "request_degraded",
                                request_id=req_id, reason="stream_incomplete",
                                chunks=event["chunks"],
                                malformed_chunks=event["malformed"],
                                duration_s=duration,
                            )
                            await emit("Stream ended unexpectedly.", True)
                            yield (
                                "\n\n---\n**Warning: this response is incomplete.** The "
                                "connection to the pod closed before the model finished. "
                                "The pod may have been stopped mid-generation. Resend to retry."
                            )

                        elif event["finish_reason"] == "length":
                            log_event(
                                logging.INFO, "request_truncated",
                                request_id=req_id, reason="max_tokens",
                                chunks=event["chunks"], duration_s=duration,
                            )
                            await emit("Complete (hit token limit).", True)
                            yield (
                                "\n\n---\n*Response reached the token limit and was cut "
                                "off. Raise `MAX_TOKENS` in the function's Valves for "
                                "longer answers.*"
                            )

                        else:
                            log_event(
                                logging.INFO, "request_success",
                                request_id=req_id, chunks=event["chunks"],
                                malformed_chunks=event["malformed"],
                                finish_reason=event["finish_reason"] or "stop",
                                duration_s=duration,
                            )
                            await emit("Complete.", True)

        # -- Error handling ---------------------------------------------------
        # Each case produces a specific, actionable message in the chat window.
        # A junior developer -- or you at 6am -- should be able to read it and
        # know exactly what to go and check.

        except TimeoutError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="warmup_timeout", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Warm-up timed out.", True)
            yield f"\n\n**Pod warm-up timed out**\n\n{exc}"

        except httpx.ConnectError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="connect_error", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Connection failed.", True)
            yield (
                f"\n\n**Cannot reach the inference pod** at `{endpoint.base_url}`.\n\n"
                f"The tailnet route is likely down. Verify with "
                f"`tailscale status | grep {self.valves.PEER_HOSTNAME}` on the Pi - if "
                f"the peer is missing entirely, the pod's ephemeral node was reaped and "
                f"`RUNPOD_HOST` needs refreshing via `./install.sh`.\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )

        except httpx.ReadTimeout:
            # Partial output may already have reached the user, so this is a
            # degraded outcome rather than a clean failure.
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="read_timeout", chunks=chunks,
                partial_output=chunks > 0,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Stream timed out.", True)
            yield (
                f"\n\n**Stream timed out** after {self.valves.REQUEST_TIMEOUT}s. "
                f"The pod may have been stopped mid-generation, or the request "
                f"exceeded the read timeout. Raise `REQUEST_TIMEOUT` in the Valves "
                f"if long generations are expected."
            )

        except RuntimeError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="runpod_api_error", chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("RunPod API error.", True)
            yield (
                f"\n\n**RunPod control plane error**\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )

        except httpx.HTTPStatusError as exc:
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="http_status_error",
                status=exc.response.status_code, chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("HTTP error.", True)
            yield (
                f"\n\n**HTTP {exc.response.status_code} from RunPod**\n\n"
                f"Check that `RUNPOD_API_KEY` is valid and scoped to this pod."
            )

        except asyncio.CancelledError:
            # The user hit stop, or Open WebUI tore the request down. Not an
            # error -- record it and re-raise so cancellation still propagates
            # correctly rather than being swallowed.
            log_event(
                logging.INFO, "request_cancelled", request_id=req_id,
                chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            raise

        except Exception as exc:  # last-resort guard so nothing escapes silently
            log_event(
                logging.ERROR, "request_failed", request_id=req_id,
                reason="unexpected", exc_type=type(exc).__name__,
                chunks=chunks,
                duration_s=round(time.monotonic() - started, 1),
            )
            await emit("Unexpected failure.", True)
            yield (
                f"\n\n**Unexpected error** (`{type(exc).__name__}`)\n\n"
                f"```\n{scrub(str(exc))[:300]}\n```"
            )
