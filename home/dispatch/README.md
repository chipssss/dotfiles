# dispatch

Local scheduling for pi workers, from worktree to independently reviewed PR.
Each worker runs as an interactive pi session in a Rex pane, under a resident supervisor.
Needing a human, idling and empty reports emit events without abandoning supervision.

| Command | What it does |
|---|---|
| `dispatch start NAME BRIEF [--common F] [--card ID \| --new-card TITLE] [--base B] [--branch B] [--existing-branch] [--dry-run]` | Creates an isolated checkout, upstream, port block, composed brief and background supervisor. Dry-run runs read-only preflight. |
| `dispatch status [--json]` | Phase, failure reason, PR, review verdict, card, ports and age. |
| `dispatch wait [CURSOR]` | Waits for new events; run again after each return. |
| `dispatch review NAME` or `--pr N --author provider/model --brief F` | Independently reviews the exact head/base snapshot, using another model family. |
| `dispatch merge PR [--dry-run]` | Requires APPROVE for the current head, base name and base SHA. |
| `dispatch adopt NAME --out FILE [--model provider/model]` | Supervises an existing pi pane. Without an actual model identity it cannot be automatically reviewed. |
| `dispatch clean NAME [--force]` | Removes owned checkout/resources and archives state. Fresh branches with an open PR are retained. Resumed remote branches are never deleted. |
| `dispatch doctor [--compare DIR]` | Checks installation, local drift, config, dependencies and disabled legacy merge scripts. |

`pi-worker` is also usable on its own. It exits 0 after a nonempty report, clean scan and
`.done` marker, 1 when the pane disappears, or 124 on timeout.

## Safe defaults

Project values live only in `$DISPATCH_CONFIG`, else `~/.config/dispatch/config`.
Start from [`dispatch.config.example`](dispatch.config.example). Missing config, dangling
links, unknown/duplicate keys and malformed safety settings never authorize writes.
Project mode requires a nonempty `protected_branches` declaration. `main` and `master`
are always protected, even when the project list contains only additional patterns.
An intentionally project-independent installation can explicitly set `approval_mode = generic`;
this protects main/master but cannot know a project's other shared branches.

Automatic approval supports only recognized **simple commands**. Compound commands,
newlines (including ambiguous terminal wraps), redirects, expansions, nested shells,
Git global options and unknown executables wait for a human. This deliberately also
rejects `cd ... && git push` and two individually safe commands joined with `;`.
A bare push is checked against the pane's exported cwd, current branch and upstream.
Use separate commands rather than weakening this boundary.

Recursive deletion resolves the target and allowed roots, checks canonical directory
boundaries, and rejects any symlink component escaping the allowed temporary roots,
even if the final path returns into tmp. `.tmp/` itself cannot be an escaping symlink.
Deleting an allowed root itself, traversal, globs, broken links and ambiguous cwd wait
for a human. This is a confirmation-time check, not a filesystem sandbox: do not use
an automatically approved path when another process can swap its directories or links
between approval and execution.

## Review and merge contract

The verdict and cache key bind `(head SHA, base branch name, base SHA)`.
Changing any member, including advancing the base without changing head, requires a
new review. The snapshot is checked after diff capture, after reviewer completion,
and immediately before invoking GitHub merge. Legacy head-only verdicts are stale.

The actual provider/model slug determines family (`openai` or `anthropic`), never the
`pi` or `claude` runner. Unknown models fail closed. A Pi-launched Anthropic model
cannot serve as an independent reviewer of another Anthropic model. The reviewer
selection comes from `interrogate reviewers` in `~/.claude/rules/pstack-models.md`.
For explicit review, pass an actual identity, for example `--author openai/gpt-6.1-sol`,
not `--author pi`. Local state and model configuration are trusted operator inputs,
not cryptographically attested identity records.

Legacy `merge_script` execution is **disabled**, not monitored after the fact. Such a
script can update and merge before a stdout observer can intervene. If configured,
merge refuses before launching it. Update the branch separately, review the new
snapshot, and explicitly remove the legacy setting to use the built-in gate.
No merge-only equivalence exemption is implemented.

