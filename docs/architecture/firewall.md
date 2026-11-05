# ClaudeShell — Firewall Architecture

This document is the dedicated Firewall architecture reference required by
the Firewall/Tools/Image workstream (task §7). It complements
`.pipeline/02-design/architecture.md` (the full stage-2 report) by
collecting everything Firewall-specific in one place: current mechanism,
new mechanism, the finalized service table, security invariants, platform
notes, and persistence behavior. Nothing here changes once the broader
stage-2 report is accepted — this file is the detail reference for FR-4
through FR-12, NFR-1 through NFR-3, UC-1/UC-2/UC-7/UC-8/UC-9/UC-10.

## 1. Current mechanism (as verified by reading the code)

`docker/entrypoint.sh` checks `DISABLE_FIREWALL`. If it is not `1`, it runs
`sudo /usr/local/bin/init-firewall.sh` — passwordless `sudo` is granted to
the `claude` user for exactly this one script
(`Dockerfile`: `echo "claude ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh" >> /etc/sudoers`).

`init-firewall.sh` today:

1. Flushes all iptables rules/chains and destroys any existing
   `allowed-domains` ipset.
2. Sets default policy `DROP` on `INPUT`/`FORWARD`/`OUTPUT`.
3. Allows loopback, established/related connections, Docker's own injected
   DNS rules (copied from `iptables-save | grep 127.0.0.11`), and port 53 to
   whatever resolver `/etc/resolv.conf` names.
4. Creates `ipset allowed-domains hash:net`, seeds it with a static
   Anthropic CIDR (`160.79.104.0/21`) and a hardcoded 14-domain
   `ALLOWED_DOMAINS` array (Anthropic API/console/Claude.ai/Statsig, npm,
   GitHub), resolved via `dig`, plus GitHub's published CIDR ranges fetched
   live from `https://api.github.com/meta`.
5. Allows `OUTPUT` to anything in `allowed-domains`; `REJECT`s everything
   else with `icmp-admin-prohibited` on both `INPUT` and `OUTPUT`.
6. Re-runs the domain resolution every 300 seconds in a disowned background
   subshell (DNS answers drift; the ipset is refreshed, not rebuilt from
   scratch each time).

