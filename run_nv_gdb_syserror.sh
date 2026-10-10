#!/bin/sh
set -e

# Call of Duty: Vanguard - capture the Sys_Error/Com_Error message.
#
# The game reaches the loading screen and hits Sys_Error, which pauses its edit
# backend and parks the main thread.  The message is formatted in 0x900ff4fd0
# and printed as "Sys_Error: %s\n"; at 0x900ff50ba rbx points at the finished
# string.
#
# Guest memory is only mapped once the emulator has started, so we launch the
# game first, wait a few seconds, then attach gdb and set the breakpoint.
#
# Uses your normal desktop GPU/display.  Output: _nv_syserror.log.

GAME="/mnt/nas/Games/emulators/ps5/Call of Duty Vanguard/PPSA01687-app"
EMULATOR="_Build/linux/kyty_emulator"
PATCH="_Patches/PPSA01687.json"
OUT="_nv_syserror.log"
STDOUT_LOG="_nv_syserror_stdout.log"
GDB_CMD="/tmp/opencode/syserror.gdb"

ATTACH_DELAY="${KYTY_ATTACH_DELAY:-10}"
CAPTURE_SECS="${KYTY_CAPTURE_SECS:-90}"

export KYTY_ALLOW_MISSING_BARYCENTRIC="${KYTY_ALLOW_MISSING_BARYCENTRIC:-1}"
export KYTY_WATCHDOG_HEARTBEAT=1
export KYTY_GUEST_PRINTF_FILE="_nv_guest_printf.log"

ulimit -c unlimited 2>/dev/null || true

mkdir -p /tmp/opencode
cat > "$GDB_CMD" <<'EOF'
set pagination off
set confirm off
handle SIGPIPE nostop noprint pass
handle SIGSEGV nostop noprint pass
handle SIGBUS nostop noprint pass
handle SIGILL nostop noprint pass
break *0x900ff50ba
commands
 silent
 printf "\n==== Sys_Error message: %s\n", (char*)$rbx
 printf "     r14(format)=%#lx rsi=%#lx\n", $r14, $rsi
 bt 8
 continue
end
continue
EOF

echo "starting game (window should appear) ..."
"$EMULATOR" --game "$GAME" --amd-cpu --game-patch "$PATCH" --hang-watchdog 0 \
    > "$STDOUT_LOG" 2>&1 &
EMU_PID=$!

echo "waiting ${ATTACH_DELAY}s, then attaching gdb ..."
sleep "$ATTACH_DELAY"

timeout "$CAPTURE_SECS" gdb -p "$EMU_PID" --batch -x "$GDB_CMD" > "$OUT" 2>&1 || true

kill -9 "$EMU_PID" 2>/dev/null || true
wait "$EMU_PID" 2>/dev/null || true

echo ""
echo "Sys_Error captures:"
grep -a -A20 "Sys_Error message" "$OUT" 2>/dev/null | head -100 || true
echo ""
echo "full gdb output : $OUT"
echo "emulator stdout : $STDOUT_LOG"