The built-in path runs `gh pr merge --match-head-commit <reviewed SHA>` in the configured
repo, never the caller's cwd. GitHub atomically checks the expected head. GitHub's merge
API does not offer an equivalent atomic base-name/base-SHA condition: the base check
is a final client-side preflight, not a server transaction. Do not concurrently retarget
or advance the base during merge, and use repository branch protections for shared
branches. A queued/deferred merge is not a new review of a later base.

## Continue an existing PR

```sh
dispatch start FIX brief.md --branch feature/fix --base origin/main --existing-branch --dry-run
dispatch start FIX brief.md --branch feature/fix --base origin/main --existing-branch
```

Default start still refuses an existing remote branch. Explicit continuation accepts
only an OPEN, non-fork PR on the configured origin, with the requested branch and base.
It refuses protected branches, existing local branches/worktrees and registered workers,
fetches the current remote head, creates a new checkout with the matching upstream,
and records PR/head metadata with the supplied task brief. Carry the original brief
forward in that file when handing off to another machine. New commits invalidate old
verdicts. Clean removes only the continuation checkout and local branch, not the remote PR.
Bare base names and `origin/name` are equivalent. Other remote prefixes and invalid or
nonexistent bases are refused; arbitrary ref expressions are not supported.

Start allocates ports and validates input files before external side effects. It writes
a `preparing` journal first, records resource ownership as each operation succeeds,
and leaves `failed` state on later errors. `status` exposes that state and `clean NAME`
can recover owned resources. If interrupted inside a creation operation, `*_pending`
flags preserve the uncertainty: clean refuses to guess ownership. Inspect the journal
and actual refs first, rather than deleting an unverified branch. Keep tracker/card
IDs from partial failures before retrying, so an external card is not duplicated.

## Public payload checks

```sh
python3 home/dispatch/public-check --repo . --base origin/main --pr 1
# Or check a prepared, not-yet-published PR body:
python3 home/dispatch/public-check --repo . --base origin/main --pr-body /tmp/pr-body.md
```

The read-only checker covers the complete diff, commit messages, author **and** committer
names/emails, and PR body. It requires public GitHub noreply emails, checks local paths
and hostnames, and runs the shared credential scanner over every payload. Referenced
commits must already exist locally. A failed or incomplete scan blocks automated review.
Published historical identity findings are not silently ignored or rewritten; decide
history governance separately and never claim that a clean incremental scan cleans history.

The scanner's finite built-in formats include OpenAI and Anthropic API keys, GitHub
tokens, JWTs and password-bearing Postgres URLs. Project-specific patterns belong in
local `secret_pattern.*` config. It reports locations/categories, never matched values.
This is not arbitrary secret detection; human review of public material is still required.
An absent default config permits built-in-only scanning, not write approval; an explicitly
missing config or broken default link is a scan error.

## Setting up another machine

1. Fetch the repository and run `dispatch doctor --compare OLD_SCRIPTS_DIR` before rebuilding.
2. Back up local copies, inspect every WARN and run the suggested diffs. Doctor only
   reports proven repository symlinks as forwarding; comments or shell text are not proof.
   Unknown helpers are reported for classification. No ignore list hides them.
3. Merge generic local improvements back into the repository; put project values in local config.
4. Move conflicting hand-installed files aside, keeping backups, then rebuild yourself.
   Never copy another machine's deletion command to remove your local improvements.
5. Validate config with doctor and run `dispatch start ... --dry-run`. No FAIL is useful
   but is not proof that migration is lossless. Inspect WARNs too.

`home.nix` links only `dispatch`, `pi-worker` and `pstack-models.md`; helpers live beside
the resolved entry point. It does not manage Pi auth or runtime state.

Tests: run each `tests/dispatch*.test.sh`. They use fake Rex, local Git fixtures and
process-boundary substitutes, never live GitHub merges, real credentials or user-directory deletion.
