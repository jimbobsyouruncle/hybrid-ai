"""
Behavioural checks for the core/wrapper split.

Focus: the security- and availability-critical behaviours that must survive any
change. Run after editing either source file.

    python3 openwebui/test_refactor.py
"""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import runpod_core as core

PASS, FAIL = [], []


def check(name: str, condition: bool, detail: str = "") -> None:
    (PASS if condition else FAIL).append(name)
    suffix = f"  -- {detail}" if detail and not condition else ""
    print(f"{'PASS' if condition else 'FAIL'}  {name}{suffix}")


def cfg(**kw):
    base = dict(runpod_api_key="rpa_test", runpod_pod_id="pod123",
                tailscale_ip="100.90.1.5", model_name="test-model")
    base.update(kw)
    return core.EndpointConfig(**base)


print("\n--- mesh address validation (100.64.0.0/10) ---")
for ip, expected in [
    ("100.64.0.1", True), ("100.127.255.255", True), ("100.90.1.5", True),
    ("100.63.255.255", False), ("100.128.0.1", False),
    ("8.8.8.8", False), ("192.168.1.1", False),
    ("100.64.0", False), ("100.64.0.1.1", False),
    ("100.abc.0.1", False), ("", False), ("100.64.0.999", False),
    ("  100.64.0.1", False), ("+100.64.0.1", False),
]:
    check(f"is_mesh_address({ip!r}) == {expected}",
          core.is_mesh_address(ip) is expected)

print("\n--- preflight refuses non-mesh transmission ---")
e = core.RunPodEndpoint(cfg(tailscale_ip="8.8.8.8"))
err = e.preflight()
check("public IP rejected", err is not None and "Refusing to transmit" in err)
check("error names the range", err is not None and "100.64.0.0/10" in err)
check("override allows opt-out",
      core.RunPodEndpoint(cfg(tailscale_ip="8.8.8.8",
                              enforce_mesh_only=False)).preflight() is None)
check("valid mesh IP passes", core.RunPodEndpoint(cfg()).preflight() is None)

print("\n--- preflight bounds ---")
for field, value, word in [
    ("warmup_timeout", 0, "WARMUP_TIMEOUT"), ("warmup_timeout", 3601, "WARMUP_TIMEOUT"),
    ("poll_interval", 0, "POLL_INTERVAL"), ("poll_interval", 61, "POLL_INTERVAL"),
    ("max_tokens", 0, "MAX_TOKENS"), ("max_tokens", 32769, "MAX_TOKENS"),
    ("vllm_port", 0, "VLLM_PORT"), ("vllm_port", 70000, "VLLM_PORT"),
]:
    err = core.RunPodEndpoint(cfg(**{field: value})).preflight()
    check(f"{field}={value} rejected", err is not None and word in err)

for field, word in [("runpod_api_key", "RUNPOD_API_KEY"),
                    ("runpod_pod_id", "RUNPOD_POD_ID"),
                    ("tailscale_ip", "TAILSCALE_IP")]:
    err = core.RunPodEndpoint(cfg(**{field: ""})).preflight()
    check(f"missing {field} rejected", err is not None and word in err)

print("\n--- credential scrubbing ---")
for secret, token, label in [
    ("rpa_abc123XYZ", "rpa_abc123XYZ", "RunPod key"),
    ("tskey-auth-abc123", "tskey-auth-abc123", "Tailscale key"),
    ("Authorization: Bearer sk-xyz123", "sk-xyz123", "auth header token"),
    ("Bearer sk-standalone99", "sk-standalone99", "bare bearer token"),
    ("api_key=supersecret", "supersecret", "api_key"),
    ("API-KEY: hunter2", "hunter2", "API-KEY"),
]:
    out = core.scrub(f"error near {secret} end")
    check(f"scrub redacts {label}", "[REDACTED]" in out and token not in out)

print("\n--- max_tokens clamping (billing protection) ---")
e = core.RunPodEndpoint(cfg(max_tokens=4096))
for requested, expected, label in [
    (999999, 4096, "oversized clamped to ceiling"),
    (100, 100, "smaller value honoured"),
    (None, 4096, "absent uses default"),
    ("garbage", 4096, "non-numeric falls back"),
    (0, 4096, "zero falls back to default"),
    (-5, 1, "negative floored at 1"),
]:
    got = e.build_payload([{"role": "user", "content": "x"}],
                          {"max_tokens": requested})["max_tokens"]
    check(f"{label} ({requested} -> {got})", got == expected, f"expected {expected}")

