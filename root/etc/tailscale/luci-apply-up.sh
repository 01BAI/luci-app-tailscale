#!/bin/sh
# 从 tailscale_up.conf 构建并执行 tailscale up / set
# 已登录时用 tailscale set（避免 --reset 触发重新登录、丢宣告路由）
# 用法: luci-apply-up.sh [--dry-run]

CONFIG_DIR="/etc/tailscale"
UP_CONF="$CONFIG_DIR/tailscale_up.conf"
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

ts_cli_base() {
	local sock=""
	sock=$(resolve_ts_socket || true)
	if [ -n "$sock" ]; then
		echo "$TS_BIN --socket=$sock"
	else
		echo "$TS_BIN"
	fi
}

ts_backend_state() {
	local ts_cmd="$1"
	local json state=""
	json=$($ts_cmd status --json 2>/dev/null)
	[ -z "$json" ] && return 0

	# tailscale status --json 为美化输出（冒号后带空格），需兼容空格
	if command -v jsonfilter >/dev/null 2>&1; then
		state=$(echo "$json" | jsonfilter -e '@.BackendState' 2>/dev/null)
	fi
	[ -z "$state" ] && state=$(echo "$json" \
		| grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
		| head -n1 \
		| sed 's/.*"BackendState"[[:space:]]*:[[:space:]]*"//; s/"$//')
	echo "$state"
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
		--advertise-exit-node|--ssh|--shields-up|--snat-subnet-routes|--exit-node-allow-lan-access)
			case "$val" in
				false|False|0|"") return 0 ;;
			esac
			;;
	esac
	return 1
}

build_apply_cmd() {
	local mode="$1"
	local prefix cmd line key val

	case "$mode" in
		set) prefix="tailscale set" ;;
		*) prefix="tailscale up --reset" ;;
	esac

	cmd="$prefix"
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
	local ts_cmd
	ts_cmd=$(ts_cli_base)

	[ -z "$expected" ] && return 0

	prefs=$($ts_cmd debug prefs 2>/dev/null) || prefs=""

	# 逐条校验（debug prefs 中每个子网单独成行/入数组，不能整串匹配）
	local missing=0 r
	local old_ifs="$IFS"
	IFS=','
	for r in $expected; do
		r=$(echo "$r" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -z "$r" ] && continue
		echo "$prefs" | grep -F "$r" >/dev/null 2>&1 || missing=1
	done
	IFS="$old_ifs"

	if [ "$missing" -eq 0 ]; then
		log_info "✅  已宣告子网: $expected"
		log_info "ℹ️  请在 Tailscale 控制台 Machines → 本机 → Subnets 中批准该路由"
		return 0
	fi

	log_warn "⚠️  配置含 --advertise-routes=$expected，但 tailscale 尚未生效"
	if echo "$prefs" | grep -i AdvertiseRoutes >/dev/null 2>&1; then
		log_warn "⚠️  当前 AdvertiseRoutes: $(echo "$prefs" | grep -i AdvertiseRoutes | head -n1)"
	fi
	log_warn "⚠️  若 debug prefs 为 null，请先 tailscale status 确认已登录，再重试"
	return 1
}

TS_CMD=$(ts_cli_base)
STATE=$(ts_backend_state "$TS_CMD")
APPLY_MODE="up"
case "$STATE" in
	Running|Starting) APPLY_MODE="set" ;;
esac

cmd=$(build_apply_cmd "$APPLY_MODE")
if [ -z "$cmd" ] || [ "$cmd" = "tailscale up" ] || [ "$cmd" = "tailscale up --reset" ] || [ "$cmd" = "tailscale set" ]; then
	log_error "❌  tailscale_up.conf 中无有效参数"
	exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
	echo "$cmd"
	exit 0
fi

cmd=$(echo "$cmd" | sed "s|^tailscale |$TS_CMD |")

if [ "$APPLY_MODE" = "set" ]; then
	log_info "ℹ️  已登录 (${STATE})，使用 tailscale set 应用配置（不 --reset）"
else
	log_info "ℹ️  尚未登录 (${STATE:-unknown})，使用 tailscale up --reset"
fi
log_info "🚀  正在执行: $cmd"

# 捕获执行输出到变量，避免与调用方的日志重定向指向同一文件而产生
# `cat file >> file` 式的无限增长（后台包装脚本会把本脚本 stdout 重定向到日志）。
# shellcheck disable=SC2086
ts_out=$(eval "$cmd" 2>&1)
rc=$?

[ -n "$ts_out" ] && printf '%s\n' "$ts_out"

if printf '%s' "$ts_out" | grep -qi 'To authenticate, visit' 2>/dev/null; then
	log_warn "⚠️  输出含登录链接：请先完成 Tailscale 登录，再保存并应用连接设置"
fi

if [ "$rc" -ne 0 ]; then
	log_error "❌  tailscale 应用失败 (exit $rc)"
	if printf '%s' "$ts_out" | grep -q 'non-default flags' 2>/dev/null; then
		log_error "❌  本地已有非默认参数且与命令不一致，请确认已部署最新 luci-apply-up.sh"
	fi
	exit "$rc"
fi

expected_routes=$(get_conf_advertise_routes)
if [ -n "$expected_routes" ]; then
	verify_advertise_routes "$expected_routes" || exit 2
fi

exit 0
