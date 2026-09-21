"""
title: RunPod vLLM (Tailscale, on-demand)
author: hybrid-ai
version: 1.0.0
license: MIT
description: >
    Routes prompts to a vLLM server on a RunPod GPU pod over a Tailscale mesh
    address. Resumes the pod on demand, waits for the model to warm, streams
    OpenAI-compatible chunks back, and lets the pod's own idle watchdog handle
    shutdown. No prompt content is logged anywhere in this module.
requirements: httpx
"""

# ---------------------------------------------------------------------------
# FILE: openwebui/runpod_pipe.py
# PURPOSE (plain English):
#   This is the bridge between the chat window on your Pi and the big AI model
#   running on a rented cloud GPU. Open WebUI calls code like this a "pipe".
#
#   When you pick the cloud model from the dropdown and hit send, this file
#   runs and does four things in order:
#
#     1. SAFETY CHECK -- confirms the destination address is inside your
#        private Tailscale network. If it is not, it refuses to send anything.
#     2. WAKE -- asks RunPod to start the GPU pod, which is normally switched
#        off to save money.
#     3. WAIT -- politely pings the pod every 5 seconds until the model has
#        finished loading and says it is ready. This can take a few minutes.
#     4. STREAM -- sends your prompt and passes the reply back word by word, so
#        text appears as it is generated rather than all at once at the end.
#
#   Shutdown is NOT handled here. The pod turns itself off after 15 idle
#   minutes via the watchdog in runpod/start.sh.
#
# HOW TO INSTALL IT:
#   Open WebUI -> Workspace -> Functions -> "+" -> paste this whole file -> Save.
#   Then enable it. Settings can be tweaked afterwards in the "Valves" panel
#   without editing this file.
#
# NOTE ON THE BLOCK AT THE VERY TOP:
#   Those lines between triple quotes are not decoration. Open WebUI reads them
#   to work out the function's name, version, and which Python packages it
#   needs installed. Do not delete them.
#
# PRIVACY NOTE:
#   Your prompts travel only over the Tailscale network (100.x.x.x addresses,
#   encrypted with WireGuard). Every log message in this file contains metadata
#   only -- timings, status, HTTP codes. Never add message text to a log line.
# ---------------------------------------------------------------------------

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import uuid
from typing import Any, AsyncGenerator, Awaitable, Callable, Dict, List, Optional

import httpx
from pydantic import BaseModel, Field

# RunPod's control API. Used to start and query pods -- never to send prompts.
RUNPOD_GRAPHQL = "https://api.runpod.io/graphql"

# Credential shapes that must never reach the chat window or a log line, even
# inside an exception message. Some libraries helpfully include the full
# request (headers and all) in their error text.
_SECRET_PATTERNS = [
    re.compile(r"rpa_[A-Za-z0-9]+"),                    # RunPod API key
    re.compile(r"tskey-[A-Za-z0-9\-]+"),                # Tailscale auth key
    re.compile(r"(?i)(authorization|bearer)\s*[:=]\s*\S+"),
    re.compile(r"(?i)api[_-]?key\s*[:=]\s*\S+"),
]


def _scrub(text: str) -> str:
    """Replace anything credential-shaped with [REDACTED]."""
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("[REDACTED]", text)
    return text


# ---------------------------------------------------------------------------
# OUTCOME LOGGING
#   Every request through this pipe finishes in exactly one of three states,
#   and all three are recorded: success, degraded (partial answer), failure.
#   Without this, a user reporting "it was slow yesterday" leaves you nothing
#   to investigate -- the chat UI keeps no record of why a request behaved
#   the way it did.
#
#   PRIVACY: these records contain METADATA ONLY -- durations, counts, state
#   names, HTTP codes. Never log message content. Every value passed through
#   here is additionally run through _scrub() as a second line of defence, in
#   case an exception string carries a credential.
# ---------------------------------------------------------------------------
logger = logging.getLogger("hybrid_ai.runpod_pipe")
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s [runpod_pipe] %(message)s")
    )
    logger.addHandler(_handler)
    logger.setLevel(os.getenv("PIPE_LOG_LEVEL", "INFO").upper())
    # Do not also hand these records to Open WebUI's root logger, which may be
    # configured more verbosely than we want for something on a privacy path.
    logger.propagate = False


