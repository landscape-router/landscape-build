/* bpffill <pinned-prog-array-path> <key-u32-decimal> <prog-id-decimal>
 * Fills a BPF_MAP_TYPE_PROG_ARRAY slot with the given prog id.
 * (bpftool `map update ... value id N` fails with EINVAL on some kernels;
 * this does the update by fd directly.) */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <linux/bpf.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdlib.h>

static int bpf(int cmd, union bpf_attr *attr) { return syscall(__NR_bpf, cmd, attr, sizeof(*attr)); }

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: %s <map-path> <key> <prog-id>\n", argv[0]); return 1; }
    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.pathname = (unsigned long)argv[1];
    int map_fd = bpf(BPF_OBJ_GET, &attr);
    if (map_fd < 0) { perror("obj_get(map)"); return 1; }

    __u32 prog_id = (__u32)strtoul(argv[3], NULL, 0);
    memset(&attr, 0, sizeof(attr));
    attr.prog_id = prog_id;
    int prog_fd = bpf(BPF_PROG_GET_FD_BY_ID, &attr);
    if (prog_fd < 0) { perror("prog_get_fd_by_id"); return 1; }

    __u32 key = (__u32)strtoul(argv[2], NULL, 0);
    __u32 val = (__u32)prog_fd;
    memset(&attr, 0, sizeof(attr));
    attr.map_fd = map_fd;
    attr.key = (unsigned long)&key;
    attr.value = (unsigned long)&val;
    attr.flags = 0;
    if (bpf(BPF_MAP_UPDATE_ELEM, &attr) < 0) { perror("map_update"); return 1; }
    printf("jmp_map[%u] = prog id %u (fd %d)\n", key, prog_id, prog_fd);
    return 0;
}
