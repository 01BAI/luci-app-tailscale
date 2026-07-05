#!/bin/sh
# 从 tailscale status --json 提取节点列表（与 tailscale status 表格字段对齐）
# 用法: luci-list-peers.sh [status.json]
# 输出 TSV（| 分隔）: id|name|ip|os|online|active|lastseen|self|routes|path

JSON="${1:-/tmp/tailscale_luci_status.json}"
JF="$(command -v jsonfilter)"

[ -f "$JSON" ] || exit 1
[ -n "$JF" ] || exit 1

dns_short() {
	[ -n "$1" ] || return
	echo "$1" | cut -d. -f1
}

routes_from_json_array() {
	line="$1"
	[ -z "$line" ] || [ "$line" = "null" ] && return 0
	echo "$line" | sed 's/^\[//;s/\]$//;s/"//g;s/\\//g' | tr ',' '\n' | while read -r cidr; do
		cidr=$(echo "$cidr" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		case "$cidr" in
			''|*/32|*/128) continue ;;
		esac
		printf '%s,' "$cidr"
	done | sed 's/,$//'
}

format_path() {
	is_self="$1"
	online="$2"
	active="$3"
	cur="$4"
	relay="$5"
	peer_relay="$6"
	tx="$7"
	rx="$8"

	[ "$is_self" = "true" ] && return 0

	case "$online" in
		true|True|1) ;;
		*) return 0 ;;
	esac

	cur=$(echo "$cur" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\\//g')
	relay=$(echo "$relay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	peer_relay=$(echo "$peer_relay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\\//g')
	tx=$(echo "$tx" | sed 's/[^0-9-]//g')
	rx=$(echo "$rx" | sed 's/[^0-9-]//g')
	[ -z "$tx" ] && tx=0
	[ -z "$rx" ] && rx=0

	if [ -n "$peer_relay" ]; then
		printf 'peer_relay|%s\n' "$peer_relay"
		return 0
	fi
	if [ -n "$cur" ]; then
		printf 'direct|%s\n' "$cur"
		return 0
	fi
	# 与 CLI「active; relay "hkg"」一致：仅活跃且走 DERP 时才算中继
	case "$active" in
		true|True|1)
			if [ -n "$relay" ]; then
				printf 'relay|%s\n' "$relay"
				return 0
			fi
			;;
	esac
	# idle 直连（有流量统计但 JSON 未填 CurAddr）
	if [ "$tx" -gt 0 ] 2>/dev/null || [ "$rx" -gt 0 ] 2>/dev/null; then
		printf 'direct|\n'
		return 0
	fi
	printf 'none\n'
}

print_row() {
	id="$1"
	name="$2"
	ip="$3"
	os="$4"
	online="$5"
	active="$6"
	lastseen="$7"
	is_self="$8"
	routes="$9"
	path="${10}"
	[ -z "$lastseen" ] && lastseen=""
	[ -z "$routes" ] && routes=""
	[ -z "$path" ] && path=""
	printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$id" "$name" "$ip" "$os" "$online" "$active" "$lastseen" "$is_self" "$routes" "$path"
}

self_id="$($JF -i "$JSON" -e '@.Self.ID' 2>/dev/null)"
self_dns="$($JF -i "$JSON" -e '@.Self.DNSName' 2>/dev/null)"
self_ip="$($JF -i "$JSON" -e '@.Self.TailscaleIPs[0]' 2>/dev/null)"
self_os="$($JF -i "$JSON" -e '@.Self.OS' 2>/dev/null)"
self_online="$($JF -i "$JSON" -e '@.Self.Online' 2>/dev/null)"
self_active="$($JF -i "$JSON" -e '@.Self.Active' 2>/dev/null)"
self_lastseen="$($JF -i "$JSON" -e '@.Self.LastSeen' 2>/dev/null)"
self_routes_raw="$($JF -i "$JSON" -e '@.Self.PrimaryRoutes' 2>/dev/null)"
self_allowed_raw="$($JF -i "$JSON" -e '@.Self.AllowedIPs' 2>/dev/null)"
self_routes="$(routes_from_json_array "$self_routes_raw")"
[ -z "$self_routes" ] && self_routes="$(routes_from_json_array "$self_allowed_raw")"

