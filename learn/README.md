# learn/ — hands-on experiments

Each script is a small experiment you can **re-run and poke at**. They come in
two kinds, and the difference is how you read them, not how important they are:

- **Concepts** (`learn/*.sh`) — read in teaching order, 05 onwards. Each answers
  *what is this mechanism?* and stands on its own.
- **Development verifications** (`learn/dev/`) — read next to the change they
  accepted. Each answers *did that change do what it claimed?*, which only means
  something alongside the entry in `docs/findings.md` that describes it.

## Conventions

- Every script opens by stating **what it tests, what you should see, and how to
  re-run it**
- One command does one thing; anything involving real data processing lives in
  `lib/`
- Nothing changes project state, except the experiments that need containers,
  which start and stop them and say so up front
- Numeric prefixes follow the main walkthrough. **Side tracks take a word
  prefix instead** (`chain-`) so parallel sessions do not collide on the same
  number
- **Every script is run from the repository root** (`./learn/...`), never from
  inside `learn/`. They resolve `lib/` relative to the root, so the working
  directory is part of the contract rather than a convenience

## Concepts — read in teaching order

| Script | Topic | Stage |
|---|---|---|
| `05-context-growth.sh` | context resent every turn, and how cost accumulates | context layer |
| `06-message-path-to-pi.sh` | how a message travels Discord → openab → pi-acp → pi (ACP over stdio) | architecture |
| `07-context-truncation.sh` | what the `sed` truncation cuts, and why it beats asking the model nicely | context layer |
| `08-tool-boundary.sh` | the tools' real granularity vs the write boundary AGENTS.md claims | context layer |
| `10-model-compliance-eval.sh` | compliance as a measurable product property (a re-runnable eval) | context layer |
| `11-tmpfs-vs-volume.sh` | tmpfs (memory) vs volume (disk): who survives a restart | system layer, basics |
| `12-shared-kernel-pid-namespace.sh` | one kernel under every container, and a PID namespace as a renumbered view of it | system layer, basics |
| `13-discord-gateway-proxy.sh` | why one process obeys the proxy over REST and ignores it over websocket, and the relay that carries the websocket through | S3 |
| `14-gate-dns-reliability.sh` | how long the gate keeps refusing after one failed lookup, and how to tell a failed lookup from a failed connection | S3 |

### Run during the walkthrough, not yet scripted

These were all run by hand while the system layer was being built, and are listed
here so the gap stays visible rather than becoming folklore:

| Topic | Stage |
|---|---|
| capabilities: CapEff vs CapBnd | S2 |
| no_new_privs, read-only, noexec | S2 |
| cgroup memory and process ceilings | S2 |
| the `/proc/1/environ` leak | S2 (open issue) |
| the network gate and routes around the allowlist | S3 |
| collecting a ticket from the token broker | S4 |

## Side track: the Vertex authentication call chain (`docs/call-chain.md`)

| Script | Topic | Step |
|---|---|---|
| `chain-01-command-vs-args.sh` | program name and arguments are two separate slots → why `config/pi-coach` has to exist | step 3 |

## Development verifications — `dev/`

These accepted a change rather than taught a concept, so each one is listed with
the write-up it belongs to. The build log behind them is `notes.md`, which is in
Chinese; `docs/findings.md` is the English account and the one to read first.

### development ① — moving sessions onto tmpfs

| Script | What it accepted | Written up in |
|---|---|---|
| `dev/01-session-dir.sh` | whether `--session-dir` really moves the files, and the blast radius the move was buying | findings #3 |
| `dev/02-cost-script-fix.sh` | `pi_cost.py` across two cases after sessions moved — including the silent wrong answer | findings #5 |

### development ③ — what the first real Discord conversation exposed

| Script | What it accepted | Written up in |
|---|---|---|
| `dev/03-stale-service-containers.sh` | `run.sh` recreating a service whose image, arguments or config changed, instead of silently reusing it | findings #8 |
| `dev/04-openab-state-volume.sh` | openab's state volume writable by uid 1000, including one Docker had already created root-owned | findings #8 |

### development ④ — keeping `vault/` in step with the main vault

| Script | What it accepted | Written up in |
|---|---|---|
| `dev/05-vault-sync.sh` | `vault-sync.sh` syncing both ways, and refusing a dirty pull, an unreviewed or non-fast-forward `back`, and a parent repository mistaken for the vault | findings #7 |
