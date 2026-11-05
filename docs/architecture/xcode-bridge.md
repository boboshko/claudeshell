# ClaudeShell — macOS Xcode Bridge Architecture

This document is the dedicated Xcode Bridge architecture reference required
by task §7 / task §3.3 ("cannot be skipped"). It complements
`.pipeline/02-design/architecture.md` (§5.7, §7, and the risk table) and
`docs/architecture/firewall.md` by specifying, precisely enough for stage 4
(build) to implement without further design decisions, the transport,
wire protocol, allow-list, path translation, error behavior, unsupported
capabilities, and lifecycle of the host-side Xcode bridge. It resolves
`requirements.md`'s open question #1 and satisfies FR-20 through FR-26 and
the relevant parts of NFR-3/NFR-6/NFR-7, and the capability matrix in
`requirements.md` §7.

Nothing here is aspirational. Every "yes" below is something a batch
HTTP request/response round-trip to a host-local process can actually do;
every "no" is stated plainly, with the mechanical reason it cannot be done,
per FR-26's explicit instruction not to fake or stub Xcode support.

## 1. Transport mechanism (resolves open question #1)

**Decision:** a host-local helper process on macOS, listening on
`127.0.0.1:<PORT>` (default `47870`, overridable), reached from inside the
container via `http://host.docker.internal:<PORT>/...`.

Why this is the right primitive, confirmed rather than assumed:

- Docker Desktop for macOS injects `host.docker.internal` into every
  container's DNS automatically, with no `extra_hosts` entry needed in
  `docker-compose.yml` — this project adds none, deliberately (see §10).
- Docker Desktop's VM uses a user-mode network layer (vpnkit/gVisor-based,
  depending on version) that specifically proxies connections to
  `host.docker.internal` through to the host's own loopback interface. This
  is why the helper can — and must — bind to `127.0.0.1` only, never
  `0.0.0.0`: Docker Desktop's proxy is what bridges the container network
  namespace to the host's loopback, not an actual LAN-facing listener on the
  helper's part. **The helper is never reachable from the LAN, from another
  container, or from any machine other than the one running Docker Desktop**,
  because nothing about this design ever asks it to bind wider than
  loopback. This satisfies NFR-3's "MUST bind only to a host-local interface"
  literally, not just in spirit.
- No Docker socket involvement whatsoever (deliberately not used as a
  transport) — the bridge has nothing to do with controlling the Docker
  daemon; using the socket here would be both unrelated to what's being
  solved and a strictly riskier mechanism than a dedicated loopback port
  (see `.pipeline/02-design/architecture.md` §5.5 for why Docker-socket
  access is treated as the single riskiest Tools toggle in this whole
  feature set — the Xcode bridge intentionally shares none of that
  machinery).
- On Linux (native Docker Engine) and, relevantly, on Windows/WSL2 (Docker
  Desktop also auto-injects `host.docker.internal` there), the hostname may
  resolve or may not — but it is **never useful** on either platform because
  the helper itself is never started there (§9: the helper is macOS-only
  code, under `scripts/platform/macos/`, never installed or launched on
  Linux/Windows). So reachability is not gated by OS-sniffing logic inside
  the container at all; it's gated by whether anything is listening on the
  other end, which is true only on macOS with the feature actually enabled.
  This is the same "fails safe by absence, not by special-casing" principle
  `.pipeline/02-design/architecture.md` §7 uses for the rest of the
  platform-isolation surface.

## 2. Why a host helper, and why Python (NFR-6/NFR-7 justification)

The container side already has everything it needs with zero new
dependencies: `curl` is in the mandatory apt base (`docker/Dockerfile`,
unconditional), so the container-side shims (§4/§9) are plain Bash scripts
calling `curl` — no new mandatory container dependency at all.

The host side is where a real decision has to be made, and it is made here
explicitly rather than left to stage 4:

