#!/bin/sh
# 后台执行 luci-apply-up.sh，日志与退出码供 RPC 轮询
# 用法: luci-apply-up-bg.sh

APPLY_LOG="/tmp/tailscale_luci_apply.log"
APPLY_PID_FILE="/tmp/tailscale_luci_apply.pid"
APPLY_RC_FILE="/tmp/tailscale_luci_apply.status"

rm -f "$APPLY_RC_FILE" "$APPLY_PID_FILE"
: > "$APPLY_LOG"
chmod 644 "$APPLY_LOG" 2>/dev/null || true

(
	/etc/tailscale/luci-apply-up.sh >>"$APPLY_LOG" 2>&1
	echo $? >"$APPLY_RC_FILE"
	rm -f "$APPLY_PID_FILE"
) &

echo $! > "$APPLY_PID_FILE"
exit 0
