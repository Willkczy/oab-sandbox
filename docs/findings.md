# Findings

Things this project got wrong on the first attempt, and what measuring them
revealed. The chronological build log lives in `notes.md` (in Chinese); this is
the part worth reading on its own.

Each finding follows the same shape: what the plan assumed, what actually
happened, and what changed as a result.

---

## 1. Four assumptions about the base image, three of them wrong

The plan treated `ghcr.io/openabdev/openab:stable-pi` as a known quantity.
Opening it up:

```
pi-acp       /usr/local/bin/pi-acp     present  (the plan's one unverified assumption -- it held)
pi           /usr/local/bin/pi          0.79.9
openab       /usr/local/bin/openab      0.9.0
openab-agent MISSING
python3      MISSING
```

- **`openab-agent` does not exist**, even though the image sets
  `OPENAB_AGENT_COMMAND=openab-agent`. That makes
  `[agent].command = "pi-acp"` mandatory rather than optional — without it the
  spawn simply fails.
- **No `python3`**, which silently breaks the two task routes in the vault's
  `AGENTS.md` that shell out to `build_index.py` and `pi_cost.py`. Resolved by
  adding a thin layer rather than rewriting the scripts in node.
- **pi 0.79.9's model list stops at `gemini-3.5-flash`**, and the only models
  measured to hold the coaching rules are `3.6-flash` and `3.1-pro-preview`. The
  interim workaround cost 1.25x more per call ($0.0080 vs $0.0064) until the
  image gained an upgrade layer.

The general lesson: an image's declared configuration is not evidence that the
thing it names exists.

---

## 2. `env_clear` is not a boundary — `/proc/1/environ` leaks anyway

openab runs `env_clear` on the agent subprocess, keeping only `HOME`, `PATH` and
`USER`. That sounds like the token is out of reach. It is not.

With every hardening flag on — `--cap-drop ALL --user 1000:1000 --read-only` —
a child process can still read PID 1's environment:

```
$ docker exec oab-probe sh -c 'tr "\0" "\n" < /proc/1/environ | grep FAKE_DISCORD_TOKEN'
FAKE_DISCORD_TOKEN=MTUzMDk1_this_is_the_secret
```

Same uid, same PID namespace, so `/proc/1/environ` is readable. **`env_clear`
means "the token was never placed in the agent's environment", not "the agent
cannot obtain the token".**

This is equally true of the host-mode setup it replaced — containerising did not
make it worse, but it did not solve it either. A real fix means moving the secret
out of the environment entirely, into a file with mount permissions, or into
openab's `[secrets.refs]` (which claims to keep values in memory only; not yet
verified).

`verify-hardening.sh` prints the leaked variable *names* on every run, without
ever printing a value, so the exposure stays visible rather than becoming
folklore.

---

## 3. A stated permission is not an enforced one

The vault's `AGENTS.md` contains a table of write permissions: which sections of
which files the coach may modify. Asking "what happens if the model ignores
this?" gives an uncomfortable answer — **nothing happens**. The agent holds
`bash` and `read`, so it can reach anything its uid can.

Enforcement is not available at that granularity either. pi has to write its own
session files, and the bash tool is pi's child process: same uid, same mount
namespace. The tool layer's granularity is *the tool*; the granularity the rule
needs is *the path*. They do not line up.

So the goal changed from prevention to blast radius. Session files moved to
tmpfs, which takes the worst case for an accidental read from roughly 32K tokens
down to under 2K.

`learn/08-tool-boundary.sh` prints the claimed boundary and the real tool list
side by side, because the gap between them is the actual lesson.

---

## 4. The authentication gap: an existence check that never reads the file

Getting a keyless container to call Vertex failed twice, and both failures were
more interesting than the fix.

**First failure — the broker's log was empty.** It was never called at all:

```
No API key found for "google-vertex".
```

The cause sits in `resolve()` in `pi-ai`'s `providers/google-vertex.js`:

```js
const adcPath = credential?.env?.GOOGLE_APPLICATION_CREDENTIALS ?? (await ctx.env("GOOGLE_APPLICATION_CREDENTIALS"));
const hasCredentials = await ctx.fileExists(adcPath ?? "~/.config/gcloud/application_default_credentials.json");
if (hasCredentials && project && location) { ... }
return undefined;   // missing file lands here; the ADC chain never runs
```

**It is a pure existence check. It never reads the file.** Meanwhile the layer
that actually exchanges the token wants the opposite:

```js
function buildGoogleAuthOptions(env) {
    const keyFilename = getProviderEnvValue("GOOGLE_APPLICATION_CREDENTIALS", env);
    return keyFilename ? { keyFilename } : undefined;   // unset -> full ADC chain -> metadata server
}
```

Two layers disagree about what a credential is, and that disagreement is the
solution. It works because of an asymmetry in how each consumes `HOME`:

| Who | How it finds the well-known file | When HOME is unset |
|---|---|---|
| pi | expands `~` via `os.homedir()` | falls back to `/etc/passwd` → finds `/home/node` |
| google-auth-library 10.6.2 | reads `process.env['HOME']` directly | gives up, skips the well-known file → metadata server |

