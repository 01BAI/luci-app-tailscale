#!/bin/sh
# 从 tailscale_up.conf 构建并执行 tailscale up（逻辑对齐 CH3NGYZ tailscale_up_generator.sh）
# 用法: luci-apply-up.sh [--dry-run]

CONFIG_DIR="/etc/tailscale"
UP_CONF="$CONFIG_DIR/tailscale_up.conf"
APPLY_LOG="/tmp/tailscale_luci_apply.log"
DRY_RUN=0

[ "$1" = "--dry-run" ] && DRY_RUN=1

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

TS_BIN=$(command -v tailscale 2>/dev/null) || TS_BIN="/usr/bin/tailscale"
if [ ! -x "$TS_BIN" ] && [ ! -L "$TS_BIN" ]; then
	log_error "❌  tailscale 命令不可用"
	exit 1
fi

if [ ! -f "$UP_CONF" ]; then
	log_error "❌  配置文件不存在: $UP_CONF"
	exit 1
fi

resolve_ts_socket() {
	local s
	for s in /var/run/tailscale/tailscaled.sock /tmp/tailscaled.sock; do
		[ -S "$s" ] && echo "$s" && return 0
	done
	return 1
}

valid_exit_node_val() {
	[ -z "$1" ] && return 1
	case "$1" in
		*[!0-9]* ) return 0 ;;
	esac
	return 1
}

should_skip_param() {
	local key="$1"
	local val="$2"
	case "$key" in
		--exit-node)
			valid_exit_node_val "$val" || return 0
			;;
	esac
	return 1
}

build_up_cmd() {
	local cmd="tailscale up --reset"
	local line key val

	while IFS= read -r line || [ -n "$line" ]; do
		line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		case "$line" in
			''|\#*) continue ;;
		esac

		key=${line%%=*}
		val=${line#*=}
		val=$(echo "$val" | sed 's/^"\(.*\)"$/\1/')

		case "$key" in
			--*) ;;
			*) continue ;;
		esac

		[ -z "$val" ] && continue
		should_skip_param "$key" "$val" && continue
		cmd="$cmd $key=$val"
	done < "$UP_CONF"

	echo "$cmd"
}

get_conf_advertise_routes() {
	grep '^--advertise-routes=' "$UP_CONF" 2>/dev/null | head -n1 | sed 's/^--advertise-routes=//; s/^"\(.*\)"$/\1/'
}

verify_advertise_routes() {
	local expected="$1"
	local prefs=""
	local ts_cmd="$TS_BIN"

	[ -z "$expected" ] && return 0

	SOCK=$(resolve_ts_socket || true)
	if [ -n "$SOCK" ]; then
		ts_cmd="$TS_BIN --socket=$SOCK"
	fi

	prefs=$($ts_cmd debug prefs 2>/dev/null) || prefs=""
	if echo "$prefs" | grep -F "$expected" >/dev/null 2>&1; then
		log_info "✅  已宣告子网: $expected"
		return 0
	fi

	log_warn "⚠️  配置含 --advertise-routes=$expected，但 tailscale 尚未生效"
	if echo "$prefs" | grep -i AdvertiseRoutes >/dev/null 2>&1; then
		log_warn "⚠️  当前 AdvertiseRoutes: $(echo "$prefs" | grep -i AdvertiseRoutes | head -n1)"
	fi
	log_warn "⚠️  请检查上方 tailscale up 是否报错，或手动执行: /etc/tailscale/luci-apply-up.sh --dry-run"
	return 1
}

cmd=$(build_up_cmd)
if [ -z "$cmd" ] || [ "$cmd" = "tailscale up" ] || [ "$cmd" = "tailscale up --reset" ]; then
	log_error "❌  tailscale_up.conf 中无有效参数"
	exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
	echo "$cmd"
	exit 0
fi

SOCK=$(resolve_ts_socket || true)
if [ -n "$SOCK" ]; then
	cmd=$(echo "$cmd" | sed "s|^tailscale |$TS_BIN --socket=$SOCK |")
else
	cmd=$(echo "$cmd" | sed "s|^tailscale |$TS_BIN |")
fi

: > "$APPLY_LOG"
log_info "🚀  正在执行: $cmd"
# shellcheck disable=SC2086
eval "$cmd" >>"$APPLY_LOG" 2>&1
rc=$?

cat "$APPLY_LOG"

if [ "$rc" -ne 0 ]; then
	log_error "❌  tailscale up 失败 (exit $rc)，子网不会推送到控制面板"
	if grep -q 'non-default flags' "$APPLY_LOG" 2>/dev/null; then
		log_error "❌  本地已有非默认参数且与命令不一致，请确认已部署最新 luci-apply-up.sh（含 --reset）"
	fi
	exit "$rc"
fi

expected_routes=$(get_conf_advertise_routes)
if [ -n "$expected_routes" ]; then
	verify_advertise_routes "$expected_routes" || exit 2
fi

exit 0
