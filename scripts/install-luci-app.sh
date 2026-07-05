#!/bin/sh
# 在 OpenWrt / iStoreOS 上一键安装 luci-app-tailscale（从 GitHub Release 下载 ipk）
#
# 用法（路由器上）：
#   curl -fsSL https://raw.githubusercontent.com/01BAI/luci-app-tailscale/main/scripts/install-luci-app.sh | sh
#
# 可选参数：
#   --repo=用户/仓库        默认 01BAI/luci-app-tailscale
#   --tag=luci-v1.0.0       默认正式版；开发版可用 luci-latest
#
# 安装完成后：LuCI → VPN → Tailscale → 点击安装 Tailscale 二进制

set -eu
set -o pipefail 2>/dev/null || true

REPO="01BAI/luci-app-tailscale"
TAG="luci-v1.0.1"
PKG_NAME="luci-app-tailscale"
TMP_DIR="/tmp/luci-app-tailscale-install.$$"

log() { echo "[install-luci-app] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

SCRIPT_REV="2026.07.05-6"

while [ $# -gt 0 ]; do
	case "$1" in
		--repo=*) REPO="${1#*=}"; shift ;;
		--tag=*) TAG="${1#*=}"; shift ;;
		-h|--help)
			sed -n '2,11p' "$0"
			exit 0
			;;
		*) die "未知参数: $1（可用 --help）" ;;
	esac
done

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM
mkdir -p "$TMP_DIR"

# ---------- 包管理器 ----------
PKG_MGR=""
if command -v opkg >/dev/null 2>&1; then
	PKG_MGR="opkg"
elif command -v apk >/dev/null 2>&1; then
	PKG_MGR="apk"
else
	die "未找到 opkg 或 apk，当前系统可能不是 OpenWrt"
fi

pkg_install() {
	case "$PKG_MGR" in
		opkg) opkg install "$@" ;;
		apk) apk add "$@" ;;
	esac
}

pkg_install_ipk() {
	case "$PKG_MGR" in
		opkg) opkg install "$@" ;;
		apk) apk add --allow-untrusted "$@" ;;
	esac
}

opkg_installed() {
	opkg list-installed 2>/dev/null | grep -qE "^${1}([0-9-]|$)"
}

opkg_pkg_installed() {
	opkg list-installed 2>/dev/null | grep -q "^${1} "
}

opkg_has_libustream() {
	if opkg list-installed 2>/dev/null | grep -q 'libustream-mbedtls'; then
		return 0
	fi
	if opkg list-installed 2>/dev/null | grep -q 'libustream-openssl'; then
		return 0
	fi
	if [ -f /lib/libustream-ssl.so ]; then
		return 0
	fi
	return 1
}

apk_installed() {
	apk info -e "$1" >/dev/null 2>&1
}

# ---------- 依赖（已存在则跳过） ----------
log "更新软件源..."
case "$PKG_MGR" in
	opkg) opkg update >/dev/null 2>&1 || log "WARN: opkg update 失败，继续尝试安装..." ;;
	apk) apk update >/dev/null 2>&1 || log "WARN: apk update 失败，继续尝试安装..." ;;
esac

DEPS="curl ca-bundle kmod-tun"
if [ "$PKG_MGR" = "opkg" ]; then
	if ! opkg_has_libustream; then
		DEPS="libustream-openssl $DEPS"
	fi
elif [ "$PKG_MGR" = "apk" ]; then
	DEPS="ca-certificates $DEPS"
fi

for pkg in $DEPS; do
	if [ "$PKG_MGR" = "opkg" ]; then
		if [ "$pkg" = "libustream-openssl" ] && opkg_has_libustream; then
			log "依赖已满足，跳过: libustream"
			continue
		fi
		if opkg_installed "$pkg"; then
			log "依赖已安装，跳过: $pkg"
			continue
		fi
	elif [ "$PKG_MGR" = "apk" ]; then
		if apk_installed "$pkg"; then
			log "依赖已安装，跳过: $pkg"
			continue
		fi
	fi

	log "安装依赖: $pkg"
	pkg_install "$pkg" || die "依赖 $pkg 安装失败"
done

