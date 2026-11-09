#!/usr/bin/env bash
# Regression tests for the independent dispatch review. No live GitHub, Rex or deletion commands.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT PYTHONDONTWRITEBYTECODE=1
exec python3 -B "$ROOT/tests/dispatch_security.py"
