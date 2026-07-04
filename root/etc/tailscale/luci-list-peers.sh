#!/bin/sh
# 从 tailscale status --json 提取节点列表（与 tailscale status 表格字段对齐）
# 用法: luci-list-peers.sh [status.json]
# 输出 TSV（| 分隔）: id|name|ip|os|online|active|lastseen|self

JSON="${1:-/tmp/tailscale_luci_status.json}"
JF="$(command -v jsonfilter)"

[ -f "$JSON" ] || exit 1
[ -n "$JF" ] || exit 1

dns_short() {
	[ -n "$1" ] || return
	echo "$1" | cut -d. -f1
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
	[ -z "$lastseen" ] && lastseen=""
	printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$id" "$name" "$ip" "$os" "$online" "$active" "$lastseen" "$is_self"
}

self_id="$($JF -i "$JSON" -e '@.Self.ID' 2>/dev/null)"
self_dns="$($JF -i "$JSON" -e '@.Self.DNSName' 2>/dev/null)"
self_ip="$($JF -i "$JSON" -e '@.Self.TailscaleIPs[0]' 2>/dev/null)"
self_os="$($JF -i "$JSON" -e '@.Self.OS' 2>/dev/null)"
self_online="$($JF -i "$JSON" -e '@.Self.Online' 2>/dev/null)"
self_active="$($JF -i "$JSON" -e '@.Self.Active' 2>/dev/null)"
self_lastseen="$($JF -i "$JSON" -e '@.Self.LastSeen' 2>/dev/null)"

if [ -n "$self_ip" ]; then
	print_row "$self_id" "$(dns_short "$self_dns")" "$self_ip" "$self_os" \
		"$self_online" "$self_active" "$self_lastseen" "true"
fi

$JF -i "$JSON" -e '@.Peer.*.ID' > /tmp/.ts_peer_ids || exit 0
[ -s /tmp/.ts_peer_ids ] || exit 0

$JF -i "$JSON" -e '@.Peer.*.DNSName' > /tmp/.ts_peer_dns
$JF -i "$JSON" -e '@.Peer.*.TailscaleIPs[0]' > /tmp/.ts_peer_ips
$JF -i "$JSON" -e '@.Peer.*.OS' > /tmp/.ts_peer_os
$JF -i "$JSON" -e '@.Peer.*.Online' > /tmp/.ts_peer_online
$JF -i "$JSON" -e '@.Peer.*.Active' > /tmp/.ts_peer_active
$JF -i "$JSON" -e '@.Peer.*.LastSeen' > /tmp/.ts_peer_lastseen

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
	print_row "$id" "$(dns_short "$dns")" "$ip" "$os" \
		"$online" "$active" "$lastseen" "false"
done < /tmp/.ts_peer_ids

rm -f /tmp/.ts_peer_ids /tmp/.ts_peer_dns /tmp/.ts_peer_ips /tmp/.ts_peer_os \
	/tmp/.ts_peer_online /tmp/.ts_peer_active /tmp/.ts_peer_lastseen
