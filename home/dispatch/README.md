# Shared Agent development environment

This directory contains machine-independent Pi supervision, safety rules, credential
scanning and a lightweight launcher. Run the same checkout on home and work machines.
No review, merge, pull-request management, issue tracker, database wrapper or project
hook belongs here. Those workflows live outside this repository.

## Setup and commands

Copy `dispatch.config.example` to `~/.config/dispatch/config`, or set `DISPATCH_CONFIG`.
Only safety policy and a port range go in this file. Missing/broken policy, unknown
keys and duplicates fail closed. Default strict approval mode requires a nonempty
protected-branch list; `main` and `master` are always added. Explicit `generic` mode
only knows those built-in branches unless more are listed. `dispatchconf.py` owns
all setting defaults and built-in protected branches; launcher, approval, scanner
and doctor use the same effective settings. Explicit empty values do not restore
defaults (and an empty protected list still fails in strict mode).

Home Manager links `dispatch` and `pi-worker`; helpers remain beside their real files.
Before deploying a changed checkout, compare hand-installed copies with doctor.
Deployment is separate from validation, and doctor never rebuilds or fetches.

Run from **any Git repository or worktree** with an `origin` remote, including a local
bare remote. No GitHub account or `gh` dependency is needed.

```sh
dispatch start DEMO brief.md --base origin/main --dry-run
dispatch start DEMO brief.md --model openai/gpt-6.1-sol
dispatch status --json
dispatch wait
# Continue an existing remote branch; the hosting platform is irrelevant.
dispatch start NEXT brief.md --branch feature/next --existing-branch --base origin/main
# Clean only after checking the report. Remote branches are NEVER deleted.
dispatch clean DEMO
```

- `start` creates a local branch/worktree, composes the brief, allocates ten ports,
  and starts a background supervisor. Fresh remote branches are not created by the
  launcher; the worker can first push with `git push -u origin HEAD`.
- `--base` accepts `origin/x` or `x`, not a different remote prefix. `--existing-branch`
  requires the remote branch to exist and no local same-named branch. Shared branch
  patterns cannot be used as worker branches. `--common FILE` prepends task context.
- `--dry-run` does read-only preflight, with no state, worktree, pane or branch writes.
- `status` shows running, needs-human, stuck, finished, failed and unexpected exits.
- `wait [CURSOR]` waits for new supervisor events; restart it after each return.
- `clean` stops a live supervisor only with `--force`, removes owned local resources,
  archives state and frees ports. Dirty/unmerged work is retained unless forced.
  Interrupted creation with uncertain ownership is never automatically deleted.
- `_run` is an internal supervisor entry, not a project integration hook.

Default state is `~/.local/state/dispatch/<hash-of-common-git-dir>`; worktrees of the
same repository share state. Outputs live in `outputs/NAME/result.md` below it.
Override runtime selection with `DISPATCH_REPO`, `DISPATCH_STATE_DIR`,
`DISPATCH_EVIDENCE_DIR`, `DISPATCH_WORKTREE_ROOT`, or `DISPATCH_MODEL`. These are
runtime inputs, not project items in the machine policy. Default worktree root is
`/private/tmp/dispatch-wt`. A global allocator lock and reservations under that root
coordinate port allocation across repositories. Alternate roots are independent.

## Supervision and safe confirmation

`pi-worker` runs a visible Pi TUI through Rex. It keeps supervising after a human
confirmation, idle pane or empty report. It notifies, writes `.needs-human` / `.stuck`
and appends events, without including the captured command (which may contain secrets).
A nonempty report and `.done` marker must pass the shared scanner before completion.
Empty output gets at most three rewrite requests, then waits for human repair.
Timeout preserves the pane. Model connection retries are bounded. `--attach` can
supervise an existing pane, but without a verifiable cwd, push confirmations wait.

Automatic push approval reads **local Git configuration, never the network**:

- Only local branch sources and branch destinations are eligible. Tags, bare tag
  names, `tag`, `refs/tags/`, `--tags`, `--follow-tags`, force/delete/mirror flags,
  `push.followTags` and remote mirror mode always need a human.
