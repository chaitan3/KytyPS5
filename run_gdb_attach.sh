#!/bin/sh
set -e

PID="$(pgrep -x kyty_emulator | head -1)"

if [ -z "$PID" ]; then
    echo "error: no running kyty_emulator process found" >&2
    echo "start the game with ./run_game.sh, wait for it to hang, then run this" >&2
    exit 1
fi

echo "attaching to pid $PID ..."

exec gdb -p "$PID" --batch \
    -ex "set pagination off" \
    -ex "set print thread-events off" \
    -ex "info threads" \
    -ex "thread apply all bt 20" \
    -ex "detach" \
    -ex "quit"