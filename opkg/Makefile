include $(TOPDIR)/rules.mk

PKG_NAME:=gatekeeper
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=@GITHUB/$(PKG_NAME)
PKG_HASH:=

PKG_MAINTAINER:=Naresh Mehta <naresh@naresh.se>
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/gatekeeper
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Telegram-based Network Access Control for OpenWrt
  URL:=https://github.com/naresh-mehta/gale-gatekeeper
  DEPENDS:=+jq +curl +coreutils +coreutils-timeout
endef

define Package/gatekeeper/description
Gatekeeper is a network access control system for OpenWrt that provides 
interactive device approval via Telegram. When a new device connects to 
your network, the system sends a notification to Telegram with Approve/Deny 
buttons. Static DHCP leases are automatically allowed. Temporary devices 
require manual approval and are subject to timeout-based access control.

Features:
- Interactive Telegram device approval with inline buttons
- Automatic static lease detection and whitelisting
- Emergency global bypass switch
- Timeout-based access control (30 minutes default)
- Rate limiting to prevent duplicate notifications
- Support for EXTEND and REVOKE commands
- Comprehensive logging and status reporting
endef

define Package/gatekeeper/conffiles
/etc/config/gatekeeper
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	cp -r $(PKG_BUILD_DIR)/* $(PKG_BUILD_DIR)/
endef

define Package/gatekeeper/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/usr/lib/gatekeeper
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/gatekeeper
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper.sh $(1)/usr/bin/gatekeeper.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tg_bot.sh $(1)/usr/bin/tg_bot.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_trigger.sh $(1)/usr/bin/gatekeeper_trigger.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dnsmasq_trigger.sh $(1)/usr/bin/dnsmasq_trigger.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_sync.sh $(1)/usr/bin/gatekeeper_sync.sh
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/opkg/usr/lib/gatekeeper/restore_helpers.sh $(1)/usr/lib/gatekeeper/restore_helpers.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper.nft $(1)/etc/gatekeeper/gatekeeper.nft
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_init $(1)/etc/init.d/gatekeeper_init
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tg_gatekeeper $(1)/etc/init.d/tg_gatekeeper
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_trigger_listener $(1)/etc/init.d/gatekeeper_trigger_listener
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/config/gatekeeper $(1)/etc/config/gatekeeper
endef

define Package/luci-app-gatekeeper
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI web interface for Gatekeeper
  URL:=https://github.com/naresh-mehta/gale-gatekeeper
  # Pin gatekeeper to >= same version: the rpcd backend sources
  # /usr/lib/gatekeeper/restore_helpers.sh which is shipped by the runtime
  # gatekeeper package. An older runtime would lack the file and break the
  # rpcd backend at every call.
  DEPENDS:=+luci-base +gatekeeper (>= $(PKG_VERSION)-$(PKG_RELEASE)) +rpcd
endef

define Package/luci-app-gatekeeper/description
Browser-based admin UI for the Gatekeeper network access control system.
Manages devices, blacklist, schedules, configuration, and backups via the
router's standard LuCI panel without requiring the Telegram bot. Independent
of the bot — both surfaces share the same UCI + nftables state, neither
requires the other.

Six pages under Services -> Gatekeeper:
- Overview (status cards + log tail + auto-refresh)
- Devices (active / denied / static + per-row Approve/Deny/Extend/Revoke)
- Blacklist (mode toggle + MAC list editor)
- Schedules (CRUD + day-preset selector + pause/resume)
- Backup / Restore (download + upload + preview-then-apply)
- Settings (token / chat_id / mode flags + Test bot connection)
endef

define Package/luci-app-gatekeeper/install
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/gatekeeper
	$(INSTALL_BIN)  $(PKG_BUILD_DIR)/opkg/luci/usr/libexec/rpcd/gatekeeper $(1)/usr/libexec/rpcd/gatekeeper
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/opkg/luci/usr/share/luci/menu.d/luci-app-gatekeeper.json $(1)/usr/share/luci/menu.d/luci-app-gatekeeper.json
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/opkg/luci/usr/share/rpcd/acl.d/luci-app-gatekeeper.json $(1)/usr/share/rpcd/acl.d/luci-app-gatekeeper.json
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/opkg/luci/htdocs/luci-static/resources/view/gatekeeper/*.js $(1)/www/luci-static/resources/view/gatekeeper/
endef

# postinst: restart rpcd so it discovers the newly-installed
# /usr/libexec/rpcd/gatekeeper plugin. Without this, the LuCI UI returns
# "Method not found" until the user manually restarts. The IPKG_INSTROOT
# guard skips the restart during image-build (offline opkg install into a
# chroot). Note: $$ is escaped for Make so the shell sees a single $.
define Package/luci-app-gatekeeper/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/rpcd restart
exit 0
endef

$(eval $(call BuildPackage,gatekeeper))
$(eval $(call BuildPackage,luci-app-gatekeeper))