#!/bin/bash
set -e
export COLUMNS=${COLUMNS:-160}

# =============================================================================
# Configuration & Prep
# =============================================================================

# Load environment configuration
if [ -f "build.env" ]; then
    source build.env
else
    # Default fallback if file is missing (optional)
    LANDSCAPE_VERSION="latest"
    LANDSCAPE_REPO="https://github.com/ThisSeanZhang/landscape"
    ENABLE_KERNEL_CONFIGURE="no"
    ARMBIAN_REPO="https://github.com/armbian/build.git"
    ARMBIAN_VERSION="v26.5.1"
    echo "Warning: build.env not found, using defaults."
fi

ARMBIAN_DIR="armbian"

# Ensure Armbian build system exists
# Check for compile.sh instead of just the directory to handle empty symlinks in CI
if [ ! -f "$ARMBIAN_DIR/compile.sh" ]; then
    echo "============================================================"
    echo "Armbian build system not found or incomplete. Cloning $ARMBIAN_VERSION..."
    echo "============================================================"
    # If it's a symlink to an empty dir, we might need to clone into it
    # Git clone usually requires the directory to be empty
    git clone --branch "$ARMBIAN_VERSION" "$ARMBIAN_REPO" "$ARMBIAN_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to clone Armbian repository."
        exit 1
    fi
fi

# Determine Download Base URL based on version
if [ "$LANDSCAPE_VERSION" == "latest" ]; then
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/latest/download"
else
    DOWNLOAD_BASE="${LANDSCAPE_REPO}/releases/download/${LANDSCAPE_VERSION}"
fi

echo "Using Landscape Version: $LANDSCAPE_VERSION"
echo "Download Source: $DOWNLOAD_BASE"
echo "Kernel Configure Mode: $ENABLE_KERNEL_CONFIGURE"

# Define resources to download
# Format: "URL|FILENAME"
RESOURCES=(
    "${DOWNLOAD_BASE}/landscape-webserver-x86_64|landscape-webserver-x86_64"
    "${DOWNLOAD_BASE}/landscape-webserver-aarch64|landscape-webserver-aarch64"
    "${DOWNLOAD_BASE}/landscape-webserver-riscv64|landscape-webserver-riscv64"
    "${DOWNLOAD_BASE}/static.zip|static.zip"
)

USERPATCHES_DIR="userpatches"
OVERLAY_DIR="${USERPATCHES_DIR}/overlay"
# 注意：Armbian 读取用户内核配置的路径是 userpatches/config/kernel/linux-<family>-<branch>.config
# （lib/functions/compilation/kernel-config.sh 中的 prepare_kernel_config_core_or_userpatches）
KERNEL_CONFIG_DIR="${USERPATCHES_DIR}/config/kernel"

# Ensure directories exist
mkdir -p "$OVERLAY_DIR"
mkdir -p "$KERNEL_CONFIG_DIR"

# Function to download resources if missing
prepare_resources() {
    echo "Checking resources..."
    for resource in "${RESOURCES[@]}"; do
        url="${resource%%|*}"
        filename="${resource##*|}"
        filepath="${OVERLAY_DIR}/${filename}"

        if [ -f "$filepath" ]; then
            echo "  [OK] $filename exists."
        else
            echo "  [DOWNLOADING] $filename..."
            curl -L -o "$filepath" "$url"
            if [ $? -ne 0 ]; then
                echo "  [ERROR] Failed to download $filename"
                exit 1
            fi
        fi
    done
}

# Function to sync userpatches to armbian directory
sync_userpatches() {
    echo "Syncing userpatches to ${ARMBIAN_DIR}/userpatches..."
    # Use rsync to mirror the directory. 
    # --delete ensures that if you remove a patch from your source, it's removed from build dir too.
    # Exclude .git just in case
    rsync -av --delete --exclude '.git' "${USERPATCHES_DIR}/" "${ARMBIAN_DIR}/userpatches/"
}

# Run prep steps
prepare_resources

# Create a build_vars.sh to pass variables to customize-image.sh
echo "ENABLE_MIRROR=\"$ENABLE_MIRROR\"" > "${OVERLAY_DIR}/build_vars.sh"

sync_userpatches

# =============================================================================
# Build Logic
# =============================================================================

cd "$ARMBIAN_DIR"

# 定义不同板子的编译参数
declare -A BOARD_CONFIGS=(
    # 格式: ["BOARD_NAME"]="BRANCH BUILD_DESKTOP BUILD_MINIMAL ..."
    ["uefi-x86"]="current no yes"
    ["mangopi-m28k"]="vendor no yes"
    ["nanopi-r5c"]="current no yes"
    ["nanopi-r2s"]="current no yes"
    ["orangepirv2"]="current no yes"    # Orange Pi RV2 (SpacemiT K1, riscv64)
    # 可以继续添加其他板子
)

