/* bpfrun <pinned-prog-path> <data-in.bin> [hold-obj ...]
 * Runs BPF_PROG_TEST_RUN on a pinned program. Any extra paths (usually the
 * program's maps) are opened and held for the duration, so maps keep a
 * user-space reference (usercnt>0) exactly like a daemon would.
 * Prints: RETVAL <n> DURATION <ns> DATA_OUT <file> */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <linux/bpf.h>
#include <sys/syscall.h>

static int bpf(int cmd, union bpf_attr *attr) { return syscall(__NR_bpf, cmd, attr, sizeof(*attr)); }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <prog-path> <data-in> [hold-obj ...]\n", argv[0]); return 1; }

    int prog_fd = bpf(BPF_OBJ_GET, &(union bpf_attr){ .pathname = (unsigned long)argv[1] });
    if (prog_fd < 0) { perror("obj_get(prog)"); return 1; }

    int hold_fd[64]; int nhold = 0;
    for (int i = 3; i < argc && nhold < 64; i++) {
        int fd = bpf(BPF_OBJ_GET, &(union bpf_attr){ .pathname = (unsigned long)argv[i] });
        if (fd < 0) { fprintf(stderr, "warn: hold %s: %s\n", argv[i], strerror(errno)); continue; }
        hold_fd[nhold++] = fd;
    }

    static char din[65536], dout[65536], ctxin[512], ctxout[512];
    int fdin = open(argv[2], O_RDONLY);
    if (fdin < 0) { perror("open data-in"); return 1; }
    ssize_t dlen = read(fdin, din, sizeof(din));
    close(fdin);
    if (dlen <= 0) { perror("read data-in"); return 1; }

    /* optional ctx file: an argv element that is a readable file NOT under
     * /sys/fs/bpf (those are hold-objs) */
    ssize_t ctxlen = 0;
    for (int i = 3; i < argc; i++) {
        if (strncmp(argv[i], "/sys/fs/bpf", 11) == 0) continue;
        int cfd = open(argv[i], O_RDONLY);
        if (cfd < 0) continue;
        ctxlen = read(cfd, ctxin, sizeof(ctxin));
        close(cfd);
        if (ctxlen > 0) break;
        ctxlen = 0;
    }

    union bpf_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.test.prog_fd = prog_fd;
    attr.test.repeat = 1;
    attr.test.data_size_in = dlen;
    attr.test.data_in = (unsigned long)din;
    attr.test.data_out = (unsigned long)dout;
    attr.test.data_size_out = sizeof(dout);
    if (ctxlen > 0) {
        attr.test.ctx_size_in = ctxlen;
        attr.test.ctx_in = (unsigned long)ctxin;
        attr.test.ctx_size_out = sizeof(ctxout);
        attr.test.ctx_out = (unsigned long)ctxout;
    }

    int ret = bpf(BPF_PROG_TEST_RUN, &attr);
    if (ret < 0) { fprintf(stderr, "test_run: %s\n", strerror(errno)); return 1; }

    printf("RETVAL %d DURATION %u\n", attr.test.retval, attr.test.duration);
    FILE *f = fopen("/tmp/bpfrun_out.bin", "wb");
    if (f) { fwrite(dout, 1, attr.test.data_size_out, f); fclose(f); printf("DATA_OUT /tmp/bpfrun_out.bin (%u bytes)\n", attr.test.data_size_out); }
    (void)hold_fd;
    return 0;
}
