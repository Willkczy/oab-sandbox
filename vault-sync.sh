#!/bin/sh
# Keep the sandbox's vault clone and the main vault in step, without letting what
# the agent wrote reach the main vault unreviewed.
#
# vault/ is a git clone of the main vault, and nothing updates it on its own. On
# 2026-09-16 it turned out to be four weeks behind: the coach had been answering
# from a snapshot, and nothing anywhere said so.
#
# The two directions carry different risk, so they are separate commands:
#
#   pull   main vault -> vault/. Your own notes going into the sandbox. Safe
#          whenever vault/ has no uncommitted edits to tracked files.
#   back   vault/ -> main vault. Whatever the agent wrote going into the vault you
#          trust. An agent that read an injected page can rewrite AGENTS.md or
#          scripts/ as easily as a note, so the commits are listed, files outside
#          the notes are flagged, and nothing merges without a yes.
#
# Commits stay manual on both sides. A message about a practice session is yours
# to write, and a script that committed everything would also commit whatever it
# should have flagged.
#
# ── Usage ─────────────────────────────────────────────────────────────
#   ./vault-sync.sh status          where things stand
#   ./vault-sync.sh pull            main vault -> vault/
#   ./vault-sync.sh back [SOURCE]   vault/ -> main vault, after a prompt
#   ./vault-sync.sh back --yes      the same, without the prompt
#
#   SOURCE defaults to vault/. It can be any git URL, including another machine
#   over ssh:  ./vault-sync.sh back willkczy@host:Projects/oab-sandbox/vault
#
#   run.sh and stop.sh call `remind-start` and `remind-stop`, which only report
#   and never fail.
#
# ── Where the vaults are ──────────────────────────────────────────────
#   vault/          next to this script; OAB_SANDBOX_VAULT overrides it
#   main vault      vault/'s `origin`; OAB_MAIN_VAULT overrides it
#
# ── When the sandbox runs on another machine ──────────────────────────
# Run status, pull and the reminders on the machine that runs the sandbox. Run
# `back` on the machine where you commit to the main vault, with SOURCE pointing
# at the other one over ssh. The main vault's .git then only ever has one machine
# writing to it. With the main vault inside iCloud Drive that is not a nicety:
# two machines writing one .git through iCloud is how a repository gets corrupted.

set -eu

SANDBOX="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VAULT="${OAB_SANDBOX_VAULT:-$SANDBOX/vault}"

say() { printf 'vault: %s\n' "$*"; }
die() { printf 'vault-sync: %s\n' "$*" >&2; exit 1; }

# A repository whose top level is this very directory. Asking git merely whether
# the path is inside a repository is not enough: run.sh mounts vault/, so Docker
# creates it as an empty directory in a fresh clone, and git would then answer
# for this repository instead.
is_repo() {
    [ -d "$1" ] || return 1
    top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$top" = "$(CDPATH= cd -- "$1" && pwd -P)" ]
}

main_vault() {
    if [ -n "${OAB_MAIN_VAULT:-}" ]; then
        printf '%s\n' "$OAB_MAIN_VAULT"
    else
        git -C "$VAULT" remote get-url origin 2>/dev/null || true
    fi
}

# changes <repo>: sets MODIFIED (tracked files with edits) and UNTRACKED.
# One `git status` rather than two, because this vault's git is slow.
changes() {
    st=$(git --no-optional-locks -C "$1" status --porcelain 2>/dev/null || true)
    if [ -z "$st" ]; then
        MODIFIED=0
        UNTRACKED=0
        return
    fi
    MODIFIED=$(printf '%s\n' "$st" | grep -vc '^??' || true)
    UNTRACKED=$(printf '%s\n' "$st" | grep -c '^??' || true)
}

