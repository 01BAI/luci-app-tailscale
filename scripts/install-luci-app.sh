#!/bin/sh
# 在 OpenWrt / iStoreOS 上一键安装 luci-app-tailscale（从 GitHub Release 下载 ipk）
#
# 用法（路由器上）：
#   curl -fsSL https://github.com/01BAI/luci-app-tailscale/raw/main/scripts/install-luci-app.sh | sh
#
# 可选参数：
#   --repo=用户/仓库        默认 01BAI/luci-app-tailscale
#   --tag=luci-latest       Release 标签，正式版可用 luci-v1.0.0
#
# 安装完成后：LuCI → VPN → Tailscale → 点击安装 Tailscale 二进制

set -eu
set -o pipefail 2>/dev/null || true

REPO="01BAI/luci-app-tailscale"
TAG="luci-latest"
TMP_DIR="/tmp/luci-app-tailscale-install.$$"

log() { echo "[install-luci-app] $*"; }
die() { log "ERROR: $*"; exit 1; }

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

# ---------- 依赖 ----------
log "更新软件源..."
case "$PKG_MGR" in
	opkg) opkg update >/dev/null 2>&1 || log "WARN: opkg update 失败，继续尝试安装..." ;;
	apk) apk update >/dev/null 2>&1 || log "WARN: apk update 失败，继续尝试安装..." ;;
esac

DEPS="curl ca-bundle kmod-tun"
if [ "$PKG_MGR" = "opkg" ]; then
	if ! opkg list-installed 2>/dev/null | grep -qE '^libustream-(openssl|mbedtls)'; then
		DEPS="libustream-openssl $DEPS"
	fi
elif [ "$PKG_MGR" = "apk" ]; then
	DEPS="ca-certificates $DEPS"
fi

for pkg in $DEPS; do
	if ! command -v "${pkg%%-*}" >/dev/null 2>&1 && \
	   ! opkg list-installed 2>/dev/null | grep -q "^${pkg} " && \
	   ! apk info -e "$pkg" >/dev/null 2>&1; then
		log "安装依赖: $pkg"
		pkg_install "$pkg" || die "依赖 $pkg 安装失败"
	fi
done

command -v curl >/dev/null 2>&1 || die "curl 不可用"

# ---------- 下载 Release 资产 ----------
API="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
JSON="$TMP_DIR/release.json"

log "获取 Release: ${REPO} @ ${TAG}"
if ! curl -fsSL --connect-timeout 20 -A "luci-app-tailscale-install" "$API" -o "$JSON"; then
	die "无法获取 Release 信息，请检查 --repo / --tag 或网络"
fi

extract_asset() {
	local pattern="$1"
	local url=""

	if command -v jq >/dev/null 2>&1; then
		url=$(jq -r --arg p "$pattern" '.assets[] | select(.name | contains($p)) | .browser_download_url' "$JSON" | head -n1)
	else
		url=$(grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' "$JSON" \
			| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
			| grep "$pattern" | head -n1)
	fi

	[ -n "$url" ] || return 1
	echo "$url"
}

MAIN_URL=$(extract_asset "luci-app-tailscale_" || true)
[ -n "$MAIN_URL" ] || die "Release 中未找到 luci-app-tailscale_*.ipk，请先确认 GitHub Actions 已发布 ${TAG}"

MAIN_IPK="$TMP_DIR/$(basename "$MAIN_URL")"
log "下载 $(basename "$MAIN_IPK") ..."
curl -fsSL --connect-timeout 60 -A "luci-app-tailscale-install" "$MAIN_URL" -o "$MAIN_IPK" \
	|| die "主包下载失败"

# ---------- 安装 ipk ----------
log "安装 luci-app-tailscale ..."
pkg_install_ipk "$MAIN_IPK" || die "luci-app-tailscale 安装失败"

/etc/init.d/rpcd restart 2>/dev/null || true

log "完成。"
log ""
log "下一步："
log "  1. 浏览器打开 LuCI → VPN → Tailscale"
log "  2. 点击「安装 Tailscale」安装 tailscaled 二进制（需 Release 中有对应架构）"
log "  3. 登录并完成 tailscale up 设置"
log ""
log "Release 标签: ${TAG}  仓库: ${REPO}"
