# ---------------------------------------------------------------------------
# FILE: openwebui/pipe_wrapper.py
# PURPOSE (plain English):
#   The Open WebUI half of the cloud-model bridge. This file is ONLY about
#   presentation: reading settings from the Valves panel, showing progress in
#   the chat window, and turning the core's structured events into markdown.
#
#   All the actual work -- validating the address, waking the pod, waiting for
#   the model, streaming -- lives in runpod_core.py and is not repeated here.
#
# THE RULE TO PRESERVE:
#   If you find yourself adding an HTTP call, a retry loop, or a RunPod API
#   query to this file, it belongs in runpod_core.py instead. Anything in here
#   is unavailable to a future shim, and duplicating it is how two
#   implementations start to drift.
#
# HOW TO INSTALL IT:
#   Do not paste THIS file into Open WebUI. Paste the generated runpod_pipe.py,
#   which build_pipe.py produces by concatenating runpod_core.py with this one.
#   Open WebUI -> Workspace -> Functions -> "+" -> paste -> Save -> enable.
# ---------------------------------------------------------------------------

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
        TAILSCALE_IP: str = Field(
            default=os.getenv("TAILSCALE_IP", ""),
            description="Mesh IP of the pod (100.x.x.x). Resolved by install.sh.",
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
            tailscale_ip=v.TAILSCALE_IP,
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
                f"`TAILSCALE_IP` needs refreshing via `./install.sh`.\n\n"
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
