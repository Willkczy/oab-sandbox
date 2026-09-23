# AGENTS.md

Conventions for anyone — human or agent — working in this repository.

## Language

**Everything under version control is English.** Code, comments, commit messages,
documentation, the README, and the GitHub description. Write it in English the
first time; do not write it in another language and plan to translate later.

Two deliberate exceptions, both already in place:

- **`docs/build-log.zh.md`** is the raw chronological build log and stays in
  Chinese. Its distillation, `docs/findings.md`, is the English document meant
  for readers. The `.zh` in the name is there so nobody opens it expecting
  otherwise.
- **A handful of strings that must not be translated**, because translating them
  would break or invalidate what they touch:
  - `learn/05` and `learn/08` reference paths and headings inside `vault/`, which
    is a separate Chinese repository. Translating those patterns means they match
    nothing.
  - The probe in `learn/10-model-compliance-eval.sh` stays in Chinese because the
    vault's coaching rules are in Chinese. An English probe would measure
    something other than what production actually does.

If you add a string in either category, say why in a comment next to it.

## Verifying changes

This repo's claims are meant to be reproducible, so changes get checked by
running things, not by reading diffs:

- `./verify-hardening.sh` after touching `run.sh`, rebuilding an image, or
  upgrading Docker. It asserts the S2 flags actually took effect.
- Scripts under `learn/` each state what they test and how to re-run them. Some
  make real Vertex calls; the cost is noted in each header.
- When editing comments or strings at scale, diff the non-comment lines before
  and after. A textual diff can look benign while changing behaviour — adjacent
  quotes in shell concatenate into a single argument, for instance.

## Git workflow

**Never commit directly to `main`.** Every piece of work starts on a branch, even
a one-line fix, and reaches `main` through a pull request.

There are two reasons beyond habit. Parallel sessions do touch this repo at the
same time, and uncommitted work from one has already collided with another. And
`main` is what someone cloning this repo runs; a half-finished experiment does
not belong there.

### Branch names

`<type>/<short-kebab-description>`, where type is one of:

| Type | For |
|---|---|
| `feat/` | new capability — a script, a container, a broker endpoint |
| `fix/` | something that is wrong, including silent wrongness |
| `docs/` | README, `docs/`, comments, this file |
| `exp/` | an experiment whose outcome is not yet known |
| `chore/` | dependencies, ignore rules, renames with no behaviour change |

### Commits

One commit per coherent change; do not batch unrelated edits together. The
message says **why**, not what — the diff already says what. State the reasoning
that would not be recoverable from the code six months later: what was assumed,
what turned out to be true, what was rejected and why.

Look at `git log` before writing one. That style is the repo's convention, and it
is deliberate.

### Before opening a pull request

`main` should stay runnable, so the branch has to be checked before it merges:

- shell scripts pass `sh -n`, python files compile
- `./verify-hardening.sh` if anything under `run.sh` or the images changed
- the affected `learn/` script actually runs, and its output is what its own
  header claims you should see
- for anything a reader would clone, check it in a fresh clone. This working copy
  has `vault/`, the built images and `~/.pi`; a reader has none of those, and
  that difference has already hidden a real defect once

Open it with `gh pr create`. The description carries the same reasoning as the
commits, plus how to verify it. Do not merge your own PR without the repo owner
looking at it — reviewing what an agent changed is the point of the gate.

### Keeping the record current

Findings are part of the deliverable, not a postscript:

- something surprising discovered while building or debugging goes into
  `docs/build-log.zh.md` as it happens, with the date
- once it is understood, it becomes an entry in `docs/findings.md` in the shape
  the other entries use: what was assumed, what happened, what changed
- a finding that changes how the system should be used belongs in `README.md`
  too, under **Known gaps** if it is unresolved

An open problem is written down rather than left out. The unresolved entries are
the most credible part of this repo, not a blemish on it.

## Credentials

No credential ever enters this repository or any image built from it. The
service-account key is mounted read-only into the broker at runtime; the Discord
token arrives through the environment. `config/config.toml` is gitignored because
it holds a Discord account id and a GCP project id — neither is a secret, but
neither belongs in a public repository either. `config/config.toml.example` is
the tracked template.

`config/adc-marker.json` is deliberately invalid JSON. It exists only to satisfy
a `fileExists` check; see `config/pi-coach` for why. Do not make it look like a
real credential — the `.gitignore` rules would then start catching it.

## `vault/`

A separate repository with its own remote and history, gitignored here on purpose
rather than vendored. To change it: `cd vault && git ...`. This repo treats it
purely as the directory mounted into the agent's workspace, and scripts that need
it check for it first and explain the dependency rather than failing on it.

Notes move between `vault/` and the main vault through `vault-sync.sh`, never by
copying files. Its `back` direction is the only way anything the agent wrote
reaches the main vault, so keep that direction reviewed: a change that makes it
merge without showing the commits, or stop flagging files that are not notes,
removes the one check on that path.
