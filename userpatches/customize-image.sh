#!/bin/bash

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

Main() {
	echo "======================== arch: $BOARD ===================================="

	# 彻底禁用 Armbian/Debian 原生联网功能，防止干扰 Landscape Router
	echo "==== 正在禁用原生网络服务 ===="
	systemctl disable systemd-resolved
	systemctl mask systemd-resolved
	systemctl mask networking
	systemctl mask NetworkManager
	systemctl mask wpa_supplicant
	
	# 清空 interfaces 配置文件，防止内核自动拉起 DHCP
	cat <<EOF > /etc/network/interfaces
# 本文件由构建脚本清空，所有网络功能由 Landscape Router 接管
auto lo
iface lo inet loopback
EOF

	# 确保 /etc/resolv.conf 不是符号链接或被锁定
	rm -f /etc/resolv.conf
	echo "nameserver 114.114.114.114" > /etc/resolv.conf

	# 加载构建变量
	if [ -f "/tmp/overlay/build_vars.sh" ]; then
		source /tmp/overlay/build_vars.sh
	fi

	if [ "$ENABLE_MIRROR" == "yes" ]; then
		echo "==== 正在启用清华源加速 ===="
		rm -f /etc/apt/sources.list
		cat <<EOF > /etc/apt/sources.list
# 默认注释了源码镜像以提高 apt update 速度，如有需要可自行取消注释
deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${RELEASE} main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian/ ${RELEASE} main contrib non-free non-free-firmware

deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${RELEASE}-updates main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian/ ${RELEASE}-updates main contrib non-free non-free-firmware

deb https://mirrors.tuna.tsinghua.edu.cn/debian/ ${RELEASE}-backports main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian/ ${RELEASE}-backports main contrib non-free non-free-firmware

# 以下安全更新软件源包含了官方源与镜像站配置，如有需要可自行修改注释切换
deb https://mirrors.tuna.tsinghua.edu.cn/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
# deb-src https://mirrors.tuna.tsinghua.edu.cn/debian-security ${RELEASE}-security main contrib non-free non-free-firmware
EOF
	else
		echo "==== 使用系统默认软件源 ===="
	fi
	apt update -y --fix-missing
	# 安装基础软件
	apt install -y ppp tcpdump bpftool iptables zip unzip dnsutils

	# WiFi 相关软件：仅在 mangopi-m28k 上安装
	if [ "$BOARD" = "mangopi-m28k" ]; then
		echo "正在为 $BOARD 安装 WiFi 相关软件包 (hostapd, iw)..."
		apt install -y hostapd iw
	fi

	# docker install start
	apt-get install -y ca-certificates curl
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc

	# Add the repository to Apt sources:
	echo \
	"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
	$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
	tee /etc/apt/sources.list.d/docker.list > /dev/null
	apt-get update

	apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	cat <<EOF > /etc/docker/daemon.json
{
	"bip": "172.18.1.1/24",
	"dns": ["172.18.1.1"]
}
EOF
	systemctl enable docker

	# 部署 Landscape 相关的可执行文件
	# 注意：这些文件应在 build.sh 阶段预先下载并放入 userpatches/overlay/
	# Armbian 构建过程会自动将 userpatches/overlay/ 下的文件挂载/复制到镜像内的 /tmp/overlay/

	if [ "$BOARD" = "uefi-x86" ]; then
		TARGET_BIN="landscape-webserver-x86_64"
		GRUB_CMD="net.ifnames=0 biosdevname=0"
		sudo sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"$GRUB_CMD /" /etc/default/grub
		sudo update-grub
	else
		TARGET_BIN="landscape-webserver-aarch64"
		# 使用默认的方式进行命名
		cat /boot/armbianEnv.txt
		echo "extraargs=net.ifnames=0 biosdevname=0" | sudo tee -a /boot/armbianEnv.txt
	fi

	if [ -f "/tmp/overlay/$TARGET_BIN" ]; then
		echo "安装 $TARGET_BIN..."
		cp "/tmp/overlay/$TARGET_BIN" /root/landscape-webserver
	else
		echo "错误：未在 /tmp/overlay 中找到 $TARGET_BIN，请检查 build.sh 下载步骤。"
	fi

	mkdir -p /root/.landscape-router/
	
	# 配置 TOML 文件
	# 优先寻找特定板子的配置，如果没有则寻找默认配置
	INIT_CONFIG="/tmp/overlay/landscape_init-${BOARD}.toml"
	if [ ! -f "$INIT_CONFIG" ]; then
		INIT_CONFIG="/tmp/overlay/landscape_init.toml"
	fi

	if [ -f "$INIT_CONFIG" ]; then
		echo "应用配置文件: $INIT_CONFIG"
		cp "$INIT_CONFIG" "/root/.landscape-router/landscape_init.toml"
	else
		echo "警告：未找到适合的初始化配置文件"
	fi

	chmod +x /root/landscape-webserver
	
	mkdir -p /root/.landscape-router/
	
	if [ -f "/tmp/overlay/static.zip" ]; then
		echo "安装 static.zip 到 /root/.landscape-router/..."
		cp /tmp/overlay/static.zip /root/.landscape-router/static.zip
		unzip -o /root/.landscape-router/static.zip -d /root/.landscape-router/
		if [ $? -eq 0 ]; then
			echo "static.zip 解压成功"
			# 可选：解压后删除压缩包以节省空间
			# rm /root/.landscape-router/static.zip
		else
			echo "错误：static.zip 解压失败"
		fi
	else
		echo "错误：未在 /tmp/overlay 中找到 static.zip"
	fi

	cat <<EOF > /etc/systemd/system/landscape-router.service
[Unit]
Description=Landscape Router
After=local-fs.target

[Service]
ExecStart=/bin/bash -c 'if [ ! -f /root/.landscape-router/landscape_init.toml ]; then exec /root/landscape-webserver --auto; else exec /root/landscape-webserver; fi'
Restart=always
User=root
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
	systemctl enable landscape-router.service

	echo "==== 正在直接应用系统设置 ===="

	# 1. 设置 root 密码
	echo "root:123456" | chpasswd

	# 2. 创建用户 ld 并设置密码
	if ! id "ld" &>/dev/null; then
		useradd -m -s /bin/bash -G sudo ld
		echo "ld:123456" | chpasswd
	fi

	# 3. 设置时区
	ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

	# 4. 设置语言环境
	sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
	locale-gen en_US.UTF-8
	update-locale LANG=en_US.UTF-8

	# 5. 禁用 Armbian 首次运行向导
	rm -f /root/.not_logged_in_yet
	touch /root/.no_first_run_setup
	systemctl disable armbian-firstrun-config.service 2>/dev/null
} # Main

Main "$@"
