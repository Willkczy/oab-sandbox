# oab-sandbox

An LLM coach for algorithm practice, and the hardened container it runs in.

The agent is `pi`, a general coding agent, pointed at an Obsidian vault of algorithm
problems and told by the vault's own `AGENTS.md` to coach rather than solve: never hand
over a solution, one tier of hint at a time, every review backed by something the
student actually wrote. None of those rules has a system layer behind it, so this repo
measures them instead of trusting them — `learn/10-model-compliance-eval.sh` is re-run
after every model change, and finding 6 records what it caught.

The container around the agent has one narrow, testable design goal: **the
service-account private key must never exist inside the container that runs the
agent.** Everything else — the read-only rootfs, the dropped capabilities, the egress
allowlist — exists to make that one guarantee hold even after the agent itself is
assumed compromised. The front-end is Discord, through openab. Its gateway websocket
ignores the egress proxy, so a small relay carries it through the same gate as
everything else (finding 8). A real conversation has run over that path, with every
hop visible in squid's log.

Every hardening flag in `run.sh` was verified empirically, and `verify-hardening.sh`
re-checks them. Findings that contradicted the original plan were written down rather
than quietly fixed — including the ones still unresolved. See
[docs/findings.md](docs/findings.md), which is the most interesting document here:
an existence check that never reads the file, a permission table nothing enforces,
and a script that reported a week-old number without ever erroring.

## If you have five minutes

1. [docs/findings.md](docs/findings.md) — the eight findings. Start here.
2. [`learn/10-model-compliance-eval.sh`](learn/10-model-compliance-eval.sh) — the
   header says why the coaching rule can only be measured, never enforced.
   [`learn/lib/grade_compliance.py`](learn/lib/grade_compliance.py) says where the
   line between a hint and a solution is drawn, and why it is not a line count.
