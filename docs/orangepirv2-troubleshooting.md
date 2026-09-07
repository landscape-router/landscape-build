# Orange Pi RV2 (riscv64) 踩坑记录

记录 2026-09 在 Orange Pi RV2（SpacemiT K1，riscv64，Armbian 6.18 spacemit 内核）上部署
Landscape Router 时遇到的两个内核问题（均已修复，对应 userpatch 910 / 911）。

---

## 问题一：BPF 程序加载失败 —— mixing bpf2bpf calls and tail calls

### 症状

landscape 的 `tc_nat_wan_egress` / `tc_wan_egress_intro` 等.tc 程序在 RV2 上加载失败：

```
mixing of tail_calls and bpf-to-bpf calls is not supported
```

### 根因

landscape 的数据面同时使用 bpf-to-bpf 调用和 `bpf_tail_call`。verifier 是否允许混用
由架构钩子 `bpf_jit_supports_subprog_tailcalls()` 决定，当时 riscv64 JIT 没有实现该能力
（x86 / arm64 早已支持）。主线已有完整实现：Pu Lehui 系列
*"[PATCH v6 0/7] Mixing bpf2bpf and tailcalls for RV64"*（2026-07 合入 mainline，晚于
6.18 基线，因此本地树缺失）。机制：TCC（尾调用计数器）改用非 callee-saved 寄存器 +
栈槽传递（借鉴 s390），最后添加 `bpf_jit_supports_subprog_tailcalls(){ return true; }`。

### 修复

userpatch **`910-riscv-bpf-mixing-bpf2bpf-tailcalls.patch`**
（`userpatches/kernel/archive/spacemit-6.18/`），backport 该系列的功能链三件套：

1. CFI 场景下 trampoline 栈损坏修复（前置依赖）
2. `RV_TAILCALL_OFFSET` 宏重构（前置依赖）
3. 混用支持主体

### 验证

最小复现程序 r1（bpf2bpf 子程序 + 尾调用）在设备上通过：空跳转表阶段返回 0，
填入目标后返回 42，与 x86 主机行为一致。

---

## 问题二：开启 NAT 后整机断网 —— bpf_timer_init 返回 -ENOMEM

### 症状

910 打上后程序全部加载成功，WAN 直通（不开 NAT）正常；**一旦开启 NAT，所有新流量
被丢弃**，断网。

### 排查过程

用最小复现工具包（`debug/jit-repro-kit/`，纯 BPF 程序，不含 landscape 代码）逐特性隔离：

| 程序 | 测试特性 | x86 主机 | RV2 设备 |
| --- | --- | --- | --- |
| r1 | bpf2bpf + 尾调用混用 | 0 / 42 | 0 / 42 ✓ |
| r2 | `bpf_loop` + bpf2bpf + 尾调用 | 0 / 42 | 0 / 42 ✓ |
| r3 | `bpf_timer_init/set_callback/start` | 0 / 42 | **RETVAL 112** ✗ |

r3 的返回值编码是 `100 + (-errno)`：112 = `100 + 12` → **`bpf_timer_init` 返回
`-ENOMEM`**。x86 全绿、设备只有 timer 失败 → 锁定 timers，与 JIT 无关。

### 根因链条

```
landscape nat4_insert_ct()
  └─ bpf_timer_init()                          # kernel/bpf/helpers.c
       └─ __bpf_async_init()
            └─ bpf_map_kmalloc_nolock()        # kernel/bpf/syscall.c
                 └─ kmalloc_nolock()           # mm/slub.c
                      └─ kmem_cache 无 __CMPXCHG_DOUBLE 标志 → 恒返回 NULL
```

- 6.18 起 `__bpf_async_init` 用 `kmalloc_nolock()` 在 irqsave 锁下分配 timer callback
  缓冲。该函数**要求 128-bit cmpxchg**（`CONFIG_HAVE_CMPXCHG_DOUBLE`，x86 需要 CX16，
  arm64 恒有，riscv 需要 **Zacas** 扩展），否则无条件返回 NULL。
