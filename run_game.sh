#!/bin/sh
set -e

GAME="/mnt/nas/Games/emulators/ps5/Demon Souls/PPSA01341-app0"
#GAME="/mnt/nas/Games/emulators/ps5/Ghost of Yotei/PPSA26344-app0"
#GAME="/mnt/nas/Games/emulators/ps5/Astro Bot/PPSA21564-app0"
GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"
PATCH="_Patches/PPSA21564.json"

# Enable core dumps so a fatal fault can be inspected with gdb afterwards
# (resolvable guest-memory faults are handled by the emulator and do not core).
ulimit -c unlimited 2>/dev/null || true

if [ ! -f "$EMULATOR" ]; then
    echo "error: $EMULATOR not found (run build.sh first)" >&2
    exit 1
fi

if [ ! -d "$GAME" ]; then
    echo "error: game folder not found at $GAME" >&2
    echo "edit this script and set GAME to the correct path" >&2
    exit 1
fi

#exec "$EMULATOR" --game "$GAME" --game-patch $PATCH
#exec "$EMULATOR" --game "$GAME"
exec "$EMULATOR" --game "$GAME" --skip-notice-screen 1 --playgo-hack --amd-cpu
