#!/usr/bin/env bash
# 将 LuCI 包文件直接同步到 OpenWrt 路由器，便于开发调试（无需每次编译 ipk）。
# 使用 tar + ssh，不依赖路由器上的 rsync。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="${1:-root@192.168.1.1}"

echo "部署到 ${ROUTER} ..."

echo "→ 同步 root/ 到 /"
tar -C "${ROOT_DIR}/root" -czf - . | ssh "${ROUTER}" "mkdir -p / && tar -xzf - -C /"

echo "→ 同步 htdocs/ 到 /www/"
ssh "${ROUTER}" "mkdir -p /www"
tar -C "${ROOT_DIR}/htdocs" -czf - . | ssh "${ROUTER}" "tar -xzf - -C /www"

ssh "${ROUTER}" <<'EOF'
chmod +x /etc/tailscale/*.sh 2>/dev/null || true
/etc/init.d/rpcd restart
sleep 1
/etc/init.d/uhttpd restart 2>/dev/null || /etc/init.d/nginx restart 2>/dev/null || true
echo "部署完成。LuCI: VPN -> Tailscale"
echo "如状态仍异常，请在路由器执行: ubus call tailscale get_overview"
EOF
