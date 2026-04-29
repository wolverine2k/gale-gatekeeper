#!/bin/bash
#
# deploy.sh - Automated deployment script for gatekeeper to OpenWrt router
#
# Usage:
#   ./deploy.sh <router-ip-or-hostname> [options]
#
# Options:
#   --dry-run        Show what would be deployed without actually deploying
#   --no-restart     Don't restart services after deployment
#   --restart-only   Only restart services (no file deployment)
#   --config-only    Only deploy configuration file
#   --scripts-only   Only deploy scripts (no config, no init scripts)
#   --no-config      Deploy everything except the configuration file (preserves existing config)
#   --luci           Also deploy the luci-app-gatekeeper files (rpcd backend, ACL, menu, frontend
#                    views) and restart rpcd. Additive — combines with other flags.
#   --luci-only      Deploy ONLY the LuCI app files; skip runtime gatekeeper scripts.
#   --ask-password   Prompt once for the router root password and reuse it for every ssh/scp
#                    call in this run. Requires `sshpass` (brew install hudochenkov/sshpass/sshpass
#                    on macOS, apt install sshpass on Debian/Ubuntu). The password is held in
#                    the SSHPASS env var inside this process only — it never appears in argv
#                    (so `ps` and shell history stay clean). For unattended use, prefer SSH
#                    keys: ssh-copy-id root@<router>.
#
# Examples:
#   ./deploy.sh 192.168.1.1
#   ./deploy.sh router.local --dry-run
#   ./deploy.sh 192.168.1.1 --no-restart
#   ./deploy.sh 192.168.1.1 --luci             # full runtime deploy + LuCI app
#   ./deploy.sh 192.168.1.1 --luci-only        # iterate on LuCI files only
#   ./deploy.sh 192.168.1.1 --ask-password     # prompt once, no repeated password prompts
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
DRY_RUN=false
RESTART_SERVICES=true
RESTART_ONLY=false
CONFIG_ONLY=false
SCRIPTS_ONLY=false
NO_CONFIG=false
INCLUDE_LUCI=false
LUCI_ONLY=false
ASK_PASSWORD=false

