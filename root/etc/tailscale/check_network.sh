#!/bin/sh
# 输出安装下载所需的网络检测结果（供 LuCI RPC / 命令行）

. /etc/tailscale/tools.sh || exit 1

diagnose_download_network >/dev/null 2>&1 || true

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
	echo "message=HTTP/HTTPS 不可用，请执行: opkg install ca-bundle curl libustream-mbedtls"
	exit 0
fi

echo "ok=0"
echo "message=GitHub 与镜像均不可达，请配置代理或编辑 /etc/tailscale/proxies.txt"
