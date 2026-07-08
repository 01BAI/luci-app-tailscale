#!/bin/sh
# 从 tailscale status --json 提取节点列表（与 tailscale status CLI 对齐）
# 输出 TSV（| 分隔）: id|name|ip|os|online|active|lastseen|self|routes|path|lasthandshake|lastwrite|status_hint

JSON="${1:-/tmp/tailscale_luci_status.json}"
JF="$(command -v jsonfilter)"
CLI_FILE="/tmp/.ts_cli_status.$$"

[ -f "$JSON" ] || exit 1
[ -n "$JF" ] || exit 1

tailscale status 2>/dev/null > "$CLI_FILE" || : > "$CLI_FILE"
trap 'rm -f "$CLI_FILE" /tmp/.ts_peer_*' EXIT INT TERM

is_zero_time() {
	case "$1" in
		''|null|"0001-01-01"*) return 0 ;;
		*) return 1 ;;
	esac
}

cli_status_for_ip() {
	_ip="$1"
	_line=$(grep -E "^${_ip}[[:space:]]" "$CLI_FILE" | head -n1)
	[ -z "$_line" ] && return 0
	echo "$_line" | awk '{
		out = ""
		for (i = 5; i <= NF; i++) {
			if (out != "") out = out " "
			out = out $i
		}
		print out
	}'
}

# 与 tailscale 控制面板一致：
# - CLI 含 offline → 离线
# - JSON Online=true → 在线（含 iOS 等 LastSeen 非零但仍在线的节点）
# - Online=false 且 LastSeen 为零时间 → 在线（与本机直连中）
# - 其余 → 离线
peer_is_connected() {
	_online="$1"
	_lastseen="$2"
	_cli="$3"

	echo "$_cli" | grep -qi "offline" && return 1

	case "$_online" in
		true|True|1) return 0 ;;
	esac

	if is_zero_time "$_lastseen"; then
		return 0
	fi

	return 1
}

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
	connected="$2"
	active="$3"
	cur="$4"
	relay="$5"
	peer_relay="$6"

	[ "$is_self" = "true" ] && return 0
	[ "$connected" = "true" ] || return 0

	case "$active" in
		true|True|1) ;;
		*) return 0 ;;
	esac

	cur=$(echo "$cur" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\\//g')
	relay=$(echo "$relay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	peer_relay=$(echo "$peer_relay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\\//g')

	if [ -n "$peer_relay" ]; then
		printf 'peer_relay#%s\n' "$peer_relay"
		return 0
	fi
	if [ -n "$cur" ]; then
		printf 'direct#%s\n' "$cur"
		return 0
	fi
	if [ -n "$relay" ]; then
		printf 'relay#%s\n' "$relay"
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
	lasthandshake="${11}"
	lastwrite="${12}"
	status_hint="${13}"
	[ -z "$lastseen" ] && lastseen=""
	[ -z "$routes" ] && routes=""
	[ -z "$path" ] && path=""
	[ -z "$lasthandshake" ] && lasthandshake=""
	[ -z "$lastwrite" ] && lastwrite=""
	[ -z "$status_hint" ] && status_hint=""
	printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$id" "$name" "$ip" "$os" "$online" "$active" "$lastseen" "$is_self" "$routes" "$path" \
		"$lasthandshake" "$lastwrite" "$status_hint"
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
		"true" "$self_active" "$self_lastseen" "true" "$self_routes" "" "" "" ""
fi

$JF -i "$JSON" -e '@.Peer.*.ID' > /tmp/.ts_peer_ids || exit 0
[ -s /tmp/.ts_peer_ids ] || exit 0

$JF -i "$JSON" -e '@.Peer.*.DNSName' > /tmp/.ts_peer_dns
$JF -i "$JSON" -e '@.Peer.*.TailscaleIPs[0]' > /tmp/.ts_peer_ips
$JF -i "$JSON" -e '@.Peer.*.OS' > /tmp/.ts_peer_os
$JF -i "$JSON" -e '@.Peer.*.Online' > /tmp/.ts_peer_online
$JF -i "$JSON" -e '@.Peer.*.Active' > /tmp/.ts_peer_active
$JF -i "$JSON" -e '@.Peer.*.LastSeen' > /tmp/.ts_peer_lastseen
$JF -i "$JSON" -e '@.Peer.*.LastWrite' > /tmp/.ts_peer_lastwrite
$JF -i "$JSON" -e '@.Peer.*.LastHandshake' > /tmp/.ts_peer_lasths
$JF -i "$JSON" -e '@.Peer.*.AllowedIPs' > /tmp/.ts_peer_allowedips
$JF -i "$JSON" -e '@.Peer.*.CurAddr' > /tmp/.ts_peer_curaddr
$JF -i "$JSON" -e '@.Peer.*.Relay' > /tmp/.ts_peer_relay
$JF -i "$JSON" -e '@.Peer.*.PeerRelay' > /tmp/.ts_peer_peerrelay

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
	lastwrite=$(sed -n "${i}p" /tmp/.ts_peer_lastwrite)
	lasthandshake=$(sed -n "${i}p" /tmp/.ts_peer_lasths)
	allowed=$(sed -n "${i}p" /tmp/.ts_peer_allowedips)
	cur=$(sed -n "${i}p" /tmp/.ts_peer_curaddr)
	relay=$(sed -n "${i}p" /tmp/.ts_peer_relay)
	peer_relay=$(sed -n "${i}p" /tmp/.ts_peer_peerrelay)
	cli_status="$(cli_status_for_ip "$ip")"
	routes="$(routes_from_json_array "$allowed")"

	if peer_is_connected "$online" "$lastseen" "$cli_status"; then
		display_online="true"
	else
		display_online="false"
	fi

	path="$(format_path "false" "$display_online" "$active" "$cur" "$relay" "$peer_relay")"
	print_row "$id" "$(dns_short "$dns")" "$ip" "$os" \
		"$display_online" "$active" "$lastseen" "false" "$routes" "$path" \
		"$lasthandshake" "$lastwrite" "$cli_status"
done < /tmp/.ts_peer_ids
