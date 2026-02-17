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
#   --config-only    Only deploy configuration file
#   --scripts-only   Only deploy scripts (no config, no init scripts)
#
# Examples:
#   ./deploy.sh 192.168.1.1
#   ./deploy.sh router.local --dry-run
#   ./deploy.sh 192.168.1.1 --no-restart
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
CONFIG_ONLY=false
SCRIPTS_ONLY=false

# Parse arguments
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: Router address required${NC}"
    echo "Usage: $0 <router-ip-or-hostname> [options]"
    exit 1
fi

ROUTER=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-restart)
            RESTART_SERVICES=false
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
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

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
        if scp "$src" "root@$ROUTER:$dst" 2>/dev/null; then
            print_success "Deployed: $dst"
        else
            print_error "Failed to deploy: $src"
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
        if ssh "root@$ROUTER" "$cmd" 2>/dev/null; then
            print_success "Done"
        else
            print_error "Failed: $cmd"
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
if ! ssh -o ConnectTimeout=5 "root@$ROUTER" "echo 'Connection OK'" &>/dev/null; then
    print_error "Cannot connect to $ROUTER via SSH"
    print_info "Please ensure:"
    print_info "  1. Router is reachable"
    print_info "  2. SSH is enabled on the router"
    print_info "  3. SSH keys are configured (or password authentication is enabled)"
    exit 1
fi
print_success "Connected to $ROUTER"

# Deploy configuration file
if [ "$SCRIPTS_ONLY" = false ]; then
    print_header "Deploying configuration"
    deploy_file "opkg/etc/config/gatekeeper" "/etc/config/gatekeeper" "UCI config file"
fi

# Deploy main scripts
if [ "$CONFIG_ONLY" = false ]; then
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
fi

# Deploy firewall rules
if [ "$CONFIG_ONLY" = false ]; then
    print_header "Deploying firewall rules"

    # Create directory if it doesn't exist
    remote_exec "mkdir -p /etc/gatekeeper" "Create /etc/gatekeeper directory"

    deploy_file "gatekeeper.nft" "/etc/gatekeeper/gatekeeper.nft" "Firewall rules"
    remote_exec "chmod +x /etc/gatekeeper/gatekeeper.nft" "Set executable: gatekeeper.nft"
fi

# Deploy init scripts
if [ "$CONFIG_ONLY" = false ] && [ "$SCRIPTS_ONLY" = false ]; then
    print_header "Deploying init scripts"
    deploy_file "gatekeeper_init" "/etc/init.d/gatekeeper_init" "Static/blacklist MAC sync init"
    deploy_file "tg_gatekeeper" "/etc/init.d/tg_gatekeeper" "Bot daemon init"
    deploy_file "gatekeeper_trigger_listener" "/etc/init.d/gatekeeper_trigger_listener" "Ubus listener init"

    # Set executable permissions
    remote_exec "chmod +x /etc/init.d/gatekeeper_init" "Set executable: gatekeeper_init"
    remote_exec "chmod +x /etc/init.d/tg_gatekeeper" "Set executable: tg_gatekeeper"
    remote_exec "chmod +x /etc/init.d/gatekeeper_trigger_listener" "Set executable: gatekeeper_trigger_listener"
fi

# Restart services
if [ "$RESTART_SERVICES" = true ] && [ "$DRY_RUN" = false ]; then
    print_header "Reloading and restarting services"

    # Reload firewall
    remote_exec "fw4 reload" "Reload firewall (apply gatekeeper.nft)"

    # Restart gatekeeper services
    remote_exec "/etc/init.d/gatekeeper_init restart" "Restart gatekeeper_init"
    remote_exec "/etc/init.d/tg_gatekeeper restart" "Restart tg_gatekeeper"
    remote_exec "/etc/init.d/gatekeeper_trigger_listener restart" "Restart trigger listener"

    print_success "Services restarted"
fi

# Verification
if [ "$DRY_RUN" = false ]; then
    print_header "Verification"

    # Check if processes are running
    print_info "Checking running processes..."

    if ssh "root@$ROUTER" "pgrep -f tg_bot.sh" &>/dev/null; then
        print_success "tg_bot.sh is running"
    else
        print_warning "tg_bot.sh is not running"
    fi

    if ssh "root@$ROUTER" "pgrep -f gatekeeper_trigger.sh" &>/dev/null; then
        print_success "gatekeeper_trigger.sh is running"
    else
        print_warning "gatekeeper_trigger.sh is not running"
    fi

    # Check nftables sets
    print_info "Checking nftables sets..."
    if ssh "root@$ROUTER" "nft list set inet fw4 blacklist_macs" &>/dev/null; then
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
