# learn/ — hands-on experiments

Each script is a small experiment you can **re-run and poke at**, matching one
concept from the walkthrough.

## Conventions

- Every script opens by stating **what it tests, what you should see, and how to
  re-run it**
- One command does one thing; anything involving real data processing lives in
  `lib/`
- Nothing changes project state, except the experiments that need containers,
  which start and stop them and say so up front

## Index (in teaching order)

| Script | Topic | Stage |
|---|---|---|
| *(to be written)* | shared kernel, PID namespace | system layer, basics |
| *(to be written)* | capabilities: CapEff vs CapBnd | S2 |
| *(to be written)* | no_new_privs, read-only, noexec | S2 |
| *(to be written)* | cgroup memory and process ceilings | S2 |
| *(to be written)* | the `/proc/1/environ` leak | S2 (open issue) |
| *(to be written)* | the network gate and routes around the allowlist | S3 |
| *(to be written)* | collecting a ticket from the token broker | S4 |
| `05-context-growth.sh` | context resent every turn, and how cost accumulates | context layer |
| `06-message-path-to-pi.sh` | how a message travels Discord → openab → pi-acp → pi (ACP over stdio) | architecture |
| `07-context-truncation.sh` | what the `sed` truncation cuts, and why it beats asking the model nicely | context layer |
| `08-tool-boundary.sh` | the tools' real granularity vs the write boundary AGENTS.md claims | context layer |
| `09-session-dir.sh` | whether `--session-dir` really moves the files, and the blast radius | development ① |
| `10-cost-script-fix.sh` | `pi_cost.py` acceptance across two cases after sessions moved | development ① |
| `10-model-compliance-eval.sh` | compliance as a measurable product property (a re-runnable eval) | context layer |

> The "to be written" experiments were all actually run during the walkthrough;
> they simply have not been turned into scripts yet.

## Side track: the Vertex authentication call chain (`docs/call-chain.md`)

| Script | Topic | Step |
|---|---|---|
| `chain-01-command-vs-args.sh` | program name and arguments are two separate slots → why `config/pi-coach` has to exist | step 3 |
