#!/bin/sh
# 卸载 Tailscale 二进制与服务，保留登录状态、LuCI 配置与 /etc/tailscale 脚本。

set -e

. /etc/tailscale/tools.sh || exit 1

log_info "开始卸载 Tailscale..."

[ -f /etc/init.d/tailscale ] && {
	/etc/init.d/tailscale stop 2>/dev/null || true
	/etc/init.d/tailscale disable 2>/dev/null || true
	rm -f /etc/init.d/tailscale
}

# 确保进程已终止（stop 失败时兜底）
killall tailscaled 2>/dev/null || true
sleep 1
killall -9 tailscaled 2>/dev/null || true

rm -f \
	/usr/bin/tailscale \
	/usr/bin/tailscaled \
	/usr/local/bin/tailscale \
	/usr/local/bin/tailscaled \
	/tmp/tailscaled \
	"$VERSION_FILE"

ip link delete tailscale0 2>/dev/null || true

if [ -f /etc/crontabs/root ]; then
	sed -i "\|$CONFIG_DIR/autoupdate.sh|d" /etc/crontabs/root 2>/dev/null || true
	/etc/init.d/cron restart 2>/dev/null || true
fi

uci -q set tailscale.settings.enabled='0' || true
uci commit tailscale 2>/dev/null || true

log_info "Tailscale 已卸载（LuCI 与脚本目录保留）"
echo "OK"
