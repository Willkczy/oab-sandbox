# Side track: the Vertex authentication call chain

> This document is a **map, not an explanation**. It marks where each step lives
> without walking through it, so you can open any single step and dig in.

---

## The question this chain answers

> How does a container holding **no credentials whatsoever** end up calling
> Vertex AI?

The answer has 11 steps, and only step 11 involves the LLM at all. That is the
chain's real teaching value: it makes the line between *what the model does* and
*what the harness does* concrete.

---

## Where the files are: two worlds

| World | How to look |
|---|---|
| **In the repo** (configuration you wrote) | just `cat` it |
| **In the image** (third-party libraries) | `docker run --rm --entrypoint sh oab-sandbox:pi -c 'cat <path>'` |

You cannot change what is in the image, and should not try, but you do have to be
able to open it — half the decisive logic in this chain lives there.

A convenient alias:

```sh
inimage() { docker run --rm --entrypoint sh oab-sandbox:pi -c "$*"; }
PIROOT=/usr/local/lib/node_modules/@earendil-works/pi-coding-agent
```

---

## The 11 steps

| # | Who | File | What to look at | Concept |
|---|---|---|---|---|
| 1 | `openab` (Rust) | `[agent] env = {...}` in `config/config.toml` | how `GCE_METADATA_HOST` and `HTTPS_PROXY` reach the subprocess | environment inheritance and `env_clear` |
| 2 | `openab` | `[agent] command` in `config/config.toml` | why it has to say `pi-acp` (the image has no `openab-agent`) | process spawning |
| 3 | `pi-acp` | `PI_ACP_PI_COMMAND` in `config.toml` | why a wrapper is required instead of just writing the arguments | the limits of spawning without a shell |
| 4 | `pi-coach` | `config/pi-coach` | what every word of `exec env -u HOME pi --model …` does | **the crux of S4 — see the section below** |
| 5 | `pi-ai` provider | `$PIROOT/node_modules/@earendil-works/pi-ai/dist/providers/google-vertex.js` | the `fileExists` gate inside `resolve()` | an existence check is not a read |
| 6 | `google-auth-library` | `$PIROOT/node_modules/google-auth-library/build/src/auth/googleauth.js` (**line 344**) | `const home = process.env['HOME']` | the three phases of the ADC chain |
| 7 | `gcp-metadata` | same tree, `build/src/index.js` (`getBaseUrl`, around line 92) | the order of environment override vs hardcoded default | why a protocol-compatible stand-in works |
| 8 | `gcp-metadata` | same file, `isAvailable()` | why the `/computeMetadata/v1/instance` path is non-negotiable | service probing, and how opaque its failure is |
| 9 | **broker** | `broker/server.js` (about 100 lines, written here) | the `Metadata-Flavor` check, the per-path responses, the audit log | the minimum viable metadata-server impersonation |
| 10 | `pi-ai` api | `$PIROOT/node_modules/@earendil-works/pi-ai/dist/api/google-vertex.js` | why `buildGoogleAuthOptions()` returning `undefined` is the correct outcome | two layers disagreeing about what a credential is |
| 11 | Gemini | — | it only ever receives text | the boundary between model and harness |

---

## Steps 4 / 5 / 6: the gap, and the part most worth your time

The whole of S4 rests on one **asymmetry**:

| Who | How it finds the home directory | When HOME is unset |
|---|---|---|
| `pi` (step 5) | expands `~` via `os.homedir()` | **falls back to `/etc/passwd`** → finds `/home/node` |
| `google-auth-library` (step 6) | reads `process.env['HOME']` directly | **gives up** → falls through to the metadata server |

So `config/pi-coach` does three things:

1. mounts a marker file that is **not a credential** (`config/adc-marker.json`) to
   satisfy the `fileExists` in step 5
2. runs `env -u HOME` so step 6 skips that file entirely
3. **leaves `GOOGLE_APPLICATION_CREDENTIALS` unset**, so step 10 walks the full
   ADC chain

**This is technical debt, not design.** Re-verify it after upgrading `pi` or
`google-auth-library`. The symptoms of it breaking are `No API key found` or
`Could not load the default credentials`.

---

## Verifying it yourself

```sh
# Bring up proxy + broker (the first half of run.sh)
./run.sh   # needs DISCORD_BOT_TOKEN; to test auth alone, start proxy and broker by hand

# Collect a ticket from a container holding no keys at all
docker run --rm --network oab-int --entrypoint sh oab-sandbox:pi -c '
  ls /run/secrets/;   # should not exist
  curl -s -H "Metadata-Flavor: Google" \
    http://oab-broker:8080/computeMetadata/v1/instance/service-accounts/default/token'

# Read both audit trails
docker logs oab-broker
docker exec oab-proxy tail -20 /var/log/squid/access.log
```

---

## Open questions

1. What does the `fileExists` gate in step 5 look like for a different model
   provider, say Anthropic? How would that difference in authentication design
   change the sandbox architecture?
2. The broker in step 9 **does not authenticate its callers** — any container on
   the same network can collect a ticket. If caller identity were added, which
   layer of this architecture should carry it?
3. `env_clear` in step 1 guarantees the agent's own environment is clean, yet
   `/proc/1/environ` still leaks (see S2 in `docs/build-log.zh.md`). Where exactly is the
   line between those two facts?
4. Which steps in this chain can prompt injection reach, and which are entirely
   outside the model's influence?
