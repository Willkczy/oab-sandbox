# oab-sandbox

An LLM coach for algorithm practice, and the hardened container it runs in.

Two halves, and the interesting part is where they meet. The **coach** is a general
coding agent told to teach rather than solve — a rule with no system layer behind it,
so this repo measures it instead of trusting it. The **cage** is built for the moment
that measurement fails: every flag exists to make one guarantee hold *after* the agent
is assumed compromised — **the service-account private key never exists inside the
container that runs the agent.**

**Status.** Since 2026-09-17 this is not a demo that gets started for a session: the
sandbox *is* the Discord bot, kept up by launchd on a machine that does nothing else,
and it replaced the host-mode deployment that used to do that job. The coach runs
`google-vertex/gemini-3.7-flash`, which `config/pi-coach` selects and justifies with
the four problems it was probed on.

## If you have five minutes

1. [docs/findings.md](docs/findings.md) — the nine findings, and the most interesting
   document here: an existence check that never reads the file, a permission table
   nothing enforces, and a script that reported a week-old number without ever
   erroring. Start here.
2. [`learn/10-model-compliance-eval.sh`](learn/10-model-compliance-eval.sh) — the
   header says why the coaching rule can only be measured, never enforced.
   [`learn/lib/grade_compliance.py`](learn/lib/grade_compliance.py) says where the
   line between a hint and a solution is drawn, and why it is not a line count.
