# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Blacklist Mode** - Major new feature that inverts approval logic
  - Only blacklisted MACs require approval, others are auto-approved for 24 hours
  - Persistent configuration via UCI (survives reboots)
  - New `blacklist_macs` nftables set for efficient filtering
  - Auto-approval messages include MAC, IP, and hostname information

- **New Telegram Bot Commands**
  - `BL_ON` / `BLACKLIST_ON` - Enable blacklist mode
  - `BL_OFF` / `BLACKLIST_OFF` - Disable blacklist mode
  - `BL_STATUS` / `BLACKLIST_STATUS` - Show blacklist status and list MACs
  - `BL_ADD [MAC]` / `BLACKLIST_ADD [MAC]` - Add MAC to blacklist
  - `BL_REMOVE [MAC]` / `BLACKLIST_REMOVE [MAC]` - Remove MAC from blacklist
  - `BL_CLEAR` / `BLACKLIST_CLEAR` - Clear all blacklist entries

- **Automated Deployment**
  - New `deploy.sh` script for automated deployment via SCP
  - Support for dry-run, config-only, and scripts-only deployment modes
  - Automatic permission setting and service restart
  - Built-in connectivity testing and verification
  - Color-coded output for better visibility

- **Enhanced Documentation**
  - Comprehensive `README.md` with quick start guide
  - New `DEPLOY.md` with detailed deployment instructions
  - Updated `CLAUDE.md` with blacklist mode documentation
  - Example configuration file (`.deploy.conf.example`)

- **Improved Synchronization**
  - `gatekeeper_sync.sh` now supports both static and blacklist MAC sync
  - `gatekeeper_init` syncs both static and blacklist MACs on boot
  - Parameter support for selective sync (`static`, `blacklist`, or `all`)

### Changed
- **Firewall Architecture**
  - Updated from 4 to 5 nftables sets (added `blacklist_macs`)
  - Updated firewall documentation and comments

- **UCI Configuration**
  - Added `blacklist_mode` option to `gatekeeper.main`
  - Added `blacklist` section for MAC address list
  - Updated default config template

- **Telegram Menu**
  - Removed "Log" and "Clear" buttons from keyboard menu
  - Cleaner 2-row layout: Status/DStatus/Help and Sync/Enable/Disable
  - Commands still accessible via text input

- **Help Command**
  - Updated to include new blacklist mode commands
  - Better organized into sections (Device Management, Blacklist Mode, System Control)

### Fixed
- No bug fixes in this release (feature addition)

## [1.0.0] - 2026-01-XX

### Added
- Initial release
- Telegram-based network access control
- Interactive approve/deny buttons
- Static DHCP lease detection
- Timeout-based access control
- Auto-deny timer (5 minutes)
- Rate limiting (60 seconds)
- Emergency bypass switch
- Device management commands (STATUS, EXTEND, REVOKE)
- Denied device tracking (DSTATUS, DEXTEND, DREVOKE)
- Activity logging
- Custom hostname caching
- IPv6 filtering
- nftables integration with 4 sets
- procd service management
- UCI configuration

---

## Version History

### Blacklist Mode Features (Current)
- Inverted approval logic for trusted networks
- Persistent blacklist configuration
- 24-hour auto-approval timeout
- Informational messages for auto-approved devices
- Full Telegram command integration

### Core Features (v1.0.0)
- Basic approval/deny workflow
- Static lease bypass
- 30-minute temporary access
- Rate limiting and auto-deny
- Emergency bypass switch
- Device management via Telegram