print("\n--- payload construction ---")
p = e.build_payload([{"role": "user", "content": "hi"}], {})
check("stream always True", p["stream"] is True)
check("model from config", p["model"] == "test-model")
check("optional params omitted when absent", "seed" not in p and "stop" not in p)
p2 = e.build_payload([{"role": "user", "content": "hi"}], {"seed": 42, "stop": ["x"]})
check("optional params passed when present", p2["seed"] == 42 and p2["stop"] == ["x"])

print("\n--- trust_env=False (proxy cannot reroute prompts) ---")
check("client built with trust_env=False",
      core.RunPodEndpoint(cfg()).client().trust_env is False)

print("\n--- warm cache invalidation ---")
e = core.RunPodEndpoint(cfg())
e._warm_until = 9e9
check("warm cache can be set", e._warm_until > 0)
e.invalidate_warm_cache()
check("invalidate_warm_cache resets it", e._warm_until == 0.0)

print("\n--- wake lock rebinds across event loops ---")
async def _get(ep):
    return ep._get_wake_lock()
e = core.RunPodEndpoint(cfg())
check("lock rebuilt for a new loop", asyncio.run(_get(e)) is not asyncio.run(_get(e)))

print("\n--- stream event contract ---")
class FakeStream:
    def __init__(self, lines, status=200):
        self._lines, self.status_code = lines, status
    async def __aenter__(self): return self
    async def __aexit__(self, *a): return False
    async def aiter_lines(self):
        for ln in self._lines: yield ln
    async def aread(self): return b'{"error":"boom"}'

class FakeClient:
    def __init__(self, stream): self._stream = stream
    def stream(self, *a, **k): return self._stream

def sse(text=None, finish=None):
    d = {"choices": [{"delta": {"content": text} if text else {},
                      "finish_reason": finish}]}
    return "data: " + json.dumps(d)

async def collect(lines, status=200):
    ep = core.RunPodEndpoint(cfg())
    return [ev async for ev in ep.stream_completion(FakeClient(FakeStream(lines, status)), {})]

evs = asyncio.run(collect([sse("Hello"), sse(" world"), "data: [DONE]"]))
check("content events yielded in order",
      [x["text"] for x in evs if x["type"] == "content"] == ["Hello", " world"])
check("saw_done True on clean stream", evs[-1]["saw_done"] is True)
check("chunk count correct", evs[-1]["chunks"] == 2)

check("truncated stream flagged saw_done=False",
      asyncio.run(collect([sse("partial")]))[-1]["saw_done"] is False)

evs = asyncio.run(collect([sse("a"), "data: {bad json", sse("b"), "data: [DONE]"]))
check("malformed chunk counted not fatal",
      evs[-1]["malformed"] == 1 and evs[-1]["chunks"] == 2)

check("finish_reason=length propagated",
      asyncio.run(collect([sse("x", finish="length"), "data: [DONE]"]))[-1]["finish_reason"] == "length")

evs = asyncio.run(collect([], status=503))
check("non-200 yields error event", evs[0]["type"] == "error" and evs[0]["status"] == 503)
check("error event has no content events",
      not any(x["type"] == "content" for x in evs))

check("non-SSE lines ignored",
      asyncio.run(collect(["", "noise", sse("ok"), "data: [DONE]"]))[-1]["chunks"] == 1)

print("\n--- core has no Open WebUI / pydantic dependency ---")
# Strip comments first: the core *discusses* pydantic and Valves in its header
# to explain the separation. That is documentation, not coupling.
src = (Path(__file__).resolve().parent / "runpod_core.py").read_text()
code = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
for forbidden in ["pydantic", "__event_emitter__", "Valves", "open_webui"]:
    check(f"core code free of {forbidden!r}", forbidden not in code)

print(f"\n{'=' * 60}\n  {len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    print("  FAILED: " + ", ".join(FAIL))
print("=" * 60)
sys.exit(1 if FAIL else 0)
