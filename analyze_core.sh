#!/bin/sh
# Analyze the most recent core dump from the emulator with gdb.
CORE=$(ls -t core* 2>/dev/null | head -1)
if [ -z "$CORE" ]; then
    echo "no core file found in $(pwd)" >&2
    exit 1
fi
echo "analyzing core: $CORE"
gdb --batch -ex "set pagination off" -ex "info threads" -ex "thread apply all bt" _Build/linux/kyty_emulator "$CORE"
