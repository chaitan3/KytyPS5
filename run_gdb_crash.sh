#!/bin/sh
set -e

# Crash catcher for Call of Duty Vanguard under the headless emulator
# (lavapipe + SDL offscreen, no display needed).
#
# Lands in the SIGSEGV handler at the first guest fault and prints the
# faulting guest PC / registers, then the emulator frames around it.

GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"
PATCH="_Patches/PPSA01687.json"

# Headless: software Vulkan + SDL offscreen + missing-barycentric fallback.
export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
export SDL_VIDEODRIVER=offscreen
export KYTY_ALLOW_MISSING_BARYCENTRIC=1

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

ARGS=""
if [ -f "$PATCH" ]; then
    ARGS="--game-patch $PATCH"
fi

exec gdb --batch \
    -ex "set pagination off" \
    -ex "set confirm off" \
    -ex "handle SIGPIPE nostop noprint pass" \
    -ex run \
    -ex "bt 12" \
    -ex "frame 0" \
    -ex "info registers rax rbx rcx rdx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15 rbp rsp rip" \
    -ex "x/4i \$rip" \
    --args "$EMULATOR" --game "$GAME" --amd-cpu $ARGS --hang-watchdog 0
