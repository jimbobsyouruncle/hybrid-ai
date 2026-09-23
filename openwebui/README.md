# openwebui/ — the bridge to the cloud GPU

Three source files and one generated file.

| File | What it is | Edit? |
|---|---|---|
| `runpod_core.py` | Wake, validate, poll, stream. No Open WebUI dependency. | Yes |
| `pipe_wrapper.py` | Open WebUI presentation: Valves, status lines, markdown. | Yes |
| `build_pipe.py` | Concatenates the two into the pasteable artifact. | Rarely |
| `runpod_pipe.py` | **Generated.** The file you paste into Open WebUI. | **No** |
| `test_refactor.py` | 62 behavioural checks over the security-critical paths. | Yes |

---

## Why the split

The wake/validate/poll logic has one consumer today and will likely have two: a waking shim
that fronts RunPod endpoints so tools other than Open WebUI can reach a pod that is currently
stopped.

If that logic stayed tangled with the Open WebUI `Pipe` class, building the shim would mean
rewriting it — and then maintaining two implementations of pod lifecycle that drift apart.

**The rule:** if you are adding an HTTP call, a retry loop, or a RunPod API query, it belongs
in `runpod_core.py`.

## Why a build step

Open WebUI functions are pasted into a text box, not installed as packages. A pipe cannot
`import` a sibling module — there is no file next to it at runtime. So: two files for humans,
one generated file for Open WebUI.

```bash
python3 openwebui/build_pipe.py           # rebuild after editing either source
python3 openwebui/build_pipe.py --check   # CI: fail if stale
```

Commit the generated file. Add `--check` to CI so a forgotten rebuild is caught before it
becomes a confusing production bug.

---

## Installing

1. `python3 openwebui/build_pipe.py`
2. Open WebUI → Workspace → Functions → **+**
3. Paste all of `runpod_pipe.py` → Save → enable
4. Adjust settings in the Valves panel — no code edit needed

**Do not remove the triple-quoted block at the top.** Open WebUI parses it for the function's
title, version, and required packages (`httpx`). Without it the function will not install.

Defaults come from `.env` via `docker-compose.yml`, so a correct `install.sh` run usually
means nothing to configure.

---

## Behaviours that must not regress

`test_refactor.py` covers these. Run it after any change to either source file.

| Behaviour | Why it matters |
|---|---|
| `100.64.0.0/10` enforced at point of use | Prompts leaving the encrypted tunnel is the failure this architecture exists to prevent |
| Strict octet parsing | `int()` accepts `"  100.64.0.1"`; permissive parsing produces a value that *looks* validated |
| `trust_env=False` | A stray `HTTP_PROXY` could silently reroute prompts |
| Credentials scrubbed from errors | Exception text routinely carries request headers |
| `max_tokens` clamped to the ceiling | An oversized value holds the GPU, and the billing meter, open |
| Warm cache cleared on failure | A stale warm flag makes the next request skip the probe and fail against a dead pod |
| Wake lock rebinds per event loop | An asyncio lock bound to a stale loop fails intermittently and is horrible to diagnose |
| `saw_done` distinguishes truncation | Without it, a stream cut short looks identical to success |
| Logs carry metadata only | Prompt content must never reach a log line |

```bash
python3 openwebui/test_refactor.py
```

---

## Two fixes made during the split

The tests surfaced two defects that existed in the original single file:

**Authorization headers leaked their token.** The pattern ended at `\S+`, which matched the
word `Bearer` and stopped — leaving the credential in the string.
`Authorization: Bearer sk-xyz123` scrubbed to `[REDACTED] sk-xyz123`. The optional `Bearer `
is now consumed together with the token that follows it.

**Whitespace passed mesh validation.** `int()` tolerates surrounding whitespace, so
`"  100.64.0.1"` validated successfully. Octets are now checked with `isdigit()` before
conversion.

---

## Deploying a change

```text
edit runpod_core.py or pipe_wrapper.py
        ↓
python3 openwebui/build_pipe.py
        ↓
python3 openwebui/test_refactor.py
        ↓
commit BOTH the sources and the generated file
        ↓
re-paste into Open WebUI
```

**The re-paste is the deploy step.** The pasted function lives in `webui_data/webui.db`; the
repo copy is mounted `:ro` for reference only. A `git pull` alone leaves you running the old
code while reading the new.