- **Not pure Bash + `nc`/`socat` on the host.** Both are good at relaying
  bytes but neither gives a clean way to (a) hold a listening HTTP-ish
  socket, (b) spawn a subprocess, demultiplex its stdout/stderr, stream them
  back live, and (c) still carry a final exit code — without hand-rolling an
  HTTP parser in `nc` pipelines, which is exactly the kind of fragile
  shell-glued protocol the `cross-platform-shell` skill's "don't glue
  incompatible mechanisms" principle warns against. `socat` is also not
  guaranteed to be preinstalled on macOS (it isn't, by default).
- **Not Node.js on the host.** Node is a hard dependency of the *container*
  image (`node:20-slim` base), not of the macOS host. There is no guarantee
  a ClaudeShell user's Mac has Node installed at all — introducing it here
  would be a brand-new mandatory host dependency, which NFR-7 explicitly
  forbids adding beyond what Docker Desktop + the current script set already
  require.
- **Python 3 (stdlib only: `http.server`, `subprocess`, `threading`, no
  `pip install` of anything).** This is the one case in the whole feature
  set where a new interpreted-language dependency is justified, and it is
  justified narrowly: `/usr/bin/python3` on modern macOS is Apple's own
  stub — before Xcode Command Line Tools (CLT) are installed, invoking it
  triggers the CLT-install GUI prompt and does nothing useful; **once CLT is
  installed, `/usr/bin/python3` becomes a real, working CPython 3
  interpreter**, because it ships as part of CLT. That is exactly the
  precondition under which this bridge is useful at all — if CLT isn't
  installed, there is no `xcodebuild`/`xcrun` to bridge to in the first
  place, and the helper's own startup check (§7) reports that plainly. So
  Python here is not a "new dependency" in the NFR-7 sense: it is present on
  every machine where the feature could possibly do anything, and absent
  exactly where the feature would be a no-op anyway.
- This is the one narrow exception recorded in `.pipeline/02-design/architecture.md`
  §0 ("No new mandatory host dependency is introduced except, specifically
  and narrowly, for the macOS Xcode bridge host helper").

## 3. Wire protocol

One endpoint, one request shape, one response shape. No JSON on either
side — not because JSON is unsafe, but because a NUL-separated-argv request
and a tagged-line response are both trivially producible and consumable in
plain Bash with zero additional tooling (no `jq`, which is an optional,
off-by-default Tool per `.pipeline/02-design/architecture.md` §5.4, so it
cannot be relied on inside the container), while still being exactly as safe
against injection as JSON would be, because the values are never
re-interpreted by a shell on either end.

### 3.1 Request — `POST http://host.docker.internal:<PORT>/invoke`

Body (`Content-Type: application/octet-stream`), NUL (`\0`)-separated
fields, in this fixed order, mirroring the `find -print0`/`xargs -0`
convention already idiomatic in Unix shell tooling (no escaping needed at
all, because NUL cannot occur in a POSIX path or a `argv` element):

```
<op>\0<cwd>\0<arg[0]>\0<arg[1]>\0...\0<arg[n]>\0
```

- `<op>` — the literal host binary to invoke: exactly `xcodebuild` or
  `xcrun` (§4). Nothing else is ever dispatched.
- `<cwd>` — a container-side path (e.g. `/workspace/1-myapp`), translated to
  the real host path before use (§5). Must be a directory.
- `<arg[0..n]>` — passed to the host binary as a literal argv list, in
  order, after allow-list validation (§4) and, for any value that looks like
  a container path, path translation (§5). **Never concatenated into a
  string and never passed through a shell** — the helper always calls
  `subprocess.Popen([op, *validated_args], shell=False, cwd=translated_cwd)`.

### 3.2 Response — tagged-line stream, HTTP/1.0 semantics, connection-close framing

The helper replies with `HTTP/1.0 200 OK`, **no `Content-Length` header**,
`Connection: close`. It writes bytes to the response socket as the
subprocess produces them and closes the connection when the subprocess
exits — this is a deliberately simple, valid form of HTTP streaming (no
chunked-encoding bookkeeping needed) that `curl --no-buffer` on the
container side consumes line-by-line in real time. One in-flight request at
a time is served (a single global lock in the helper); a concurrent request
while one is already running gets an immediate `2|...` + `0|75` response
(`EX_TEMPFAIL`) rather than silently queuing.

Each line written to the body is tagged by a one-character prefix and a
`|`:

| Prefix | Meaning | Example |
|---|---|---|
| `1\|` | one line of the subprocess's stdout | `1\|=== BUILD TARGET MyApp ===` |
| `2\|` | one line of the subprocess's stderr, **or** a rejection message produced before the subprocess was ever started (§4/§5) | `2\|error: scheme "Bogus" not found` |
| `0\|` | always the final line: the integer exit code, closing the stream | `0\|0` |

Reserved application-level exit codes the helper itself produces (never
from the real `xcodebuild`/`xcrun` process, so they are unambiguous), using
the same sysexits.h-style convention the rest of the Bash codebase already
favors for exit-code contracts:

| Code | Meaning | Produced when |
|---|---|---|
| `65` (`EX_DATAERR`) | request rejected before execution | allow-list violation (§4) or path-translation failure (§5) |
| `69` (`EX_UNAVAILABLE`) | Xcode/CLT not usable on this host | `xcode-select -p`/`xcodebuild -version` fails at dispatch time |
| `75` (`EX_TEMPFAIL`) | helper busy | a request arrived while another was already in flight |

A fourth failure mode — the HTTP request never reaching the helper at all
(connection refused/timeout) — is **synthesized client-side** by the
container shim itself (it never comes from the server, because the server
was never reached): the shim exits `69` (`EX_UNAVAILABLE`) with its own
diagnostic (§7) without ever seeing a `0|` line.

### 3.3 Container-side shim shape (illustrative, final enough to build from)

```bash
#!/usr/bin/env bash
# /usr/local/bin/xcodebuild — Xcode bridge shim, shipped in every image
set -euo pipefail
PORT="${XCODE_BRIDGE_PORT:-47870}"
REQ="$(mktemp)"; trap 'rm -f "$REQ"' EXIT
printf '%s\0' "xcodebuild" "$PWD" "$@" > "$REQ"

exit_code=69
if ! curl -fsS --no-buffer --data-binary @"$REQ" \
       -H 'Content-Type: application/octet-stream' \
       "http://host.docker.internal:${PORT}/invoke" 2>/dev/null; then
  echo "xcodebuild (bridge): cannot reach the ClaudeShell Xcode bridge" \
       "helper on the host (host.docker.internal:${PORT}). Enable it from" \
       "ClaudeShell: Tools -> Xcode." >&2
  exit 69
fi | while IFS= read -r line; do
  case "$line" in
    1\|*) printf '%s\n' "${line#1|}" ;;
    2\|*) printf '%s\n' "${line#2|}" >&2 ;;
    0\|*) exit_code="${line#0|}" ;;
  esac
done
exit "$exit_code"
```

(`xcrun` and the `simctl` convenience wrapper — which simply forwards to
`xcrun simctl ...` — are the same shape with `op="xcrun"`.) This is the
concrete contract stage 4 implements; the real script additionally needs to
propagate `exit_code` out of the `while` subshell via a temp file or
process substitution (a known Bash subshell-scoping detail, not a design
ambiguity) — flagged here so stage 4 doesn't have to rediscover it.

## 4. Allow-listed operations (FR-23, enforcement mechanism)

Enforcement lives **only** on the host helper, never trusted to the
container-side shim (a compromised container could call `/invoke` directly,
bypassing the shim entirely — so the shim is a convenience, the table below
is the actual control):

```python
ALLOWED = {
    "xcodebuild": {
        "actions": {"build", "test", "clean", "-list",
                    "-showBuildSettings", "-version"},
        "flags": {"-project", "-workspace", "-scheme", "-target",
                  "-configuration", "-sdk", "-destination",
                  "-derivedDataPath", "-resultBundlePath", "-quiet", "-json"},
        # values following -project/-workspace/-derivedDataPath/
        # -resultBundlePath are path-translated per §5 before use.
    },
    "xcrun": {
        "tools": {
            "simctl": {"list", "boot", "shutdown", "install", "uninstall",
                       "launch", "terminate", "spawn", "getenv", "io"},
        },
        # xcrun <tool> <subcommand> [...] — argv[0] must be a key of "tools",
        # argv[1] must be in that tool's allowed-subcommand set.
    },
}
```

Dispatch rule, stated once and applied uniformly: **every argv element is
either a recognized action/flag/subcommand token checked against this table,
or a value immediately following a recognized flag** (e.g. the scheme name
after `-scheme`) — a value is never itself checked against the table, it is
passed through as a literal, opaque `argv` element. There is no code path
anywhere in the helper that builds a shell string and no code path that
calls `shell=True`, `os.system`, or `eval` — `subprocess.Popen` always
receives a Python list. An argv element that doesn't match any recognized
action/flag/subcommand at its expected position, or an `op`/subtool not
present in the table at all, is rejected with exit `65` (§3.2) before any
process is spawned.

This is intentionally a small v1 set, matching exactly what
`requirements.md` §7's capability matrix asks to be deliverable
(`xcodebuild build`/`test`/`-list`, non-interactive `simctl` operations) —
extending it later (e.g. adding `xccov`, another `xcrun` subtool) is a
one-line addition to this table, not a redesign.

**Addendum (security-review correction — do not reintroduce):** the table
above originally also listed `simctl spawn` and `simctl io`. `spawn` is
Apple's own documented mechanism for executing an arbitrary host executable
with caller-supplied arguments (e.g. `simctl spawn booted /bin/bash -c
'<anything>'`), and neither `spawn` nor `io` was ever in
`requirements.md` §7's capability matrix (list/boot/install/launch/
log-capture only). Combined with the fact that `argv[2:]` for `xcrun` was
never path-translated or shape-checked at all (the `op == "xcodebuild"`
gate in path translation silently excluded every `xcrun` argument), this
was a genuine, exploitable unrestricted-host-code-execution hole — found
by `security-engineer` at stage 6, not a hypothetical. Fixed as follows,
and must stay fixed:

- `spawn` and `io` are **removed** from the `simctl` subcommand set.
  Reintroducing either requires the same scrutiny as adding a brand-new
  capability, not a one-line table edit — `spawn` in particular cannot be
  made safe by argument validation alone, since its entire purpose is to
  execute an arbitrary host binary.
- The remaining `simctl` subcommands (`list`, `boot`, `shutdown`,
  `install`, `uninstall`, `launch`, `terminate`, `getenv`) now have an
  explicit per-subcommand shape check (`_validate_simctl` in the helper):
  fixed arity where the real command has one, a bounded safe-token regex
  (`^[A-Za-z0-9._-]{1,128}$`) for device IDs/bundle IDs/env-var names, and
  a small explicit allow-list of filter tokens for `list`. No `xcrun`
  argument is passed through as a fully unchecked literal anymore, except
  `launch`'s trailing, genuinely free-form app-launch arguments (bounded
  by count and length — a disclosed, narrower judgment call, not an
  oversight).
