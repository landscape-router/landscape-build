/* Self-contained BPF program header — no vmlinux.h / bpf_helpers.h needed.
 * Only the pieces the repro programs touch are declared. */
#ifndef __BPF_HDR_H
#define __BPF_HDR_H

#define SEC(NAME) __attribute__((section(NAME), used))

typedef signed char __s8;
typedef unsigned char __u8;
typedef short __s16;
typedef unsigned short __u16;
typedef int __s32;
typedef unsigned int __u32;
typedef long long __s64;
typedef unsigned long long __u64;
typedef __u16 __be16;
typedef __u32 __be32;

/* opaque context: programs never dereference skb */
struct __sk_buff { __u32 _opaque; };

/* helper function pointers (uapi linux/bpf.h IDs) */
static void *(*bpf_map_lookup_elem)(const void *map, const void *key) = (void *)1;
static long (*bpf_map_update_elem)(const void *map, const void *key, const void *value,
                                   __u64 flags) = (void *)2;
static long (*bpf_tail_call)(void *ctx, const void *map, __u32 index) = (void *)12;
static long (*bpf_get_prandom_u32)(void) = (void *)7;
static long (*bpf_loop)(__u32 nr_loops, int (*callback)(__u32 index, void *ctx), void *ctx,
                        __u64 flags) = (void *)181;
/* NOTE: on stop (cb returns 0) bpf_loop returns the count EXCLUDING the
 * stopping iteration; full completion returns nr_loops. */
static long (*bpf_timer_init)(void *timer, void *map, __u64 flags) = (void *)169;
static long (*bpf_timer_set_callback)(void *timer, void *callback_fn) = (void *)170;
static long (*bpf_timer_start)(void *timer, __u64 nsecs, __u64 flags) = (void *)171;

/* map definition macros (same convention as bpf_helpers.h) */
#define __uint(name, val) int (*name)[val]
#define __type(name, val) typeof(val) *name

/* linux/bpf.h map types */
#define BPF_MAP_TYPE_HASH 1
#define BPF_MAP_TYPE_ARRAY 2
#define BPF_MAP_TYPE_PROG_ARRAY 3

#define CLOCK_MONOTONIC 1

struct bpf_timer {
    __u64 __opaque[2];
};

#endif
