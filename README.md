# Landscape Build

Landscape Build is a customized image packaging solution based on the Armbian build system, specifically designed for deploying [Landscape Router](https://github.com/ThisSeanZhang/landscape).

[中文说明](./README.zh.md)

## 🔗 Links

- **Main Project**: [ThisSeanZhang/landscape](https://github.com/ThisSeanZhang/landscape)
- **Official Documentation**: [landscape.whileaway.dev](https://landscape.whileaway.dev)

## 📖 Introduction

This project wraps and customizes the Armbian build system to achieve:
- **Customized Kernel**: Pre-integrated with core features for network acceleration and monitoring such as eBPF and BTF.
- **Auto Deployment**: Automatically downloads and installs Landscape Router and its static resources during the image building phase.
- **Multi-platform Support**: Supports x86 (UEFI), Orange Pi RV2 (riscv64), MangoPi M28K, NanoPi R5C, and more.
- **Out-of-the-box**: Built-in services start automatically, and native network management is disabled to avoid conflicts.

## 🧩 Supported Boards

| Board ID | Board | Architecture | Kernel Branch | Notes |
| --- | --- | --- | --- | --- |
| `uefi-x86` | Generic UEFI x86_64 | x86_64 | current | Image is also converted to `.vmdk` for VMs |
| `mangopi-m28k` | MangoPi M28K | arm64 | vendor | |
| `nanopi-r5c` | NanoPi R5C | arm64 | current | |
| `nanopi-r2s` | NanoPi R2S | arm64 | current | |
| `orangepirv2` | Orange Pi RV2 (SpacemiT K1) | **riscv64** | current | Default: `eth0` = WAN, `eth1` bridged into `br_lan` = LAN |

> The Orange Pi RV2 build requires Armbian ≥ `v26.5.1` (the first release carrying `orangepirv2` support, pinned in `build.env`). Since Docker's official apt repository does not ship riscv64 packages, riscv64 images install `docker.io` from the Debian repository instead.

## 🚀 How to Use

### 1. Local Build

In a Linux environment (Ubuntu 22.04+ recommended), you can run the script directly to start building.

```bash
# Grant execution permissions
chmod +x build.sh

# Run the build script (supports interactive selection)
./build.sh

# Or specify a board ID directly (e.g., build x86 version)
./build.sh uefi-x86
```

Generated image artifacts will be saved in the `armbian/output/images/` directory.

### 2. GitHub Actions Auto Build

The project is integrated with GitHub CI, so you don't need a heavy build environment locally:
1. Go to the **Actions** tab on your GitHub repository page.
2. Select the **Build x86 Image** workflow.
3. Click **Run workflow** and enter the target board ID (default is `uefi-x86`).
4. Once completed, download the packaged image from the **Artifacts** section at the bottom of the workflow details page.

---

## 🛠 Image Customization

If you need to make your own modifications, check these directories:
- `userpatches/customize-image.sh`: Initialization script executed before the first run of the image.
- `userpatches/overlay/`: Static resources and configuration files automatically copied into the image system during build. Board-specific network initialization uses the `landscape_init-<board>.toml` naming convention.
- `userpatches/config/kernel/`: Kernel config overrides, read by Armbian as `linux-<family>-<branch>.config` (e.g. `linux-spacemit-current.config` for the Orange Pi RV2).
- `userpatches/kernel/`: Kernel patches, applied on top of the Armbian patch series (e.g. `archive/spacemit-6.18/` backports the mainline riscv BPF JIT fix that allows `bpf_tail_call` in programs using bpf-to-bpf calls, required by the Landscape eBPF datapath on the Orange Pi RV2).
- `build.env`: Configures Armbian version, Landscape version, and whether to enable the interactive kernel configuration menu.
