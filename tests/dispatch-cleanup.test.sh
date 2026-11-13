#!/usr/bin/env bash
# Real Git worktrees and a local bare remote; fake Rex, no hosted PR mutations.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
exec python3 -B "$ROOT/tests/dispatch_cleanup.py"
