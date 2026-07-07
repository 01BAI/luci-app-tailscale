include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale
PKG_VERSION:=$(shell cat $(CURDIR)/VERSION 2>/dev/null || echo 1.0.0)
PKG_RELEASE:=$(shell cat $(CURDIR)/BUILD 2>/dev/null || echo 1)
LUCI_TITLE:=LuCI support for Tailscale
LUCI_DESCRIPTION:=LuCI web UI to install and manage Tailscale on OpenWrt (own GitHub Release binaries).
PKG_MAINTAINER:=Lou <lou@example.com>
LUCI_DEPENDS:=+luci-base +luci-compat
LUCI_PKGARCH:=all

define Package/luci-app-tailscale/conffiles
/etc/config/tailscale
/etc/tailscale/install.conf
/etc/tailscale/tailscale_up.conf
/etc/tailscale/release.conf
/etc/tailscale/proxies.txt
/etc/tailscale/proxy.env
endef

define Package/luci-app-tailscale/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod +x /etc/tailscale/*.sh 2>/dev/null || true
	if [ ! -f /etc/tailscale/tailscale_up.conf ]; then
		cat > /etc/tailscale/tailscale_up.conf <<'EOF'
# tailscale up 参数，由 LuCI 管理
# 格式: --参数名="值"
--accept-routes="false"
--netfilter-mode="nodivert"
EOF
	fi
	/etc/init.d/rpcd restart 2>/dev/null || true
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
