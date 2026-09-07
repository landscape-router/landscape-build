# riscv64 BPF JIT "bpf2bpf + tail call 混用" 最小复现梯子

背景：RV2 (SpacemiT K1) 内核 6.18 打了主线 backport
`userpatches/kernel/archive/spacemit-6.18/910-riscv-bpf-mixing-bpf2bpf-and-tailcalls.patch`
之后，landscape 的 tc_nat_wan_egress 在 `prog run` 中对合法 LAN→WAN SYN 返回
TC_ACT_SHOT(2)，而正确行为是完成 SNAT 改写并返回 TC_ACT_UNSPEC(-1)。
本梯子绕开 landscape 语义，直接质询 backport 的 JIT 正确性。

x86-64 对照组（本目录在 Debian 6.12 主机上）已全部通过：r1/r2/r3 均 0/42，r3 异步 timer fired≥1。

## 文件
| 文件 | 说明 |
|---|---|
| `bpf_hdr.h` | 自包含 BPF 头（无 vmlinux.h/libbpf 依赖；helper id: tail_call=12, loop=181, timer=169/170/171） |
| `r1_b2b_tailcall.c` | b2b 调用 + 尾调用（基本混用） |
| `r2_loop_b2b_tailcall.c` | bpf_loop 回调 + b2b + 尾调用（= nat4_alloc_port 同款结构） |
| `r3_timer_loop_b2b_tailcall.c` | bpf_timer 回调 + loop + b2b + 尾调用（= tc_nat 完整形态） |
| `run_jit_tests.sh` | 设备端一键运行 |
| `bpffill.c` | 用 fd 填 prog_array（bpftool `value id` 会 EINVAL） |
| `bpfrun.c` | `BPF_PROG_TEST_RUN` 执行器（持有 map fd 保证 usercnt>0，ctx 文件可选） |
| `bpfget.c` | dump 某 pinned prog 的 jited 原始字节（供 host 反汇编取证） |

以上 `.c` 的编译产物（`*.o`、`bpffill`、`bpfrun`、`*.riscv64`）不入库。

## 编译（主机上）

```bash
# 工具链: clang（需带 BPF target）、gcc、riscv64-linux-gnu-gcc
# Debian/Ubuntu: apt install clang gcc gcc-riscv64-linux-gnu
./build.sh all    # 生成全部 *.o 与工具二进制
./build.sh kit    # 打包 ../jit-repro-kit.tar.gz（含编译产物，scp 上设备）
```

## 设备端运行（root）
```bash
# kit scp 到设备后:
chmod +x run_jit_tests.sh bpffill.riscv64 bpfget.riscv64
ln -sf bpffill.riscv64 bpffill        # 脚本调用 ./bpffill
sudo ./run_jit_tests.sh               # 或 ./run_jit_tests.sh r2 只跑单个
```

## 判读
| 测试 | phase1 (空 jmp_map) | phase2 (jmp_map[0]=target) | 附检 |
|---|---|---|---|
| r1 | 0 | 42 | — |
| r2 | 0 | 42 | — |
| r3 | 0 | 42 | sleep 1s 后 `timer_map.fired ≥ 1` |

- 加载失败 = verifier/JIT 拒绝（把 `/tmp/jit_kit_load.err` 发回来）。
- 返回值编码失败点：r1: 21=b2b 结果错 / 43=target 侧错；r2: 7x=回调执行次数、23=acc、1xx=n、45/46=target 侧；r3: 51-58=timer 各步、55/56=loop、45/46=target 侧。
- r2 或 r3 出错而 r1 正常 ⇒ 混用 JIT 在 bpf_loop/timer 回调（PSEUDO 调用）路径上损坏，与 nat 症状直接对应。
- 全部 0/42 ⇒ backport 对这些形态正确，嫌疑转向 landscape 语义（用下面的侧效定位继续）。

## landscape nat 侧效定位（区分 SHOT 出口）
```bash
bpftool prog show | grep tc_nat_wan_egress          # 记下 id
bpftool map show | grep -E "nat4_egress_dyn_map|nat4_ingress_dyn_map|nat4_timer_map|nat4_tcp_port_queue"
# 记下上面 4 个 id，然后:
bpftool map dump id <egress_dyn> | grep -c key      # 基线计数
bpftool map dump id <timer_map>  | grep -c key
bpftool map dump id <tcp_queue>  | grep -c key
bpftool prog run id <nat-id> data_in /tmp/pkt.bin ctx_in /tmp/ctx.bin data_out /tmp/out.bin repeat 1
od -A d -t x1 /tmp/out.bin | sed -n '2,3p'          # 偏移 26-29 源IP(0a 01 01 ba=10.1.1.186), 34-35 源端口
bpftool map dump id <egress_dyn> | grep -c key      # 重计
```
| 现象 | 结论 |
|---|---|
| egress_dyn +1、timer_map +1、queue −1、仍 2 | alloc/insert/CT 全对，死在 modify_headers 之后（若 out.bin 已改写=改写成功但最终 return/链尾坏 → 指向 backport TCC 核心） |
| 全部不变 | nat4_alloc_port（bpf_loop 区）失败 → 与 kit r2 对应 |
| egress_dyn+1 但 timer 不变 | nat4_ct_create（bpf_timer 区）失败 → 与 kit r3 对应 |
| -1 且 out.bin 已改写为 10.1.1.186 | NAT 实际是好的，问题在别处（回到链/lifecycle） |

注：ctx 里 ifindex=0 → SHOT(2) 是**正确行为**（wan_ip_binding[0] 不存在，tc_nat4.h:123），
不能当 JIT 证据。
