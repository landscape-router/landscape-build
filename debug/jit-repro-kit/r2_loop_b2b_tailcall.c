/* R2: bpf_loop (non-inline callback = PSEUDO call) + bpf2bpf + tail call.
 * This is the shape nat4_alloc_port() uses — the prime suspect.
 * Phase 1 (jmp_map empty):  expect retval 0
 * Phase 2 (jmp_map[0]=target): expect retval 42
 * (bpf_loop does not count the stopping iteration => entry n=7, target n=3.)
 * 21/45 => n wrong; 22/46 => calls|acc wrong; 24 => b2b wrong. */
#include "bpf_hdr.h"

char LICENSE[] SEC("license") = "GPL";

struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u32);
} jmp_map SEC(".maps");

struct loop_ctx {
    __u32 acc;
    __u32 calls;
};

static __attribute__((noinline)) int loop_cb(__u32 i, struct loop_ctx *ctx) {
    ctx->calls++;
    ctx->acc += i + 1;
    return i == 7; /* 0=continue, nonzero=break => 8 iterations: acc = 36, calls = 8 */
}

static __attribute__((noinline)) int subprog_a(__u32 x) { return x * 3 + 1; }

SEC("tc/egress")
int r2_entry(struct __sk_buff *skb) {
    struct loop_ctx ctx = {0, 0};
    __u64 n = bpf_loop(8, (int (*)(__u32, void *))loop_cb, &ctx, 0);
    __u32 v = subprog_a(7); /* 22 */
    bpf_tail_call(skb, &jmp_map, 0);
    if (ctx.calls != 8) return 70 + ctx.calls;
    if (ctx.acc != 36) return 23;
    if (n != 8) return 100 + (int) n;
    return (v == 22) ? 0 : 24;
}

SEC("tc/egress")
int r2_egress_t(struct __sk_buff *skb) {
    struct loop_ctx ctx = {0, 0};
    __u64 n = bpf_loop(4, (int (*)(__u32, void *))loop_cb, &ctx, 0); /* acc = 10, calls = 4 */
    __u32 v = subprog_a(9);                  /* 28 */
    if (n != 4) return 45;
    return (ctx.calls == 4 && ctx.acc == 10 && v == 28) ? 42 : 46;
}
