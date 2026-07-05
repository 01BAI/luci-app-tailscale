#!/usr/bin/env bash
# 将 LuCI 包文件直接同步到 OpenWrt 路由器，便于开发调试（无需每次编译 ipk）。
# 使用 tar + ssh，不依赖路由器上的 rsync。
# 注意：用户配置文件（conffiles）不会被覆盖，避免热部署清空 LuCI 已保存的设置。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="${1:-root@192.168.1.1}"

bash "${ROOT_DIR}/scripts/sync-version.sh"
LUCID_VER="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"

# 与 Makefile conffiles 一致：部署时不覆盖路由器上已有配置
DEPLOY_CONFFILE_EXCLUDES=(
	'./etc/config/tailscale'
	'./etc/tailscale/install.conf'
	'./etc/tailscale/tailscale_up.conf'
	'./etc/tailscale/release.conf'
	'./etc/tailscale/proxies.txt'
	'./etc/tailscale/proxy.env'
)

TAR_EXCLUDE_ARGS=()
for _path in "${DEPLOY_CONFFILE_EXCLUDES[@]}"; do
	TAR_EXCLUDE_ARGS+=(--exclude="$_path")
done

echo "部署到 ${ROUTER} （LuCI 插件 v${LUCID_VER}）..."
echo "→ 同步 root/ 到 /（跳过用户配置文件，保留路由器上的 tailscale_up.conf 等）"

tar -C "${ROOT_DIR}/root" -czf - "${TAR_EXCLUDE_ARGS[@]}" . | ssh "${ROUTER}" "mkdir -p / && tar -xzf - -C /"

echo "→ 同步 htdocs/ 到 /www/"
ssh "${ROUTER}" "mkdir -p /www"
tar -C "${ROOT_DIR}/htdocs" -czf - . | ssh "${ROUTER}" "tar -xzf - -C /www"

ssh "${ROUTER}" <<'EOF'
# 首次部署时写入默认 tailscale_up.conf（若不存在）
if [ ! -f /etc/tailscale/tailscale_up.conf ]; then
	mkdir -p /etc/tailscale
	cat > /etc/tailscale/tailscale_up.conf <<'CONF'
# tailscale up 参数，由 LuCI 管理
# 格式: --参数名="值"
--accept-routes="false"
--netfilter-mode="nodivert"
CONF
fi

chmod +x /etc/tailscale/*.sh 2>/dev/null || true
rm -rf /tmp/luci-*cache* 2>/dev/null || true
/etc/init.d/rpcd restart
sleep 1
/etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/nginx restart 2>/dev/null || true
echo "部署完成。LuCI: VPN -> Tailscale"
echo "用户配置保留: /etc/tailscale/tailscale_up.conf"
grep -m1 'UI_REV' /www/luci-static/resources/view/tailscale/overview.js 2>/dev/null || true
cat /etc/tailscale/luci-app.version 2>/dev/null | sed 's/^/LuCI 插件版本: /' || true
echo "如状态仍异常，请在路由器执行: ubus call tailscale get_overview"
EOF