def _log_event(level: int, event: str, **fields: Any) -> None:
    """Emit one structured, metadata-only line: event=<name> key=value ..."""
    parts = [f"event={event}"]
    for key, value in fields.items():
        parts.append(f"{key}={_scrub(str(value))}")
    logger.log(level, " ".join(parts))


class Pipe:
    """On-demand RunPod vLLM backend for Open WebUI."""

    class Valves(BaseModel):
        """
        Settings you can change from the Open WebUI settings panel.

        Each default reads from an environment variable first, falling back to
        a hardcoded value. Those environment variables come from the .env file
        that install.sh generated on the Pi, passed in by docker-compose.yml.
        In short: you should not need to edit this file to configure it.
        """

        RUNPOD_API_KEY: str = Field(
            default=os.getenv("RUNPOD_API_KEY", ""),
            description="RunPod API key. Used for podResume / status queries only.",
        )
        RUNPOD_POD_ID: str = Field(
            default=os.getenv("RUNPOD_POD_ID", ""),
            description="Target RunPod pod ID.",
        )
        TAILSCALE_IP: str = Field(
            default=os.getenv("TAILSCALE_IP", ""),
            description="Mesh IP of the pod (100.x.x.x). Resolved by install.sh.",
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
        # "manifold" tells Open WebUI this pipe can offer one or more models
        # in the model dropdown, rather than being a single fixed endpoint.
        self.type = "manifold"
        self.id = "runpod_vllm"
        self.name = "runpod/"
        self.valves = self.Valves()
        # Small optimisation: after a successful readiness check we skip
        # re-checking for 60 seconds. Avoids a pointless network round trip on
        # every message during an active conversation.
        self._warm_until: float = 0.0
        # AVAILABILITY: if two chats hit the cloud model at once, both would
        # independently try to resume the pod and both would poll. A lock
        # serialises the wake-and-warm phase so only one does the work; the
        # second waits and then finds it already warm.
        #
        # Created lazily rather than here, because an asyncio primitive binds
        # to the event loop it is first used on. Open WebUI may construct this
        # object once and serve it from a different loop, which would produce
        # intermittent "attached to a different loop" errors that are horrible
        # to diagnose. _get_wake_lock() rebuilds it if the loop changes.
        self._wake_lock: Optional[asyncio.Lock] = None
        self._wake_lock_loop: Any = None

    def _get_wake_lock(self) -> asyncio.Lock:
        """Return a lock that belongs to the currently running event loop."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            loop = None
        if self._wake_lock is None or self._wake_lock_loop is not loop:
            self._wake_lock = asyncio.Lock()
            self._wake_lock_loop = loop
        return self._wake_lock

    # -- Open WebUI model registration --------------------------------------

    def pipes(self) -> List[Dict[str, str]]:
        """Open WebUI calls this to ask which models to show in the dropdown."""
        return [{"id": "vllm-cloud", "name": self.valves.MODEL_DISPLAY_NAME}]

    # -- Helpers -------------------------------------------------------------

    @property
    def _base_url(self) -> str:
        """The root URL of the vLLM server, e.g. http://100.x.x.x:8000"""
        return f"http://{self.valves.TAILSCALE_IP}:{self.valves.VLLM_PORT}"

    @staticmethod
    def _is_mesh_address(ip: str) -> bool:
        """
        Return True only if the address is inside 100.64.0.0/10, the range
        Tailscale uses for private mesh addresses.

        WHY THIS MATTERS: if TAILSCALE_IP were ever wrong -- a typo, a stale
        value, a copy-paste of a public address -- your prompts would be sent
        unencrypted across the open internet. This check makes that impossible.
        The range covers 100.64.x.x through 100.127.x.x.
        """
        parts = ip.split(".")
        if len(parts) != 4:
            return False
        try:
            octets = [int(p) for p in parts]
        except ValueError:
            return False
        if any(o < 0 or o > 255 for o in octets):
            return False
        return octets[0] == 100 and 64 <= octets[1] <= 127

    def _preflight(self) -> Optional[str]:
        """
        Check configuration before doing anything.
        Returns an error message string if something is wrong, or None if all
        is well. Called first thing in pipe() so problems surface as a readable
        chat message instead of a stack trace.
        """
        v = self.valves
        if not v.RUNPOD_API_KEY:
            return "RUNPOD_API_KEY is not set. Re-run ./install.sh on the Pi."
        if not v.RUNPOD_POD_ID:
            return "RUNPOD_POD_ID is not set. Re-run ./install.sh on the Pi."
        if not v.TAILSCALE_IP:
            return (
                "TAILSCALE_IP is empty. The pod has not registered on the tailnet yet. "
                "Start it once manually, then re-run ./install.sh to discover the peer."
            )
        # Validate numeric bounds. These come from environment variables, which
        # on a misconfigured host could be absent, zero, or absurd. A zero
        # POLL_INTERVAL would busy-loop; an unbounded MAX_TOKENS would let a
        # single request hold the GPU (and the meter running) indefinitely.
        if not (1 <= v.WARMUP_TIMEOUT <= 3600):
            return f"WARMUP_TIMEOUT must be between 1 and 3600 (got {v.WARMUP_TIMEOUT})."
        if not (0.5 <= v.POLL_INTERVAL <= 60):
            return f"POLL_INTERVAL must be between 0.5 and 60 (got {v.POLL_INTERVAL})."
        if not (1 <= v.MAX_TOKENS <= 32768):
            return f"MAX_TOKENS must be between 1 and 32768 (got {v.MAX_TOKENS})."
        if not (1 <= v.VLLM_PORT <= 65535):
            return f"VLLM_PORT must be a valid port (got {v.VLLM_PORT})."

        if v.ENFORCE_MESH_ONLY and not self._is_mesh_address(v.TAILSCALE_IP):
            return (
                f"Refusing to transmit: {v.TAILSCALE_IP} is outside the Tailscale mesh "
                f"range (100.64.0.0/10). Prompts would leave the encrypted tunnel. "
                f"Fix TAILSCALE_IP, or disable ENFORCE_MESH_ONLY if this is intentional."
            )
        return None

    async def _emit(
        self,
        emitter: Optional[Callable[[dict], Awaitable[None]]],
        description: str,
        done: bool = False,
    ) -> None:
        """
        Show a status line in the chat UI ("Waiting for vLLM to load weights...").
        Wrapped in try/except because a cosmetic status update must never be
        allowed to crash an in-flight response.
        """
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

    # -- RunPod control plane ------------------------------------------------

    async def _graphql(self, client: httpx.AsyncClient, query: str, variables: dict) -> dict:
        """
        Send one GraphQL request to RunPod and return the "data" section.

        GraphQL is the query language RunPod's API uses. Unlike a normal REST
        API, errors can come back with a 200 OK status inside an "errors" key,
        so we have to check for that explicitly rather than trusting the HTTP
        status code alone.
        """
        # SECURITY: the API key is sent in an Authorization header, NOT as a
        # ?api_key= query parameter. RunPod's docs show the query-string form,
        # but credentials in URLs get written into proxy logs, server access
        # logs, and Referer headers. Headers are not logged by default.
        # AVAILABILITY: retry transient transport failures and 5xx/429
        # responses with exponential backoff. A brief blip in RunPod's API
        # should not surface to the user as a hard failure.
        #
        # We deliberately do NOT retry 4xx responses other than 429 -- a bad
        # key or an unknown pod id will fail identically every time, and
        # retrying just delays a clear error message.
        last_exc: Optional[Exception] = None
        for attempt in range(1, 4):
            try:
                resp = await client.post(
                    RUNPOD_GRAPHQL,
                    json={"query": query, "variables": variables},
                    headers={
                        "Content-Type": "application/json",
                        "Authorization": f"Bearer {self.valves.RUNPOD_API_KEY}",
                    },
                    timeout=30.0,
                )
                if resp.status_code == 429 or resp.status_code >= 500:
                    if attempt < 3:
                        _log_event(logging.WARNING, "runpod_api_retry",
                                   attempt=attempt, status=resp.status_code)
                        await asyncio.sleep(2 ** attempt)
                        continue
                resp.raise_for_status()
                payload = resp.json()
                if payload.get("errors"):
                    msgs = "; ".join(e.get("message", "unknown") for e in payload["errors"])
                    raise RuntimeError(f"RunPod API error: {msgs}")
                return payload.get("data") or {}

            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout) as exc:
                last_exc = exc
                if attempt < 3:
                    _log_event(logging.WARNING, "runpod_api_retry",
                               attempt=attempt, reason=type(exc).__name__)
                    await asyncio.sleep(2 ** attempt)
                    continue
                raise

        if last_exc:
            raise last_exc
        raise RuntimeError("RunPod API unreachable after 3 attempts.")

    async def _pod_status(self, client: httpx.AsyncClient) -> str:
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
                client, query, {"input": {"podId": self.valves.RUNPOD_POD_ID}}
            )
            pod = data.get("pod") or {}
            return pod.get("desiredStatus") or "UNKNOWN"
        except Exception:
            return "UNKNOWN"

    async def start_pod(
        self,
        client: httpx.AsyncClient,
        emitter: Optional[Callable[[dict], Awaitable[None]]] = None,
    ) -> None:
        """
        Resume the pod if it is not already running. Safe to call every time --
        if the pod is already up, this returns immediately.
        """
        status = await self._pod_status(client)

        if status == "RUNNING":
            await self._emit(emitter, "Pod already running - checking model...")
            return

        await self._emit(emitter, f"Pod is {status} - sending resume request...")

        mutation = """
        mutation resume($input: PodResumeInput!) {
          podResume(input: $input) { id desiredStatus imageName }
        }
        """
        # gpuCount is a required field in RunPod's schema. 1 matches the
        # single-GPU default; multi-GPU pods resume with their own configured
        # count regardless of what we pass here.
        variables = {"input": {"podId": self.valves.RUNPOD_POD_ID, "gpuCount": 1}}

        try:
            data = await self._graphql(client, mutation, variables)
            new_status = (data.get("podResume") or {}).get("desiredStatus", "?")
            await self._emit(emitter, f"Resume accepted (status: {new_status}).")
        except RuntimeError as exc:
            # If the pod was already starting up, RunPod rejects the resume
            # request. That is harmless -- carry on to the readiness check.
            if "already" in str(exc).lower():
                await self._emit(emitter, "Pod was already starting.")
                return
            raise

    async def wait_for_vllm(
        self,
        client: httpx.AsyncClient,
        emitter: Optional[Callable[[dict], Awaitable[None]]] = None,
    ) -> None:
        """
        Poll the /v1/models endpoint until vLLM reports the model is loaded.

        Connection errors during this loop are completely normal and expected:
        the pod is still booting and nothing is listening yet. We only give up
        once WARMUP_TIMEOUT seconds have elapsed.
        """
        if time.monotonic() < self._warm_until:
            return  # we confirmed it was ready less than 60 seconds ago

        # time.monotonic() is a clock that only ever moves forward. Unlike
        # wall-clock time, it cannot jump if the system clock is adjusted,
        # which makes it the correct choice for measuring elapsed time.
        deadline = time.monotonic() + self.valves.WARMUP_TIMEOUT
        probe_url = f"{self._base_url}/v1/models"
        attempt = 0

        while time.monotonic() < deadline:
            attempt += 1
            elapsed = int(self.valves.WARMUP_TIMEOUT - (deadline - time.monotonic()))
            try:
                resp = await client.get(probe_url, timeout=10.0)
                if resp.status_code == 200:
                    body = resp.json()
                    served = [m.get("id") for m in body.get("data", [])]
                    if served:
                        self._warm_until = time.monotonic() + 60.0
                        await self._emit(
                            emitter, f"Model ready after {elapsed}s - streaming...", done=True
                        )
                        return
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadTimeout):
                pass  # expected while the pod boots and weights load
            except Exception:
                pass

            await self._emit(
                emitter,
                f"Waiting for vLLM to load weights... {elapsed}s elapsed (probe #{attempt})",
            )
            await asyncio.sleep(self.valves.POLL_INTERVAL)

        raise TimeoutError(
            f"vLLM did not become ready within {self.valves.WARMUP_TIMEOUT}s at {probe_url}. "
            f"Check that the pod started, joined the tailnet as 'runpod-vllm', and that "
            f"start.sh did not exit early."
        )

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
        "yields" pieces of text as they arrive, which is what produces the
        typewriter effect in the chat window.
        """
        emitter = __event_emitter__

        # Correlation id: lets you tie a user's "it failed at 3pm" report to
        # the exact log lines for that request. Short random hex, no user data.
        req_id = uuid.uuid4().hex[:8]
        started = time.monotonic()
        chunks = 0            # content fragments delivered
        malformed = 0         # chunks that failed to parse
        saw_done = False      # did the server send its end-of-stream marker
        finish_reason = None  # why generation stopped

        # -- Step 1: validate configuration before touching the network ------
        config_error = self._preflight()
        if config_error:
            # Config errors are logged at WARNING, not ERROR: they are a
            # misconfiguration to fix, not a system fault to page on.
            _log_event(logging.WARNING, "request_rejected",
                       request_id=req_id, reason="preflight_failed",
                       detail=config_error[:120])
            yield f"**Configuration error**\n\n{config_error}"
            return

        messages = body.get("messages", [])
        if not messages:
            _log_event(logging.WARNING, "request_rejected",
                       request_id=req_id, reason="empty_messages")
            yield "**Error**: no messages in request body."
            return

        # Clamp here so the value is logged and sent from one place.
        # Client-supplied max_tokens is never trusted above our own ceiling:
        # an oversized value holds the GPU, and the billing meter, open.
        try:
            requested_tokens = int(body.get("max_tokens") or self.valves.MAX_TOKENS)
        except (TypeError, ValueError):
            requested_tokens = self.valves.MAX_TOKENS
        effective_tokens = max(1, min(requested_tokens, self.valves.MAX_TOKENS))

        # Metadata only: how many turns, not what is in them.
        _log_event(logging.INFO, "request_started", request_id=req_id,
                   message_count=len(messages), max_tokens=effective_tokens)

        # Build the request in the OpenAI chat-completions format, which vLLM
        # understands natively.
        payload: Dict[str, Any] = {
            "model": self.valves.MODEL_NAME,
            "messages": messages,
            "stream": True,
            "max_tokens": effective_tokens,
            "temperature": body.get("temperature", 0.7),
            "top_p": body.get("top_p", 0.9),
        }
        # Pass through optional tuning parameters only if the UI supplied them.
        for opt in ("frequency_penalty", "presence_penalty", "stop", "seed"):
            if body.get(opt) is not None:
                payload[opt] = body[opt]

        # Separate timeouts for each phase. "read" is generous because
        # generating a long answer legitimately takes minutes.
        timeout = httpx.Timeout(
            connect=15.0, read=float(self.valves.REQUEST_TIMEOUT), write=30.0, pool=15.0
        )

        try:
            # trust_env=False ignores any HTTP_PROXY environment variables. A
            # stray proxy setting could silently reroute prompts somewhere we
            # did not intend, so we refuse to honour them at all.
            async with httpx.AsyncClient(timeout=timeout, trust_env=False) as client:

                # -- Steps 2 and 3: wake, then wait ---------------------------
                # Serialised so concurrent chats do not both try to resume the
                # same pod. The second caller waits here, then finds it warm.
                async with self._get_wake_lock():
                    await self._emit(emitter, "Contacting RunPod control plane...")
                    wake_started = time.monotonic()
                    try:
                        await self.start_pod(client, emitter)
                        await self.wait_for_vllm(client, emitter)
                    except Exception:
                        # AVAILABILITY: clear the "it is warm" cache on any
                        # failure. Leaving a stale warm flag would make the
                        # next request skip the readiness probe and fail
                        # immediately against a pod that is not actually up.
                        self._warm_until = 0.0
                        raise
                    _log_event(logging.INFO, "pod_ready", request_id=req_id,
                               wake_seconds=round(time.monotonic() - wake_started, 1))

                # -- Step 4: stream the answer -------------------------------
                async with client.stream(
                    "POST",
                    f"{self._base_url}/v1/chat/completions",
                    json=payload,
                    headers={
                        "Content-Type": "application/json",
                        "Accept": "text/event-stream",
                    },
                ) as response:

                    if response.status_code != 200:
                        # SECURITY: do not echo the raw upstream body into the
                        # chat. Error bodies routinely contain internal paths,
                        # library versions, and occasionally fragments of the
                        # request. Surface the status code and a short, scrubbed
                        # excerpt only.
                        raw = await response.aread()
                        detail = _scrub(raw.decode("utf-8", errors="replace"))[:200]
                        yield (
                            f"\n\n**vLLM returned HTTP {response.status_code}**\n\n"
                            f"```\n{detail}\n```\n\n"
                            f"Full detail is in the pod's logs in the RunPod console."
                        )
                        return

                    # Server-Sent Events format: every line looks like
                    #   data: {...json...}
                    # and the stream finishes with the literal  data: [DONE]
                    async for line in response.aiter_lines():
                        if not line or not line.startswith("data: "):
                            continue
                        data = line[6:].strip()   # strip the "data: " prefix
                        if data == "[DONE]":
                            saw_done = True
                            break
                        try:
                            chunk = json.loads(data)
                        except json.JSONDecodeError:
                            malformed += 1
                            continue   # skip a malformed chunk rather than dying

                        choices = chunk.get("choices") or []
                        if not choices:
                            continue
                        # finish_reason tells us HOW generation ended. "length"
                        # means it hit the token ceiling and was cut off -- the
                        # user deserves to know that rather than silently
                        # receiving a truncated answer.
                        if choices[0].get("finish_reason"):
                            finish_reason = choices[0]["finish_reason"]
                        delta = choices[0].get("delta") or {}
                        content = delta.get("content")
                        if content:
                            chunks += 1
                            yield content

                # --- Classify the outcome -------------------------------
                # A stream that ends without [DONE] was cut short: the pod was
                # stopped, the tunnel dropped, or the server died. Previously
                # this looked identical to success from the user's side.
                duration = round(time.monotonic() - started, 1)

                if not saw_done:
                    _log_event(
                        logging.WARNING, "request_degraded", request_id=req_id,
                        reason="stream_incomplete", chunks=chunks,
                        malformed_chunks=malformed, duration_s=duration,
                    )
                    await self._emit(emitter, "Stream ended unexpectedly.", done=True)
                    yield (
                        "\n\n---\n**Warning: this response is incomplete.** The "
                        "connection to the pod closed before the model finished. "
                        "The pod may have been stopped mid-generation. Resend to retry."
                    )
                elif finish_reason == "length":
                    _log_event(
                        logging.INFO, "request_truncated", request_id=req_id,
                        reason="max_tokens", chunks=chunks, duration_s=duration,
                    )
                    await self._emit(emitter, "Complete (hit token limit).", done=True)
                    yield (
                        "\n\n---\n*Response reached the token limit and was cut "
                        "off. Raise `MAX_TOKENS` in the function's Valves for "
                        "longer answers.*"
                    )
                else:
                    _log_event(
                        logging.INFO, "request_success", request_id=req_id,
                        chunks=chunks, malformed_chunks=malformed,
                        finish_reason=finish_reason or "stop", duration_s=duration,
                    )
                    await self._emit(emitter, "Complete.", done=True)

        # -- Error handling ---------------------------------------------------
        # Each case below produces a specific, actionable message in the chat
        # window. A junior developer (or you at 6am) should be able to read the
        # message and know exactly what to go and check.

        except TimeoutError as exc:
            _log_event(logging.ERROR, "request_failed", request_id=req_id,
                       reason="warmup_timeout", chunks=chunks,
                       duration_s=round(time.monotonic() - started, 1))
            await self._emit(emitter, "Warm-up timed out.", done=True)
            yield f"\n\n**Pod warm-up timed out**\n\n{exc}"

        except httpx.ConnectError as exc:
            _log_event(logging.ERROR, "request_failed", request_id=req_id,
                       reason="connect_error", chunks=chunks,
                       duration_s=round(time.monotonic() - started, 1))
            await self._emit(emitter, "Connection failed.", done=True)
            yield (
                f"\n\n**Cannot reach the inference pod** at `{self._base_url}`.\n\n"
                f"The tailnet route is likely down. Verify with "
                f"`tailscale status | grep runpod-vllm` on the Pi - if the peer is "
                f"missing entirely, the pod's ephemeral node was reaped and "
                f"`TAILSCALE_IP` needs refreshing via `./install.sh`.\n\n"
                f"```\n{_scrub(str(exc))[:300]}\n```"
            )

        except httpx.ReadTimeout:
            # Partial output may already have reached the user, so this is a
            # degraded outcome rather than a clean failure.
            _log_event(logging.ERROR, "request_failed", request_id=req_id,
                       reason="read_timeout", chunks=chunks,
                       partial_output=chunks > 0,
                       duration_s=round(time.monotonic() - started, 1))
            await self._emit(emitter, "Stream timed out.", done=True)
            yield (
                f"\n\n**Stream timed out** after {self.valves.REQUEST_TIMEOUT}s. "
                f"The pod may have been stopped mid-generation, or the request "
                f"exceeded the read timeout. Raise `REQUEST_TIMEOUT` in the Valves "
                f"if long generations are expected."
            )

        except RuntimeError as exc:
            _log_event(logging.ERROR, "request_failed", request_id=req_id,
                       reason="runpod_api_error", chunks=chunks,
                       duration_s=round(time.monotonic() - started, 1))
            await self._emit(emitter, "RunPod API error.", done=True)
            yield f"\n\n**RunPod control plane error**\n\n```\n{_scrub(str(exc))[:300]}\n```"

        except httpx.HTTPStatusError as exc:
            _log_event(logging.ERROR, "request_failed", request_id=req_id,
                       reason="http_status_error",
                       status=exc.response.status_code, chunks=chunks,
                       duration_s=round(time.monotonic() - started, 1))
            await self._emit(emitter, "HTTP error.", done=True)
            yield (
                f"\n\n**HTTP {exc.response.status_code} from RunPod**\n\n"
                f"Check that `RUNPOD_API_KEY` is valid and scoped to this pod."
            )

        except asyncio.CancelledError:
            # The user hit stop, or Open WebUI tore the request down. This is
            # not an error -- record it and re-raise so cancellation still
            # propagates correctly rather than being swallowed.
            _log_event(logging.INFO, "request_cancelled", request_id=req_id,
                       chunks=chunks,
                       duration_s=round(time.monotonic() - started, 1))
            raise

        except Exception as exc:  # last-resort guard so nothing escapes silently
            _log_event(logging.ERROR, "request_failed", request_id=req_id,
                       reason="unexpected", exc_type=type(exc).__name__,
                       chunks=chunks,
                       duration_s=round(time.monotonic() - started, 1))
            await self._emit(emitter, "Unexpected failure.", done=True)
            yield (
                f"\n\n**Unexpected error** (`{type(exc).__name__}`)\n\n"
                f"```\n{_scrub(str(exc))[:300]}\n```"
            )
