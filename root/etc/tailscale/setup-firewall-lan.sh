#!/bin/sh
# 注册 firewall.user 钩子并应用 LAN→tailscale MASQUERADE（幂等）

set -e

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

FW_USER="/etc/firewall.user"
HOOK_MARK="# luci-app-tailscale: LAN via tailscale0"
HOOK_LINE='[ -x /etc/tailscale/firewall-lan-tailscale.sh ] && /etc/tailscale/firewall-lan-tailscale.sh --apply'

register_firewall_hook() {
	if [ ! -f "$FW_USER" ]; then
		touch "$FW_USER"
		chmod 755 "$FW_USER"
	fi

	if grep -qF "$HOOK_MARK" "$FW_USER" 2>/dev/null; then
		return 0
	fi

	cat >>"$FW_USER" <<EOF

$HOOK_MARK
$HOOK_LINE
EOF
	log_info "✅  已注册 firewall.user 钩子"
}

unregister_firewall_hook() {
	[ -f "$FW_USER" ] || return 0
	sed -i "/$(echo "$HOOK_MARK" | sed 's/[\/&]/\\&/g')/d" "$FW_USER" 2>/dev/null || true
	sed -i "\|$HOOK_LINE|d" "$FW_USER" 2>/dev/null || true
}

case "${1:-}" in
	--unregister)
		unregister_firewall_hook
		/etc/tailscale/firewall-lan-tailscale.sh --remove 2>/dev/null || true
		exit 0
		;;
esac

register_firewall_hook
/etc/tailscale/firewall-lan-tailscale.sh --apply || true

# 立即生效（不依赖用户手动 restart firewall）
if [ -x /etc/init.d/firewall ]; then
	/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true
fi

log_info "✅  LAN 经 Tailscale 互访防火墙已配置"