There is exactly one on/off switch (`DISABLE_FIREWALL` env var, wired
through `docker-compose.yml`'s `environment:` block), no per-service
granularity, and no persistence — today it is set per-session from a
`start.sh` sub-menu that is removed by this work (see §3 below).

## 2. New mechanism

### 2.1 Modes (FR-4)

- **Disabled** — `DISABLE_FIREWALL=1`, identical in effect to today's
  "Firewall OFF": `entrypoint.sh` prints a warning and skips
  `init-firewall.sh` entirely. Fully open egress.
- **Recommended** — `DISABLE_FIREWALL` unset/`0`: `entrypoint.sh` runs
  `sudo init-firewall.sh` exactly as today, which now builds its allow-list
  from persisted per-service state instead of a single hardcoded array.

These are the **only** two modes (FR-4) — there is no partial/custom mode
distinct from Recommended; "custom" is expressed *within* Recommended via
per-service toggles and custom domain/CIDR entries (FR-5/FR-7), not as a
third top-level mode.

### 2.2 Config format and location (NFR-1)

`scripts/firewall.conf` — host-side, plain-text, git-ignored (added to
`.gitignore` alongside `scripts/mounts.conf`), outside any image/volume, so
it survives `docker image rm`, volume recreation, and self-updates (NFR-1).

```
MODE=recommended
SERVICE_NPM=on
SERVICE_GITHUB=on
SERVICE_GITLAB=on
SERVICE_PYPI=on
SERVICE_DOCKERHUB=on
SERVICE_HUGGINGFACE=off
SERVICE_MICROSOFT=off
SERVICE_APPLE=off
SERVICE_GO=off
SERVICE_RUST=on
CUSTOM_1=example.com
CUSTOM_2=10.0.0.0/24
```

Owned, read, and written by `scripts/lib-firewall.sh` — the single parser
used both host-side (by `manage-firewall.sh`) and container-side (bind-mounted
into the running container and `source`d by `init-firewall.sh`), so there is
exactly one implementation of "what counts as a valid config" (NFR-8).

The Anthropic API/console group is **mandatory and not represented in this
file** — see §4.1. It is not a "service" a user can disable, because
disabling it would stop Claude Code itself from functioning, which is a
materially different kind of risk than disabling, say, PyPI access.

### 2.3 How the config reaches enforcement (FR-9/FR-10)

`docker/docker-compose.yml` bind-mounts two files read-only, statically
(not a generated per-user override — the path is always the same relative
location, unlike `mounts.conf`'s per-user paths):

```yaml
volumes:
  - ../scripts/firewall.conf:/etc/claude-shell/firewall.conf:ro
  - ../scripts/lib-firewall.sh:/etc/claude-shell/lib-firewall.sh:ro
```

`scripts/run-claude.sh` calls `firewall_conf_ensure` before every
`docker compose run`, guaranteeing the bind-mount source exists (an absent
host file bind-mounted by older Docker versions becomes an empty directory,
which would break `source` inside the container — this call makes that
impossible). Toggling mode or any per-service state writes
`scripts/firewall.conf` immediately; enforcement is only (re-)evaluated at
container-start time, exactly as today — **no image rebuild is ever
required or triggered by a Firewall change** (FR-9), because
`scripts/firewall.conf` is deliberately excluded from
`run-claude.sh`'s `compute_build_hash` (see `.pipeline/02-design/architecture.md`
§5.8/§6 for why Firewall and Tools build/runtime concerns are genuinely
decoupled, not merely assumed to be).

### 2.4 Finalized Recommended service table

| Slug | Service | Domains/CIDRs | Default |
|---|---|---|---|
| *(mandatory, not a toggle)* | Anthropic API/Console | `api.anthropic.com`, `console.anthropic.com`, `platform.claude.com`, `claude.ai`, `statsig.anthropic.com`, `statsig.com`, `api.statsig.com`, CIDR `160.79.104.0/21` | always on |
| `npm` | npm registry | `registry.npmjs.org`, `npmjs.org`, `www.npmjs.org` | on |
| `github` | GitHub | `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, + live CIDR ranges from `api.github.com/meta` | on |
| `gitlab` | GitLab | `gitlab.com`, `registry.gitlab.com`, `assets.gitlab-static.net` | on |
| `pypi` | PyPI | `pypi.org`, `files.pythonhosted.org` | on |
| `dockerhub` | Docker Hub | `registry-1.docker.io`, `auth.docker.io`, `index.docker.io`, `production.cloudflare.docker.com` | on |
| `rust` | Rust toolchain | `static.rust-lang.org`, `crates.io`, `static.crates.io`, `index.crates.io` | on |
| `huggingface` | Hugging Face | `huggingface.co`, `cdn-lfs.huggingface.co`, `cdn-lfs-us-1.huggingface.co` | off |
| `microsoft` | Microsoft dev services | `api.nuget.org`, `nuget.org`, `marketplace.visualstudio.com`, `vscode.blob.core.windows.net`, `dotnet.microsoft.com`, `download.visualstudio.microsoft.com` | off |
| `apple` | Apple dev resources | `developer.apple.com`, `swift.org`, `download.swift.org` | off |
| `go` | Go toolchain | `proxy.golang.org`, `sum.golang.org` | off |

`go` deliberately excludes `storage.googleapis.com` (the module proxy's
underlying CDN) because that domain is broad enough to front a large amount
of unrelated Google Cloud Storage content — enabling it by default would
meaningfully widen the allow-list beyond what "Go toolchain access" implies.
A user whose module fetches need the GCS fallback path can add it via the
custom-entry mechanism (FR-7) with full awareness of what they're opening.

`huggingface`/`microsoft`/`apple`/`go` default **off** — each unblocks a
specific workflow most installs won't need; `npm`/`github`/`gitlab`/`pypi`/
`dockerhub`/`rust` default **on** as the curated baseline a typical dev
container needs. Restoring defaults (FR-8) resets to exactly this on/off
split.

### 2.5 Custom entries (FR-7)

`CUSTOM_<n>=<domain-or-CIDR>`, dense 1-based numbering. Added via
`manage-firewall.sh`'s `+ Add custom domain/CIDR` action, validated against
the same domain/CIDR regex `firewall_parse_strict` enforces on read, so a
value that would be rejected on the next read is rejected at write time
instead. Removal re-numbers the sequence (same approach as
`mounts_remove_by_index`'s line-delete-and-reindex). Custom entries are
additive only — there is no mechanism to *remove* a mandatory or
built-in-service domain via this path; the only way to reduce scope is
toggling a whole service off.

## 3. Migration of the old per-session prompt (FR-3)

`start.sh`'s current `run)` branch pops a three-item sub-menu ("Firewall
ON" / "Firewall OFF" / "Back") that sets `DISABLE_FIREWALL` for one
invocation and persists nothing. This is **deleted**, not kept behind a
flag — FR-3 explicitly names it as superseded. It is replaced by a one-line
status print reading the persisted mode before every launch:

```
Firewall: Recommended (6 service(s) active). Change this in the Firewall menu.
```

or

```
Firewall: Disabled — unrestricted egress. Change this in the Firewall menu.
```

This is the only user-visible behavior change in the whole Firewall
workstream, and it is intentional: the user is never surprised by a silent
switch, but is also never re-asked on every run, matching UC-2's "toggles
one service off, saves; the next Run Claude Code enforces the new list
immediately, with no image rebuild."

## 4. Security invariants

### 4.1 Fail-safe default, never default-allow (FR-11, UC-8)

- `scripts/firewall.conf` is parsed by a **strict, whitelist-based** line
  parser (`firewall_parse_strict`), not `source`d as shell — a hand-edited
  file cannot inject arbitrary bash into either the host UI process or the
  privileged container-side `init-firewall.sh` process.
- Any single invalid line (wrong `KEY` shape, `MODE` value other than
  `disabled`/`recommended`, `SERVICE_*` value other than `on`/`off`,
  `CUSTOM_*` value that isn't a syntactically valid domain or IPv4 CIDR)
  invalidates the **entire file** — there is no partial-trust mode.
- On any invalidation (missing file, unreadable file, malformed file), every
  reader falls back to the curated Recommended defaults from §2.4. **There
  is no code path that produces an open/default-allow firewall as a result
  of a parse failure** — the only way to reach `Disabled` is a successfully
  parsed `MODE=disabled` line in an otherwise fully valid file.
- This check happens independently in two places (host-side
  `firewall_conf_ensure`/`firewall_parse_strict` before the container even
  starts, and container-side inside `init-firewall.sh` via the same
  `source`d `lib-firewall.sh`) — defense in depth, not reliance on a single
  checkpoint.

### 4.2 Scoped sudo, never widened (NFR-3)

The passwordless-sudo grant stays scoped to exactly
`/usr/local/bin/init-firewall.sh`, byte-for-byte the same sudoers line as
today. Nothing in this design asks for broader sudo — Tools installation
happens at `docker build` time (root context by default, no sudo needed,
no running-container privilege at all), and the Xcode bridge never touches
the container's own sudo configuration (see `docs/architecture/xcode-bridge.md`).

### 4.3 Default-deny, never a deny-list (NFR-3)

The iptables policy shape is unchanged: default `DROP` on all chains, a
single `ACCEPT` rule for the `allowed-domains` ipset, `REJECT` for
everything else. Per-service toggles only ever change *what gets added to*
the ipset before that final `ACCEPT`/`REJECT` pair is installed — there is
no code path that flips the overall policy to default-`ACCEPT` with
per-service `DROP` rules layered on top.

### 4.4 Mandatory Anthropic access is not a security weakening

Making the Anthropic API group non-togglable is a deliberate asymmetry: it
is the one thing the container must always be able to reach for the
application to function at all (same reasoning the Tools design applies to
keeping `git`/Node mandatory rather than toggleable). It does not expand the
attack surface beyond what today's hardcoded list already always allowed.

## 5. Platform notes

- **Linux (Docker Engine)** — native `cap_add: NET_ADMIN, NET_RAW` on a real
  kernel; no difference from today.
- **macOS (Docker Desktop)** — the container runs inside Docker Desktop's
  Linux VM; iptables/ipset operate on that VM's container network
  namespace exactly as on native Linux. No macOS-specific code in the
  firewall path at all.
- **Windows (Docker Desktop, WSL2 backend)** — the container runs on the
  same real Linux kernel Docker Desktop's WSL2 backend provides; there is no
  Windows-native networking stack involved in the container's own network
  namespace. This is asserted here on the basis of how Docker Desktop's
  WSL2 backend is documented to work, and should get one real
  confirmation run during stage 5 (test) to close UC-10 as empirically
  verified rather than assumed — no firewall code changes are anticipated
  as a result of that verification; this is a test-coverage gap, not a
  design gap.

## 6. Persistence and restore behavior (FR-10/FR-11)

| Event | Behavior |
|---|---|
| Shell restart (`start.sh` exits and is re-run) | `scripts/firewall.conf` unchanged on disk; next `firewall_conf_ensure` is a no-op; mode/services exactly as left. |
| Container restart (`docker compose run` again) | Config is re-read fresh at every container start (it always was — `init-firewall.sh` runs at every `entrypoint.sh` invocation); no in-container caching to go stale. |
| Image rebuild/update (`Image` section) | `scripts/firewall.conf` is host-side and untouched by any Image action (see `.pipeline/02-design/architecture.md` §8.5); the next container run after a rebuild enforces whatever was last configured, unchanged. |
| File manually deleted | Next `firewall_conf_ensure` recreates it with curated Recommended defaults (§2.4) — equivalent to a fresh install, not an error. |
| File manually corrupted (UC-8) | `firewall_parse_strict` rejects it; a warning is printed; curated Recommended defaults are used for that run without ever writing over the user's file automatically (so the user can inspect/fix their hand-edit without losing it, rather than having it silently overwritten) — a subsequent explicit `Restore recommended defaults` action is what actually rewrites the file on disk. |