- `install`'s app-bundle path argument (the one case among the remaining
  subcommands that represents a host path) is now actually mount-confined
  via the same `translate_path`/§5 mechanism `xcodebuild` already used —
  the path-translation gate is no longer hardcoded to `op == "xcodebuild"`.

## 5. Path translation (FR-24)

The container never knows the real host path of anything — by design, it
only ever sees `/workspace/...`. The host helper independently recomputes
the exact same mapping `scripts/lib-mounts.sh::mounts_generate_override`
already produces, rather than trusting the container to assert a host path
(trusting the container here would be a directory-traversal/sandbox-escape
primitive — never done):

1. On every request, the helper re-reads `scripts/mounts.conf` (reloaded if
   its mtime changed since the last read) and rebuilds, in-process, the
   identical table `mounts_generate_override` builds: index `1..N` in file
   order, `target = "/workspace/" + i + "-" + sanitize(basename(path))`
   using the same `tr -c 'a-zA-Z0-9_-' '-'` sanitization rule, plus the
   always-present root mapping `/workspace -> $SCRIPT_ROOT/workspace`.
2. A container-side path argument (`cwd`, or any `-project`/`-workspace`/
   `-derivedDataPath`/`-resultBundlePath` value) must match either exactly
   `/workspace` or `/workspace/<n>-<rest>` where `<n>` is one of the
   currently-mounted indices. Anything else — a bare relative path, a path
   under `/etc`, `/home/claude`, or any other container-internal location,
   or a `/workspace/<n>-...` where `<n>` is not a currently mounted index —
   is **rejected outright** (`65`, §3.2) with a diagnostic naming the exact
   path that failed and pointing at `Manage mounted folders`. There is no
   fallback to "use the project root" or any other default; an unresolvable
   path is always a hard error, never a silent substitution.
