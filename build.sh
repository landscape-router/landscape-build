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
    ARMBIAN_VERSION="v24.08"
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
    "${DOWNLOAD_BASE}/static.zip|static.zip"
)

USERPATCHES_DIR="userpatches"
OVERLAY_DIR="${USERPATCHES_DIR}/overlay"
KERNEL_CONFIG_DIR="${USERPATCHES_DIR}/kernel"

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
    ["hinlink-h68k"]="current no yes"
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
./compile.sh \
    build BOARD="$SELECTED_BOARD" \
    BRANCH="$BRANCH" \
    BUILD_DESKTOP="$BUILD_DESKTOP" \
    BUILD_MINIMAL="$BUILD_MINIMAL" \
    KERNEL_CONFIGURE="$ENABLE_KERNEL_CONFIGURE" \
    RELEASE=trixie \
    KERNEL_GIT=shallow \
    NETWORKING_STACK="none"

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