3. [Known gaps](#known-gaps) — what is still open, written down rather than left out.

## The coach

The agent is `pi`, pointed at an Obsidian vault of algorithm problems and told by the
vault's own `AGENTS.md` to coach rather than solve: never hand over a solution, one
tier of hint at a time, every review backed by something the student actually wrote.
The vault also holds the problem bank, pattern notes, and the python scripts the agent
shells out to — which is why this repo's `Dockerfile` installs the python3 the base
image lacks.

None of those rules has a system layer behind it. A model that ignores them fails
silently, and looks helpful while doing it, so `learn/10-model-compliance-eval.sh`
re-runs after every model change and finding 6 records what it caught: one model that
handed over a near-complete implementation, and the grading line that separates a hint
from a solution.

`vault/` is a separate git repository with its own remote and history, gitignored here
on purpose rather than vendored. This repo treats it purely as the directory mounted
into the agent's workspace; [docs/operations.md](docs/operations.md) covers keeping it
in step.

## The cage

```
                                   oab-ext  (has a route to the internet)
                                           │
                                  ┌────────┴────────┐   squid, domain allowlist:
                                  │    oab-proxy    │   *.googleapis.com, *.discord.com,
                                  │     (squid)     │   *.discordapp.net, *.discordapp.com,
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
  to `oab-relay`, which opens the `CONNECT` tunnel on its behalf (finding 8). TLS stays
  end to end, and squid refuses any destination that resolves to a private address.
- **The broker is the smallest possible blast radius.** No shell tooling, no curl, no git;
  runs as uid 1000; dependencies pinned via `package-lock.json` and installed with `npm ci`.

[docs/architecture.md](docs/architecture.md) has the codemap, the invariants and a
message's path end to end; [docs/call-chain.md](docs/call-chain.md) walks the eleven
steps between a keyless container and a Vertex call.

## What is defended, and what checked it

Every row assumes the agent is already doing the wrong thing.

| If the agent … | What stops it | How that was checked |
|---|---|---|
| reads the cloud credential | it is not there; `oab-broker` holds the key and hands out short-lived tokens | finding 4, `docs/call-chain.md` |
| reaches a host of its choosing | `--internal` network; squid allows six domain patterns and refuses private addresses | `learn/13`, `learn/14`, squid's `access.log` |
| escalates inside the container | `--cap-drop ALL`, `no-new-privileges`, uid 1000, read-only rootfs, `/tmp` `noexec` | `verify-hardening.sh` |
| exhausts the host | `--memory 2g`, `--pids-limit 256`, and tighter ceilings for the relay and broker | `verify-hardening.sh` |
| reads other sessions' logs | sessions live on a tmpfs; the archive lands on the host, where the agent cannot reach it | `learn/dev/01` |
| writes into the vault you trust | only `vault/` is writable, and `vault-sync.sh back` shows the commits before a fast-forward | `learn/dev/05` |
| hands the student a full solution | nothing stops it — this one is measured, not enforced | finding 6, `learn/10` |

The last row is the honest one: a coaching rule is a property of the model's output,
and no container flag can hold it.

## Quick start

- Docker. Built and tested on Docker Desktop on arm64; the machine that hosts it
  permanently runs Colima on an Intel Mac, where Homebrew no longer builds bottles and
  the runtime is a downloaded binary
- A GCP service-account key at `~/.config/openab/sa-key.json` — mounted read-only into
  the broker, never copied into any image
- A Discord bot token. If you already run this agent elsewhere, **create a second bot**:
  sharing one token means both instances answer every message.
- A working directory to mount as the agent's workspace at `./vault`

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

# 5. Stop — and archive the session log, which only stop.sh does
./stop.sh
```

Started this way, the sandbox lasts as long as your session. The machine that hosts it
permanently does not start it by hand at all: `deploy/install-service.sh` puts it under
launchd. Both cases, and what each script refuses to do quietly, are in
[docs/operations.md](docs/operations.md).

## Repository map

| Path | What it is |
|---|---|
| `run.sh`, `stop.sh` | Start the four containers; stop the agent and archive its session log. Every hardening flag lives in `run.sh`. |
| `verify-hardening.sh` | Asserts those flags took effect, from inside the running containers. |
| `broker/`, `relay/`, `proxy/` | The token broker, the Discord gateway relay, and squid's allowlist. |
| `config/` | The agent config template, the model wrapper `pi-coach`, and `adc-marker.json` — **not a credential**, deliberately invalid JSON that only exists to satisfy pi's `fileExists` gate. |
| `deploy/` | The LaunchAgents for the machine that hosts this permanently. |
| `learn/` | Re-runnable experiments, indexed in teaching order by `learn/README.md`. |
| `docs/` | [findings](docs/findings.md), [architecture](docs/architecture.md), [call chain](docs/call-chain.md), [operations](docs/operations.md), and the Chinese build log the findings distil. |

## Experiments

`learn/` holds small, re-runnable scripts, each opening with what it tests, what you
should expect to see, what it costs, and how to re-run it. They cover context growth
across turns, truncation behaviour, the tool boundary, tmpfs versus volume across a
restart, session directory resolution, why an egress proxy is not a uniform gate and
how a relay carries a websocket through one, and a cross-model instruction-compliance
eval. [`learn/README.md`](learn/README.md) indexes them in teaching order.

Most cost nothing; three make a real Vertex call, two at about $0.0001 and the
compliance eval at about $0.01 per model measured.

## Known gaps

The unresolved entries are the most credible part of this repo, not a blemish on it.
[Still open](docs/findings.md#still-open) in `findings.md` carries the detail.

- **The broker issues a token to anything on its network** that asks with the right
  `Metadata-Flavor` header. The agent's blast radius is "a Vertex token", not "no
  credential at all".
- **`/proc/1/environ` leaks `DISCORD_BOT_TOKEN`** to the agent's own child processes.
  The bot cannot run without the variable, so the fix is an assertion that nothing
  *else* is in that list, and it is not written yet.
- **A Discord resume has not been measured.** Discord sends a resumed session to a
  regional host such as `gateway-us-east1-b.discord.gg`, which neither the allowlist
  nor the relay's hosts entry covers.
- **Why the gate's DNS lookups fail is unexplained.** Finding 9 shortened each outage
  without finding the cause, so the bot can still refuse to reach Discord in bursts.
- **A crashed container loses its session log.** `--rm` removes it before `stop.sh`
  could archive anything, and launchd never calls `stop.sh`.
- **The compliance eval probes one turn, not two.** The leak worth catching is the
  second turn, when the student pushes back with "I don't get it, just write it", so a
  PASS in finding 6 is weaker evidence than it looks.
- **`config/pi-coach` rests on implementation details** in pi and google-auth-library:
  `os.homedir()` falling back to `/etc/passwd` while the other reads `HOME` directly.
  Re-verify authentication after either dependency changes.

## Related work

The gap this repo aims at — isolating the *secret*, not just the process — is one
other projects have named too, at different layers:

- [anthropic-experimental/sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime)
  enforces filesystem and network restrictions on a process without a container, and
  injects credentials at its proxy so the workload never holds them. Same idea as the
  broker here, one layer down.
- [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox)
  asks the same isolation question at cluster scale, where the answer is a stronger
  runtime such as gVisor or Kata rather than flags on `docker run`.

What this repo does differently is smaller and more specific: it is one deployment, of
one agent, where every claim is re-runnable and the things that did not work are
written down next to the things that did.

## License

MIT — see [LICENSE](LICENSE).
