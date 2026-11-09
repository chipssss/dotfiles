#!/bin/sh
# One-shot coordinator notification (dispatch wait runs this); restart it after each notification.
# Usage: pi-events-wait.sh [CURSOR_FILE]. One waiter per cursor; unread events are replayed.
exec python3 - "${PI_SUPERVISOR_STATE_DIR:-/private/tmp/pi-supervisor}" "${1:-}" <<'PY'
import os
from pathlib import Path
import sys
import time

state = Path(sys.argv[1])
state.mkdir(parents=True, exist_ok=True)
log = state / 'events.log'
cursor = Path(sys.argv[2]) if sys.argv[2] else state / 'events.cursor'
try:
    offset = int(cursor.read_text())
except (FileNotFoundError, ValueError):
    offset = 0
while True:
    try:
        with log.open('rb') as stream:
            if os.fstat(stream.fileno()).st_size < offset:
                offset = 0
            stream.seek(offset)
            data = stream.read()
    except FileNotFoundError:
        data = b''
    end = data.rfind(b'\n') + 1
    if end:
        sys.stdout.buffer.write(data[:end])
        sys.stdout.buffer.flush()
        tmp = cursor.with_name(cursor.name + '.' + str(os.getpid()))
        tmp.write_text(str(offset + end))
        os.replace(tmp, cursor)
        break
    time.sleep(0.5)
PY