# position: fetches origin, then sets BRANCH, BEHIND (in the main vault, not in
# vault/) and AHEAD (in vault/, not in the main vault). FETCHED=no when the main
# vault could not be reached, in which case the counts are as of the last fetch.
position() {
    BRANCH=$(git -C "$VAULT" symbolic-ref --quiet --short HEAD) \
        || die "vault/ is not on a branch"
    if git -C "$VAULT" fetch -q origin "$BRANCH" 2>/dev/null; then
        FETCHED=yes
    else
        FETCHED=no
    fi
    if git -C "$VAULT" rev-parse -q --verify "origin/$BRANCH" >/dev/null; then
        BEHIND=$(git -C "$VAULT" rev-list --count "HEAD..origin/$BRANCH")
        AHEAD=$(git -C "$VAULT" rev-list --count "origin/$BRANCH..HEAD")
    else
        BEHIND=0
        AHEAD=0
    fi
}

# Files that are not notes. What the agent is told to do lives in AGENTS.md and
# CLAUDE.md, what it runs lives in scripts/, and .obsidian/ holds plugin config;
# a change to any of those deserves a look before it lands in the main vault.
flag_paths() {
    grep -E '(^|/)(AGENTS|CLAUDE)\.md$|^\.obsidian/|^scripts/|^\.gitignore$|\.(sh|py|js|mjs|cjs|ts|json|toml|ya?ml)$' || true
}

cmd_status() {
    is_repo "$VAULT" || die "$VAULT is not a git repository"
    position
    main=$(main_vault)
    changes "$VAULT"

    say "vault/      $VAULT ($BRANCH, $(git -C "$VAULT" rev-parse --short HEAD))"
    say "main vault  $main"
    [ "$FETCHED" = yes ] || say "could not reach the main vault; counts are as of the last fetch"
    say "in the main vault, not in vault/   $BEHIND commit(s)"
    say "in vault/, not in the main vault   $AHEAD commit(s)"
    say "uncommitted in vault/              $MODIFIED modified, $UNTRACKED untracked"
    if [ -d "$main" ] && is_repo "$main"; then
        changes "$main"
        say "uncommitted in the main vault      $MODIFIED modified, $UNTRACKED untracked"
    fi
}

cmd_pull() {
    is_repo "$VAULT" || die "$VAULT is not a git repository"
    position
    [ "$FETCHED" = yes ] || die "could not fetch from the main vault ($(main_vault))"
    changes "$VAULT"
    if [ "$MODIFIED" -gt 0 ]; then
        die "vault/ has $MODIFIED uncommitted edit(s) to tracked files. Commit them in vault/ (and bring them back with ./vault-sync.sh back) before pulling."
    fi
    if [ "$BEHIND" -eq 0 ]; then
        say "vault/ already has everything in the main vault"
        return 0
    fi
    git -C "$VAULT" pull -q --rebase origin "$BRANCH"
    say "pulled $BEHIND commit(s); vault/ is now at $(git -C "$VAULT" rev-parse --short HEAD)"
}

