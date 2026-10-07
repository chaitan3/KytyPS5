#!/bin/sh
set -e

GAME="/mnt/nas/Games/emulators/ps5/Demon Souls/PPSA01341-app0"
EMULATOR="_Build/linux/kyty_emulator"

if [ ! -f "$EMULATOR" ]; then
    echo "error: $EMULATOR not found (run build.sh first)" >&2
    exit 1
fi
if [ ! -d "$GAME" ]; then
    echo "error: game folder not found at $GAME" >&2
    exit 1
fi

# Let the emulator's own handler resolve handled faults; gdb stops only when the
# process actually dies (unhandled signal or terminate/abort) or hangs.
exec gdb --batch \
    -ex "set pagination off" \
    -ex "handle SIGSEGV nostop noprint pass" \
    -ex "handle SIGBUS nostop noprint pass" \
    -ex "handle SIGILL nostop noprint pass" \
    -ex run \
    -ex "echo \n=== process stopped or terminated ===\n" \
    -ex "info registers rip rsp rbp" \
    -ex "bt 30" \
    --args "$EMULATOR" --game "$GAME"