- Resolve selected remote from explicit arguments, `branch.*.pushRemote`,
  `remote.pushDefault` and `branch.*.remote`; then inspect `remote.<name>.push`.
  An explicit bare source still honors its configured destination mapping.
- With no mapping/refspec, resolve `push.default` (`simple`, `upstream`, `current`)
  and `branch.<name>.merge`. Matching, nothing, wildcard/multiple ambiguous mappings,
  detached HEAD, missing cwd, missing source or unresolved targets need a human.
- All actual destinations must avoid protected patterns. Explicit
  `HEAD:refs/heads/feature/x` does not inherit a remote's default refspec, but still
  rejects implicit tag/mirror settings. Unknown syntax never gets guessed.

Deletion approval resolves real paths, checks directory boundaries and checks every
symlink component. Escaping a temporary root and linking back is refused. A `.tmp`
root cannot itself be a symlink. Multiple deletion targets must all be safe.
This parser cannot prove a shell AST, so **all compounds, expansions and
redirections wait for a human**, including apparently safe ones. For simple commands,
only the executable word can trigger the process-command-line reason: `ps` and
`pgrep -f/-l/-a` (including long options and known system paths). `docker ps`,
PID-only `pgrep -x`, and `ps` in branch names or deletion paths do not trigger it.
Non-push/rm commands still need a human, with a generic reason. Database/container
operations and hosted-PR mutations have no automatic allowlist here.

## Two-machine comparison and tests

```sh
dispatch doctor --compare /path/to/old/helpers
dispatch doctor --json > /tmp/dispatch-machine.json
# Copy the other machine's JSON report to /tmp/dispatch-other.json, then:
python3 - /tmp/dispatch-machine.json /tmp/dispatch-other.json <<'PY'
import json, sys
left, right = [json.load(open(p)) for p in sys.argv[1:]]
for key in ('head', 'files', 'config_sha256', 'dirty', 'install', 'versions', 'dependencies'):
    if left[key] != right[key]:
        print(key, 'differs')
PY
for t in tests/dispatch*.test.sh; do bash "$t"; done
python3 tests/dotfiles-public-check --base BASE_SHA
```

Doctor's `--json` stdout is one JSON document, without text prefixes or suffixes.
It reports the checkout `head`, helper `files` hashes, dependency paths and versions,
`dirty` (tracked changes or untracked, non-ignored files), and `install` status for
`dispatch` and `pi-worker`: `linked`, `identical-copy`, `drifted` or `missing`.
`config_sha256` hashes effective configuration with defaults, ignoring comments,
key order and whitespace in list settings; it does not expose configuration values.
Invalid policy produces a null fingerprint and a FAIL check even in JSON mode.
`checks` and `fail_count` retain diagnostics. Installation paths and dependency paths
can naturally differ between machines; compare status/version as well as hashes.
Missing/different installation is a WARN before deployment, not proof that this new
checkout is installed. FAIL means invalid safety policy or a missing runtime dependency.
Matching shell comments are never accepted as evidence that a helper forwards to the
repository. Doctor does not modify either installation.

The public release check under `tests/` examines only **this dotfiles checkout's**
diff, commit messages and author/committer identities. It is not part of worker
startup or collection, and is not a reusable public-PR gate. Existing historical
metadata is not rewritten. Choose the new-commit base explicitly.

The credential scanner checks OpenAI/Anthropic API key shapes, GitHub tokens,
`BEGIN ... PRIVATE KEY` headers (including `BEGIN PGP PRIVATE KEY BLOCK`),
three-part JWT-shaped strings, and generic
`scheme://user:password@host.invalid/path`-shaped URLs, including empty usernames
such as `redis://:password@host.invalid/0` and nested/binary output. Password URLs
on reserved `.invalid` hosts or exact loopback hosts (`localhost`, `127.0.0.1`,
`::1`, `[::1]`) are exempt regardless of the password, with no port, numeric ports,
or CI template ports. Lookalikes such as `127.0.0.1.evil.com` and
`localhost.example` are still flagged. The legacy `secret_fixture_passwords`
setting remains accepted for config compatibility but no longer controls these
exemptions. URLs without a password are not flagged by this rule.
It prints locations/categories, never matched values. These patterns and custom
regexes are finite checks, not proof that arbitrary data is non-secret. Human
inspection remains necessary.