# 获取用户选择的板子
if [ -n "$1" ]; then
    SELECTED_BOARD="$1"
    if [[ -z "${BOARD_CONFIGS[$SELECTED_BOARD]}" ]]; then
        echo "错误：指定的板子 '$SELECTED_BOARD' 不存在！"
        exit 1
    fi
else
    # 提取所有 BOARD 名字，用于用户选择 (保持原来的逻辑，但仅在无参数时执行)
    BOARDS=("${!BOARD_CONFIGS[@]}")
    # 显示选项菜单
    echo "请选择要编译的板子："
    for i in "${!BOARDS[@]}"; do
        echo "$((i+1))) ${BOARDS[$i]}"
    done

    # 读取用户输入
    read -p "输入编号 (1-${#BOARDS[@]}): " choice

    # 检查用户输入是否有效
    if [[ "$choice" -lt 1 || "$choice" -gt "${#BOARDS[@]}" ]]; then
        echo "错误：无效的选择！"
        exit 1
    fi

    # 获取用户选择的板子
    SELECTED_BOARD="${BOARDS[$((choice-1))]}"
fi

# 提取对应的参数
IFS=' ' read -r BRANCH BUILD_DESKTOP BUILD_MINIMAL <<< "${BOARD_CONFIGS[$SELECTED_BOARD]}"

echo "你选择了: $SELECTED_BOARD"
echo "参数: BRANCH=$BRANCH, BUILD_DESKTOP=$BUILD_DESKTOP, BUILD_MINIMAL=$BUILD_MINIMAL"

# 执行编译
# KERNEL_CONFIGURE 由 build.env 控制
# 如果你需要重新配置内核，在 build.env 中将 ENABLE_KERNEL_CONFIGURE 设为 yes
# BUILD_CPUTHREADS 为可选的编译并行度限制（内存小的机器建议降低，默认 -j(CPU*1.5)）
EXTRA_ARGS=()
if [ -n "${BUILD_CPUTHREADS:-}" ]; then
    echo "Limiting kernel build threads to: -j$BUILD_CPUTHREADS"
    EXTRA_ARGS+=("CPUTHREADS=$BUILD_CPUTHREADS")
fi
# 不安装内核头文件：appliance 镜像用不到。但部分 Armbian 版本该参数不生效，
# headers 包的 postinst 需要 rootfs 里有 python3/libelf-dev/zlib 才能编译
# resolve_btfids（BUILD_MINIMAL 下没有，会导致构建失败），故同时注入这些包兜底。
./compile.sh \
    build BOARD="$SELECTED_BOARD" \
    BRANCH="$BRANCH" \
    BUILD_DESKTOP="$BUILD_DESKTOP" \
    BUILD_MINIMAL="$BUILD_MINIMAL" \
    KERNEL_CONFIGURE="$ENABLE_KERNEL_CONFIGURE" \
    RELEASE=trixie \
    KERNEL_GIT=shallow \
    NETWORKING_STACK="none" \
    INSTALL_HEADERS="no" \
    EXTRA_PACKAGES_ROOTFS="python3 libelf-dev zlib1g-dev" \
    EXTRA_PACKAGES_ROOTFS_REFS="build:build.sh:0 build:build.sh:0 build:build.sh:0" \
    "${EXTRA_ARGS[@]}"

# Post-build logic: Sync kernel config back if configure mode was enabled
if [ "$ENABLE_KERNEL_CONFIGURE" == "yes" ]; then
    echo "============================================================"
    echo "Kernel Configure Mode Enabled: Syncing configs back..."
    echo "============================================================"
    
    if [ -d "output/config" ]; then
        cp -u -v output/config/linux-*.config "../$KERNEL_CONFIG_DIR/" 2>/dev/null
        if [ $? -eq 0 ]; then
             echo "✅ Successfully synced kernel configs to userpatches/kernel/"
        else
             echo "⚠️  No matching config files found to sync."
        fi
    fi
fi

# Convert to VMDK for uefi-x86
if [ "$SELECTED_BOARD" == "uefi-x86" ]; then
    echo "============================================================"
    echo "Converting uefi-x86 image to VMDK..."
    echo "============================================================"
    
    # Find the latest .img file for uefi-x86 (case-insensitive)
    LATEST_IMG=$(ls -t output/images/*.img 2>/dev/null | grep -i "uefi-x86" | head -n 1)
    
    if [ -n "$LATEST_IMG" ]; then
        VMDK_OUT="${LATEST_IMG%.img}.vmdk"
        echo "Source: $LATEST_IMG"
        echo "Target: $VMDK_OUT"
        
        qemu-img convert -f raw -O vmdk "$LATEST_IMG" "$VMDK_OUT"
        
        if [ $? -eq 0 ]; then
            echo "✅ Successfully converted to VMDK: $VMDK_OUT"
        else
            echo "❌ Error: Failed to convert to VMDK."
        fi
    else
        echo "⚠️  No uefi-x86 .img file found in output/images/ to convert."
        echo "   Available files in output/images/:"
        ls -F output/images/ 2>/dev/null || echo "   (Directory is empty or missing)"
    fi
fi


