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
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/gatekeeper
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper.sh $(1)/usr/bin/gatekeeper.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tg_bot.sh $(1)/usr/bin/tg_bot.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_trigger.sh $(1)/usr/bin/gatekeeper_trigger.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dnsmasq_trigger.sh $(1)/usr/bin/dnsmasq_trigger.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_sync.h $(1)/usr/bin/gatekeeper_sync.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper.nft $(1)/etc/gatekeeper/gatekeeper.nft
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_init $(1)/etc/init.d/gatekeeper_init
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tg_gatekeeper $(1)/etc/init.d/tg_gatekeeper
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/gatekeeper_trigger_listener $(1)/etc/init.d/gatekeeper_trigger_listener
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/config/gatekeeper $(1)/etc/config/gatekeeper
endef

$(eval $(call BuildPackage,gatekeeper))