#!/bin/sh
set -e

# Headless debug run: no display, no GPU needed.
#
# Uses Mesa lavapipe (software Vulkan, package "vulkan-swrast") plus SDL3's
# offscreen video driver. The emulator normally hard-requires
# VK_KHR_fragment_shader_barycentric, which lavapipe does not expose, so
# KYTY_ALLOW_MISSING_BARYCENTRIC=1 is set: device selection no longer rejects the
# driver and the pixel-shader recompiler drops its barycentric path. Rendering is
# therefore approximate (not pixel-correct), but the guest runs normally, which is
# enough to debug hangs, crashes and library behaviour.
#
# If a real GPU/display is available, run_game_debug.sh is preferable for accurate
# rendering.

GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"

LOG="_kyty_headless.log"
STDOUT_LOG="_kyty_headless_stdout.log"
SHADER_LOG_FOLDER="_Shaders"

# Software Vulkan. Override VK_DRIVER_FILES to point at another ICD if desired.
export VK_DRIVER_FILES="${VK_DRIVER_FILES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export VK_ICD_FILENAMES="$VK_DRIVER_FILES"

# SDL3 offscreen video driver + the emulator's missing-barycentric fallback.
export SDL_VIDEODRIVER=offscreen
export KYTY_ALLOW_MISSING_BARYCENTRIC=1

# Tier-1 diagnostics (same as run_game_debug.sh).
export KYTY_WATCHDOG_HEARTBEAT=1
export KYTY_TRACE_SLEEP=1

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

mkdir -p "$SHADER_LOG_FOLDER"

echo "headless logging:"
echo "  emulator log : $LOG"
echo "  raw stdout   : $STDOUT_LOG"
echo "  shader log   : $SHADER_LOG_FOLDER/"
echo "  vulkan icd   : $VK_DRIVER_FILES"
echo "watch with  : tail -f $LOG $STDOUT_LOG"
echo ""

set +e
"$EMULATOR" --game "$GAME" \
    --printf-direction File --printf-output-file "$LOG" \
    --shader-log-direction File --shader-log-folder "$SHADER_LOG_FOLDER" \
    --graphics-debug-dump true \
    --hang-watchdog "${KYTY_HANG_WATCHDOG:-30}" \
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
