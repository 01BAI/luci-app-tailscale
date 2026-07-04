#!/bin/sh
# tailscaled 启动后应用已保存的连接设置（tailscale up --reset + tailscale_up.conf）

[ -x /sbin/ubus ] || exit 0
ubus call tailscale apply_saved_up 2>/dev/null || true
