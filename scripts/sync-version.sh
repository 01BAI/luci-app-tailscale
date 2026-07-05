#!/usr/bin/env bash
# 以仓库根目录 VERSION 为唯一来源，同步到 luci-app.version 与 overview.js UI_REV。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"

if [ -z "$VER" ]; then
	echo "VERSION 文件为空" >&2
	exit 1
fi

echo "$VER" > "$ROOT_DIR/root/etc/tailscale/luci-app.version"

OVERVIEW_JS="$ROOT_DIR/htdocs/luci-static/resources/view/tailscale/overview.js"
if [ -f "$OVERVIEW_JS" ]; then
	if sed --version >/dev/null 2>&1; then
		sed -i "s/const UI_REV = '[^']*'/const UI_REV = '${VER}'/" "$OVERVIEW_JS"
	else
		sed -i '' "s/const UI_REV = '[^']*'/const UI_REV = '${VER}'/" "$OVERVIEW_JS"
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

echo "已同步 LuCI 插件版本: ${VER}（install-luci-app.sh → luci-v${VER}）"
