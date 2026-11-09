#!/bin/sh
# Shared completion contract: 0 = nonempty safe evidence + marker, 1 = pending, 2 = stuck.
completion_evidence_safe() {
  if sh "$PI_SCRIPTS/secret-scan.sh" "$(dirname "$1")" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' '证据安全扫描命中疑似凭据或未能完成；请检查本任务目录全部产出，清理并独立复查后再写 .done。命中内容不回显'
  return 1
}
# A shared counter/lock keeps concurrent pi-worker supervisors (launch and --attach) from each sending three nudges.
completion_check() {
  completion_out=$1 completion_block=$2
  completion_state=${PI_COMPLETION_STATE_DIR:-/private/tmp/pi-completion}
  mkdir -p "$completion_state"
  completion_key=$(printf '%s' "$completion_out" | shasum -a 256 | awk '{print $1}')
  completion_count="$completion_state/$completion_key.count"
  completion_lock="$completion_state/$completion_key.lock"
  mkdir "$completion_lock" 2>/dev/null || return 1
  completion_n=0
  [ ! -f "$completion_count" ] || read -r completion_n < "$completion_count"
  completion_problem="$(basename -- "$completion_out") 是空的，请重写完整报告（太长就分段追加），确认非空后再写 .done"
  if [ -f "$completion_out.done" ] && [ -s "$completion_out" ]; then
    if completion_problem=$(completion_evidence_safe "$completion_out"); then
      rmdir "$completion_lock"
      return 0
    fi
    printf '%s\n' "$completion_problem" >&2
  fi
  if [ "$completion_n" -ge 4 ]; then
    rm -f "$completion_out.done"
    rmdir "$completion_lock"
    return 2
  fi
  if [ ! -f "$completion_out.done" ]; then
    rmdir "$completion_lock"
    return 1
  fi
  # Do not consume a retry until we have a pane to send the repair instruction to.
  if [ -z "$completion_block" ]; then
    rm -f "$completion_out.done"
    rmdir "$completion_lock"
    return 2
  fi
  rm -f "$completion_out.done"
  completion_n=$(( completion_n + 1 ))
  printf '%s\n' "$completion_n" > "$completion_count"
  rmdir "$completion_lock"
  if [ "$completion_n" -le 3 ]; then
    "$PI_SCRIPTS/pi-send.sh" "$completion_block" "$completion_problem" >&2 || true
    return 1
  fi
  return 2
}
