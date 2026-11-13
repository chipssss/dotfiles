#!/bin/sh
# PreToolUse hook: deny Claude subagents (Agent tool, incl. fork / worktree / remote).
# Delegate to pi (dispatch / pi-worker), or a claude CLI in a Rex pane when a Claude model is needed.
# Escape hatch: launch Claude Code with ALLOW_CLAUDE_SUBAGENT=1.
cat >/dev/null
[ "${ALLOW_CLAUDE_SUBAGENT:-}" = 1 ] && exit 0
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Claude subagents are blocked; follow /lin-mode. Check `quota-axi` first. Non-Claude model: repo code work via `dispatch start NAME BRIEF --model <provider/id>`, one-shot work via `~/.claude/bin/pi-worker --model openai/gpt-6.1-sol ...` (Bash run_in_background). Claude model (pi has none, and only when Claude quota allows): start `cc` (alias of claude --dangerously-skip-permissions) in a Rex pane, `rex run -s \"$REX_SESSION\" --focus=false --label 'claude NAME' --json --shell=none -c DIR -- zsh -ic 'cc --model opus --effort high \"$(cat \"$1\")\"' _ BRIEF`, with the brief telling it to write OUT and OUT.done. If neither works, tell the user why; they can relaunch with ALLOW_CLAUDE_SUBAGENT=1."}}
JSON
