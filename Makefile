include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale
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
endef

define Package/luci-app-tailscale/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	chmod +x /etc/tailscale/*.sh 2>/dev/null || true
	/etc/init.d/rpcd restart 2>/dev/null || true
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
