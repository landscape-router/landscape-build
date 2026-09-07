# Landscape Build

Landscape Build 是基于 Armbian 构建系统定制的镜像打包方案，专门用于部署 [Landscape Router](https://github.com/ThisSeanZhang/landscape)。

## 🔗 相关链接

- **项目本体**: [ThisSeanZhang/landscape](https://github.com/ThisSeanZhang/landscape)
- **官方文档**: [landscape.whileaway.dev](https://landscape.whileaway.dev)

## 📖 项目简介

本项目通过对 Armbian 构建系统的二次封装和定制，实现了：
- **定制化内核**: 预集成了 eBPF、BTF 等网络加速与监控所需的核心功能。
- **自动部署**: 在镜像构建阶段自动下载并安装 Landscape Router 及其静态资源。
- **多平台支持**: 支持 x86 (UEFI)、Orange Pi RV2 (riscv64)、MangoPi M28K、NanoPi R5C 等多种硬件。
- **开箱即用**: 内置服务自动启动，并禁用了原生网络管理以避免冲突。

## 🧩 支持的板子

| 板子 ID | 板子 | 架构 | 内核分支 | 备注 |
| --- | --- | --- | --- | --- |
| `uefi-x86` | 通用 UEFI x86_64 | x86_64 | current | 镜像会额外转换为 `.vmdk` 用于虚拟机 |
| `mangopi-m28k` | MangoPi M28K | arm64 | vendor | |
| `nanopi-r5c` | NanoPi R5C | arm64 | current | |
| `nanopi-r2s` | NanoPi R2S | arm64 | current | |
| `orangepirv2` | Orange Pi RV2 (SpacemiT K1) | **riscv64** | current | 默认 `eth0` = WAN，`eth1` 桥接入 `br_lan` = LAN |

> Orange Pi RV2 需要 Armbian ≥ `v26.5.1`（首个包含 `orangepirv2` 支持的版本，已在 `build.env` 中固定）。由于 Docker 官方 apt 源不提供 riscv64 包，riscv64 镜像改用 Debian 官方源的 `docker.io`。

## 🚀 如何使用

### 1. 本地构建

在 Linux 环境下（推荐 Ubuntu 22.04+），你可以直接运行脚本开始构建。

```bash
# 赋予执行权限
chmod +x build.sh

# 运行构建脚本（支持交互式选择）
./build.sh

# 或者直接指定板子 ID（例如构建 x86 版本）
./build.sh uefi-x86
```

生成的镜像产物将保存在 `armbian/output/images/` 目录下。

### 2. GitHub Actions 自动构建

项目已集成 GitHub CI，你无需在本地搭建繁重的编译环境：
1. 在 GitHub 仓库页面点击 **Actions**。
2. 选择 **Build x86 Image** 工作流。
3. 点击 **Run workflow**，输入目标板子 ID（默认 `uefi-x86`）。
4. 构建完成后，在 Workflow 详情页面底部的 **Artifacts** 处下载打包好的镜像。

---

## 🛠 镜像定制

如果你需要添加自己的修改，可以关注以下目录：
- `userpatches/customize-image.sh`: 镜像初次运行前执行的初始化脚本。
- `userpatches/overlay/`: 构建时会自动复制到镜像系统中的静态资源和配置文件。板级网络初始化配置遵循 `landscape_init-<board>.toml` 命名。
- `userpatches/config/kernel/`: 内核配置覆盖目录，Armbian 按 `linux-<family>-<branch>.config` 命名读取（例如 Orange Pi RV2 对应 `linux-spacemit-current.config`）。
- `userpatches/kernel/`: 内核补丁目录，应用在 Armbian 官方补丁系列之上（例如 `archive/spacemit-6.18/` backport 了主线 riscv BPF JIT 的"bpf2bpf 调用与尾调用混用"支持，Landscape 的 eBPF 数据面在 Orange Pi RV2 上依赖该特性）。
- `build.env`: 配置 Armbian 版本、Landscape 版本以及是否开启内核配置菜单。