# Help text. Single source of truth for the CLI surface — keep this in sync with
# the README / CLAUDE.md "Development Workflow" section when adding new flags.
show_help() {
    cat <<EOF
deploy.sh — Automated deployment for gatekeeper to an OpenWrt router

USAGE
    $0 <router-ip-or-hostname> [options]
    $0 -h | --help

ARGUMENTS
    <router-ip-or-hostname>    SSH target, e.g. 192.168.1.1 or router.local.
                               Logs in as root@<host>; SSH keys recommended
                               (or use --ask-password for one-shot password auth).

OPTIONS
    -h, --help        Show this help message and exit.
    --dry-run         Print every copy/remote action without touching the router.
    --no-restart      Deploy files but skip the final service-restart phase.
    --restart-only    Skip all file deploys; only restart services on the router.
    --config-only     Deploy ONLY /etc/config/gatekeeper (UCI config).
    --scripts-only    Deploy scripts + firewall rules + restore_helpers.sh;
                      skip the UCI config and init scripts.
    --no-config       Deploy everything EXCEPT /etc/config/gatekeeper
                      (preserves existing token / chat_id / settings).
    --luci            Additive: also deploy luci-app-gatekeeper (rpcd backend,
                      ACL, menu manifest, frontend views) and restart rpcd
                      at the end. Combines with other flags.
    --luci-only       Deploy ONLY the luci-app-gatekeeper files; skip runtime
                      gatekeeper scripts/config/init/firewall. Use for iterative
                      LuCI rpcd / frontend work.
    --ask-password    Prompt once for the router root password and reuse it
                      for every ssh/scp call in this run. Requires \`sshpass\`
                      (\`brew install hudochenkov/sshpass/sshpass\` on macOS,
                      \`apt-get install sshpass\` on Debian/Ubuntu). The password
                      lives in the SSHPASS env var inside this process only —
                      it never appears in argv, \`ps\`, or shell history. For
                      unattended use, prefer SSH keys: ssh-copy-id root@<router>.

MUTUALLY EXCLUSIVE FLAGS
    These pairs cannot be combined; the script exits with an error naming both:
        --restart-only  ⨯  --luci-only
        --restart-only  ⨯  --luci
        --restart-only  ⨯  --config-only
        --restart-only  ⨯  --scripts-only
        --restart-only  ⨯  --no-config
        --config-only   ⨯  --luci-only
        --config-only   ⨯  --scripts-only
        --config-only   ⨯  --no-config
        --scripts-only  ⨯  --luci-only

    Notes:
      • --luci is ADDITIVE — pairs with --no-config, --dry-run, --no-restart,
        --ask-password (and with --scripts-only, subject to the rules above).
      • --no-restart can pair with any deploy mode; it only skips the final
        service-restart phase.
      • --dry-run and --ask-password compose with every other flag.

EXAMPLES
    $0 192.168.1.1                       # Full deploy + service restart
    $0 192.168.1.1 --dry-run             # Preview only, no remote changes
    $0 192.168.1.1 --no-restart          # Deploy files, do not restart
    $0 192.168.1.1 --restart-only        # Restart services, no file copy
    $0 192.168.1.1 --scripts-only        # Iterate on scripts; keep init/config
    $0 192.168.1.1 --config-only         # Push UCI config only
    $0 192.168.1.1 --no-config           # Everything except UCI config
    $0 192.168.1.1 --luci                # Runtime + luci-app, restart rpcd
    $0 192.168.1.1 --luci-only           # Iterate on the LuCI app only
    $0 192.168.1.1 --ask-password        # Prompt once for root password
EOF
}

# Allow `-h` / `--help` without a router argument, and from any positional slot.
for arg in "$@"; do
    case $arg in
        -h|--help)
            show_help
            exit 0
            ;;
    esac
done

# Parse arguments
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: Router address required${NC}"
    echo "Usage: $0 <router-ip-or-hostname> [options]"
    echo "Run '$0 --help' for the full flag list."
    exit 1
fi

ROUTER=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-restart)
            RESTART_SERVICES=false
            shift
            ;;
        --restart-only)
            RESTART_ONLY=true
            shift
            ;;
        --config-only)
            CONFIG_ONLY=true
            shift
            ;;
        --scripts-only)
            SCRIPTS_ONLY=true
            shift
            ;;
        --no-config)
            NO_CONFIG=true
            shift
            ;;
        --luci)
            INCLUDE_LUCI=true
            shift
            ;;
        --luci-only)
            INCLUDE_LUCI=true
            LUCI_ONLY=true
            shift
            ;;
        --ask-password)
            ASK_PASSWORD=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Reject obviously-conflicting flag combinations. Silently honoring one and
# ignoring the other (the previous behavior) led to "I asked for X but got Y"
# bugs. Fail fast with a message that names BOTH offending flags.
fail_conflict() {
    echo -e "${RED}Error: --$1 and --$2 are mutually exclusive.${NC}" >&2
    exit 1
}
# Order matters: LUCI_ONLY implies INCLUDE_LUCI, so check the more-specific
# flag FIRST or the error would always blame --luci rather than --luci-only.
[ "$RESTART_ONLY" = true ] && [ "$LUCI_ONLY"     = true ] && fail_conflict restart-only luci-only
[ "$RESTART_ONLY" = true ] && [ "$INCLUDE_LUCI"  = true ] && fail_conflict restart-only luci
[ "$RESTART_ONLY" = true ] && [ "$CONFIG_ONLY"   = true ] && fail_conflict restart-only config-only
[ "$RESTART_ONLY" = true ] && [ "$SCRIPTS_ONLY"  = true ] && fail_conflict restart-only scripts-only
[ "$RESTART_ONLY" = true ] && [ "$NO_CONFIG"     = true ] && fail_conflict restart-only no-config
[ "$CONFIG_ONLY"  = true ] && [ "$LUCI_ONLY"     = true ] && fail_conflict config-only luci-only
[ "$CONFIG_ONLY"  = true ] && [ "$SCRIPTS_ONLY"  = true ] && fail_conflict config-only scripts-only
[ "$CONFIG_ONLY"  = true ] && [ "$NO_CONFIG"     = true ] && fail_conflict config-only no-config
[ "$SCRIPTS_ONLY" = true ] && [ "$LUCI_ONLY"     = true ] && fail_conflict scripts-only luci-only

# Resolve --ask-password before defining ssh/scp wrappers. The password is
# stored in the SSHPASS env var; sshpass(1) reads it from there with `-e`,
# so it never appears in argv / `ps` output / shell history.
if [ "$ASK_PASSWORD" = true ]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "Error: --ask-password requires 'sshpass' but it's not installed."
        echo "  macOS:  brew install hudochenkov/sshpass/sshpass"
        echo "  Debian: apt-get install sshpass"
        echo "  Or use SSH keys instead: ssh-copy-id root@$ROUTER"
        exit 1
    fi
    printf "Router password (root@%s): " "$ROUTER"
    stty -echo
    read -r SSHPASS
    stty echo
    printf "\n"
    if [ -z "$SSHPASS" ]; then
        echo "Error: empty password"
        exit 1
    fi
    export SSHPASS
fi

# ssh / scp wrappers: route through sshpass when SSHPASS is set, otherwise
# call the binaries directly so passwordless / SSH-key auth is unaffected.
ssh_cmd() {
    if [ -n "${SSHPASS:-}" ]; then
        sshpass -e ssh "$@"
    else
        ssh "$@"
    fi
}

scp_cmd() {
    if [ -n "${SSHPASS:-}" ]; then
        sshpass -e scp "$@"
    else
        scp "$@"
    fi
}

# Function to print section headers
print_header() {
    echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"
}

# Function to print info messages
print_info() {
    echo -e "  ${BLUE}→${NC} $1"
}

# Function to print success messages
print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

# Function to print warning messages
print_warning() {
    echo -e "  ${YELLOW}!${NC} $1"
}

# Function to print error messages
print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

# Function to check if file exists
check_file() {
    if [ ! -f "$1" ]; then
        print_error "File not found: $1"
        return 1
    fi
    return 0
}

# Function to deploy a file via SCP
deploy_file() {
    local src=$1
    local dst=$2
    local description=$3

    if ! check_file "$src"; then
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would copy: $src → root@$ROUTER:$dst"
    else
        print_info "Copying: $description"
        # Capture combined stdout+stderr so we can surface the real error on
        # failure. Previously we discarded stderr (2>/dev/null), which made
        # diagnosing remote failures impossible.
        local out rc
        out=$(scp_cmd "$src" "root@$ROUTER:$dst" 2>&1) && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            print_success "Deployed: $dst"
        else
            print_error "Failed to deploy: $src (exit $rc)"
            [ -n "$out" ] && printf '    %s\n' "$out" >&2
            return 1
        fi
    fi
    return 0
}

# Function to execute remote command
remote_exec() {
    local cmd=$1
    local description=$2

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would execute: $cmd"
    else
        print_info "$description"
        local out rc
        out=$(ssh_cmd "root@$ROUTER" "$cmd" 2>&1) && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
            print_success "Done"
        else
            print_error "Failed: $cmd (exit $rc)"
            [ -n "$out" ] && printf '    %s\n' "$out" >&2
            return 1
        fi
    fi
    return 0
}

# Main deployment
print_header "Gatekeeper Deployment to $ROUTER"

if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN MODE - No changes will be made"
fi

# Check SSH connectivity
print_header "Testing connectivity"
if ! ssh_cmd -o ConnectTimeout=5 "root@$ROUTER" "echo 'Connection OK'" &>/dev/null; then
    print_error "Cannot connect to $ROUTER via SSH"
    print_info "Please ensure:"
    print_info "  1. Router is reachable"
    print_info "  2. SSH is enabled on the router"
    print_info "  3. SSH keys are configured (or password authentication is enabled)"
    exit 1
fi
print_success "Connected to $ROUTER"

# Deploy configuration file
if [ "$RESTART_ONLY" = false ] && [ "$SCRIPTS_ONLY" = false ] && [ "$NO_CONFIG" = false ] && [ "$LUCI_ONLY" = false ]; then
    print_header "Deploying configuration"
    deploy_file "opkg/etc/config/gatekeeper" "/etc/config/gatekeeper" "UCI config file"
fi

# Deploy main scripts
if [ "$RESTART_ONLY" = false ] && [ "$CONFIG_ONLY" = false ] && [ "$LUCI_ONLY" = false ]; then
    print_header "Deploying main scripts"
    deploy_file "gatekeeper.sh" "/usr/bin/gatekeeper.sh" "Main approval handler"
    deploy_file "tg_bot.sh" "/usr/bin/tg_bot.sh" "Telegram bot daemon"
    deploy_file "gatekeeper_trigger.sh" "/usr/bin/gatekeeper_trigger.sh" "Ubus event listener"
    deploy_file "dnsmasq_trigger.sh" "/usr/bin/dnsmasq_trigger.sh" "DHCP event bridge"
    deploy_file "gatekeeper_sync.sh" "/usr/bin/gatekeeper_sync.sh" "Manual sync utility"

    # Set executable permissions
    print_header "Setting permissions"
    remote_exec "chmod +x /usr/bin/gatekeeper.sh" "Set executable: gatekeeper.sh"
    remote_exec "chmod +x /usr/bin/tg_bot.sh" "Set executable: tg_bot.sh"
    remote_exec "chmod +x /usr/bin/gatekeeper_trigger.sh" "Set executable: gatekeeper_trigger.sh"
    remote_exec "chmod +x /usr/bin/dnsmasq_trigger.sh" "Set executable: dnsmasq_trigger.sh"
    remote_exec "chmod +x /usr/bin/gatekeeper_sync.sh" "Set executable: gatekeeper_sync.sh"

    # Shared restore helpers library — sourced by tg_bot.sh on every poll, so a
    # missing copy here breaks the bot at startup. Also sourced by the LuCI
    # rpcd backend when installed.
    print_header "Deploying shared library"
    remote_exec "mkdir -p /usr/lib/gatekeeper" "Create /usr/lib/gatekeeper directory"
    deploy_file "opkg/usr/lib/gatekeeper/restore_helpers.sh" "/usr/lib/gatekeeper/restore_helpers.sh" "Restore helpers library"
fi

# Deploy firewall rules
if [ "$RESTART_ONLY" = false ] && [ "$CONFIG_ONLY" = false ] && [ "$LUCI_ONLY" = false ]; then
    print_header "Deploying firewall rules"

    # Create directory if it doesn't exist
    remote_exec "mkdir -p /etc/gatekeeper" "Create /etc/gatekeeper directory"

    deploy_file "gatekeeper.nft" "/etc/gatekeeper/gatekeeper.nft" "Firewall rules"
    remote_exec "chmod +x /etc/gatekeeper/gatekeeper.nft" "Set executable: gatekeeper.nft"
fi

# Deploy init scripts
if [ "$RESTART_ONLY" = false ] && [ "$CONFIG_ONLY" = false ] && [ "$SCRIPTS_ONLY" = false ] && [ "$LUCI_ONLY" = false ]; then
    print_header "Deploying init scripts"
    deploy_file "gatekeeper_init" "/etc/init.d/gatekeeper_init" "Static/blacklist MAC sync init"
    deploy_file "tg_gatekeeper" "/etc/init.d/tg_gatekeeper" "Bot daemon init"
    deploy_file "gatekeeper_trigger_listener" "/etc/init.d/gatekeeper_trigger_listener" "Ubus listener init"

    # Set executable permissions
    remote_exec "chmod +x /etc/init.d/gatekeeper_init" "Set executable: gatekeeper_init"
    remote_exec "chmod +x /etc/init.d/tg_gatekeeper" "Set executable: tg_gatekeeper"
    remote_exec "chmod +x /etc/init.d/gatekeeper_trigger_listener" "Set executable: gatekeeper_trigger_listener"
fi

# Deploy luci-app-gatekeeper (rpcd backend, ACL, menu, frontend views)
if [ "$INCLUDE_LUCI" = true ] && [ "$RESTART_ONLY" = false ]; then
    print_header "Deploying luci-app-gatekeeper"

    # rpcd backend
    remote_exec "mkdir -p /usr/libexec/rpcd" "Create /usr/libexec/rpcd directory"
    deploy_file "opkg/luci/usr/libexec/rpcd/gatekeeper" "/usr/libexec/rpcd/gatekeeper" "rpcd ubus backend"
    remote_exec "chmod +x /usr/libexec/rpcd/gatekeeper" "Set executable: /usr/libexec/rpcd/gatekeeper"

    # Menu manifest
    remote_exec "mkdir -p /usr/share/luci/menu.d" "Create /usr/share/luci/menu.d directory"
    deploy_file "opkg/luci/usr/share/luci/menu.d/luci-app-gatekeeper.json" "/usr/share/luci/menu.d/luci-app-gatekeeper.json" "LuCI menu manifest"

    # ACL definitions
    remote_exec "mkdir -p /usr/share/rpcd/acl.d" "Create /usr/share/rpcd/acl.d directory"
    deploy_file "opkg/luci/usr/share/rpcd/acl.d/luci-app-gatekeeper.json" "/usr/share/rpcd/acl.d/luci-app-gatekeeper.json" "rpcd ACL definitions"

    # Frontend views
    remote_exec "mkdir -p /www/luci-static/resources/view/gatekeeper" "Create /www/luci-static/resources/view/gatekeeper directory"
    for v in opkg/luci/htdocs/luci-static/resources/view/gatekeeper/*.js; do
        b="$(basename "$v")"
        deploy_file "$v" "/www/luci-static/resources/view/gatekeeper/$b" "View: $b"
    done
fi

# Restart services
if [ "$RESTART_SERVICES" = true ] && [ "$DRY_RUN" = false ]; then
    print_header "Reloading and restarting services"

    if [ "$LUCI_ONLY" = false ]; then
        # Reload firewall
        remote_exec "fw4 reload" "Reload firewall (apply gatekeeper.nft)"

        # Restart gatekeeper services
        remote_exec "/etc/init.d/gatekeeper_init restart" "Restart gatekeeper_init"
        remote_exec "/etc/init.d/tg_gatekeeper restart" "Restart tg_gatekeeper"
        remote_exec "/etc/init.d/gatekeeper_trigger_listener restart" "Restart trigger listener"
    fi

    if [ "$INCLUDE_LUCI" = true ]; then
        # rpcd discovers /usr/libexec/rpcd/gatekeeper only after a restart;
        # without this, the LuCI UI gets "Method not found" errors.
        remote_exec "/etc/init.d/rpcd restart" "Restart rpcd (discover LuCI gatekeeper plugin)"
    fi

    print_success "Services restarted"
fi

# Verification
if [ "$DRY_RUN" = false ]; then
    print_header "Verification"

    # Check if processes are running
    print_info "Checking running processes..."

    if ssh_cmd "root@$ROUTER" "pgrep -f tg_bot.sh" &>/dev/null; then
        print_success "tg_bot.sh is running"
    else
        print_warning "tg_bot.sh is not running"
    fi

    if ssh_cmd "root@$ROUTER" "pgrep -f gatekeeper_trigger.sh" &>/dev/null; then
        print_success "gatekeeper_trigger.sh is running"
    else
        print_warning "gatekeeper_trigger.sh is not running"
    fi

    # Check nftables sets
    print_info "Checking nftables sets..."
    if ssh_cmd "root@$ROUTER" "nft list set inet fw4 blacklist_macs" &>/dev/null; then
        print_success "blacklist_macs set exists"
    else
        print_warning "blacklist_macs set not found"
    fi
fi

# Summary
print_header "Deployment Summary"
if [ "$DRY_RUN" = true ]; then
    print_info "Dry run completed - no changes were made"
    print_info "Run without --dry-run to deploy"
else
    print_success "Deployment completed successfully!"
    print_info ""
    print_info "Next steps:"
    print_info "  1. Configure Telegram credentials if not already done:"
    print_info "     ssh root@$ROUTER"
    print_info "     uci set gatekeeper.main.token='YOUR_TOKEN'"
    print_info "     uci set gatekeeper.main.chat_id='YOUR_CHAT_ID'"
    print_info "     uci commit gatekeeper"
    print_info "     /etc/init.d/tg_gatekeeper restart"
    print_info ""
    print_info "  2. Test the bot by sending 'STATUS' command in Telegram"
    print_info ""
    print_info "  3. Monitor logs:"
    print_info "     ssh root@$ROUTER 'logread -f | grep -E \"gatekeeper|tg_bot\"'"
fi

echo ""