Hence three moves in `config/pi-coach`: mount a marker file that is deliberately
*not* a credential to satisfy the existence check, `env -u HOME` so the auth
library skips it, and leave `GOOGLE_APPLICATION_CREDENTIALS` unset so the full
ADC chain runs.

**This is technical debt, not design.** It depends on two implementation details
that no one promised to keep. The symptoms of it breaking are `No API key found`
or `Could not load the default credentials`.

**Second failure — a 404 that read as "not on GCE".** With the gate passed, the
broker was finally reached and it still failed:

```
Could not load the default credentials.
broker log: ALLOW GET /computeMetadata/v1/instance      <- answered 404
```

`gcp-metadata`'s `isAvailable()` probes `/computeMetadata/v1/instance`. A 404
there means "not running on GCE", the whole chain gives up, and the resulting
error names nothing that would lead you back to the cause. This is why
`broker/server.js` answers detection paths with 200 and — separately — returns
404 rather than an empty 200 for anything unimplemented: an empty body reads as a
legitimate answer and moves the failure somewhere far away from its cause.

---

## 5. The most dangerous failures are the ones that look fine

Moving session files to tmpfs broke `pi_cost.py`, but it did not crash. The
script infers "the current session" by scanning a directory and taking the newest
mtime. With the directory changed underneath it, it reported a session from **a
week earlier** as the current one. No error, plausible numbers, correct
formatting.

Four assumptions were checked *before* making the change, and one of them caught
a different problem — `pi_cost.py` had the old path hardcoded at line 22 — but
the silent-fallback behaviour was not something a pre-flight check found.

The fix was two things, and only the first is the obvious one:

1. `resolve_sessions_dir()`: `PI_SESSION_DIR`, then `/tmp/sessions` if it exists,
   then the host default.
2. **Make the choice visible.** Print the full resolved path rather than a bare
   label, and put the directory actually scanned in the summary header.

A script that silently guesses wrong is worse than one that crashes, and the
second fix is what converts one into the other.

`learn/dev/02-cost-script-fix.sh` exercises both cases.

---

## 6. Compliance is measurable, not enforceable

Rule 1 of the vault's coaching rules — never provide complete solution code — is
the only rule in this system with no layer behind it. Its entire implementation
is the model choosing to comply.

Since it cannot be enforced, it gets measured, with the sharpest probe available:
ask outright, and pre-empt the follow-up questions the rules would normally
require.

| Model | Result |
|---|---|
| `gemini-3.6-flash` | holds the rule; refuses, then offers an empty skeleton |
| `gemini-3.1-pro-preview` | holds the rule; asks which tier of hint is wanted |
| `gemini-3.5-flash-lite` | **hands over a near-complete implementation** |

That last row is why the eval exists at all, and why it is re-run after every
model swap or version bump. `learn/10-model-compliance-eval.sh` is the harness;
its grader is deliberately left unimplemented, because deciding what counts as a
violation — is pseudo-code in a fence a violation? is a one-line nudge? — is the
judgement call the eval is really about, and the most dangerous way to get it
wrong is to score a violation as a pass.

---

## 7. Small operational surprises worth writing down

- **squid cannot log to `/dev/stdout`.** `ubuntu/squid` drops privileges to the
  `proxy` user and those device nodes belong to root, so it fails to start with
  `FATAL: Cannot open '/dev/stdout' for writing`. Use the default file path and
  `docker exec oab-proxy tail -f /var/log/squid/access.log`.
- **squid cannot restrict method or response size over HTTPS.** A CONNECT tunnel
  exposes only the destination hostname. `reply_body_max_size` and "GET only"
  are inert on that path; enforcing them would need SSL-bump, which means a CA
  private key inside the container — a new attack surface traded for the old one.
  Bandwidth limits are the only control that survives the tunnel, and they
  constrain bulk transfer, not a hundred bytes of injected text.
- **Every token fetch is logged, which host mode could not do.** When the key is
  just a file the agent can read, there is no record of it being used. Routing
  through a broker produces an audit trail outside the agent's reach — arguably
  a larger gain than the shortened credential lifetime.

- **`docker cp` cannot read a tmpfs mount.** It copies from the container's
  filesystem layers, and a tmpfs is mounted by the kernel outside them, so
  `docker cp oab-sandbox:/tmp/sessions .` fails with `Could not find the file
  /tmp/sessions in container` while `docker exec ls` lists the files at that very
  path. Streaming a tar out of `docker exec` crosses that boundary, which is how
  `stop.sh` archives the session log.

---

## Still open

- **A crash takes the session log with it.** `stop.sh` archives the log before
  removing the container, which covers an ordinary stop. A container that dies on
  its own — OOM, a panic — is already gone under `--rm` by the time `stop.sh`
  would run, and that is exactly when the log would have been worth the most.
- **Whether Discord's gateway survives the proxy.** serenity uses
  `async-tungstenite`, which is not expected to honour proxy environment
  variables. If it does not, the agent container has to join `oab-ext` as well —
  giving up the "exactly one gate" property — or the setup stays as verified
  today. This is the only remaining question that could still change the
  architecture.
- **Turning the `/proc/1/environ` check into an assertion**, so that the presence
  of any secret beyond `DISCORD_BOT_TOKEN` fails the run.
- **Caller identity at the broker.** It currently issues tokens to anything on
  the network that asks with the right header.
