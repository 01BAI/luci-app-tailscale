#!/bin/sh
# 让 LAN 内设备（无需安装 Tailscale）经本机 tailscale0 访问其它子网路由器
# 用法: firewall-lan-tailscale.sh [--apply|--remove|--status]

set -e

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

NFT_COMMENT="tailscale-lan-nat"
FW4_CHAIN="inet fw4 srcnat_lan"

detect_lan_subnet() {
	local ip mask network prefix

	ip=$(uci -q get network.lan.ipaddr 2>/dev/null) || return 1
	[ -n "$ip" ] || return 1

	mask=$(uci -q get network.lan.netmask 2>/dev/null)
	if [ -n "$mask" ] && [ -f /lib/functions/network.sh ]; then
		# shellcheck disable=SC1091
		. /lib/functions/network.sh
	fi
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

nft_rule_present() {
	nft list chain $FW4_CHAIN 2>/dev/null | grep -q "comment \"$NFT_COMMENT\""
}

apply_nft() {
	local subnet="$1"

	nft list chain $FW4_CHAIN >/dev/null 2>&1 || return 1
	nft_rule_present && return 0

	nft add rule $FW4_CHAIN ip saddr "$subnet" oifname "tailscale0" \
		counter masquerade comment "$NFT_COMMENT"
	log_info "✅  防火墙: LAN $subnet → tailscale0 MASQUERADE 已启用"
	return 0
}

remove_nft() {
	local handle

	nft list chain $FW4_CHAIN >/dev/null 2>&1 || return 0

	nft -a list chain $FW4_CHAIN 2>/dev/null | grep "comment \"$NFT_COMMENT\"" | while read -r line; do
		handle=$(echo "$line" | sed -n 's/.*# handle \([0-9]*\).*/\1/p')
		[ -n "$handle" ] && nft delete rule $FW4_CHAIN handle "$handle" 2>/dev/null || true
	done
}

apply_iptables() {
	local subnet="$1"

	iptables -t nat -C POSTROUTING -s "$subnet" ! -d "$subnet" -o tailscale0 \
		-j MASQUERADE -m comment --comment "$NFT_COMMENT" 2>/dev/null && return 0

	iptables -t nat -A POSTROUTING -s "$subnet" ! -d "$subnet" -o tailscale0 \
		-j MASQUERADE -m comment --comment "$NFT_COMMENT"
	log_info "✅  防火墙(iptables): LAN $subnet → tailscale0 MASQUERADE 已启用"
}

remove_iptables() {
	iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | \
		grep "$NFT_COMMENT" | awk '{print $1}' | sort -rn | while read -r num; do
			[ -n "$num" ] && iptables -t nat -D POSTROUTING "$num" 2>/dev/null || true
		done
}

apply_rules() {
	local subnet

	subnet=$(detect_lan_subnet) || {
		log_warn "⚠️  无法检测 LAN 网段 (network.lan)，跳过 tailscale LAN NAT"
		return 1
	}

	if apply_nft "$subnet"; then
		return 0
	fi

	if iptables -t nat -L POSTROUTING >/dev/null 2>&1; then
		apply_iptables "$subnet"
		return 0
	fi

	log_warn "⚠️  未找到 fw4 或 iptables NAT，跳过 tailscale LAN NAT"
	return 1
}

remove_rules() {
	remove_nft
	remove_iptables
	log_info "🛑  已移除 tailscale LAN NAT 规则"
}

show_status() {
	local subnet
	subnet=$(detect_lan_subnet 2>/dev/null) || subnet="(unknown)"
	if nft_rule_present 2>/dev/null; then
		echo "active nft: $subnet -> tailscale0 masquerade"
		return 0
	fi
	if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "$NFT_COMMENT"; then
		echo "active iptables: $subnet -> tailscale0 masquerade"
		return 0
	fi
	echo "inactive"
	return 1
}

ACTION="apply"
case "${1:-}" in
	--apply|apply) ACTION="apply" ;;
	--remove|remove) ACTION="remove" ;;
	--status|status) ACTION="status" ;;
	-h|--help)
		echo "用法: $0 [--apply|--remove|--status]"
		exit 0
		;;
esac

case "$ACTION" in
	apply) apply_rules ;;
	remove) remove_rules ;;
	status) show_status ;;
esac
