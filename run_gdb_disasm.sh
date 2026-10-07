#!/bin/sh
# Inspect the async job the Database thread is stuck on in a hung kyty_emulator.
#
# Start the game with ./run_game_debug.sh, wait for the black screen (or the
# watchdog dump), then run this. Output is saved to _guest_disasm.log.
set -e

PID="$(pgrep -x kyty_emulator | head -1)"

if [ -z "$PID" ]; then
    echo "error: no running kyty_emulator process found" >&2
    echo "start the game first, wait for the hang, then run this" >&2
    exit 1
fi

OUT="_guest_disasm.log"

echo "attaching to pid $PID ..."

gdb -p "$PID" --batch \
    -ex "set pagination off" \
    -ex "set print thread-events off" \
    -ex "set disassembly-flavor intel" \
    -ex "echo \n=== Main guest wait helper (polls load event, usleep return 0x90022abec) ===\n" \
    -ex "disassemble 0x90022a800,0x90022ac00" \
    -ex "echo \n=== Main guest final loop (usleep return 0x900ff4fb7) ===\n" \
    -ex "disassemble 0x900ff4c00,0x900ff5100" \
    -ex "echo \n=== Database job-poll function (0x90067a020..0x90067a2d0) ===\n" \
    -ex "disassemble 0x90067a020,0x90067a2d0" \
    -ex "echo \n=== Database job-wait loop (usleep return 0x90067a405) ===\n" \
    -ex "disassemble 0x90067a380,0x90067a420" \
    -ex "echo \n=== Database thread (gdb thread 4) guest stack ===\n" \
    -ex "thread 4" \
    -ex "info registers rbx r12 r13 r14 r15 rbp rsp" \
    -ex "x/32gx \$rsp" \
    -ex "echo \n=== job entry: 0x907022720 + (id & 0x3ff)*0x88 ===\n" \
    -ex "set \$idx = ((unsigned int)\$ebx) & 0x3ff" \
    -ex "printf \"id(ebx)=0x%x idx=0x%x entry=0x%lx\\n\", \$ebx, \$idx, 0x907022720 + \$idx*0x88" \
    -ex "x/32wx 0x907022720+\$idx*0x88+0x14800" \
    -ex "echo \n=== referenced resource entry (stride 0x148) ===\n" \
    -ex "set \$res = *(int*)(0x907022720 + \$idx*0x88 + 0x14814)" \
    -ex "printf \"res_idx=0x%x res_entry=0x%lx\\n\", \$res, 0x907022720 + \$res*0x148" \
    -ex "x/24wx 0x907022720+\$res*0x148+0x100" \
    -ex "detach" \
    -ex "quit" 2>&1 | tee "$OUT"

echo ""
echo "saved to $OUT"
