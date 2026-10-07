#!/bin/sh
set -e

GAME="/mnt/nas/Games/emulators/ps5/Demon Souls/PPSA01341-app0"
#GAME="/mnt/nas/Games/emulators/ps5/Ghost of Yotei/PPSA26344-app0"
#GAME="/mnt/nas/Games/emulators/ps5/Astro Bot/PPSA21564-app0"
GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"
PATCH="_Patches/PPSA21564.json"

# Debug build of run_game.sh: keeps the same game/emulator selection but turns on
# the emulator's LOGF logging (Silent by default) so the last calls before a hang
# are visible. Output goes to files instead of the terminal to avoid flooding.
LOG="_kyty_debug.log"
SHADER_LOG_FOLDER="_Shaders"
STDOUT_LOG="_kyty_debug_stdout.log"
GUEST_PRINTF_LOG="_guest_printf.log"

# Diagnostics are always on; no need to set any environment variables.
#  - heartbeat: log the main guest thread's last call/wait every second
#  - trace sleep: dump the caller chain + fatal message when Sys_Error sleeps
#  - guest printf: capture the game's printf output to a file
export KYTY_WATCHDOG_HEARTBEAT=1
export KYTY_TRACE_SLEEP=1
export KYTY_GUEST_PRINTF_FILE="$GUEST_PRINTF_LOG"

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

mkdir -p "$SHADER_LOG_FOLDER"

echo "logging:"
echo "  emulator log : $LOG"
echo "  raw stdout   : $STDOUT_LOG (printf + --- Fatal Error --- reports)"
echo "  shader log   : $SHADER_LOG_FOLDER/"
echo "  guest printf : $GUEST_PRINTF_LOG"
echo "watch with  : tail -f $LOG $STDOUT_LOG"
echo ""

# Tier-1 diagnostics (always on, bounded):
# --printf-direction        switches LOGF/PrintName output from Silent to File.
# --shader-log-direction    logs the shader recompiler IR (via LOGF, can be large).
# --graphics-debug-dump     enables AGC command trace, SPIR-V/original shader dumps
#                           into the shader folder, flip logs and per-draw traces.
# --hang-watchdog           dumps all guest threads after N seconds without progress.
#
# Tier-2 diagnostics (large/slow, opt-in): set KYTY_DEEP_DUMP=1 to enable
# command-buffer PM4 dumps (_Buffers/) and Vulkan + SPIR-V validation.
# For a full trace of every guest library entry, force PRINT_NAME_ENABLED on in
# src/libs/libs.h and rebuild; expect a very large log.
#
# stdout+stderr are captured separately because fatal reports (Common::DbgExitHandler)
# always go to stdout, and DbgExit() calls _Exit() so no core is written.
DEEP_DUMP="${KYTY_DEEP_DUMP:-0}"
if [ "$DEEP_DUMP" = "1" ]; then
    DEEP_ARGS="--command-buffer-dump true --command-buffer-dump-folder _Buffers --vulkan-validation true --shader-validation true"
else
    DEEP_ARGS=""
fi

HANG_WATCHDOG="${KYTY_HANG_WATCHDOG:-20}"

if [ "${KYTY_SKIP_NOTICE_SCREEN:-0}" = "1" ]; then
    NOTICE_ARGS="--skip-notice-screen true"
else
    NOTICE_ARGS=""
fi

BUFFER_LOG_FOLDER="_Buffers"

echo "diagnostics:"
echo "  graphics debug dump : on (AGC trace + shader dumps in $SHADER_LOG_FOLDER/)"
echo "  shader recompiler IR: on (in $LOG)"
echo "  hang watchdog       : ${HANG_WATCHDOG}s (manual: kill -USR1 \$(pgrep -x kyty_emulator))"
echo "  main-thread heartbeat: on (in $LOG and $STDOUT_LOG)"
echo "  Sys_Error tracing   : on (caller chain + message in $LOG)"
echo "  guest printf capture: on (in $GUEST_PRINTF_LOG)"
if [ "$DEEP_DUMP" = "1" ]; then
    echo "  deep dump           : on (command buffers in $BUFFER_LOG_FOLDER/, validation layers)"
else
    echo "  deep dump           : off (set KYTY_DEEP_DUMP=1 for command buffers + validation)"
fi
echo ""

set +e
#exec "$EMULATOR" --game "$GAME" --game-patch "$PATCH" \
"$EMULATOR" --game "$GAME" \
    --printf-direction File --printf-output-file "$LOG" \
    --shader-log-direction File --shader-log-folder "$SHADER_LOG_FOLDER" \
    --graphics-debug-dump true \
    --hang-watchdog "$HANG_WATCHDOG" \
    $NOTICE_ARGS \
    $DEEP_ARGS \
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
