#!/bin/sh

[ -f /etc/tailscale/tools.sh ] && . /etc/tailscale/tools.sh

ARCH=""
current=""
remote=""

safe_source "$INST_CONF"
ensure_arch || exit 1
[ -z "$current" ] && current="latest"

remote=$("$CONFIG_DIR/fetch_and_install.sh" --dry-run)

recorded=""
[ -f "$VERSION_FILE" ] && recorded=$(cat "$VERSION_FILE")

if [ "$AUTO_UPDATE" = "true" ]; then
  if [ "$remote" = "$recorded" ]; then
    log_info "✅  已是最新版 $remote, 无需更新"
    exit 0
  fi

  if "$CONFIG_DIR/fetch_and_install.sh" --version="$remote" --mirror-list="$VALID_MIRRORS"; then
    echo "$remote" > "$VERSION_FILE"
    log_info "✅  更新成功至版本 $remote"
    log_info "🛠️  重启以应用最新版..."
    /etc/init.d/tailscale restart || { log_error "❌  重启服务失败, 将启动服务"; /etc/init.d/tailscale start >/dev/null 2>&1 & }
    if should_notify "update"; then
      send_notify "✅  Tailscale 已更新" "版本更新至 $remote"
    fi
  else
    log_error "❌  更新失败"
    if should_notify "emergency"; then
      send_notify "❌  Tailscale 更新失败" "版本更新失败，请检查日志"
    fi
    exit 1
  fi
else
  if [ ! -x "/usr/local/bin/tailscaled" ]; then
    log_info "⚙️  未检测到 tailscaled，尝试安装版本 $current..."
    if "$CONFIG_DIR/fetch_and_install.sh" --version="$current" --mirror-list="$VALID_MIRRORS"; then
      echo "$current" > "$VERSION_FILE"
    else
      log_error "❌  安装失败"
      if should_notify "emergency"; then
        send_notify "❌  Tailscale 安装失败" "版本 $current 安装失败" ""
      fi
      exit 1
    fi
  else
    log_info "✅  自动更新已关闭, 本地已存在 tailscaled, 跳过安装"
  fi
fi
