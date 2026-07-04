#!/bin/sh
# 简化版定时任务：仅配置 autoupdate，不依赖 test_mirrors.sh

set -e

AUTO_UPDATE="${1:-false}"

. /etc/tailscale/tools.sh || exit 1

if [ -f /etc/crontabs/root ]; then
	sed -i "\|$CONFIG_DIR/autoupdate.sh|d" /etc/crontabs/root 2>/dev/null || true
fi

if [ "$AUTO_UPDATE" != "true" ]; then
	/etc/init.d/cron restart 2>/dev/null || true
	exit 0
fi

RANDOM_HOUR=$((4 + $(awk -v seed=$(date +%s) 'BEGIN{srand(seed); print int(rand()*3)}')))
RANDOM_MIN=$(awk -v seed=$(date +%s) 'BEGIN{srand(seed+1000); print int(rand()*60)}')

echo "$RANDOM_MIN $RANDOM_HOUR * * * $CONFIG_DIR/autoupdate.sh" >> /etc/crontabs/root
/etc/init.d/cron restart 2>/dev/null || true
