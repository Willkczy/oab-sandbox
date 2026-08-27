# AGENTS.md

Conventions for anyone — human or agent — working in this repository.

## Language

**Everything under version control is English.** Code, comments, commit messages,
documentation, the README, and the GitHub description. Write it in English the
first time; do not write it in another language and plan to translate later.

Two deliberate exceptions, both already in place:

- **`notes.md`** is the raw chronological build log and stays in Chinese. Its
  distillation, `docs/findings.md`, is the English document meant for readers.
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
