#!/bin/sh

GAME="/mnt/nas/Games/emulators/ps5/Demon Souls/PPSA01341-app0"
EMULATOR="_Build/linux/kyty_emulator"

ulimit -c unlimited 2>/dev/null || true

"$EMULATOR" --game "$GAME" 2>&1 | tee /tmp/kyty_probe.log
status="${PIPESTATUS[0]}"

echo ""
echo "=== emulator exited with status $status ==="
if [ "$status" -ge 128 ]; then
    sig=$((status - 128))
    echo "=== died from signal $sig ($(kill -l "$sig" 2>/dev/null)) ==="
fi

exit "$status"