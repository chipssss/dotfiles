# dispatch

Local scheduling for pi workers, one entry from worktree to merge.
Each worker runs as an interactive pi session in a Rex pane, under a supervisor that never gives up on it.

```text
dispatch start NAME BRIEF.md   worktree + own branch and upstream + port block + optional work card + composed brief
        |                      pi-worker supervises the pane: safe confirmations auto-approved, the rest NEEDS HUMAN
        v
pi-worker  --DONE-->  secret scan of the report  -->  cross-family review of the PR head  -->  verdict.json
                                                                                               |
dispatch merge PR  <-- only an APPROVE from another model family for the current head --------+
```

| Command | What it does |
|---|---|
| `dispatch start NAME BRIEF [--common F] [--card ID \| --new-card TITLE] [--base B] [--branch B] [--dry-run]` | Starts a worker in the background. `--dry-run` runs every check and prints the plan without writing anything. |
| `dispatch status [--json]` | One row per worker: phase, why it is stuck, PR, review verdict, card, ports. |
| `dispatch wait [CURSOR]` | Blocks until a new event (DONE, NEEDS HUMAN, STUCK, REVIEWED, ...); run again after each return. |
| `dispatch review NAME` or `--pr N --author pi\|claude --brief F` | Reviews the current PR head with a model from the other family (from `interrogate reviewers` in `~/.claude/rules/pstack-models.md`). |
| `dispatch merge PR [--dry-run]` | Merges only with an APPROVE verdict for the current head. |
| `dispatch adopt NAME --out FILE` | Supervises a pi pane that was started without dispatch. |
| `dispatch clean NAME [--force]` | Closes the pane, removes worktree and branches, frees ports, archives state. Refuses while the PR is open. |
| `dispatch doctor [--compare DIR]` | Installed vs repo version, local copies that drifted, project config, dependencies. |

`pi-worker` is also usable on its own (pstack's `pi:` roles call `~/.claude/bin/pi-worker`).
It exits 0 when the report and its `.done` marker are written, 1 when the pane is gone, 124 on timeout; needing a human, idling and empty reports only emit events.

## Files

- `dispatch`, `pi-worker`, `pi-readonly.ts` - entry points and the read-only sandbox for review workers.
- `approve-rules.sh`, `completion-rules.sh`, `secret-scan.sh` - approval rules, completion contract, credential scanner (prints locations, never values).
- `pi-send.sh`, `pi-events-wait.sh` - type into a pane; one-shot event waiter.
- `dispatchconf.py` - reads the project config.
- Tests: `tests/dispatch.test.sh`, `tests/dispatch-approvers.test.sh` (fake Rex, no GitHub, no credentials).

`home.nix` links `~/.local/bin/dispatch`, `~/.claude/bin/pi-worker` and `~/.claude/rules/pstack-models.md`; everything else is found next to the real file.

## Project config

Nothing project-specific lives here.
Repo path, state and evidence directories, work-card command, merge script, protected branches, temp-delete prefixes, database wrapper and extra secret patterns live in one local file: `$DISPATCH_CONFIG`, else `~/.config/dispatch/config`.
Start from [`dispatch.config.example`](dispatch.config.example).
A convenient layout is to keep the real file next to your project notes and symlink `~/.config/dispatch/config` to it, so pi-worker launched outside dispatch reads the same rules.

## Setting up another machine

1. `git -C ~/.dotfiles pull`, then run `~/.dotfiles/home/dispatch/dispatch doctor` *before* rebuilding.
   It diffs any hand-installed `pi-worker`, its old helper directory (or `--compare DIR`) and `~/.claude/bin` against this repo.
2. Generic improvements it finds go back into this repo as a commit; project values go into the local config.
3. Move the reported local copies aside (home-manager will not overwrite them), then `./rebuild.sh`.
4. Write the project config, then `dispatch doctor` until it has no FAIL, and `dispatch start NAME BRIEF --dry-run`.
