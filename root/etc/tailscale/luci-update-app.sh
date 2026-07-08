#!/bin/sh
# 从 GitHub Release 下载并覆盖安装 luci-app-tailscale ipk
# 用法: luci-update-app.sh luci-v1.0.0

set -eu
set -o pipefail 2>/dev/null || true

TAG="${1:-}"
[ -n "$TAG" ] || { echo "缺少 Release 标签（如 luci-v1.0.0）" >&2; exit 1; }

. /etc/tailscale/tools.sh || exit 1

REPO="${GITHUB_RELEASE_REPO:-01BAI/luci-app-tailscale}"
TMP_DIR="/tmp/luci-app-update.$$"
JSON="$TMP_DIR/release.json"
BUILTIN_MIRRORS="https://ghfast.top/ https://ghproxy.net/ https://gh-proxy.com/"
SCRIPT_REV="2026.07.07-1"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP_DIR"

command -v curl >/dev/null 2>&1 || { log_error "❌  curl 不可用"; exit 1; }
command -v opkg >/dev/null 2>&1 || { log_error "❌  opkg 不可用"; exit 1; }

case "$TAG" in
	luci-v*) VER="${TAG#luci-v}" ;;
	*) log_error "❌  无效标签: $TAG"; exit 1 ;;
esac

curl_fetch() {
	curl -fsSL --http1.1 --globoff --connect-timeout 20 --max-time 120 \
		-A "luci-app-tailscale-update/${SCRIPT_REV}" "$1" -o "$2" 2>/dev/null
}

curl_probe() {
	curl -fsSL --http1.1 --globoff --connect-timeout 15 --max-time 30 \
		-A "luci-app-tailscale-update/${SCRIPT_REV}" \
		-r 0-0 "$1" -o /dev/null 2>/dev/null
}

list_mirror_prefixes() {
	if [ -f "$CONFIG_DIR/proxies.txt" ]; then
		while read -r mirror; do
			mirror=$(echo "$mirror" | sed 's|#.*||; s/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -z "$mirror" ] && continue
			echo "$mirror" | sed 's|/*$|/|'
		done < "$CONFIG_DIR/proxies.txt"
	fi
	for mirror in $BUILTIN_MIRRORS; do
		echo "$mirror"
	done
}

curl_download() {
	local url="$1"
	local out="$2"
	local github_path mirror

	if curl -fsSL --http1.1 --globoff --connect-timeout 60 --max-time 300 \
		-A "luci-app-tailscale-update/${SCRIPT_REV}" \
		"$url" -o "$out" 2>/dev/null; then
		return 0
	fi

	case "$url" in
		https://github.com/*) github_path="${url#https://github.com/}" ;;
		*) return 1 ;;
	esac

	for mirror in $(list_mirror_prefixes); do
		log_warn "⚠️  直连下载失败，尝试镜像: ${mirror}"
		if curl -fsSL --http1.1 --globoff --connect-timeout 60 --max-time 300 \
			-A "luci-app-tailscale-update/${SCRIPT_REV}" \
			"${mirror}https://github.com/${github_path}" -o "$out" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

fetch_release_json() {
	local api_path="repos/${REPO}/releases/tags/${TAG}"
	local mirror url

	if curl_fetch "https://api.github.com/${api_path}" "$JSON"; then
		return 0
	fi

	for mirror in $(list_mirror_prefixes); do
		url="${mirror}https://api.github.com/${api_path}"
		if curl_fetch "$url" "$JSON"; then
			return 0
		fi
	done
	return 1
}

extract_latest_asset() {
	local url=""

	[ -s "$JSON" ] || return 1

	url=$(grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*luci-app-tailscale_[^"]*"' "$JSON" \
		| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
		| sort -V | tail -n1)

	[ -n "$url" ] || return 1
	echo "$url"
}

try_direct_ipk() {
	local mirror_prefix="${1:-}"
	local r path url

	for r in 1 2 3 4 5; do
		path="${REPO}/releases/download/${TAG}/luci-app-tailscale_${VER}-r${r}_all.ipk"
		url="${mirror_prefix}https://github.com/${path}"
		if curl_probe "$url"; then
			echo "$url"
			return 0
		fi
	done
	return 1
}

resolve_ipk_url() {
	local url mirror

	if fetch_release_json; then
		url=$(extract_latest_asset || true)
		[ -n "$url" ] && { echo "$url"; return 0; }
	fi

	url=$(try_direct_ipk "" || true)
	[ -n "$url" ] && { echo "$url"; return 0; }

	for mirror in $(list_mirror_prefixes); do
		url=$(try_direct_ipk "$mirror" || true)
		[ -n "$url" ] && { echo "$url"; return 0; }
	done

	log_error "❌  无法解析 ipk 下载地址（${TAG}）"
	return 1
}

MAIN_URL=$(resolve_ipk_url) || exit 1
MAIN_IPK="$TMP_DIR/$(basename "$MAIN_URL")"

log_info "📦  下载插件: $(basename "$MAIN_IPK")"
curl_download "$MAIN_URL" "$MAIN_IPK" || { log_error "❌  下载失败（已尝试 HTTP/1.1 与镜像）"; exit 1; }

log_info "📦  安装 ipk..."
if ! opkg install --force-reinstall "$MAIN_IPK" 2>/dev/null; then
	opkg remove luci-app-tailscale 2>/dev/null || true
	opkg install "$MAIN_IPK" || { log_error "❌  ipk 安装失败"; exit 1; }
fi

# 仅重启 rpcd 加载新后端；勿重启 uhttpd，否则会断开 LuCI 登录会话
/etc/init.d/rpcd restart 2>/dev/null || true

log_info "✅  插件已更新至 ${TAG}"
log_info "ℹ️  请在 LuCI 页面点击「刷新页面」或 Ctrl+F5 加载新界面"
echo "OK"