3. The matched prefix is replaced with the corresponding host path, the
   remainder is appended unchanged, and the result is canonicalized
   (`os.path.realpath`). The canonicalized result **must still be a
   descendant of the expected host root** (string-prefix check against the
   canonicalized root, done *after* resolving symlinks/`..`) — this is the
   concrete defense against a crafted `/workspace/1-myapp/../../../etc`
   style argument; if the canonical path escapes the mounted root, it is
   rejected exactly like case 2, never "clamped" back into range.
4. Only after steps 1–3 succeed does the helper hand the translated,
   canonical host path to the allow-listed binary.

## 6. Security posture and residual risk

**Blast radius if the container is compromised:** an attacker with full
control of the container can, at most, invoke the operations in §4's table
against host paths that correspond to folders the user already explicitly
mounted (§5) — nothing else. Concretely this means they can: trigger
`xcodebuild build`/`test`/`clean` and inspect its output/build settings for
a mounted project, and drive `simctl` for a simulator (list/boot/shutdown/
install/uninstall/launch/terminate/getenv) against mounted app bundles —
`spawn`/`io` are not part of this list; they were removed from the
allow-list (see §4's addendum) and are not something a compromised
container can currently do. It explicitly does **not** mean
they can: read or write any host file outside a mounted folder (§5 rejects
it), run an arbitrary host binary or shell command (no shell, no
non-allow-listed `op`), escalate to root on the host (the helper runs as the
unprivileged user who started it — this path has nothing to do with the
Firewall's narrow, unrelated passwordless-`sudo` grant for
`init-firewall.sh`), or reach the helper from any machine other than the one
running Docker Desktop (§1's loopback-only bind).

**Disclosed residual risk, not closable by the allow-list alone:** once
`xcodebuild build`/`test` is allow-listed at all, the *project file itself*
(already sitting on the host disk, inside a folder the user already
mounted) can define arbitrary **Run Script build phases**, which `xcodebuild`
will execute as part of a normal build — on the host, as the user who runs
the helper. The bridge does not grant this capability; it exposes a
capability that already existed (anyone who runs `xcodebuild build` on that
project from Terminal gets the exact same Run Script execution) to a new
caller — code running inside the container. This is accepted, not
papered over: a project someone chose to mount and build through the bridge
is a project they are implicitly trusting to the same degree they'd trust
running `xcodebuild` on it themselves. It is listed explicitly in
`.pipeline/02-design/architecture.md`'s risk table as a residual risk
inherent to delivering real build functionality at all, not a gap the
allow-list failed to close.

**Addendum — three additional hardening fixes from the same security
review pass:**

- **TOCTOU symlink race — two tiers of mitigation, disclosed honestly as
  unequal:**
  - **`cwd` (fully closed):** opened with `os.open(path, os.O_NOFOLLOW |
    O_DIRECTORY)` immediately after the §5 containment check, and the
    resulting file descriptor — not a re-resolvable path string — is
    passed to `subprocess.Popen(cwd=<fd>)`. A symlink swap after
    validation cannot redirect an already-open descriptor. This is a
    genuine, complete fix for this one argument.
  - **`-project`/`-workspace`/`-derivedDataPath`/`-resultBundlePath`
    (`xcodebuild`) and `simctl install`'s app-bundle path (`xcrun`) —
    narrowed, not fully closed:** `subprocess.Popen`'s argv cannot carry a
    file descriptor in place of a string, and macOS has no `/proc/self/fd`
    equivalent that would let the helper hand the *child* process a
    descriptor-backed path reference the way Linux's `/proc/self/fd/<n>`
    trick allows (macOS's own `/dev/fd/<n>` was considered, but rewriting
    the argument to a synthetic devfs path risks breaking `xcodebuild`'s
    own internal path handling — e.g. scheme/relative-path resolution that
    assumes a conventional on-disk path — in a way that cannot be verified
    without a real macOS host, so it was deliberately not attempted).
    Instead, `confine_for_argv()` adds a second, independent check beyond
    `translate_path`'s realpath/containment logic: immediately before the
    value is placed into the final argv, the resolved path (or, if the
    leaf does not yet exist — legitimate for `-derivedDataPath`/
    `-resultBundlePath`, which `xcodebuild` creates — the nearest existing
    ancestor directory, walked up at most 16 levels) is opened with
    `O_NOFOLLOW | O_DIRECTORY` and immediately closed. This catches a
    symlink substitution at or above the target at the moment of this
    second check, shrinking the exploitable window to the gap between
    this check and `xcodebuild`/`simctl`'s own later, helper-uncontrolled
    open — but does **not** eliminate that gap, since the actual
    dereference still happens inside a separate process at an
    unpredictable later time. This is a disclosed, reduced-not-closed
    residual risk specifically for these five argument slots, distinct
    from `cwd`'s complete fix.
- **Execution timeout:** every dispatched operation now has a hard wall-
  clock deadline (`DEFAULT_OPERATION_TIMEOUT_SECONDS = 300`). If no output
  arrives before the deadline, the subprocess is killed, `2|operation
  timed out...` + `0|124` is sent, and — critically — the single global
  lock is released regardless. Before this fix, a hung `xcodebuild`/
  `simctl boot` held the lock forever, permanently denying the bridge to
  every subsequent request.
- **Bounded request body:** `Content-Length` greater than
  `MAX_REQUEST_BODY_BYTES` (64KiB) is rejected (`65`) before any `read()`
  of the body, closing an unbounded-memory-allocation DoS vector.

## 7. Error and diagnostic behavior (FR-25)

One concrete, distinguishable behavior per failure mode — never a generic
"something went wrong," never a false "success":

| Condition | Where detected | Behavior |
|---|---|---|
| Helper not running / unreachable | Container shim's `curl` call fails (connection refused/timeout) | Shim prints the host-unreachable diagnostic (§3.3) to stderr, exits `69`. No `0\|` line is ever seen because the server was never reached. |
| Not actually a macOS Docker Desktop host (Linux, or the bridge path somehow invoked despite FR-20 hiding the menu item) | Same as above — nothing is listening, because the helper is only ever started by macOS-only code (§9) | Identical "unreachable" diagnostic/exit `69` — no OS-sniffing needed inside the container; absence of a listener is itself the safe failure mode. |
| Xcode/CLT not installed on the host | Helper runs `xcode-select -p` (and/or `xcodebuild -version`) before dispatching any real request | Helper writes `2\|Xcode Command Line Tools are not installed on this host.` then `0\|69`; shim relays both verbatim. |
| Requested operation not on the allow-list | Helper's dispatch table lookup (§4) | `2\|operation '<op> ...' is not on the Xcode bridge allow-list` then `0\|65`. |
| Requested path not reachable via any mount | Helper's path-translation step (§5) | `2\|path '<container-path>' is not under any currently mounted folder; mount it first via ClaudeShell -> Manage mounted folders` then `0\|65`. |

Every one of these is relayed to the container-side caller (and therefore
to Claude Code) as real stderr text plus a real nonzero exit code — never
swallowed, never reported as success.

## 8. Capabilities that will not work

Stated plainly, matching `requirements.md` §7's capability matrix exactly,
because the task explicitly forbids faking or proposing a workaround for
these:

- **GUI interaction** — Xcode.app windows, Interface Builder, a visible
  Simulator window. The bridge is a batch command-dispatch mechanism over a
  loopback HTTP socket; it has no connection to the host's display server
  (WindowServer) and never invokes `open`/launches a GUI application. Note
  that `simctl boot` itself does not open a visible Simulator window either
  (that requires `open -a Simulator`, which is not on the allow-list and
  never will be for this reason) — booting a simulator via the bridge is a
  headless operation, consistent with what's actually deliverable.
- **Interactive debugging** — attaching `lldb`, stepping through code,
  breakpoints, REPL-style inspection. This model is one HTTP request → one
  subprocess → a streamed result; there is no persistent, bidirectional,
  low-latency terminal session backing it, and building a fake one (e.g. a
  polling-based pseudo-REPL) would be exactly the kind of stubbed support
  the task forbids rather than a genuine capability. Only batch invocation
  and result/log retrieval are delivered, as already scoped in
  `requirements.md` §7.

## 9. Helper lifecycle: install, start, stop, graceful degradation (NFR-7)

All platform-specific code for this lives under `scripts/platform/macos/`,
sourced/invoked only when `platform_is_macos` (from `lib-platform.sh`,
`.pipeline/02-design/architecture.md` §7) is true — never on Linux/Windows,
confirming §1's "fails safe by absence" claim.

- `scripts/platform/macos/xcode-bridge-helper.py` — the helper itself
  (stdlib-only, §2).
- `scripts/platform/macos/lib-xcode-bridge.sh` — host-side control
  functions, sourced by `manage-tools.sh` only on macOS:
  - `xcode_bridge_detect()` — runs `xcode-select -p`/`xcodebuild -version`
    **directly on the host**, no bridge round-trip needed, since
    `manage-tools.sh` already runs as a plain host process. This is what
    satisfies FR-21 ("Selecting/enabling the Xcode tool triggers host
    Xcode/CLT detection") — the bridge itself is only needed for the
    container→host path (FR-22), not for this host-side check.
  - `xcode_bridge_start()` — if `scripts/platform/macos/.bridge.pid` doesn't
    name a live process, starts
    `nohup python3 scripts/platform/macos/xcode-bridge-helper.py --port "$XCODE_BRIDGE_PORT" >~/.claude-shell/xcode-bridge.log 2>&1 & disown`,
    recording the PID — the same PID-file convention
    `.pipeline/02-design/architecture.md` §8.1 already uses for
    `docker/.build.lock`.
  - `xcode_bridge_stop()` — kills the recorded PID, clears the pidfile.
  - An optional, secondary convenience action in the `Tools -> Xcode` row,
    "Install login-item (auto-start)", writes a `launchd` user-agent plist
    (`~/Library/LaunchAgents/com.claudeshell.xcode-bridge.plist`) that runs
    the same helper command at login. This is explicitly optional — the
    foreground start above always works without it, so no new *mandatory*
    host dependency or setup step is introduced (NFR-7).
- Toggling `TOOL_XCODE` off in `Tools` calls `xcode_bridge_stop()` and sets
  `XCODE_BRIDGE_ENABLED=0` (consumed by `docker-compose.yml`, see §10) —
  it does **not** touch any Dockerfile `ARG`/layer (nothing is installed in
  the Linux-based image for a host-only toolchain), matching
  `.pipeline/02-design/architecture.md` §5.7.
- **Graceful degradation:** if `python3` itself can't run the helper (which,
  per §2, also implies CLT isn't installed), `manage-tools.sh` reports the
  concrete reason from `xcode_bridge_detect()`, leaves `TOOL_XCODE=off`, and
  nothing else in ClaudeShell is affected. If the helper was running and then
  dies later (crash, manual `kill`, logout without the optional login-item),
  the container-side shim's §7 "unreachable" diagnostic is what surfaces
  that — no component anywhere crashes as a result; the rest of ClaudeShell
  (Firewall, Tools for other slugs, Image, Mounts) is fully unaffected,
  satisfying NFR-7's "absence must degrade to a clear diagnostic, not a
  crash."

## 10. Runtime wiring recap

Two environment variables, both wired through `docker-compose.yml` exactly
like `DISABLE_FIREWALL` is today (same `${VAR:-default}` pattern, no new
Compose feature):

```yaml
environment:
  - XCODE_BRIDGE_ENABLED=${XCODE_BRIDGE_ENABLED:-0}
  - XCODE_BRIDGE_PORT=${XCODE_BRIDGE_PORT:-47870}
```

Set by `scripts/run-claude.sh` from `tools_enabled xcode` and
`scripts/platform/macos/.bridge.pid`'s recorded port, respectively, before
every `docker compose run` — the same read-at-launch pattern the Firewall
status line (`.pipeline/02-design/architecture.md` §1.1) already uses.
No `extra_hosts` entry is added for `host.docker.internal` (§1) — Docker
Desktop injects it automatically on macOS, and adding it manually would only
matter for native Linux Docker Engine, where there is deliberately nothing
listening on the other end anyway (§1, §7). Toggling `TOOL_XCODE` never
dirties `compute_build_hash` and never triggers a rebuild — nothing in the
image changes; the container-side shims (§3.3) ship unconditionally in every
build regardless of the toggle, and simply always report "bridge
unreachable" when `XCODE_BRIDGE_ENABLED` is effectively off/absent, which is
the only behavior they need on Linux and Windows/WSL2 as well (no
bridge-specific platform branching inside the container at all, confirming
`.pipeline/02-design/architecture.md` §7's claim).