if [ -n "$self_ip" ]; then
	print_row "$self_id" "$(dns_short "$self_dns")" "$self_ip" "$self_os" \
		"$self_online" "$self_active" "$self_lastseen" "true" "$self_routes" ""
fi

$JF -i "$JSON" -e '@.Peer.*.ID' > /tmp/.ts_peer_ids || exit 0
[ -s /tmp/.ts_peer_ids ] || exit 0

$JF -i "$JSON" -e '@.Peer.*.DNSName' > /tmp/.ts_peer_dns
$JF -i "$JSON" -e '@.Peer.*.TailscaleIPs[0]' > /tmp/.ts_peer_ips
$JF -i "$JSON" -e '@.Peer.*.OS' > /tmp/.ts_peer_os
$JF -i "$JSON" -e '@.Peer.*.Online' > /tmp/.ts_peer_online
$JF -i "$JSON" -e '@.Peer.*.Active' > /tmp/.ts_peer_active
$JF -i "$JSON" -e '@.Peer.*.LastSeen' > /tmp/.ts_peer_lastseen
$JF -i "$JSON" -e '@.Peer.*.AllowedIPs' > /tmp/.ts_peer_allowedips
$JF -i "$JSON" -e '@.Peer.*.CurAddr' > /tmp/.ts_peer_curaddr
$JF -i "$JSON" -e '@.Peer.*.Relay' > /tmp/.ts_peer_relay
$JF -i "$JSON" -e '@.Peer.*.PeerRelay' > /tmp/.ts_peer_peerrelay
$JF -i "$JSON" -e '@.Peer.*.TxBytes' > /tmp/.ts_peer_tx
$JF -i "$JSON" -e '@.Peer.*.RxBytes' > /tmp/.ts_peer_rx

i=0
while IFS= read -r id; do
	[ -z "$id" ] && continue
	i=$((i + 1))
	dns=$(sed -n "${i}p" /tmp/.ts_peer_dns)
	ip=$(sed -n "${i}p" /tmp/.ts_peer_ips)
	os=$(sed -n "${i}p" /tmp/.ts_peer_os)
	online=$(sed -n "${i}p" /tmp/.ts_peer_online)
	active=$(sed -n "${i}p" /tmp/.ts_peer_active)
	lastseen=$(sed -n "${i}p" /tmp/.ts_peer_lastseen)
	allowed=$(sed -n "${i}p" /tmp/.ts_peer_allowedips)
	cur=$(sed -n "${i}p" /tmp/.ts_peer_curaddr)
	relay=$(sed -n "${i}p" /tmp/.ts_peer_relay)
	peer_relay=$(sed -n "${i}p" /tmp/.ts_peer_peerrelay)
	tx=$(sed -n "${i}p" /tmp/.ts_peer_tx)
	rx=$(sed -n "${i}p" /tmp/.ts_peer_rx)
	routes="$(routes_from_json_array "$allowed")"
	path="$(format_path "false" "$online" "$active" "$cur" "$relay" "$peer_relay" "$tx" "$rx")"
	print_row "$id" "$(dns_short "$dns")" "$ip" "$os" \
		"$online" "$active" "$lastseen" "false" "$routes" "$path"
done < /tmp/.ts_peer_ids

rm -f /tmp/.ts_peer_ids /tmp/.ts_peer_dns /tmp/.ts_peer_ips /tmp/.ts_peer_os \
	/tmp/.ts_peer_online /tmp/.ts_peer_active /tmp/.ts_peer_lastseen /tmp/.ts_peer_allowedips \
	/tmp/.ts_peer_curaddr /tmp/.ts_peer_relay /tmp/.ts_peer_peerrelay \
	/tmp/.ts_peer_tx /tmp/.ts_peer_rx
