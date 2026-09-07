/* R3: full nat-shaped soup — bpf_timer callback subprog (async!) + bpf_loop
 * callback + bpf2bpf + tail call, all in one program.
 *
 * Phase 1 (jmp_map empty):  expect retval 0
 * Phase 2 (jmp_map[0]=target): expect retval 42
 * 51..54 => entry-side step failures (see code);
 * 45/46  => target-side failures.
 * After phase 1, wait ~1s and dump timer_map: value "fired" should be >= 1,
 * which proves the ASYNC timer callback subprog also runs correctly under JIT. */
#include "bpf_hdr.h"

char LICENSE[] SEC("license") = "GPL";

struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u32);
} jmp_map SEC(".maps");

struct tval {
    struct bpf_timer t;
    __u64 fired;
    __u64 armed;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, __u64);
    __type(value, struct tval);
} timer_map SEC(".maps");

struct loop_ctx {
    __u32 acc;
    __u32 calls;
};

static __attribute__((noinline)) int loop_cb(__u32 i, struct loop_ctx *ctx) {
    ctx->calls++;
    ctx->acc += i + 1;
    return i == 7;
}

static __attribute__((noinline)) int subprog_a(__u32 x) { return x * 3 + 1; }

/* async callback: another non-inlined subprog in the same prog */
static int timer_cb(void *map, __u64 *key, struct tval *val) {
    val->fired++;
    bpf_timer_start(&val->t, 500000000ULL /* 500ms */, 0);
    return 0;
}

SEC("tc/egress")
int r3_entry(struct __sk_buff *skb) {
    __u64 k = 0;
    struct tval *v = bpf_map_lookup_elem(&timer_map, &k);
    if (!v) {
        struct tval zero = {0};
        if (bpf_map_update_elem(&timer_map, &k, &zero, 0)) return 58;
        v = bpf_map_lookup_elem(&timer_map, &k);
        if (!v) return 51;
    }
    if (!v->armed) {
        /* diag: 1xx=init, 14x=set_callback, 18x=start; value = -errno:
         * 101 EPERM(map usercnt=0) 112 ENOMEM 122 EINVAL 116 EBUSY 195 EOPNOTSUPP */
        long r = bpf_timer_init(&v->t, &timer_map, CLOCK_MONOTONIC);
        if (r) return 100 + (int) (-r);
        r = bpf_timer_set_callback(&v->t, timer_cb);
        if (r) return 140 + (int) (-r);
        r = bpf_timer_start(&v->t, 500000000ULL, 0);
        if (r) return 180 + (int) (-r);
        v->armed = 1;
    }
    struct loop_ctx lc = {0, 0};
    __u64 n = bpf_loop(8, (int (*)(__u32, void *))loop_cb, &lc, 0);
    __u32 x = subprog_a(7); /* 22 */
    bpf_tail_call(skb, &jmp_map, 0);
    if (n != 8) return 55;
    if (lc.calls != 8 || lc.acc != 36) return 56;
    return (x == 22) ? 0 : 57;
}

SEC("tc/egress")
int r3_egress_t(struct __sk_buff *skb) {
    struct loop_ctx lc = {0, 0};
    __u64 n = bpf_loop(4, (int (*)(__u32, void *))loop_cb, &lc, 0);
    __u32 x = subprog_a(9); /* 28 */
    if (n != 4) return 45;
    return (lc.calls == 4 && lc.acc == 10 && x == 28) ? 42 : 46;
}
