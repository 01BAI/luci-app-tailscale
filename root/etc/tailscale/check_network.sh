#!/bin/sh
# 输出安装下载所需的网络检测结果（供 LuCI RPC / 命令行）
# 用法: check_network.sh [--quick]

QUICK=0
[ "$1" = "--quick" ] && QUICK=1

. /etc/tailscale/tools.sh || {
	echo "ok=0"
	echo "message=无法加载 tools.sh，请确认 luci-app-tailscale 安装完整"
	exit 0
}

QUICK_NET_CHECK=$QUICK diagnose_download_network >/dev/null 2>&1 || true

echo "internet=${NET_INTERNET_OK:-0}"
echo "https=${NET_HTTPS_OK:-0}"
echo "github=${NET_GITHUB_OK:-0}"
echo "mirror=${NET_MIRROR_OK:-0}"
echo "mirror_prefix=${NET_USABLE_MIRROR:-}"

if [ "${NET_INTERNET_OK:-0}" != "1" ]; then
	echo "ok=0"
	echo "message=无默认路由或无法连通外网，请检查 WAN / DNS / 网关"
	exit 0
fi

if [ "${NET_GITHUB_OK:-0}" = "1" ]; then
	echo "ok=1"
	echo "message=GitHub 直连可用"
	exit 0
fi

if [ "${NET_MIRROR_OK:-0}" = "1" ]; then
	echo "ok=1"
	echo "message=GitHub 直连不可用，将使用镜像: ${NET_USABLE_MIRROR}"
	exit 0
fi

if [ "${NET_HTTPS_OK:-0}" != "1" ]; then
	echo "ok=0"
	echo "message=HTTP/HTTPS 不可用，请在 SSH 执行: opkg update && opkg install ca-bundle curl libustream-mbedtls"
	exit 0
fi

# HTTPS 正常但预检未命中 GitHub/镜像：仍允许安装（与 luci-install 实际下载逻辑一致）
echo "ok=1"
echo "message=HTTPS 可用，安装时将依次尝试 GitHub 直连与 /etc/tailscale/proxies.txt 镜像"
