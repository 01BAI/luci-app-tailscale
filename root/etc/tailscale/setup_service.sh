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
  log_info "🛠️  检测更新, 日志: /tmp/tailscale_update.log"
  "$CONFIG_DIR/autoupdate.sh" 2>&1 | tee -a /tmp/tailscale_update.log
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
  [ -x "$CONFIG_DIR/luci-apply-up.sh" ] && ( sleep 2; "$CONFIG_DIR/luci-apply-up.sh" ) &
}
EOF

chmod +x /etc/init.d/tailscale

log_info "🛠️  启用 Tailscale 服务..."
/etc/init.d/tailscale enable || { log_error "❌  启用服务失败"; exit 1; }

log_info "🛠️  启动服务..."
/etc/init.d/tailscale restart || { log_error "❌  重启服务失败, 将启动服务"; /etc/init.d/tailscale start > /dev/null 2>&1; }

log_info "🎉  Tailscale 服务已启动!"
