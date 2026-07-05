#!/bin/sh
# LuCI 安装/更新：后台执行 luci-install.sh，日志供前端轮询显示

INSTALL_LOG="/tmp/tailscale_luci_install.log"
INSTALL_PID_FILE="/tmp/tailscale_luci_install.pid"
INSTALL_RC_FILE="/tmp/tailscale_luci_install.status"

AUTO_UPDATE="${1:-false}"
VERSION="${2:-latest}"

: > "$INSTALL_LOG"
rm -f "$INSTALL_RC_FILE"

(
	/etc/tailscale/luci-install.sh "$AUTO_UPDATE" "$VERSION" >>"$INSTALL_LOG" 2>&1
	echo $? >"$INSTALL_RC_FILE"
) &

echo $! > "$INSTALL_PID_FILE"
exit 0
