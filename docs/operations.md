# Operations

Everything about running this after the first `./run.sh`: the two ways it gets
started, what each script refuses to do quietly, and how the vault stays in
step. The README has the quick start; this is the rest.

---

## The two ways it runs

| | On a laptop you also use | On the machine that hosts it |
|---|---|---|
| Started by | `./run.sh`, by hand | launchd, at login and after every exit |
| Stopped by | `./stop.sh`, which archives the session log | nothing — it is meant to stay up |
| Runtime | Docker Desktop, arm64 | Colima on an Intel Mac |
| Lasts | as long as your session | until the machine is shut down |

Both run the same `run.sh` with the same flags. The difference is who calls it.

---

## Stopping, and the session log

`stop.sh` copies the agent's session log out of the container before removing
it, into `learn/out/archive/<timestamp>/` (gitignored).

pi writes those sessions to a tmpfs, so the agent only ever sees the current
one — `config/pi-coach` explains why. Archiving keeps the full history without
giving that property up, because the archive lands on the host, where the agent
cannot reach it.

**Do not add `learn/` to `run.sh`'s mount list.** That would hand the
accumulated history straight back to the agent, which is the one thing the tmpfs
was for.

A container that dies on its own is removed by `--rm` before `stop.sh` could
copy anything, so a crash still takes its log with it. That is
[still open](findings.md#still-open), and it matters more under launchd, which
restarts the sandbox without ever calling `stop.sh`.

---

## Re-running `run.sh` while it is up

`run.sh` can be re-run at any time. It keeps `oab-proxy`, `oab-relay` and
`oab-broker` only if each was started from the image, arguments and config it
would use now — that comparison is a fingerprint in the `oab.inputs` label — and
recreates any that was not, saying which and why. It always recreates the agent.

This exists because a stale service container once looked exactly like a working
one for an evening; finding 8 has that story.

---

## `verify-hardening.sh`

Worth re-running after any change to `run.sh`, any image rebuild, and any
upgrade of Docker or Colima. It asserts that capabilities are empty, the process
is non-root, `no_new_privs` is set, the rootfs is read-only, `/tmp` is `noexec`,
and the memory and pid ceilings are in place — for the relay as well as the
agent.

It also checks that the relay can still bind port 443 without privileges, which
depends on a Docker default rather than on anything in this repo, and prints the
*names* of the environment variables PID 1 leaks. Never the values: the leak is
an open issue, and the script's job is to keep the list visible, not to publish
it.

---

## Running it always-on

On a machine that does nothing else, launchd runs the sandbox:

```sh
./deploy/install-service.sh            # install and start
./deploy/install-service.sh --remove   # stop and remove
```

Three agents, because they fail differently:

- **`dev.oab.colima`** starts the container VM, once, at login.
- **`dev.oab.sandbox`** runs `deploy/start-sandbox.sh`, which waits for that VM,
  reads the bot token from `~/.config/openab/env.sh`, and execs `run.sh`.
  launchd starts it again whenever it exits.
- **`dev.oab.watchdog`** runs `deploy/watchdog.sh` every five minutes, and
  restarts the sandbox agent when the gateway has stopped carrying heartbeats.

A restarting sandbox must never restart the VM under it, which is why they are
separate agents and not one.

The watchdog exists because staying up is not the same as staying connected.
Finding 10 is the eight days this cost. It watches the relay's byte counters,
since the relay carries the gateway websocket and nothing else, and acts after
two silent checks in a row. Neither plist holds a secret — a LaunchAgent plist is
world-readable, so the token stays in the environment file. Both log to
`~/Library/Logs/dev.oab.*.log`.

Measured on 2026-09-17, on an Intel MacBook Pro with 8GB running Colima:
`launchctl kickstart -k` on the sandbox agent has the bot connected again within
a minute. A start from cold has not been measured. The VM that day had been
started by hand, and `dev.oab.colima` had failed at install, unable to find
`limactl` on launchd's PATH, and that went unnoticed for five days. It now has
the PATH it needs, and a reboot is the test it has still not had.

Measured on 2026-09-26: freezing the agent container with `docker pause`, which
leaves every container up and the tunnel open while the heartbeats stop, had the
watchdog restart it on its second check and the bot connected again 45 seconds
later. The installer was fixed the same day — `launchctl bootout` returns before
the job is gone, and bootstrapping too soon failed, which left the bot down until
someone looked.

---

## Keeping `vault/` in step

`vault/` is a clone of the vault you practise in, and nothing updates it by
itself. Left alone it drifts: on 2026-09-16 it was four weeks behind, and the
coach had been answering from that snapshot. `run.sh` and `stop.sh` now say when
the two copies have diverged.

```sh
./vault-sync.sh status   # where things stand
./vault-sync.sh pull     # main vault -> vault/, before a session
./vault-sync.sh back     # vault/ -> main vault, after a session
```

The two directions are not treated alike. `pull` carries your own notes into the
sandbox. `back` carries what the agent wrote into the vault you trust, and
`vault/` is the one host path the agent can write — so `back` lists the commits,
flags every file that is not a note (`AGENTS.md`, `scripts/`, `.obsidian/`), and
fast-forwards only after a yes. Commits stay manual on both sides.

When the sandbox runs on another machine, run `back` on the machine that commits
to the main vault and point it at the other one over ssh:

```sh
./vault-sync.sh back user@host:Projects/oab-sandbox/vault
```

A main vault in iCloud Drive should only ever have one machine writing its
`.git`. Finding 7 records what happened to the copy that had two.
