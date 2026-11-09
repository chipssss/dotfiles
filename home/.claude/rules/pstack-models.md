# pstack model configuration. One line per role. Delete a line to fall back to the skill default.
# `inherit-parent` or `auto` as a value: the role runs on the parent chat model (omit Task `model`). Alias entries in a panel list still count toward its fan-out.
# `pi:<provider>/<model> <effort>` as a value: the role runs outside the Agent tool, on that pi model, through
#   ~/.claude/bin/pi-worker --model <provider>/<model> --thinking <effort> [--readonly] --cwd <dir> --prompt-file <brief.md> --out <result.md>
#   Write the full subagent brief to the prompt file (file pointers, goal, output path). Do not pass --readonly; a read-only role says "do not edit files" in its brief and the caller checks git status.
#   Run it with Bash run_in_background so the result arrives as a notification; it opens a Rex pane the user can watch and exits with pi's status.
#   It is a different model family from Claude, so it counts as a cross-family judge and a diverse panel seat.
# budget: medium (high)
feature, refactoring: inherit-parent
bug-fix: inherit-parent
perf-issue: inherit-parent
hillclimb: inherit-parent
judgment and prose: opus high
hardest tasks: opus high
how explorer: pi:openai/gpt-6.1-sol high
how explainer: opus high
why investigators: pi:openai/gpt-6.1-sol high
why synthesizer: opus high
reflect tooling: pi:openai/gpt-6.1-sol high
reflect judgment, divergent, synthesizer: opus high
arena runners: opus high, pi:openai/gpt-6.1-sol high
arena cross-judge pool: pi:openai/gpt-6.1-sol high, opus high
swarm workers: pi:openai/gpt-6.1-sol high
architect runners: opus high, pi:openai/gpt-6.1-sol high
interrogate reviewers: opus high, pi:openai/gpt-6.1-sol high
