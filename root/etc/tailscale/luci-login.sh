#!/bin/sh
# LuCI 登录：后台执行 tailscale up，日志与 helper 菜单 2 行为一致

LOGIN_LOG="/tmp/tailscale_luci_up.log"
LOGIN_PID_FILE="/tmp/tailscale_luci_up.pid"
LOGIN_RC_FILE="/tmp/tailscale_luci_up.status"
LOGIN_CMD_FILE="/tmp/tailscale_luci_up.cmd"

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

if [ ! -s "$LOGIN_CMD_FILE" ]; then
	log_error "❌  缺少登录命令文件: $LOGIN_CMD_FILE"
	exit 1
fi

cmd=$(cat "$LOGIN_CMD_FILE")

: > "$LOGIN_LOG"
rm -f "$LOGIN_RC_FILE"

(
	eval "$cmd" >>"$LOGIN_LOG" 2>&1
	echo $? >"$LOGIN_RC_FILE"
) &

echo $! > "$LOGIN_PID_FILE"
exit 0
