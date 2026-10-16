#!/bin/sh
set -e

# Headless debug run: no display, no GPU needed.
#
# Uses Mesa lavapipe (software Vulkan) plus SDL3's offscreen video driver. The
# emulator normally hard-requires VK_KHR_fragment_shader_barycentric, which
# lavapipe does not expose, so KYTY_ALLOW_MISSING_BARYCENTRIC=1 is set: device
# selection no longer rejects the driver and the pixel-shader recompiler drops
# its barycentric path.

GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"

LOG="_kyty_headless.log"
STDOUT_LOG="_kyty_headless_stdout.log"
GUEST_PRINTF_LOG="_guest_printf.log"
FRAME_DIR="_frames"

# Software Vulkan. Override VK_DRIVER_FILES to point at another ICD if desired.
export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export VK_ICD_FILENAMES="$VK_DRIVER_FILES"

# SDL3 offscreen video driver + the emulator's missing-barycentric fallback.
export SDL_VIDEODRIVER=offscreen
export KYTY_ALLOW_MISSING_BARYCENTRIC=1

# Debug-only scaffolding for headless iteration (remove before upstreaming):
#  - KYTY_FAKE_PAD      : synthesize a controller so menus can be advanced.
#  - KYTY_NP_SIGNED_IN  : NP layer reports a signed-in user.
#  - KYTY_DUMP_FRAME    : write presented frames as PPM files for inspection.
#  - KYTY_GUEST_PRINTF_FILE : capture the game's own printf output.
export KYTY_FAKE_PAD=1
export KYTY_GUEST_PRINTF_FILE="$GUEST_PRINTF_LOG"
# Frame dumping is opt-in (set KYTY_DUMP_FRAME in the caller's env to enable).
if [ -n "$KYTY_DUMP_FRAME" ]; then
    export KYTY_DUMP_FRAME
    export KYTY_DUMP_FRAME_INTERVAL="${KYTY_DUMP_FRAME_INTERVAL:-120}"
    export KYTY_DUMP_FRAME_COUNT="${KYTY_DUMP_FRAME_COUNT:-24}"
fi
export KYTY_ALLOW_UPLOAD_REENTRY=1

ulimit -c unlimited 2>/dev/null || true

if [ ! -f "$EMULATOR" ]; then
    echo "error: $EMULATOR not found (run ./build.sh first)" >&2
    exit 1
fi

if [ ! -d "$GAME" ]; then
    echo "error: game folder not found at $GAME" >&2
    echo "edit this script and set GAME to the correct path" >&2
    exit 1
fi

if [ ! -f "$VK_DRIVER_FILES" ]; then
    echo "error: Vulkan ICD not found at $VK_DRIVER_FILES" >&2
    echo "install vulkan-swrast (Arch) or set VK_DRIVER_FILES" >&2
    exit 1
fi

mkdir -p "$FRAME_DIR"
rm -f "$FRAME_DIR"/frame_*.ppm "$GUEST_PRINTF_LOG"

echo "headless logging:"
echo "  emulator log : $LOG"
echo "  raw stdout   : $STDOUT_LOG"
echo "  guest printf : $GUEST_PRINTF_LOG"
echo "  frames       : $FRAME_DIR/"
echo "  vulkan icd   : $VK_DRIVER_FILES"
echo "watch with  : tail -f $LOG $STDOUT_LOG"
echo ""

PATCH_ARG=""
if [ -n "$GAME_PATCH" ]; then
    PATCH_ARG="--game-patch $GAME_PATCH"
fi

set +e
# shellcheck disable=SC2086
"$EMULATOR" --game "$GAME" \
    --network-connected true \
    $PATCH_ARG \
    --printf-direction File --printf-output-file "$LOG" \
    --skip-notice-screen true \
    > "$STDOUT_LOG" 2>&1
status=$?
set -e

echo ""
echo "emulator exited with status $status"
if [ "$status" -ge 128 ]; then
    sig=$((status - 128))
    echo "killed by signal $sig ($(kill -l "$sig" 2>/dev/null))"
fi
echo "see $STDOUT_LOG for stdout/stderr and $LOG for LOGF output"
