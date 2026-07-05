#!/bin/sh
set -e
[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

log_info "🛠️  生成 Tailscale 服务..."
cat > /etc/init.d/tailscale <<"EOF"
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=90
STOP=1

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

start_tailscaled() {
  local bin_path=$1
  $bin_path --cleanup > /dev/null 2>&1
  procd_open_instance 
  procd_set_param name tailscale
  procd_set_param env TS_DEBUG_FIREWALL_MODE=auto
  procd_set_param command $bin_path
  procd_append_param command --port 41641
  procd_append_param command --state /etc/config/tailscaled.state
  procd_set_param respawn
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}

start_service() {
  log_info "🛠️  启动 Tailscale..."
  if [ ! -x /usr/bin/tailscaled ]; then
    log_error "❌  未找到 /usr/bin/tailscaled，请先安装 Tailscale"
    return 1
  fi

  start_tailscaled /usr/bin/tailscaled
  schedule_apply_up
}

stop_service() {
  log_info "🛑  停止服务..."
  [ -x "/usr/local/bin/tailscaled" ] && /usr/local/bin/tailscaled --cleanup >/dev/null 2>&1 || true

  if pgrep tailscaled >/dev/null 2>&1; then
    killall tailscaled >/dev/null 2>&1 || log_warn "⚠️  未能停止 tailscaled 服务"
  else
    log_info "✅  tailscaled 已停止"
  fi
}

schedule_apply_up() {
  [ "$TS_SKIP_APPLY_UP" = "1" ] && return 0
  [ -x "$CONFIG_DIR/luci-apply-up.sh" ] || return 0
  (
    sleep 2
    TS_BIN=$(command -v tailscale 2>/dev/null) || TS_BIN="/usr/bin/tailscale"
    TS_CMD="$TS_BIN"
    for s in /var/run/tailscale/tailscaled.sock /tmp/tailscaled.sock; do
      [ -S "$s" ] && TS_CMD="$TS_BIN --socket=$s" && break
    done
    state=$($TS_CMD status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | head -n1 | sed 's/.*:"//;s/"$//')
    case "$state" in
      Running|Starting)
        "$CONFIG_DIR/luci-apply-up.sh"
        ;;
      *)
        log_info "ℹ️  尚未登录，跳过自动 tailscale up（请在 LuCI 点击登录）"
        ;;
    esac
  ) >>/tmp/tailscale_boot_apply.log 2>&1 &
}
EOF

chmod +x /etc/init.d/tailscale

if [ -x "$CONFIG_DIR/luci-setup-cron.sh" ]; then
	"$CONFIG_DIR/luci-setup-cron.sh" false || log_warn "⚠️  清除 autoupdate 定时任务失败"
fi

if [ "$TS_REGEN_ONLY" = "1" ]; then
	log_info "✅ init.d 已更新（TS_REGEN_ONLY，未重启服务）"
	exit 0
fi

log_info "🛠️  启用 Tailscale 服务..."
/etc/init.d/tailscale enable || { log_error "❌  启用服务失败"; exit 1; }

log_info "🛠️  启动服务..."
/etc/init.d/tailscale restart || { log_error "❌  重启服务失败, 将启动服务"; /etc/init.d/tailscale start > /dev/null 2>&1; }

log_info "🎉  Tailscale 服务已启动!"

if [ -x "$CONFIG_DIR/setup-firewall-lan.sh" ]; then
	"$CONFIG_DIR/setup-firewall-lan.sh" || log_warn "⚠️  LAN/Tailscale 防火墙配置未完成（可稍后手动执行 setup-firewall-lan.sh）"
fi