3. [Known gaps](#known-gaps) — what is still open, including the Discord path above.

## Architecture

```
                                   oab-ext  (has a route to the internet)
                                           │
                                  ┌────────┴────────┐
                                  │    oab-proxy    │   squid, domain allowlist:
                                  │     (squid)     │   *.googleapis.com, *.discord.com,
                                  └────────┬────────┘   gateway.discord.gg, r.jina.ai
                                           │            — everything else denied
 ═════════════════════ oab-int  (--internal: no route out at all) ═════════════════════
          │                                │                                │
┌─────────┴─────────┐            ┌─────────┴─────────┐            ┌─────────┴─────────┐
│     oab-relay     │            │    oab-sandbox    │            │    oab-broker     │
│                   │ ◀─ wss ──  │                   │ ─ token ─▶ │                   │
│ socat: CONNECT    │  gateway   │ openab + pi agent │  request   │ holds the SA key  │
│ via oab-proxy     │            │ vault mounted rw  │ ◀─ token ─ │ (mounted :ro)     │
│ TLS left intact   │            │ NO credentials    │ short-lived│ GCE-metadata API  │
└───────────────────┘            └───────────────────┘            └───────────────────┘
```

Three properties follow from this layout:

- **The agent container has no credentials.** It is given `GCE_METADATA_HOST=oab-broker:8080`
  and nothing else. `GOOGLE_APPLICATION_CREDENTIALS` is deliberately *not* inherited.
  Google's auth libraries treat the broker as if it were GCE's metadata server.
- **The agent container has no route out.** It sits on an `--internal` network. The only
  path to the internet is through squid, which enforces a domain allowlist. openab's
  gateway websocket ignores proxy settings, so the agent resolves `gateway.discord.gg`
  to `oab-relay`, which opens the `CONNECT` tunnel on its behalf. TLS stays end to end,
  and squid refuses any destination that resolves to a private address.
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

# 2. Build the three images (run.sh expects them to exist)
docker build -t oab-sandbox:pi .
docker build -t oab-broker:latest broker/
docker build -t oab-relay:latest relay/

# 3. Check the hardening flags actually took effect
./verify-hardening.sh

# 4. Run
export DISCORD_BOT_TOKEN=<your bot token>
./run.sh

# 5. Stop — this is not a long-running service
./stop.sh
```

`stop.sh` copies the agent's session log out of the container before removing it, into
`learn/out/archive/<timestamp>/` (gitignored). pi writes those sessions to a tmpfs so the
agent only ever sees the current one — `config/pi-coach` explains why — and archiving
them keeps the full history without giving that property up, because the archive lives on
the host where the agent cannot reach it. **Do not add `learn/` to `run.sh`'s mount
list**; that would hand the accumulated history straight back to the agent.


`verify-hardening.sh` is worth re-running after any change to `run.sh`, any image
rebuild, or any Docker Desktop upgrade. It asserts capabilities are empty, the process
is non-root, `no_new_privs` is set, the rootfs is read-only, `/tmp` is `noexec`, and the
memory and pid ceilings are in place, for the relay as well as the agent. It also checks
that the relay can still bind port 443 without privileges, which depends on a Docker
default rather than on anything in this repo.

## Layout

| Path | What it is |
|---|---|
| `Dockerfile` | Thin layer over `ghcr.io/openabdev/openab:stable-pi`. Adds python3 and bumps pi — it deliberately rebuilds nothing from the base. |
| `broker/` | The token broker. Its `server.js` implements just enough of the GCE metadata API for Google's auth libraries to accept it. |
| `relay/` | The Discord gateway relay: socat alone in an alpine image, turning each connection into a `CONNECT` tunnel through squid. |
| `proxy/squid.conf` | Egress allowlist, a bandwidth pool for `r.jina.ai`, and a rule that never tunnels into a private address. |
| `config/config.toml.example` | Template for the agent config. The real `config.toml` is gitignored. |
| `config/pi-coach` | Model wrapper the agent invokes instead of `pi` directly. |
| `config/adc-marker.json` | **Not a credential.** Deliberately invalid JSON that only exists to satisfy pi's `fileExists` gate; anything that actually parses it fails loudly, which is the point. |
| `learn/` | Standalone experiments — see below. |
| `docs/findings.md` | **Start here.** What the plan got wrong and what measuring it revealed. |
| `docs/call-chain.md` | A map of the 11 steps between a keyless container and a Vertex call. |
| `notes.md` | The raw chronological build log, in Chinese. `docs/findings.md` is the readable distillation of it. |

## Experiments

`learn/` holds small, re-runnable scripts. Each one opens with what it tests, what you
should expect to see, what it costs, and how to re-run it. They cover context growth
across turns, truncation behaviour, the tool boundary, what a restart does to a tmpfs
versus a volume, session directory resolution, why an egress proxy is not a uniform
gate and how a relay carries a websocket through one, and a cross-model
instruction-compliance eval. `learn/README.md` indexes all of
them in teaching order.

Most cost nothing. Three make a real Vertex call: two are about $0.0001, and the
compliance eval is about $0.01 for each model it measures. They resolve the GCP project
id through `learn/lib/project-id.sh`: `$GOOGLE_CLOUD_PROJECT` if exported, otherwise the
value in `config/config.toml`, and a hard error if neither is present.

## Known gaps

- **A Discord resume has not been measured.** openab's gateway websocket reaches
  Discord through `oab-relay`, and a real conversation has run over it
  ([finding 8](docs/findings.md)). Discord directs a resumed session to a regional
  host such as `gateway-us-east1-b.discord.gg`, which neither the allowlist nor the
  relay's hosts entry covers, and what serenity does when that fails is not known.
- **`run.sh` reuses containers that are already running, whatever changed.** It
  starts `oab-proxy`, `oab-relay` and `oab-broker` only when they are absent, and
  squid reads its configuration once, at start. Switching branches with the sandbox
  up therefore left squid enforcing the old allowlist, and the bot stayed offline
  with no error. Run `./stop.sh` before `./run.sh` after changing anything those
  containers read.
- **openab's own state does not persist.** The root of the `oab-openab-home`
  volume is owned by root while openab runs as uid 1000, so it logs
  `failed to persist thread mapping ... Permission denied` and starts every run
  with an empty thread map, reminder list and cache. `oab-pi-home` is owned by
  uid 1000 and is unaffected.
- **`/proc/1/environ` is readable by the agent's own child processes**, which exposes
  `DISCORD_BOT_TOKEN` — the bot cannot function without it, so this is not fixable by
  removing the variable. `verify-hardening.sh` prints the leaked variable *names* (never
  values) so the list stays visible. Turning it into an assertion — "this must be the
  *only* secret there" — is still open.
- **`config/pi-coach` relies on implementation details in pi and
  google-auth-library.** Its marker-file workaround depends on `os.homedir()`
  falling back to `/etc/passwd` while google-auth-library reads `HOME`
  directly. Re-verify authentication after either dependency changes.
- **A crashed container loses its session log.** `stop.sh` copies the agent's session
  log out of the tmpfs to `learn/out/archive/` before removing the container, so an
  ordinary stop keeps the record. A container that dies on its own is removed by
  `--rm` first, and nothing is archived.

## What the agent actually does — `vault/`

The workspace mounted at `/workspace` is an Obsidian vault for algorithm practice, and
the agent runs as a *coach* rather than a solver: its `AGENTS.md` forbids handing over a
complete solution, allows only one tier of hint at a time, and requires that any review
it writes be backed by something the user actually produced. The vault holds the problem
bank, the coaching rules, pattern notes, and the python scripts the agent shells out to
(`build_index.py` rebuilds the problem index, `pi_cost.py` reports spend) — which is why
this repo's `Dockerfile` installs python3 that the base image lacks.

`vault/` is a separate git repository with its own remote and its own history, and it is
gitignored here on purpose rather than vendored as a submodule. To change it,
`cd vault && git ...`. This repo treats it purely as the directory that gets mounted
into the agent's workspace.
