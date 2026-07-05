#!/bin/sh
# 非交互安装：先检测网络，再按直连 / 镜像顺序下载。

set -e

AUTO_UPDATE="${1:-false}"
VERSION="${2:-latest}"

. /etc/tailscale/tools.sh || exit 1

ensure_arch || exit 1

log_info "▶  开始安装 Tailscale（版本: ${VERSION:-latest}）"
log_info "▶  系统架构: $(uname -m) → ${ARCH:-检测中...}"

if ! diagnose_download_network; then
	exit 1
fi

HOST_NAME="$(uci -q get system.@system[0].hostname 2>/dev/null || hostname)"

mkdir -p "$CONFIG_DIR"

if [ -f /etc/init.d/tailscale ]; then
	/etc/init.d/tailscale stop 2>/dev/null || true
fi

rm -f /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/bin/tailscale /usr/bin/tailscaled

do_install() {
	local use_direct="$1"

	GITHUB_DIRECT="$use_direct"
	export GITHUB_DIRECT
	apply_github_mode

	if [ "$use_direct" = "true" ]; then
		log_info "▶  尝试 GitHub 直连下载..."
	else
		log_info "▶  使用 GitHub 镜像下载..."
	fi

	cat > "$INST_CONF" <<EOF
# 安装配置记录 (LuCI)
AUTO_UPDATE=$AUTO_UPDATE
VERSION=$VERSION
ARCH=$ARCH
HOST_NAME=$HOST_NAME
GITHUB_DIRECT=$GITHUB_DIRECT
TIMESTAMP=$(date +%s)
EOF

	"$CONFIG_DIR/fetch_and_install.sh" \
		--version="$VERSION" \
		--mirror-list="$CONFIG_DIR/proxies.txt"
}

installed=0

if [ "$NET_GITHUB_OK" = "1" ] && do_install true; then
	log_info "✅  GitHub 直连安装成功"
	installed=1
elif [ "$NET_MIRROR_OK" = "1" ] && do_install false; then
	log_info "✅  镜像模式安装成功"
	installed=1
fi

if [ "$installed" != "1" ]; then
	log_error "❌  安装失败"
	log_error "❌  网络检测已通过但下载失败，请检查 /etc/tailscale/proxy.env 或 proxies.txt"
	exit 1
fi

log_info "▶  配置 init 服务与 cron..."
"$CONFIG_DIR/setup_service.sh"
"$CONFIG_DIR/luci-setup-cron.sh" "$AUTO_UPDATE"

uci -q set tailscale.settings.enabled='1' || true
uci -q set tailscale.settings.version="$VERSION" || true
uci -q set tailscale.settings.auto_update="$([ "$AUTO_UPDATE" = "true" ] && echo 1 || echo 0)" || true
uci commit tailscale 2>/dev/null || true

/etc/init.d/tailscale enable
/etc/init.d/tailscale start

log_info "✅  安装流程完成"
echo "OK"
