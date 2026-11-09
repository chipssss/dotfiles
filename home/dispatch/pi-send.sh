#!/bin/sh
# usage: pi-send.sh BLOCK_ID MESSAGE - type MESSAGE into a pi pane and submit it.
# A path in the message opens pi's path completion, and the first enter only accepts it,
# so keep pressing enter until the input box (between the last two rule lines) is empty.
b=$1; shift
rex block send -s "${REX_SESSION:?}" -b "$b" "$*" >/dev/null || exit 1
for _ in 1 2 3 4; do
  rex block send-key -s "$REX_SESSION" -b "$b" enter >/dev/null
  sleep 2
  rex block capture -s "$REX_SESSION" -b "$b" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -8 | awk '
    /^─+[[:space:]]*$/ { if (prev_rule) empty=1; else empty=0; prev_rule=1; next }
    { prev_rule=0 }
    END { exit empty ? 0 : 1 }' && exit 0
done
echo "pi-send: input still not empty in $b" >&2; exit 2
