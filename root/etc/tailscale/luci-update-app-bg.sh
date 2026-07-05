#!/bin/sh
# 后台更新 LuCI 插件，日志供前端轮询

UPDATE_LOG="/tmp/tailscale_luci_app_update.log"
UPDATE_PID_FILE="/tmp/tailscale_luci_app_update.pid"
UPDATE_RC_FILE="/tmp/tailscale_luci_app_update.status"

TAG="${1:-}"

rm -f "$UPDATE_RC_FILE" "$UPDATE_PID_FILE"
: > "$UPDATE_LOG"
chmod 644 "$UPDATE_LOG" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在启动插件更新 (${TAG})..." >>"$UPDATE_LOG"

(
	/etc/tailscale/luci-update-app.sh "$TAG" >>"$UPDATE_LOG" 2>&1
	echo $? >"$UPDATE_RC_FILE"
	rm -f "$UPDATE_PID_FILE"
) &

echo $! > "$UPDATE_PID_FILE"
exit 0
