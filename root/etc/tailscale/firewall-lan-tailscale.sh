#!/bin/sh
# 兼容入口，实际逻辑在 setup-firewall-lan.sh（UCI NAT，LuCI 可见）

SCRIPT="/etc/tailscale/setup-firewall-lan.sh"

case "${1:-}" in
	--remove) exec /bin/sh "$SCRIPT" --unregister ;;
	--apply) exec /bin/sh "$SCRIPT" ;;
	--status|status) exec /bin/sh "$SCRIPT" --status ;;
	-h|--help)
		echo "用法: $0 [--apply|--remove|--status]"
		echo "请使用: $SCRIPT [--unregister|--status]"
		exit 0
		;;
	*) exec /bin/sh "$SCRIPT" "$@" ;;
esac