cmd_back() {
    yes=no
    source=""
    for arg in "$@"; do
        case "$arg" in
            --yes) yes=yes ;;
            -*) die "unknown option: $arg" ;;
            *) source=$arg ;;
        esac
    done
    source=${source:-$VAULT}

    main=$(main_vault)
    [ -n "$main" ] || die "cannot tell where the main vault is; set OAB_MAIN_VAULT"
    is_repo "$main" || die "the main vault ($main) is not a git repository"
    branch=$(git -C "$main" symbolic-ref --quiet --short HEAD) \
        || die "the main vault is not on a branch"

    # A fast-forward over edited tracked files can stop halfway. Untracked files
    # are left alone, so a stray screenshot does not block anything.
    changes "$main"
    if [ "$MODIFIED" -gt 0 ]; then
        die "the main vault has $MODIFIED uncommitted edit(s) to tracked files. Commit them first."
    fi

    git -C "$main" fetch -q "$source" "$branch" \
        || die "could not fetch $branch from $source"
    incoming=$(git -C "$main" rev-list --count HEAD..FETCH_HEAD)
    if [ "$incoming" -eq 0 ]; then
        say "nothing to bring back from $source"
        return 0
    fi
    if ! git -C "$main" merge-base --is-ancestor HEAD FETCH_HEAD; then
        die "vault/ does not have the main vault's latest commits, so this cannot fast-forward. Run ./vault-sync.sh pull where the sandbox runs, then try again."
    fi

    echo "commits to bring back from $source:"
    git -C "$main" log --format='  %h %s' HEAD..FETCH_HEAD
    echo
    git -C "$main" -c core.quotepath=off diff --stat HEAD FETCH_HEAD
    flagged=$(git -C "$main" -c core.quotepath=off diff --name-only HEAD FETCH_HEAD | flag_paths)
    if [ -n "$flagged" ]; then
        echo
        echo "!! These are not notes. Read their diffs before saying yes:"
        printf '%s\n' "$flagged" | sed 's/^/     /'
        echo "   git -C \"$main\" diff HEAD FETCH_HEAD -- <path>"
    fi
    echo

    if [ "$yes" != yes ]; then
        if [ ! -t 0 ]; then
            die "not asking without a terminal; pass --yes to merge without the prompt"
        fi
        printf 'Fast-forward the main vault to these %s commit(s)? [y/N] ' "$incoming"
        read -r answer
        case "$answer" in
            y | Y | yes) ;;
            *)
                say "left the main vault unchanged"
                return 0
                ;;
        esac
    fi

    git -C "$main" merge -q --ff-only FETCH_HEAD
    say "the main vault is now at $(git -C "$main" rev-parse --short HEAD)"
}

# Reminders never fail the script that calls them, and stay silent about vaults
# they cannot read: a fresh clone of this repository has no vault/ at all.
cmd_remind_start() {
    is_repo "$VAULT" || { say "vault/ is not a git clone; skipping the sync check"; return 0; }
    position
    [ "$FETCHED" = yes ] || say "could not reach the main vault ($(main_vault)); the check below may be stale"
    quiet=yes
    if [ "$BEHIND" -gt 0 ]; then
        say "the main vault has $BEHIND commit(s) the coach cannot see. Run ./vault-sync.sh pull."
        quiet=no
    fi
    main=$(main_vault)
    if [ -d "$main" ] && is_repo "$main"; then
        changes "$main"
        if [ "$MODIFIED" -gt 0 ]; then
            say "the main vault has $MODIFIED uncommitted edit(s). The coach sees them only after you commit and pull."
            quiet=no
        fi
    fi
    changes "$VAULT"
    if [ "$AHEAD" -gt 0 ] || [ "$MODIFIED" -gt 0 ] || [ "$UNTRACKED" -gt 0 ]; then
        say "vault/ still holds work from an earlier session ($AHEAD commit(s), $MODIFIED modified, $UNTRACKED untracked). Commit it there, then run ./vault-sync.sh back."
        quiet=no
    fi
    [ "$quiet" = no ] || say "vault/ is in step with the main vault"
}

cmd_remind_stop() {
    is_repo "$VAULT" || return 0
    position
    changes "$VAULT"
    if [ "$MODIFIED" -gt 0 ] || [ "$UNTRACKED" -gt 0 ]; then
        say "this session left $MODIFIED modified and $UNTRACKED untracked file(s) in vault/."
        say "  review and commit them:  git -C \"$VAULT\" status"
        say "  then bring them back:    ./vault-sync.sh back"
    elif [ "$AHEAD" -gt 0 ]; then
        say "vault/ has $AHEAD commit(s) the main vault does not. Run ./vault-sync.sh back."
    else
        say "nothing in vault/ to bring back"
    fi
}

case "${1:-}" in
    status) cmd_status ;;
    pull) cmd_pull ;;
    back) shift; cmd_back "$@" ;;
    remind-start) cmd_remind_start || true ;;
    remind-stop) cmd_remind_stop || true ;;
    *)
        sed -n '/^# ── Usage/,/^# ── Where/p' "$0" | sed '$d' >&2
        exit 2
        ;;
esac
