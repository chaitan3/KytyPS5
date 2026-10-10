#!/bin/sh
set -e

# Call of Duty: Vanguard debug run on the desktop GPU (NVIDIA) with a real
# display.  Unlike run_gdb_crash.sh this does NOT force lavapipe/offscreen, so
# it uses whatever Vulkan ICD + SDL video driver your session normally uses.
#
# It turns on the emulator's Tier-1 diagnostics:
#   * hang watchdog         : after N seconds without progress (or on SIGUSR1)
#                             dumps every guest thread's last library call and
#                             the wait it is parked on.
#   * main-thread heartbeat : logs the primary guest thread's last call every
#                             second, so a short stall is visible before the
#                             watchdog fires.
#   * guest printf capture  : the game's own printf output.
#   * LOGF (PrintName) log  : last library calls, in _nv_debug.log.
#   * event-flag trace      : every create/set/clear/wait on the event flag that
#                             the main thread parks on (filtered by its low 24
#                             bits, KYTY_EVENT_TRACE), with guest return addrs.
#                             The default filter is the CoD loading-screen flag
#                             0x21d480.  Use KYTY_EVENT_TRACE=0 to log all.
#
# A SIGUSR1 dump is sent automatically after KYTY_AUTODUMP seconds (default 15),
# so a stall is captured without any manual step. Send SIGUSR1 manually at any
# time to force a dump (kill -USR1 $(pgrep -x kyty_emulator)).
#
# Usage:
#   ./run_nv_debug.sh                 # 60s watchdog, 15s autodump (defaults)
#   KYTY_HANG_WATCHDOG=20 KYTY_AUTODUMP=35 ./run_nv_debug.sh
#   KYTY_EVENT_TRACE=0 ./run_nv_debug.sh     # trace every event flag
#
# Relevant output:
#   _nv_watchdog.log      : just the guest-thread dump (share this)
#   _nv_events.log        : just the [EV] event-flag trace (share this)
#   _nv_debug_stdout.log  : full emulator stdout
#   _nv_debug.log         : LOGF (library-call) trace
#   _nv_guest_printf.log  : the game's printf output

GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"
PATCH="_Patches/PPSA01687.json"

LOG="_nv_debug.log"
STDOUT_LOG="_nv_debug_stdout.log"
GUEST_PRINTF_LOG="_nv_guest_printf.log"

# Do not clamp the ICD or SDL here: we want the desktop GPU and the real window.
export KYTY_ALLOW_MISSING_BARYCENTRIC="${KYTY_ALLOW_MISSING_BARYCENTRIC:-1}"
export KYTY_WATCHDOG_HEARTBEAT=1
export KYTY_GUEST_PRINTF_FILE="$GUEST_PRINTF_LOG"
# Trace the event flag the main thread parks on (low-24-bit filter). 0 = all.
export KYTY_EVENT_TRACE="${KYTY_EVENT_TRACE:-0x21d480}"
# Report the user as signed in to PlayStation Network (set to 0 to disable).
export KYTY_NP_SIGNED_IN="${KYTY_NP_SIGNED_IN:-1}"
# Make the NpCppWebApi async-poll stubs report "finished" so the online-services
# task stops polling forever (set to 0 to disable).
export KYTY_NP_TASK_DONE="${KYTY_NP_TASK_DONE:-1}"
# Report the host network as up so NetCtl stops saying "disconnected" (set to 0
# to disable).
export KYTY_NET_CONNECTED="${KYTY_NET_CONNECTED:-1}"

ulimit -c unlimited 2>/dev/null || true

if [ ! -f "$EMULATOR" ]; then
    echo "error: $EMULATOR not found (run build.sh first)" >&2
    exit 1
fi

if [ ! -d "$GAME" ]; then
    echo "error: game folder not found at $GAME" >&2
    exit 1
fi

HANG_WATCHDOG="${KYTY_HANG_WATCHDOG:-60}"
AUTODUMP="${KYTY_AUTODUMP:-15}"

echo "watchdog     : ${HANG_WATCHDOG}s (autodump at ${AUTODUMP}s; manual: kill -USR1 \$(pgrep -x kyty_emulator))"
echo "event trace  : KYTY_EVENT_TRACE=$KYTY_EVENT_TRACE"
echo "stdout log   : $STDOUT_LOG"
echo "LOGF log     : $LOG"
echo "guest printf : $GUEST_PRINTF_LOG"
echo ""

set +e
"$EMULATOR" --game "$GAME" --amd-cpu --game-patch "$PATCH" \
    --printf-direction File --printf-output-file "$LOG" \
    --hang-watchdog "$HANG_WATCHDOG" \
    > "$STDOUT_LOG" 2>&1 &
EMU_PID=$!

# Force a full guest-thread dump after a delay even if the loading screen keeps
# presenting frames (which suppresses the watchdog's own "no progress" dump).
( sleep "$AUTODUMP"; kill -USR1 "$EMU_PID" 2>/dev/null ) &
TIMER_PID=$!

wait "$EMU_PID"
status=$?
kill "$TIMER_PID" 2>/dev/null
set -e

# Pre-extract the two artifacts worth sharing.
WATCHDOG_LOG="_nv_watchdog.log"
EVENTS_LOG="_nv_events.log"
awk '/Kyty hang watchdog: guest thread dump/{f=1} f' "$STDOUT_LOG" > "$WATCHDOG_LOG" 2>/dev/null || true
grep -a "\[EV\]" "$STDOUT_LOG" > "$EVENTS_LOG" 2>/dev/null || true

echo ""
echo "emulator exited with status $status"
echo "share these two files:"
echo "  $WATCHDOG_LOG  ($(wc -l < "$WATCHDOG_LOG" 2>/dev/null || echo 0) lines) guest-thread dump"
echo "  $EVENTS_LOG    ($(wc -l < "$EVENTS_LOG" 2>/dev/null || echo 0) lines) event-flag trace"
echo "  (full stdout: $STDOUT_LOG)"