log "install-luci-app.sh rev ${SCRIPT_REV}"

command -v curl >/dev/null 2>&1 || die "curl 不可用"

# ---------- 下载 Release 资产 ----------
JSON="$TMP_DIR/release.json"
BUILTIN_API_MIRRORS="https://ghfast.top/ https://ghproxy.net/ https://gh-proxy.com/"

curl_fetch() {
	local url="$1"
	local out="$2"
	curl -fsSL --globoff --connect-timeout 20 --max-time 90 \
		-A "luci-app-tailscale-install/${SCRIPT_REV}" \
		-H "Accept: application/vnd.github+json" \
		"$url" -o "$out" 2>/dev/null
}

url_looks_valid() {
	case "$1" in
		http://*|https://*) return 0 ;;
	esac
	return 1
}

# 正式版 tag luci-v1.0.0 → 尝试已知 ipk 命名，无需 GitHub API
try_direct_tag_ipk_urls() {
	local mirror_prefix="${1:-}"
	local ver r path url

	case "$TAG" in
		luci-v*) ver="${TAG#luci-v}" ;;
		*) return 1 ;;
	esac

	for r in 1 2 3 4 5; do
		path="${REPO}/releases/download/${TAG}/luci-app-tailscale_${ver}-r${r}_all.ipk"
		url="${mirror_prefix}https://github.com/${path}"
		if curl -fsSL --globoff --connect-timeout 15 --max-time 30 \
			-A "luci-app-tailscale-install/${SCRIPT_REV}" \
			-r 0-0 "$url" -o /dev/null 2>/dev/null; then
			echo "$url"
			return 0
		fi
	done
	return 1
}

fetch_release_json() {
	local api_path="repos/${REPO}/releases/tags/${TAG}"
	local mirror trimmed url tried=0

	log "获取 Release: ${REPO} @ ${TAG}"

	if curl_fetch "https://api.github.com/${api_path}" "$JSON"; then
		return 0
	fi
	log "WARN: GitHub API 直连失败（可能 403 限流），尝试镜像..."

	if [ -f /etc/tailscale/proxies.txt ]; then
		while read -r mirror; do
			mirror=$(echo "$mirror" | sed 's|#.*||; s/^[[:space:]]*//; s/[[:space:]]*$//')
			[ -z "$mirror" ] && continue
			mirror=$(echo "$mirror" | sed 's|/*$|/|')
			url="${mirror}https://api.github.com/${api_path}"
			log "尝试 API 镜像: $url"
			if curl_fetch "$url" "$JSON"; then
				return 0
			fi
			tried=$((tried + 1))
			[ "$tried" -ge 3 ] && break
		done < /etc/tailscale/proxies.txt
	fi

	for mirror in $BUILTIN_API_MIRRORS; do
		url="${mirror}https://api.github.com/${api_path}"
		log "尝试 API 镜像: $url"
		if curl_fetch "$url" "$JSON"; then
			return 0
		fi
	done

	return 1
}

