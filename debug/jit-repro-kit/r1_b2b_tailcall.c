/* R1: bpf2bpf call + tail call (the basic mixing shape).
 * Phase 1 (jmp_map empty):  expect retval 0
 * Phase 2 (jmp_map[0]=target): expect retval 42   <-- the mixing case:
 *         entry does b2b calls, then tail-calls into a prog that does b2b too.
 * Any other retval (or hang/crash) = JIT mixing bug. */
#include "bpf_hdr.h"

char LICENSE[] SEC("license") = "GPL";

struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u32);
} jmp_map SEC(".maps");

static __attribute__((noinline)) int subprog_a(__u32 x) { return x * 3 + 1; }

static __attribute__((noinline)) int subprog_b(__u32 x) { return x ^ 0x5a; }

SEC("tc/egress")
int r1_entry(struct __sk_buff *skb) {
    __u32 v = subprog_a(7) + subprog_b(3); /* 22 + 89 = 111 */
    bpf_tail_call(skb, &jmp_map, 0);
    return (v == 111) ? 0 : 21;
}

SEC("tc/egress")
int r1_egress_t(struct __sk_buff *skb) {
    __u32 v = subprog_a(9); /* 28 */
    return (v == 28) ? 42 : 43;
}
