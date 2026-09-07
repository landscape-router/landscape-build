#!/bin/bash
# 最小 JIT 混用复现梯子 — 在 RV2 设备上以 root 运行。
# 用法: ./run_jit_tests.sh [r1|r2|r3]     (默认依次跑 r1 r2 r3)
#
# 判读:
#   r1: 阶段1=0 阶段2=42         => bpf2bpf+尾调用 基本混用 OK
#   r2: 阶段1=0 阶段2=42         => bpf_loop 回调 + b2b + 尾调用 OK (nat4_alloc_port 同款结构)
#   r3: 阶段1=0 阶段2=42 且 timer_map.fired>=1
#                                => bpf_timer 回调 + loop + b2b + 尾调用 全链 OK
#   任何非预期返回值/加载失败 = 对应环节的 JIT/verifier 问题;
#   返回值编码了失败点(见各 .c 头注释)。
set -u

BPFTOOL=bpftool
PIN=/sys/fs/bpf/jit_repro_kit
MAPS=$PIN/maps
TESTS=${@:-r1 r2 r3}
HERE=$(cd "$(dirname "$0")" && pwd)

$BPFTOOL version >/dev/null 2>&1 || { echo "need bpftool"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

head -c 64 /dev/zero > /tmp/jit_kit_data.bin

# bpfrun（若可用）: test_run 期间持有所有 map fd（usercnt>0，等价于 landscape 常驻持有）,
# 避免 bpf_timer_init 因 EPERM 失败; 否则回退 bpftool prog run。
if [ -x "$HERE/bpfrun.riscv64" ] && [ "$(uname -m)" = riscv64 ]; then RUNNER="$HERE/bpfrun.riscv64"
elif [ -x "$HERE/bpfrun" ]; then RUNNER="$HERE/bpfrun"
else RUNNER=""; fi

run_entry() { # $1 = pinned entry path
    if [ -n "$RUNNER" ]; then
        local HOLD=""
        for m in "$MAPS"/*; do [ -e "$m" ] && HOLD="$HOLD $m"; done
        # shellcheck disable=SC2086
        $RUNNER "$1" /tmp/jit_kit_data.bin $HOLD
    else
        $BPFTOOL prog run pinned "$1" data_in /tmp/jit_kit_data.bin repeat 5 2>&1
    fi
}

target_id() { # $1 = pinned target path
    $BPFTOOL prog show pinned "$1" | head -1 | awk '{print $1}' | tr -d ':'
}

for t in $TESTS; do
    case $t in
        r1) OBJ=$HERE/r1_b2b_tailcall.o ;;
        r2) OBJ=$HERE/r2_loop_b2b_tailcall.o ;;
        r3) OBJ=$HERE/r3_timer_loop_b2b_tailcall.o ;;
        *) echo "unknown test $t"; continue ;;
    esac

    echo "================ $t ================"
    rm -rf $PIN 2>/dev/null
    if ! $BPFTOOL prog loadall "$OBJ" $PIN pinmaps $MAPS 2> /tmp/jit_kit_load.err; then
        echo "LOAD FAILED (verifier/JIT):"; cat /tmp/jit_kit_load.err; continue
    fi

    echo "-- phase 1 (jmp_map empty, expect retval 0) --"
    run_entry $PIN/${t}_entry

    TID=$(target_id $PIN/${t}_egress_t)
    echo "-- phase 2 (jmp_map[0] -> $TID, expect retval 42; the real mixing case) --"
    if [ "$(uname -m)" = riscv64 ] && [ -x "$HERE/bpffill.riscv64" ]; then FILL="$HERE/bpffill.riscv64"; else FILL="$HERE/bpffill"; fi
    if [ -x "$FILL" ]; then
        $FILL $MAPS/jmp_map 0 "$TID" || { echo "map update failed"; continue; }
    else
        $BPFTOOL map update pinned $MAPS/jmp_map key 0 0 0 0 value id "$TID" || { echo "map update failed (no bpffill)"; continue; }
    fi
    run_entry $PIN/${t}_entry

    if [ "$t" = r3 ]; then
        echo "-- r3 async check: sleep 1s 后 timer_cb 应已自触发, fired>=1 --"
        sleep 1
        $BPFTOOL map dump pinned $MAPS/timer_map
    fi

    rm -rf $PIN
done
echo "done"
