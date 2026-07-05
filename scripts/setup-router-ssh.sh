#!/bin/sh
# 将本机 SSH 公钥写入 OpenWrt/iStoreOS，便于 Cursor Agent 免密访问。
# 用法: ./scripts/setup-router-ssh.sh [root@192.168.99.254]

set -eu

ROUTER="${1:-root@192.168.99.254}"
PUB="${HOME}/.ssh/id_ed25519.pub"

if [ ! -f "$PUB" ]; then
	echo "未找到 $PUB，请先生成: ssh-keygen -t ed25519" >&2
	exit 1
fi

echo "目标: $ROUTER"
echo "公钥: $PUB"
echo ""
echo "请输入路由器 root 密码（仅需一次）..."
ssh "$ROUTER" "mkdir -p /etc/dropbear && chmod 700 /etc/dropbear && touch /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys && grep -Fq '$(cat "$PUB")' /etc/dropbear/authorized_keys || echo '$(cat "$PUB")' >> /etc/dropbear/authorized_keys"

echo ""
echo "测试免密登录..."
ssh -o BatchMode=yes "$ROUTER" 'echo SSH OK; uname -a'
