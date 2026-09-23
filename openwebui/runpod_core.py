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
    tailscale_ip: str = ""
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
        """Root URL of the vLLM server, e.g. http://100.x.x.x:8000"""
        return f"http://{self.config.tailscale_ip}:{self.config.vllm_port}"

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
        if not c.tailscale_ip:
            return (
                "TAILSCALE_IP is empty. The pod has not registered on the tailnet yet. "
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
        # install time. The address is resolved from live tailnet state and can
        # change between runs.
        if c.enforce_mesh_only and not is_mesh_address(c.tailscale_ip):
            return (
                f"Refusing to transmit: {c.tailscale_ip} is outside the Tailscale mesh "
                f"range (100.64.0.0/10). Prompts would leave the encrypted tunnel. "
                f"Fix TAILSCALE_IP, or disable ENFORCE_MESH_ONLY if this is intentional."
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