extract_latest_asset() {
	local prefix="$1"
	local url=""

	[ -s "$JSON" ] || return 1

	# 优先 grep（OpenWrt jq 常缺正则库）
	url=$(grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*'"${prefix}"'[^"]*"' "$JSON" \
		| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
		| sort -V | tail -n1)

	if [ -z "$url" ] && command -v jq >/dev/null 2>&1; then
		url=$(jq -r --arg p "$prefix" '
			[.assets[]? | select(.name | startswith($p)) | .browser_download_url]
			| sort | last // empty
		' "$JSON" 2>/dev/null)
	fi

	[ -n "$url" ] || return 1
	echo "$url"
}

scrape_ipk_url_from_release_page() {
	local mirror_prefix="${1:-}"
	local page html rel

	page="${mirror_prefix}https://github.com/${REPO}/releases/expanded_assets/${TAG}"
	html="$TMP_DIR/release_page.html"

	curl -fsSL --globoff --connect-timeout 20 --max-time 90 \
		-A "luci-app-tailscale-install/${SCRIPT_REV}" \
		"$page" -o "$html" 2>/dev/null || return 1

	rel=$(grep -oE 'href="/[^"]+/releases/download/[^"]+luci-app-tailscale_[^"]+\.ipk"' "$html" \
		| sed 's/href="//;s/"$//' | sort -V | tail -n1)
	[ -n "$rel" ] || return 1

	if [ -n "$mirror_prefix" ]; then
		echo "${mirror_prefix}https://github.com${rel}"
	else
		echo "https://github.com${rel}"
	fi
}

resolve_main_ipk_url() {
	local url="" mirror

	# 1. 正式版 tag：直连 github.com 下载（不走 API，避免 403 限流）
	url=$(try_direct_tag_ipk_urls "" || true)
	if url_looks_valid "$url"; then
		log "使用 Release 直链: $(basename "$url")"
		echo "$url"
		return 0
	fi

	# 2. GitHub API（含镜像）
	if fetch_release_json; then
		url=$(extract_latest_asset "luci-app-tailscale_" || true)
	fi
	if url_looks_valid "$url"; then
		echo "$url"
		return 0
	fi

	# 3. Release 页面解析
	if [ -z "$url" ]; then
		log "WARN: API 不可用，尝试 GitHub Release 页面解析 ipk..."
		url=$(scrape_ipk_url_from_release_page "" || true)
	fi
	if url_looks_valid "$url"; then
		echo "$url"
		return 0
	fi

	# 4. 镜像：直链 → 页面
	for mirror in $BUILTIN_API_MIRRORS; do
		url=$(try_direct_tag_ipk_urls "$mirror" || true)
		if url_looks_valid "$url"; then
			log "使用镜像直链: $(basename "$url")"
			echo "$url"
			return 0
		fi
		log "尝试 Release 页面镜像: ${mirror}https://github.com/..."
		url=$(scrape_ipk_url_from_release_page "$mirror" || true)
		if url_looks_valid "$url"; then
			echo "$url"
			return 0
		fi
	done

	die "无法获取 Release / ipk 下载地址，请检查 --repo / --tag 或网络"
}

MAIN_URL=$(resolve_main_ipk_url)
url_looks_valid "$MAIN_URL" || die "解析到的下载地址无效"

MAIN_IPK="$TMP_DIR/$(basename "$MAIN_URL")"
log "下载: $(basename "$MAIN_IPK") ..."
curl -fsSL --globoff --connect-timeout 60 --max-time 300 \
	-A "luci-app-tailscale-install/${SCRIPT_REV}" \
	"$MAIN_URL" -o "$MAIN_IPK" \
	|| die "主包下载失败"

# ---------- 安装 / 覆盖 ipk ----------
case "$PKG_MGR" in
	opkg)
		if opkg_pkg_installed "$PKG_NAME"; then
			old_ver=$(opkg list-installed "$PKG_NAME" 2>/dev/null | awk '{print $3}')
			log "已安装 ${PKG_NAME} ${old_ver:-}，将覆盖为最新 ipk ..."
		fi
		if ! opkg install --force-reinstall "$MAIN_IPK" 2>/dev/null; then
			if opkg_pkg_installed "$PKG_NAME"; then
				log "force-reinstall 不可用，先卸载再安装 ..."
				opkg remove "$PKG_NAME" || die "卸载旧版 ${PKG_NAME} 失败"
			fi
			pkg_install_ipk "$MAIN_IPK" || die "${PKG_NAME} 安装失败"
		fi
		;;
	apk)
		if apk_installed "$PKG_NAME"; then
			log "已安装 ${PKG_NAME}，将覆盖为最新 ipk ..."
		fi
		apk add --allow-untrusted --force-overwrite "$MAIN_IPK" \
			|| die "${PKG_NAME} 安装失败"
		;;
esac

/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/nginx restart 2>/dev/null || true

log "完成。"
log ""
log "下一步："
log "  1. 浏览器打开 LuCI → VPN → Tailscale（建议 Ctrl+Shift+R 强制刷新）"
log "  2. 点击「安装 Tailscale」安装 tailscaled 二进制（需 Release 中有对应架构）"
log "  3. 登录并完成 tailscale up 设置"
log ""
log "Release 标签: ${TAG}  仓库: ${REPO}  ipk: $(basename "$MAIN_IPK")"
