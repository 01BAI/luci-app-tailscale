#!/bin/sh
# 写入 UCI 防火墙 NAT（LuCI 可见），使 LAN 客户端经 tailscale0 访问其它子网
# 用法: setup-firewall-lan.sh [--unregister|--status]

set -e

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

UCI_SECTION="tailscale_lan_nat"
NAT_NAME="TailscaleLAN"
FW_USER="/etc/firewall.user"
HOOK_MARK="# luci-app-tailscale: LAN via tailscale0"

detect_lan_subnet() {
	local ip mask

	ip=$(uci -q get network.lan.ipaddr 2>/dev/null) || return 1
	[ -n "$ip" ] || return 1

	mask=$(uci -q get network.lan.netmask 2>/dev/null)
	if [ -n "$mask" ] && command -v ipcalc.sh >/dev/null 2>&1; then
		# shellcheck disable=SC1091
		eval "$(ipcalc.sh "$ip" "$mask")"
		if [ -n "${NETWORK:-}" ] && [ -n "${PREFIX:-}" ]; then
			echo "${NETWORK}/${PREFIX}"
			return 0
		fi
	fi

	echo "${ip%.*}.0/24"
}

remove_legacy_hook() {
	[ -f "$FW_USER" ] || return 0
	sed -i "/$(echo "$HOOK_MARK" | sed 's/[\/&]/\\&/g')/d" "$FW_USER" 2>/dev/null || true
	sed -i '\|firewall-lan-tailscale.sh|d' "$FW_USER" 2>/dev/null || true
}

remove_legacy_nft() {
	local handle line

	nft -a list chain inet fw4 srcnat_lan 2>/dev/null | grep 'tailscale-lan-nat' | while read -r line; do
		handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
		[ -n "$handle" ] && nft delete rule inet fw4 srcnat_lan handle "$handle" 2>/dev/null || true
	done
}

apply_uci_nat() {
	local subnet

	subnet=$(detect_lan_subnet) || {
		log_warn "⚠️  无法检测 LAN 网段 (network.lan)，跳过 Tailscale NAT"
		return 1
	}

	if ! uci -q get "firewall.${UCI_SECTION}" >/dev/null 2>&1; then
		uci set "firewall.${UCI_SECTION}=nat"
	fi

	uci set "firewall.${UCI_SECTION}.name=${NAT_NAME}"
	uci set "firewall.${UCI_SECTION}.family=ipv4"
	uci set "firewall.${UCI_SECTION}.proto=all"
	uci set "firewall.${UCI_SECTION}.src=lan"
	uci set "firewall.${UCI_SECTION}.target=MASQUERADE"
	uci set "firewall.${UCI_SECTION}.extra=-o tailscale0"
	uci set "firewall.${UCI_SECTION}.src_ip=${subnet}"

	uci commit firewall
	remove_legacy_hook
	remove_legacy_nft

	if [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true
	fi

	log_info "✅  已添加 NAT 规则 ${NAT_NAME}: ${subnet} → tailscale0（LuCI → 防火墙 → NAT）"
	return 0
}

remove_uci_nat() {
	if uci -q get "firewall.${UCI_SECTION}" >/dev/null 2>&1; then
		uci delete "firewall.${UCI_SECTION}"
		uci commit firewall
	fi

	remove_legacy_hook
	remove_legacy_nft

	if [ -x /etc/init.d/firewall ]; then
		/etc/init.d/firewall reload 2>/dev/null || /etc/init.d/firewall restart 2>/dev/null || true
	fi

	log_info "🛑  已移除 NAT 规则 ${NAT_NAME}"
}

show_status() {
	local subnet

	if uci -q get "firewall.${UCI_SECTION}" >/dev/null 2>&1; then
		subnet=$(uci -q get "firewall.${UCI_SECTION}.src_ip" 2>/dev/null)
		echo "active uci: ${subnet:-?} -> tailscale0 masquerade (${NAT_NAME})"
		return 0
	fi

	if nft list chain inet fw4 srcnat_lan 2>/dev/null | grep -q "TailscaleLAN"; then
		echo "active nft: TailscaleLAN"
		return 0
	fi

	echo "inactive"
	return 1
}

case "${1:-}" in
	--unregister|unregister)
		remove_uci_nat
		exit 0
		;;
	--status|status)
		show_status
		exit $?
		;;
	-h|--help)
		echo "用法: $0 [--unregister|--status]"
		exit 0
		;;
esac

apply_uci_nat
