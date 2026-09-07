#!/bin/bash
# Build all artifacts of the JIT repro kit. Run on a HOST, not the device:
#   .o   objects : clang with BPF target
#   x86  tools   : gcc (static)
#   riscv64 tool : riscv64-linux-gnu-gcc (static)  [apt: gcc-riscv64-linux-gnu]
# Usage: ./build.sh [all|bpf|host|riscv|kit]
set -euo pipefail
cd "$(dirname "$0")"

BPF_SRCS="r1_b2b_tailcall.c r2_loop_b2b_tailcall.c r3_timer_loop_b2b_tailcall.c"
CLANG=${CLANG:-clang}
CC=${CC:-gcc}
RISCV_CC=${RISCV_CC:-riscv64-linux-gnu-gcc}

build_bpf() {
    for src in $BPF_SRCS; do
        "$CLANG" -O2 -g -target bpf -c "$src" -o "${src%.c}.o"
    done
}

build_host() {
    "$CC" -O2 -static -o bpffill bpffill.c
    "$CC" -O2 -static -o bpfrun bpfrun.c
}

build_riscv() {
    "$RISCV_CC" -O2 -static -o bpffill.riscv64 bpffill.c
    "$RISCV_CC" -O2 -static -o bpfrun.riscv64 bpfrun.c
    "$RISCV_CC" -O2 -static -o bpfget.riscv64 bpfget.c
}

build_kit() {
    tar -czf ../jit-repro-kit.tar.gz -C .. jit-repro-kit
    echo "kit: ../jit-repro-kit.tar.gz"
}

case "${1:-all}" in
    all)   build_bpf; build_host; build_riscv ;;
    bpf)   build_bpf ;;
    host)  build_host ;;
    riscv) build_riscv ;;
    kit)   build_kit ;;
    *) echo "usage: $0 [all|bpf|host|riscv|kit]" >&2; exit 1 ;;
esac
