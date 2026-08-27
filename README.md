# oab-sandbox

A hardened container sandbox for running a coding agent with a Discord front-end.

The design goal is narrow and testable: **the service-account private key must never
exist inside the container that runs the agent.** Everything else — the read-only
rootfs, the dropped capabilities, the egress allowlist — exists to make that one
guarantee hold even after the agent itself is assumed compromised.

Every hardening flag in `run.sh` was verified empirically, and `verify-hardening.sh`
re-checks them. Findings that contradicted the original plan are recorded in
`notes.md` rather than quietly fixed.

## Architecture

```
                            oab-ext  (has a route to the internet)
                                 │
                        ┌────────┴────────┐
                        │    oab-proxy    │   squid, domain allowlist:
                        │     (squid)     │   *.googleapis.com, *.discord.com,
                        └────────┬────────┘   r.jina.ai — everything else denied
                                 │
 ══════════════ oab-int  (--internal: no route out at all) ═══════════════
              │                                        │
   ┌──────────┴──────────┐                  ┌──────────┴──────────┐
   │     oab-sandbox     │                  │     oab-broker      │
   │                     │ ── token req ──▶ │                     │
   │  openab + pi agent  │                  │  holds the SA key   │
   │  vault mounted rw   │ ◀── short-lived  │  (mounted :ro)      │
   │  NO credentials     │      token ───── │  GCE-metadata API   │
   └─────────────────────┘                  └─────────────────────┘
```

Three properties follow from this layout:

- **The agent container has no credentials.** It is given `GCE_METADATA_HOST=oab-broker:8080`
  and nothing else. `GOOGLE_APPLICATION_CREDENTIALS` is deliberately *not* inherited.
  Google's auth libraries treat the broker as if it were GCE's metadata server.
- **The agent container has no route out.** It sits on an `--internal` network. The only
  path to the internet is through squid, which enforces a domain allowlist.
- **The broker is the smallest possible blast radius.** No shell tooling, no curl, no git;
  runs as uid 1000; dependencies pinned via `package-lock.json` and installed with `npm ci`.

## Prerequisites

- Docker (tested on Docker Desktop, arm64)
- A GCP service-account key at `~/.config/openab/sa-key.json` — mounted read-only into
  the broker, never copied into any image
- A Discord bot token. If you already run this agent elsewhere, **create a second bot**:
  sharing one token means both instances answer every message.
- A working directory to mount as the agent's workspace at `./vault`

## Setup

```sh
# 1. Configuration — the real file is gitignored; it holds your own identifiers
cp config/config.toml.example config/config.toml
$EDITOR config/config.toml          # set allowed_users and GOOGLE_CLOUD_PROJECT

# 2. Build both images (run.sh expects them to exist)
docker build -t oab-sandbox:pi .
docker build -t oab-broker:latest broker/

# 3. Check the hardening flags actually took effect
./verify-hardening.sh

# 4. Run
export DISCORD_BOT_TOKEN=<your bot token>
./run.sh

# 5. Stop — this is not a long-running service
./stop.sh
```

`verify-hardening.sh` is worth re-running after any change to `run.sh`, any image
rebuild, or any Docker Desktop upgrade. It asserts capabilities are empty, the process
is non-root, `no_new_privs` is set, the rootfs is read-only, `/tmp` is `noexec`, and the
memory and pid ceilings are in place.

## Layout

| Path | What it is |
|---|---|
| `Dockerfile` | Thin layer over `ghcr.io/openabdev/openab:stable-pi`. Adds python3 and bumps pi — it deliberately rebuilds nothing from the base. |
| `broker/` | The token broker. Its `server.js` implements just enough of the GCE metadata API for Google's auth libraries to accept it. |
| `proxy/squid.conf` | Egress allowlist, plus a bandwidth pool for `r.jina.ai`. |
| `config/config.toml.example` | Template for the agent config. The real `config.toml` is gitignored. |
| `config/pi-coach` | Model wrapper the agent invokes instead of `pi` directly. |
| `config/adc-marker.json` | **Not a credential.** Deliberately invalid JSON that only exists to satisfy pi's `fileExists` gate; anything that actually parses it fails loudly, which is the point. |
| `learn/` | Standalone experiments — see below. |
| `docs/` | Written explanations, including a walkthrough of the full call chain. |
| `notes.md` | Chronological build log: what was tried, what the plan got wrong, what is still open. |

## Experiments

`learn/` holds small, re-runnable scripts. Each one opens with what it tests, what you
should expect to see, what it costs, and how to re-run it. They cover context growth
across turns, truncation behaviour, the tool boundary, session directory resolution,
and a cross-model instruction-compliance eval.

Several of them make a real Vertex call (on the order of $0.0001 each). They resolve the
GCP project id through `learn/lib/project-id.sh`: `$GOOGLE_CLOUD_PROJECT` if exported,
otherwise the value in `config/config.toml`, and a hard error if neither is present.

## Known gaps

- **`/proc/1/environ` is readable by the agent's own child processes**, which exposes
  `DISCORD_BOT_TOKEN` — the bot cannot function without it, so this is not fixable by
  removing the variable. `verify-hardening.sh` prints the leaked variable *names* (never
  values) so the list stays visible. Turning it into an assertion — "this must be the
  *only* secret there" — is still open.
- **`config/pi-coach` and `run.sh` assume the repo lives at `~/Projects/oab-sandbox`.**

## A note on `vault/`

`vault/` is a separate git repository with its own remote and its own history, and it is
gitignored here on purpose rather than vendored as a submodule. To change it,
`cd vault && git ...`. This repo treats it purely as the directory that gets mounted
into the agent's workspace.
