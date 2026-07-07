#!/usr/bin/env bash
# 以 VERSION + BUILD 为来源，同步 luci-app.version 与 overview.js UI_REV。
# 完整版本示例: 1.0.1 build26070701  →  v1.0.1 build26070701
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD" 2>/dev/null || true)"

if [ -z "$VER" ]; then
	echo "VERSION 文件为空" >&2
	exit 1
fi

FULL_VER="$VER"
[ -n "$BUILD" ] && FULL_VER="${VER} build${BUILD}"

echo "$FULL_VER" > "$ROOT_DIR/root/etc/tailscale/luci-app.version"

OVERVIEW_JS="$ROOT_DIR/htdocs/luci-static/resources/view/tailscale/overview.js"
if [ -f "$OVERVIEW_JS" ]; then
	# FULL_VER 可能含空格，用 | 作 sed 分隔符
	if sed --version >/dev/null 2>&1; then
		sed -i "s|const UI_REV = '[^']*'|const UI_REV = '${FULL_VER}'|" "$OVERVIEW_JS"
	else
		sed -i '' "s|const UI_REV = '[^']*'|const UI_REV = '${FULL_VER}'|" "$OVERVIEW_JS"
	fi
fi

INSTALL_SH="$ROOT_DIR/scripts/install-luci-app.sh"
if [ -f "$INSTALL_SH" ]; then
	if sed --version >/dev/null 2>&1; then
		sed -i "s/^TAG=\"luci-v[^\"]*\"/TAG=\"luci-v${VER}\"/" "$INSTALL_SH"
	else
		sed -i '' "s/^TAG=\"luci-v[^\"]*\"/TAG=\"luci-v${VER}\"/" "$INSTALL_SH"
	fi
fi

echo "已同步 LuCI 插件版本: ${FULL_VER}（Release 标签 luci-v${VER}，PKG_RELEASE=${BUILD:-1}）"
