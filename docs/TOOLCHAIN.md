# Personal toolchain targets (from MacBook + Mini snapshot)

These are **observed versions**, not hard pins. Fresh machine: install via Brewfile / official installers, then re-check.

| Tool | MacBook (personal) | Mini (chips) | Install |
| --- | --- | --- | --- |
| node | v23.10.0 | v26.x (brew) | `brew install node` |
| pnpm | 9.12.2 | 10.x | `brew install pnpm` |
| go | 1.24.1 | 1.27.x | `brew install go` |
| uv | 0.9.26 | brew | `brew install uv` |
| bun | 1.3.11 | 1.3.x | `curl -fsSL https://bun.sh/install \| bash` |
| python | 3.13.2 | 3.13/3.14 | `brew install python@3.13` |
| tmux | 3.6a | brew | `brew install tmux` |
| gh | 2.86.0 | brew | `brew install gh` |
| neovim | present | nix + brew | Brewfile / nix home.packages |

Firstmate preflight wants: Git, `gh` logged into `lighthouser-agent`, Node ≥20, tmux, Codex CLI, Pi.