- SpacemiT K1 的 X60 核心支持 `zaamo` 但**不支持 `zacas`**（/proc/cpuinfo 的 isa 串
  可确认）→ RV2 上 `bpf_timer_init` 必然 `-ENOMEM`。
- landscape 侧 `nat4_insert_ct` 失败 → `nat4_ct_create` 失败 → `tc_nat` 对每个新流
  SHOT（fail-closed，且 map 回滚干净、无副作用累积）→ 表现为"一开 NAT 就断网"。
- x86 / arm64 不受影响：CX16 / 恒真，走的还是 nolock 路径。

### 修复

userpatch **`911-bpf-timer-init-fallback-without-cmpxchg-double.patch`**：在
`__bpf_async_init` 中，当 `!IS_ENABLED(CONFIG_HAVE_CMPXCHG_DOUBLE) &&
!IS_ENABLED(CONFIG_PREEMPT_RT)` 时，改用 `bpf_map_kmalloc_node(map, size,
GFP_NOWAIT | __GFP_NOWARN | __GFP_NOMEMALLOC, map->numa_node)` 分配。等价于恢复
v6.12 时代的 `GFP_ATOMIC` 行为（NOWAIT 不睡眠，在 irqsave 锁下合法）。

影响面分析：

- x86 / arm64：编译期常量短路，**零变化**。
- PREEMPT_RT 且无 cmpxchg128 的组合仍保持 nolock 路径（RT 正确性优先），即此类
  环境依旧会被 6.18 上游问题卡住。
- 残余风险：真实内存压力下 NOWAIT 分配可能瞬时失败 → landscape 侧干净回滚、该流
  SHOT，不产生半成品状态。
- 上游进展：*"[PATCH bpf v3] bpf: do not use kmalloc_nolock when
  !HAVE_CMPXCHG_DOUBLE"*（Levi Zim, 2026-03）只覆盖 local storage，timers 尚未修复，
  911 是对这一空缺的本地补位；后续 rebase 时留意上游是否收编 timer 修复。

### 验证

刷入含 910 + 911 的镜像后：r3 返回 0 / 42，NAT 实测正常。

---

## 附：调试方法备忘

- **新架构先跑特性探针**：不要直接上完整业务。用最小 BPF 程序逐特性验证
  （bpf2bpf+尾调用 / bpf_loop / bpf_timer），返回值编码 `100 + (-errno)` 可以把
  具体失败点带回宿主机分析。
- **`bpf_loop` 回调语义**：回调返回 **0 = 继续，非 0 = 中断**；中断的那次迭代也计入
  返回值（x86 JIT：`test rax,rax; je loop_header`，计数先自增再判断）。
- **helper ID**：`bpf_timer_init=169`、`bpf_timer_set_callback=170`、
  `bpf_timer_start=171`（`bpf_loop=181`、`bpf_tail_call=12`）。从
  `linux/bpf.h` 的宏提取时注意宏名没有 `bpf_` 前缀。
- **prog_array 更新的隐藏约束**：`bpf_prog_map_compatible()` 要求 expected_attach_type
  匹配，SEC 命名（`tc/ingress` vs `tc/egress`）不对时 `map update` 会 EINVAL。
- **`bpftool prog dump jited`** 需要工具链支持反汇编，不支持时可用
  `BPF_OBJ_GET_INFO_BY_FD` 拿原始字节自行反汇编。
- **6.18 内核相关源码位置**：`kernel/bpf/helpers.c`（`__bpf_async_init`）、
  `mm/slub.c`（`kmalloc_nolock_noprof`）、`arch/riscv/include/asm/cmpxchg.h`
  （`system_has_cmpxchg128()` = Zacas 检测）、`arch/Kconfig`
  （`HAVE_CMPXCHG_DOUBLE` 仅 x86/arm64 select）。
