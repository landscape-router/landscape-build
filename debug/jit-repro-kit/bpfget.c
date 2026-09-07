/* bpfget <pinned-prog-path> [out.bin]
 * Dumps the JITed machine code of a pinned BPF program as raw bytes
 * (via BPF_OBJ_GET_INFO_BY_FD), for offline disassembly on the host, e.g.:
 *   riscv64-linux-gnu-objdump -D -b binary -m riscv:rv64 prog.bin */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <linux/bpf.h>
#include <sys/syscall.h>
#include <unistd.h>

static int bpf(int cmd, union bpf_attr *attr) { return syscall(__NR_bpf, cmd, attr, sizeof(*attr)); }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <prog-path> [out.bin]\n", argv[0]); return 1; }

    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.pathname = (unsigned long)argv[1];
    int prog_fd = bpf(BPF_OBJ_GET, &attr);
    if (prog_fd < 0) { perror("obj_get(prog)"); return 1; }

    struct bpf_prog_info info = {};
    memset(&attr, 0, sizeof(attr));
    attr.info.bpf_fd = prog_fd;
    attr.info.info_len = sizeof(info);
    attr.info.info = (unsigned long)&info;
    if (bpf(BPF_OBJ_GET_INFO_BY_FD, &attr) < 0) { perror("get_info(len)"); return 1; }
    __u32 jited_len = info.jited_prog_len;
    if (jited_len == 0) { fprintf(stderr, "prog id %u: no jited image (JIT disabled?)\n", info.id); return 1; }

    char *buf = malloc(jited_len);
    if (!buf) { perror("malloc"); return 1; }
    info.jited_prog_insns = (unsigned long)buf;
    if (bpf(BPF_OBJ_GET_INFO_BY_FD, &attr) < 0) { perror("get_info(jited)"); return 1; }
    jited_len = info.jited_prog_len;

    fprintf(stderr, "prog id %u: %u bytes of jited code\n", info.id, jited_len);
    if (argc > 2) {
        FILE *f = fopen(argv[2], "wb");
        if (!f) { perror("fopen"); return 1; }
        fwrite(buf, 1, jited_len, f);
        fclose(f);
    } else {
        fwrite(buf, 1, jited_len, stdout);
    }
    return 0;
}
