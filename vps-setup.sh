#!/usr/bin/env bash
# =============================================================================
# VPS Setup Script v2.0 — NGINX + Pi-hole + Tailscale + Minecraft Proxy
# =============================================================================
# Configures an Ubuntu VPS with:
#   - Tailscale (exit node + tailnet DNS)
#   - Pi-hole (bare-metal, DNS sinkhole, web UI on port 8443)
#   - NGINX (reverse proxy with Let's Encrypt SSL + TCP stream for Minecraft)
#   - UFW firewall
#
# Architecture:
#   Internet ──► NGINX (VPS)
#                   ├── HTTP (80/443):
#                   │   ├── mcpanel.example.com  ──► <AMP_TAILSCALE_IP>:8080 (AMP via Tailscale, HTTP)
#                   │   └── pihole.example.com ──► localhost:8443 (Pi-hole web UI)
#                   └── Stream/TCP (dynamic ports):
#                       ├── :25565 ──► <AMP_TAILSCALE_IP>:25565 (MC instance 1)
#                       └── ...
#
# Phases:
#   1. Prerequisites & System Update
#   2. Tailscale Setup + DNS + Exit Node
#   3. Pi-hole Installation
#   4. NGINX HTTP Configuration + SSL (Certbot)
#   5. NGINX Stream (Minecraft TCP Proxy)
#   6. UFW Firewall Configuration
#   7. Verification & Summary
#
# Usage:
#   sudo bash vps-setup.sh              # Run full interactive setup
#   sudo bash vps-setup.sh --help       # Show help
#   sudo bash vps-setup.sh --add-mc     # Add a new Minecraft instance
#   sudo bash vps-setup.sh --remove-mc  # Remove a Minecraft instance
#   sudo bash vps-setup.sh --status     # Show setup status
#   sudo bash vps-setup.sh --uninstall  # Remove everything installed by this script
#   sudo bash vps-setup.sh --force      # Force re-run completed phases
#
# Idempotent: Safe to re-run. Completed phases are skipped unless --force is used.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly MARKER_DIR="/etc/vps-setup"
readonly PIHOLE_WEB_PORT="8443"
readonly LOG_FILE="/var/log/vps-setup.log"
readonly DNS_UPSTREAM_1="1.1.1.1"
readonly DNS_UPSTREAM_2="8.8.8.8"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ---------------------------------------------------------------------------
# Global variables (populated by interactive prompts)
# ---------------------------------------------------------------------------
VPS_HOSTNAME=""
TS_EXIT_NODE=false
PIHOLE_ADMIN_PASSWORD=""
AMP_DOMAIN=""
PIHOLE_DOMAIN=""
LE_EMAIL=""
MC_INSTANCES=()
TS_IP=""
VPS_PUBLIC_IP=""
AMP_TS_IP=""
AMP_TS_PORT="8080"
WAN_INTERFACE=""

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    log "[INFO] $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "[OK] $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "[WARN] $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "[ERROR] $*"
}

banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          VPS Setup Script v${SCRIPT_VERSION}                        ║"
    echo "║   NGINX + Pi-hole + Tailscale + Minecraft Proxy            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

separator() {
    echo -e "${BLUE}──────────────────────────────────────────────────────────────${NC}"
}

phase_header() {
    local phase_num="$1"
    local phase_name="$2"
    echo ""
    separator
    echo -e "${BOLD}${CYAN}Phase ${phase_num}: ${phase_name}${NC}"
    separator
    echo ""
    log "========== Phase ${phase_num}: ${phase_name} =========="
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local options=""
    if [[ "$default" == "Y" ]]; then
        options="[Y/n]"
    else
        options="[y/N]"
    fi
    while true; do
        read -r -p "$(echo -e "${BOLD}${prompt}${NC} ${options}: ")" answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer Y or N." ;;
        esac
    done
}

ask_input() {
    local prompt="$1"
    local default="$2"
    local is_password="${3:-false}"
    local result=""
    if [[ "$is_password" == "true" ]]; then
        while true; do
            read -r -s -p "$(echo -e "${BOLD}${prompt}${NC}: ")" result
            echo ""
            local confirm=""
            read -r -s -p "$(echo -e "${BOLD}Confirm ${prompt}${NC}: ")" confirm
            echo ""
            if [[ "$result" == "$confirm" ]]; then
                break
            else
                error "Passwords do not match. Please try again."
            fi
        done
    else
        local display_default=""
        if [[ -n "$default" ]]; then
            display_default=" [$default]"
        fi
        read -r -p "$(echo -e "${BOLD}${prompt}${NC}${display_default}: ")" result
        result="${result:-$default}"
    fi
    echo "$result"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS. This script is designed for Ubuntu."
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        error "This script is designed for Ubuntu. Detected: $ID"
        exit 1
    fi
    info "Detected Ubuntu $VERSION_ID"
}

ensure_dns() {
    info "Checking DNS resolution..."
    if curl -fsSL --connect-timeout 10 https://pkgs.tailscale.com >/dev/null 2>&1; then
        success "DNS resolution is working."
        return 0
    fi

    warn "DNS resolution failed. Attempting to fix with fallback DNS servers..."
    cp /etc/resolv.conf /etc/resolv.conf.bak.vps-setup 2>/dev/null || true

    if ! grep -q "nameserver ${DNS_UPSTREAM_1}" /etc/resolv.conf 2>/dev/null; then
        {
            echo "# Fallback DNS added by vps-setup.sh"
            echo "nameserver ${DNS_UPSTREAM_1}"
            echo "nameserver ${DNS_UPSTREAM_2}"
        } >> /etc/resolv.conf
    fi

    if curl -fsSL --connect-timeout 10 https://pkgs.tailscale.com >/dev/null 2>&1; then
        success "DNS resolution fixed with fallback servers."
        return 0
    fi

    error "Cannot resolve hostnames even with fallback DNS."
    return 1
}

phase_completed() {
    local phase="$1"
    mkdir -p "$MARKER_DIR"
    touch "${MARKER_DIR}/${phase}.done"
    success "Phase ${phase} marked as completed."
}

is_phase_completed() {
    local phase="$1"
    [[ -f "${MARKER_DIR}/${phase}.done" ]]
}

# Detect the primary WAN interface (the one with the default route)
detect_wan_interface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        if ip link show eth0 &>/dev/null; then
            iface="eth0"
        else
            iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | grep -v '^tailscale' | head -1)
        fi
    fi
    echo "$iface"
}

# Configure Pi-hole web server port (handles both v5 and v6)
configure_pihole_web_port() {
    local port="$1"
    if command -v pihole-FTL &>/dev/null; then
        info "Setting Pi-hole web server port to ${port} (v6+ CLI method)..."
        if pihole-FTL --config webserver.port "${port}o,[::]:${port}o" 2>/dev/null; then
            success "Pi-hole web server port set to ${port} via CLI (v6+)."
            return 0
        fi
    fi

    if [[ -f /etc/pihole/pihole.toml ]]; then
        info "Setting Pi-hole web server port to ${port} (v6 TOML method)..."
        if grep -q '^\[webserver\]' /etc/pihole/pihole.toml; then
            sed -i "/^\[webserver\]/,/^\[/ s/^port = .*/port = \"${port}o,[::]:${port}o\"/" /etc/pihole/pihole.toml
        else
            echo -e "\n[webserver]\nport = \"${port}o,[::]:${port}o\"" >> /etc/pihole/pihole.toml
        fi
        success "Pi-hole web server port set to ${port} (v6 TOML)."
        return 0
    fi

    if [[ -f /etc/pihole/pihole-FTL.conf ]]; then
        info "Setting Pi-hole web server port to ${port} (v5 method)..."
        if grep -q "^webserver.port=" /etc/pihole/pihole-FTL.conf; then
            sed -i "s/^webserver.port=.*/webserver.port=${port}/" /etc/pihole/pihole-FTL.conf
        else
            echo "webserver.port=${port}" >> /etc/pihole/pihole-FTL.conf
        fi
        success "Pi-hole web server port set to ${port} (v5)."
        return 0
    fi

    warn "Could not set Pi-hole web port automatically. Default port will be used."
    return 1
}

show_help() {
    cat << EOF
VPS Setup Script v${SCRIPT_VERSION}

Configures an Ubuntu VPS with NGINX (reverse proxy + Minecraft TCP proxy),
Pi-hole (DNS sinkhole), and Tailscale (exit node + tailnet DNS).

Usage:
  sudo bash vps-setup.sh [options]

Options:
  --help, -h        Show this help message
  --uninstall       Remove everything installed by this script
  --add-mc          Add a new Minecraft instance
  --remove-mc       Remove a Minecraft instance
  --status          Show current setup status
  --force           Force re-run of completed phases
  --skip-phase N    Skip a specific phase (1-7)

Phases:
  1. Prerequisites & System Update
  2. Tailscale Setup + DNS + Exit Node
  3. Pi-hole Installation
  4. NGINX HTTP Configuration + SSL (Certbot)
  5. NGINX Stream (Minecraft TCP Proxy)
  6. UFW Firewall Configuration
  7. Verification & Summary

Examples:
  sudo bash vps-setup.sh                    # Full interactive setup
  sudo bash vps-setup.sh --force            # Re-run all phases
  sudo bash vps-setup.sh --skip-phase 3     # Skip Pi-hole installation
  sudo bash vps-setup.sh --add-mc          # Add a Minecraft instance
  sudo bash vps-setup.sh --uninstall        # Remove everything

Log file: ${LOG_FILE}
EOF
}

# ---------------------------------------------------------------------------
# Phase 1: Prerequisites & System Update
# ---------------------------------------------------------------------------

phase1_prerequisites() {
    phase_header "1" "Prerequisites & System Update"

    if is_phase_completed "phase1" && [[ "$FORCE" != true ]]; then
        warn "Phase 1 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Ask for hostname
    local current_hostname
    current_hostname=$(hostname 2>/dev/null || echo "")
    VPS_HOSTNAME=$(ask_input "Enter hostname for this VPS" "${current_hostname:-vps}")

    info "Setting hostname to ${VPS_HOSTNAME}..."
    hostnamectl set-hostname "$VPS_HOSTNAME"

    # Add hostname to /etc/hosts if not present
    VPS_PUBLIC_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo "")
    if [[ -n "$VPS_PUBLIC_IP" ]]; then
        if ! grep -q "$VPS_HOSTNAME" /etc/hosts 2>/dev/null; then
            echo "${VPS_PUBLIC_IP} ${VPS_HOSTNAME}" >> /etc/hosts
        fi
        success "Hostname set to ${VPS_HOSTNAME} (${VPS_PUBLIC_IP})"
    else
        success "Hostname set to ${VPS_HOSTNAME}"
    fi

    # System update
    info "Updating system packages..."
    apt update -y
    apt upgrade -y

    # Install prerequisites
    info "Installing prerequisite packages..."
    apt install -y curl wget apt-transport-https software-properties-common \
        netcat-openbsd dnsutils jq ufw ca-certificates gnupg lsb-release

    # Ensure DNS works
    ensure_dns

    success "Prerequisites installed."
    phase_completed "phase1"
}

# ---------------------------------------------------------------------------
# Phase 2: Tailscale Setup + DNS + Exit Node
# ---------------------------------------------------------------------------

phase2_tailscale() {
    phase_header "2" "Tailscale Setup + DNS + Exit Node"

    if is_phase_completed "phase2" && [[ "$FORCE" != true ]]; then
        warn "Phase 2 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Install Tailscale
    info "Installing Tailscale..."
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/lunar.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/lunar.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    apt update -y
    apt install -y tailscale

    # Bring Tailscale up
    info "Starting Tailscale..."
    systemctl enable --now tailscaled
    info "You will need to authenticate Tailscale. Opening auth URL..."
    tailscale up --ssh --accept-risk=all 2>&1 || true

    # Wait for Tailscale to come up
    info "Waiting for Tailscale to connect..."
    local ts_wait=0
    while ! tailscale status &>/dev/null; do
        ((ts_wait++))
        if [[ $ts_wait -ge 30 ]]; then
            error "Tailscale did not connect within 30 seconds."
            error "Please run 'tailscale up' manually and re-run this script."
            return 1
        fi
        sleep 1
    done
    success "Tailscale is connected."

    # Ask about exit node
    if ask_yes_no "Should this VPS advertise as a Tailscale exit node?" "Y"; then
        TS_EXIT_NODE=true
        info "Configuring as exit node..."
        tailscale up --reset --advertise-exit-node --accept-dns=false --ssh --accept-risk=all

        # Detect WAN interface for UFW forward rules
        WAN_INTERFACE=$(detect_wan_interface)
        info "Detected WAN interface: ${WAN_INTERFACE}"

        # Enable IP forwarding (required for exit node)
        # Per Tailscale docs: https://tailscale.com/kb/1019/subnets
        info "Enabling IP forwarding for exit node..."
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
        if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.d/99-tailscale.conf 2>/dev/null; then
            cat > /etc/sysctl.d/99-tailscale.conf << EOF
# Tailscale exit node — IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
            sysctl --system >/dev/null 2>&1 || true
        fi
        success "IP forwarding enabled."

        # NAT masquerading (required for exit node)
        info "Configuring NAT masquerading for exit node..."
        if command -v nft &>/dev/null; then
            nft add table ip tailscale 2>/dev/null || true
            nft add chain ip tailscale postrouting '{ type nat hook postrouting priority 100 ; }' 2>/dev/null || true
            nft add rule ip tailscale postrouting oifname != "tailscale0" masquerade 2>/dev/null || true
            mkdir -p /etc/nftables.d
            nft list ruleset > /etc/nftables.d/50-tailscale-exit-node.nft 2>/dev/null || true
            success "NAT masquerading configured (nftables)."
        elif command -v iptables &>/dev/null; then
            iptables -t nat -A POSTROUTING -o "$WAN_INTERFACE" -j MASQUERADE 2>/dev/null || true
            if command -v netfilter-persistent &>/dev/null; then
                netfilter-persistent save 2>/dev/null || true
            elif command -v iptables-save &>/dev/null; then
                mkdir -p /etc/iptables
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            success "NAT masquerading configured (iptables)."
        else
            warn "Neither nftables nor iptables found. Install with: apt install nftables"
        fi

        # UFW forward rule — THIS IS THE CRITICAL FIX
        # UFW blocks forwarded traffic by default. Without this rule, packets from
        # tailnet clients arrive at the VPS but are dropped by UFW before reaching
        # the internet. This was the root cause of the "exit node breaks internet" bug.
        info "Adding UFW forward rule for exit node traffic..."
        if command -v ufw &>/dev/null; then
            ufw route allow in on tailscale0 out on "$WAN_INTERFACE" comment "Tailscale exit node" 2>/dev/null || true
            success "UFW forward rule added (tailscale0 -> ${WAN_INTERFACE})."
        else
            warn "UFW not installed yet. Forward rule will be added in Phase 6."
        fi

        success "Exit node configured. Approve it in the Tailscale admin console."
    fi

    # Discover Tailscale IP
    TS_IP=$(tailscale ip -4)
    success "VPS Tailscale IP: $TS_IP"

    # Ask for AMP connection details
    AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "")
    AMP_TS_PORT=$(ask_input "Enter AMP server port (HTTP)" "8080")

    # Verify connectivity to AMP
    info "Verifying connectivity to AMP server at ${AMP_TS_IP}:${AMP_TS_PORT}..."
    local amp_status
    amp_status=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${AMP_TS_IP}:${AMP_TS_PORT}" 2>/dev/null) || true
    if [[ "$amp_status" =~ ^[0-9]+$ ]] && [[ "$amp_status" -ge 200 ]] 2>/dev/null; then
        success "Successfully connected to AMP at ${AMP_TS_IP}:${AMP_TS_PORT} (HTTP ${amp_status})"
    else
        warn "Could not connect to AMP at ${AMP_TS_IP}:${AMP_TS_PORT}."
        warn "Troubleshooting:"
        warn "  1. Check that AMP is running on the remote machine"
        warn "  2. Verify the Tailscale IP: run 'tailscale status' on both machines"
        warn "  3. Verify the AMP port (default HTTP: 8080)"
        warn "  4. Test from this VPS: curl http://${AMP_TS_IP}:${AMP_TS_PORT}"
        if ! ask_yes_no "Continue anyway?" "Y"; then
            error "Aborting. Please verify AMP connectivity and re-run."
            return 1
        fi
    fi

    phase_completed "phase2"
}

# ---------------------------------------------------------------------------
# Phase 3: Pi-hole Installation
# ---------------------------------------------------------------------------

phase3_pihole() {
    phase_header "3" "Pi-hole Installation"

    if is_phase_completed "phase3" && [[ "$FORCE" != true ]]; then
        warn "Phase 3 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Pre-configure Pi-hole before installation
    info "Pre-configuring Pi-hole settings..."

    # Set up environment variables for unattended install
    # DNS upstreams: Cloudflare + Google
    export PIHOLE_INTERFACE=""
    export PIHOLE_DNS_1="${DNS_UPSTREAM_1}"
    export PIHOLE_DNS_2="${DNS_UPSTREAM_2}"
    export QUERY_LOGGING=true
    export INSTALL_WEB_SERVER=true
    export INSTALL_WEB_INTERFACE=true
    export LIGHTTPD_ENABLED=false
    export DNSMASQ_LISTENING="all"

    # Download Pi-hole installer
    info "Downloading Pi-hole installer..."
    curl -fsSL https://install.pi-hole.net -o /tmp/basic-install.sh

    # Run installer unattended
    info "Running Pi-hole installer (unattended)..."
    bash /tmp/basic-install.sh --unattended

    # Configure Pi-hole web port to 8443
    configure_pihole_web_port "$PIHOLE_WEB_PORT"

    # Set Pi-hole admin password
    info "Setting Pi-hole admin password..."
    PIHOLE_ADMIN_PASSWORD=$(ask_input "Enter Pi-hole admin password" "" "true")

    # Try v6 password command first, then v5 fallback
    if pihole setpassword "$PIHOLE_ADMIN_PASSWORD" 2>/dev/null; then
        success "Pi-hole password set (v6 method)."
    elif pihole -a -p "$PIHOLE_ADMIN_PASSWORD" 2>/dev/null; then
        success "Pi-hole password set (v5 method)."
    else
        warn "Could not set password via CLI. You may need to set it manually."
    fi

    # Restart Pi-hole FTL to apply changes
    info "Restarting Pi-hole FTL..."
    systemctl restart pihole-FTL 2>/dev/null || pihole restartdns 2>/dev/null || true
    sleep 2

    # Switch Tailscale to use Pi-hole for DNS
    if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
        info "Switching Tailscale to use Pi-hole for DNS..."
        if [[ "$TS_EXIT_NODE" == true ]]; then
            tailscale up --reset --accept-dns=true --advertise-exit-node --accept-risk=all --ssh 2>&1 || true
        else
            tailscale up --reset --accept-dns=true --accept-risk=all --ssh 2>&1 || true
        fi

        # Verify DNS still works
        if curl -fsSL --connect-timeout 10 https://github.com >/dev/null 2>&1; then
            success "Tailscale DNS switched to Pi-hole. DNS resolution working."
        else
            warn "DNS resolution failed after switching to Pi-hole DNS."
            warn "Restoring system DNS..."
            cp /etc/resolv.conf.bak.vps-setup /etc/resolv.conf 2>/dev/null || true
            if [[ "$TS_EXIT_NODE" == true ]]; then
                tailscale up --reset --accept-dns=false --advertise-exit-node --accept-risk=all --ssh 2>&1 || true
            else
                tailscale up --reset --accept-dns=false --accept-risk=all --ssh 2>&1 || true
            fi
            warn "Tailscale DNS override disabled. Enable it later from the admin console."
        fi
    fi

    success "Pi-hole installation complete."
    echo ""
    echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║              PI-HOLE ADMIN CREDENTIALS                       ║${NC}"
    echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${GREEN}║  Web UI:  http://localhost:${PIHOLE_WEB_PORT}/admin              ${NC}"
    echo -e "${BOLD}${GREEN}║  Password: ${PIHOLE_ADMIN_PASSWORD}                           ${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    log "Pi-hole password set and displayed to console."

    phase_completed "phase3"
}

# ---------------------------------------------------------------------------
# Phase 4: NGINX HTTP Configuration + SSL (Certbot)
# ---------------------------------------------------------------------------

phase4_nginx_http() {
    phase_header "4" "NGINX HTTP Configuration + SSL"

    if is_phase_completed "phase4" && [[ "$FORCE" != true ]]; then
        warn "Phase 4 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Ensure AMP connection details are available
    if [[ -z "$AMP_TS_IP" ]]; then
        AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "")
    fi
    if [[ -z "$AMP_TS_PORT" ]]; then
        AMP_TS_PORT=$(ask_input "Enter AMP server port (HTTP)" "8080")
    fi

    # Ask for domain names
    AMP_DOMAIN=$(ask_input "Enter domain name for AMP control panel" "mcpanel.example.com")
    PIHOLE_DOMAIN=$(ask_input "Enter domain name for Pi-hole admin panel" "pihole.example.com")
    LE_EMAIL=$(ask_input "Enter email for Let's Encrypt notifications" "admin@example.com")

    # Install NGINX and certbot
    info "Installing NGINX and Certbot..."
    apt install -y nginx libnginx-mod-stream certbot python3-certbot-nginx

    # Create NGINX directories
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
    mkdir -p /etc/nginx/streams-available /etc/nginx/streams-enabled

    # Create AMP reverse proxy config (HTTP only initially; SSL added by certbot)
    info "Creating NGINX server block for AMP..."
    cat > /etc/nginx/sites-available/amp.conf << NGINXEOF
# AMP Control Panel Reverse Proxy
# Proxies to AMP server on Tailscale network at ${AMP_TS_IP}:${AMP_TS_PORT} (HTTP)
server {
    listen 80;
    listen [::]:80;
    server_name ${AMP_DOMAIN};

    location / {
        proxy_pass http://${AMP_TS_IP}:${AMP_TS_PORT};
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_set_header        Upgrade \$http_upgrade;
        proxy_set_header        Connection "Upgrade";
        proxy_set_header        X-AMP-Scheme \$scheme;
        proxy_read_timeout      86400s;
        proxy_send_timeout      86400s;
        proxy_http_version      1.1;
        proxy_redirect          off;
        proxy_buffering         off;
        client_max_body_size    10240M;
    }
}
NGINXEOF

    # Create Pi-hole reverse proxy config
    info "Creating NGINX server block for Pi-hole..."
    cat > /etc/nginx/sites-available/pihole.conf << NGINXEOF
# Pi-hole Admin Panel Reverse Proxy
# Proxies to Pi-hole web UI on localhost:${PIHOLE_WEB_PORT}
server {
    listen 80;
    listen [::]:80;
    server_name ${PIHOLE_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PIHOLE_WEB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (Pi-hole v6 uses WebSockets)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /api/ {
        proxy_pass http://127.0.0.1:${PIHOLE_WEB_PORT}/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

    # Remove default site and enable custom sites
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/amp.conf /etc/nginx/sites-enabled/amp.conf
    ln -sf /etc/nginx/sites-available/pihole.conf /etc/nginx/sites-enabled/pihole.conf

    # Test and reload NGINX
    info "Testing NGINX configuration..."
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "NGINX HTTP configured and reloaded."
    else
        error "NGINX configuration test failed."
        nginx -t 2>&1 || true
        return 1
    fi

    # Obtain SSL certificates with Certbot
    info "Obtaining SSL certificates with Certbot..."
    info "Make sure your DNS records for ${AMP_DOMAIN} and ${PIHOLE_DOMAIN} point to ${VPS_PUBLIC_IP:-this VPS}."

    if ! ask_yes_no "Have you configured DNS records for both domains? Proceed with Certbot?" "Y"; then
        warn "Skipping SSL. You can run certbot manually later:"
        warn "  certbot --nginx -d ${AMP_DOMAIN} -m ${LE_EMAIL}"
        warn "  certbot --nginx -d ${PIHOLE_DOMAIN} -m ${LE_EMAIL}"
    else
        # Get cert for AMP domain
        info "Requesting certificate for ${AMP_DOMAIN}..."
        if certbot --nginx -d "$AMP_DOMAIN" -m "$LE_EMAIL" --agree-tos --no-eff-email --redirect 2>&1; then
            success "SSL certificate obtained for ${AMP_DOMAIN}"
        else
            warn "Failed to obtain certificate for ${AMP_DOMAIN}. You can retry later."
        fi

        # Get cert for Pi-hole domain
        info "Requesting certificate for ${PIHOLE_DOMAIN}..."
        if certbot --nginx -d "$PIHOLE_DOMAIN" -m "$LE_EMAIL" --agree-tos --no-eff-email --redirect 2>&1; then
            success "SSL certificate obtained for ${PIHOLE_DOMAIN}"
        else
            warn "Failed to obtain certificate for ${PIHOLE_DOMAIN}. You can retry later."
        fi

        # Reload NGINX to pick up SSL configs
        systemctl reload nginx 2>/dev/null || true
    fi

    success "NGINX HTTP + SSL configuration complete."
    phase_completed "phase4"
}

# ---------------------------------------------------------------------------
# Phase 5: NGINX Stream (Minecraft TCP Proxy)
# ---------------------------------------------------------------------------

phase5_nginx_stream() {
    phase_header "5" "NGINX Stream (Minecraft TCP Proxy)"

    if is_phase_completed "phase5" && [[ "$FORCE" != true ]]; then
        warn "Phase 5 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Ensure AMP connection details are available
    if [[ -z "$AMP_TS_IP" ]]; then
        AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "")
    fi

    # Test if the stream directive works (the only reliable check)
    info "Checking NGINX stream module..."
    local stream_works=false
    local temp_conf
    temp_conf=$(mktemp)
    {
        cat /etc/nginx/nginx.conf | grep -E '^load_module|^include.*modules-enabled' 2>/dev/null || true
        echo 'events { worker_connections 1; }'
        echo 'stream { }'
    } > "$temp_conf"

    if nginx -t -c "$temp_conf" 2>/dev/null; then
        stream_works=true
        info "NGINX stream module is available and working."
    else
        info "NGINX stream module not available. Installing libnginx-mod-stream..."
        apt install -y libnginx-mod-stream 2>/dev/null || apt install -y nginx-extras 2>/dev/null || true

        # Re-test after installation
        {
            cat /etc/nginx/nginx.conf | grep -E '^load_module|^include.*modules-enabled' 2>/dev/null || true
            echo 'events { worker_connections 1; }'
            echo 'stream { }'
        } > "$temp_conf"

        if nginx -t -c "$temp_conf" 2>/dev/null; then
            stream_works=true
            info "NGINX stream module is now available."
        else
            rm -f "$temp_conf"
            error "Could not enable NGINX stream module. Cannot proxy Minecraft."
            error "Try: apt install libnginx-mod-stream"
            return 1
        fi
    fi
    rm -f "$temp_conf"
    success "NGINX stream module is available."

    # Ask how many Minecraft instances
    local mc_count
    mc_count=$(ask_input "How many Minecraft instances do you want to configure?" "1")

    if ! [[ "$mc_count" =~ ^[0-9]+$ ]] || [[ "$mc_count" -lt 1 ]]; then
        error "Invalid number of instances. Must be a positive integer."
        return 1
    fi

    MC_INSTANCES=()
    local default_vps_port=25565

    for ((i = 1; i <= mc_count; i++)); do
        echo ""
        info "--- Minecraft Instance ${i} of ${mc_count} ---"

        local name amp_port vps_port
        name=$(ask_input "  Instance name (e.g., survival, creative, skyblock)" "server${i}")
        amp_port=$(ask_input "  AMP server port on ${AMP_TS_IP}" "${default_vps_port}")
        vps_port=$(ask_input "  VPS listening port (what players connect to)" "${default_vps_port}")

        MC_INSTANCES+=("${name}:${amp_port}:${vps_port}")
        ((default_vps_port++))
    done

    # Create stream config directory
    mkdir -p /etc/nginx/streams-available /etc/nginx/streams-enabled

    # Generate stream config
    info "Creating NGINX stream configuration for Minecraft..."
    cat > /etc/nginx/streams-available/minecraft.conf << 'NGINXEOF'
# Minecraft TCP Stream Proxy
# Proxies Minecraft TCP traffic from VPS to AMP server via Tailscale
NGINXEOF

    for instance in "${MC_INSTANCES[@]}"; do
        local name amp_port vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        amp_port="${remainder%%:*}"
        vps_port="${remainder##*:}"

        cat >> /etc/nginx/streams-available/minecraft.conf << NGINXEOF

# Minecraft instance: ${name}
server {
    listen ${vps_port};
    listen [::]:${vps_port};
    proxy_pass ${AMP_TS_IP}:${amp_port};
    proxy_connect_timeout 60s;
    proxy_timeout 86400s;
}
NGINXEOF
    done

    # Enable stream config
    ln -sf /etc/nginx/streams-available/minecraft.conf /etc/nginx/streams-enabled/minecraft.conf

    # Add stream block to nginx.conf if not already present
    if ! grep -q "^stream {" /etc/nginx/nginx.conf; then
        info "Adding stream block to nginx.conf..."
        # Remove any old bare include line from a previous run
        sed -i '/include \/etc\/nginx\/streams-enabled/d' /etc/nginx/nginx.conf
        sed -i '/# Stream module configuration for TCP proxying/d' /etc/nginx/nginx.conf
        # Insert a stream { } block before the http { } block
        sed -i '/^http {/i \
# Stream module configuration for TCP proxying\
stream {\
    include /etc/nginx/streams-enabled/*.conf;\
}\

' /etc/nginx/nginx.conf
    fi

    # Test NGINX configuration
    info "Testing NGINX configuration..."
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "NGINX stream configuration applied."
    else
        error "NGINX configuration test failed."
        nginx -t 2>&1 || true
        return 1
    fi

    # Print SRV record instructions
    echo ""
    echo -e "${BOLD}${CYAN}Minecraft SRV DNS Records:${NC}"
    echo "Add the following SRV records to your DNS registrar:"
    echo ""
    for instance in "${MC_INSTANCES[@]}"; do
        local name vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        vps_port="${remainder##*:}"
        echo "  _minecraft._tcp.${name}.${AMP_DOMAIN}. 0 5 ${vps_port} ${AMP_DOMAIN}."
    done
    echo ""

    phase_completed "phase5"
}

# ---------------------------------------------------------------------------
# Phase 6: UFW Firewall Configuration
# ---------------------------------------------------------------------------

phase6_ufw() {
    phase_header "6" "UFW Firewall Configuration"

    if is_phase_completed "phase6" && [[ "$FORCE" != true ]]; then
        warn "Phase 6 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    if ! ask_yes_no "This will reset UFW and add new rules. Continue?" "Y"; then
        warn "Skipping UFW configuration."
        return 0
    fi

    info "Resetting UFW firewall..."
    ufw --force reset

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH
    ufw allow 22/tcp comment "SSH"

    # Allow HTTP and HTTPS
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"

    # Allow Pi-hole web UI (localhost only, but open for NGINX proxy)
    ufw allow "${PIHOLE_WEB_PORT}/tcp" comment "Pi-hole Web UI"

    # Allow Minecraft ports
    for instance in "${MC_INSTANCES[@]}"; do
        local name vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        vps_port="${remainder##*:}"
        ufw allow "${vps_port}/tcp" comment "Minecraft: ${name}"
        info "Allowed Minecraft port ${vps_port}/tcp (${name})"
    done

    # If exit node, add the critical forward rule
    if [[ "$TS_EXIT_NODE" == true ]]; then
        if [[ -z "$WAN_INTERFACE" ]]; then
            WAN_INTERFACE=$(detect_wan_interface)
        fi
        info "Adding UFW forward rule for Tailscale exit node..."
        ufw route allow in on tailscale0 out on "$WAN_INTERFACE" comment "Tailscale exit node" 2>/dev/null || true
        success "UFW forward rule added (tailscale0 -> ${WAN_INTERFACE})."
    fi

    # Enable UFW
    info "Enabling UFW..."
    ufw --force enable

    # Show status
    echo ""
    info "UFW Firewall Rules:"
    ufw status verbose

    success "UFW firewall configured."
    phase_completed "phase6"
}

# ---------------------------------------------------------------------------
# Phase 7: Verification & Summary
# ---------------------------------------------------------------------------

phase7_verification() {
    phase_header "7" "Verification & Summary"

    if is_phase_completed "phase7" && [[ "$FORCE" != true ]]; then
        warn "Phase 7 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                    SETUP SUMMARY                             ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BOLD}System:${NC}"
    echo "  Hostname:          $VPS_HOSTNAME"
    echo "  Public IP:         ${VPS_PUBLIC_IP:-unknown}"
    echo "  Tailscale IP:      ${TS_IP:-not configured}"
    echo ""

    echo -e "${BOLD}Tailscale:${NC}"
    echo "  Exit Node:         $([ "$TS_EXIT_NODE" == true ] && echo "Yes (advertised)" || echo "No")"
    if [[ "$TS_EXIT_NODE" == true ]]; then
        echo "  WAN Interface:     ${WAN_INTERFACE:-unknown}"
        echo "  IP Forwarding:     $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 'unknown')"
    fi
    echo ""

    echo -e "${BOLD}Pi-hole:${NC}"
    echo "  Web UI:            http://localhost:${PIHOLE_WEB_PORT}/admin"
    echo "  Password:          ${PIHOLE_ADMIN_PASSWORD:-(not set)}"
    echo "  DNS Upstream:      ${DNS_UPSTREAM_1}, ${DNS_UPSTREAM_2}"
    echo ""

    echo -e "${BOLD}NGINX:${NC}"
    echo "  AMP Domain:        ${AMP_DOMAIN:-not configured}"
    echo "  Pi-hole Domain:    ${PIHOLE_DOMAIN:-not configured}"
    echo "  AMP Proxy:         http://${AMP_TS_IP:-?}:${AMP_TS_PORT:-?} (via Tailscale)"
    echo "  Pi-hole Proxy:     http://127.0.0.1:${PIHOLE_WEB_PORT}"
    echo ""

    if [[ ${#MC_INSTANCES[@]} -gt 0 ]]; then
        echo -e "${BOLD}Minecraft Instances:${NC}"
        for instance in "${MC_INSTANCES[@]}"; do
            local name amp_port vps_port
            name="${instance%%:*}"
            local remainder="${instance#*:}"
            amp_port="${remainder%%:*}"
            vps_port="${remainder##*:}"
            echo "  ${name}: VPS port ${vps_port} -> AMP ${AMP_TS_IP}:${amp_port}"
        done
        echo ""
    fi

    # Service status
    echo -e "${BOLD}Service Status:${NC}"
    for svc in tailscaled pihole-FTL nginx; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $svc"
        else
            echo -e "  ${RED}✗${NC} $svc"
        fi
    done
    echo ""

    # Manual steps
    echo -e "${BOLD}${YELLOW}Manual steps required:${NC}"
    echo ""
    echo -e "${BOLD}1. Tailscale Admin Console:${NC}"
    echo "   a. Go to: https://login.tailscale.com/admin/dns"
    echo "   b. Add custom DNS server: ${TS_IP:-your VPS Tailscale IP}"
    echo "   c. (Optional) Enable 'Override local DNS'"
    echo ""
    if [[ "$TS_EXIT_NODE" == true ]]; then
        echo -e "${BOLD}2. Approve Exit Node:${NC}"
        echo "   a. Go to: https://login.tailscale.com/admin/machines"
        echo "   b. Find this VPS → Edit route settings → Enable 'Use as exit node'"
        echo ""
        echo -e "   ${GREEN}IP forwarding, NAT masquerading, and UFW forward rules${NC}"
        echo -e "   ${GREEN}have been configured automatically by this script.${NC}"
        echo ""
    fi

    if [[ ${#MC_INSTANCES[@]} -gt 0 ]]; then
        echo -e "${BOLD}3. Minecraft SRV Records:${NC}"
        echo "   Add these SRV records to your DNS registrar:"
        for instance in "${MC_INSTANCES[@]}"; do
            local name vps_port
            name="${instance%%:*}"
            local remainder="${instance#*:}"
            vps_port="${remainder##*:}"
            echo "   _minecraft._tcp.${name}.${AMP_DOMAIN}. 0 5 ${vps_port} ${AMP_DOMAIN}."
        done
        echo ""
    fi

    echo -e "${BOLD}Log file:${NC} ${LOG_FILE}"
    echo ""

    phase_completed "phase7"
}

# ---------------------------------------------------------------------------
# Add/Remove Minecraft instances
# ---------------------------------------------------------------------------

add_minecraft_instance() {
    phase_header "MC" "Add Minecraft Instance"

    if [[ -z "$AMP_TS_IP" ]]; then
        AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "")
    fi

    local name amp_port vps_port
    name=$(ask_input "Instance name (e.g., survival, creative)" "server")
    amp_port=$(ask_input "AMP server port on ${AMP_TS_IP}" "25565")
    vps_port=$(ask_input "VPS listening port (what players connect to)" "25565")

    # Append to existing stream config
    cat >> /etc/nginx/streams-available/minecraft.conf << NGINXEOF

# Minecraft instance: ${name}
server {
    listen ${vps_port};
    listen [::]:${vps_port};
    proxy_pass ${AMP_TS_IP}:${amp_port};
    proxy_connect_timeout 60s;
    proxy_timeout 86400s;
}
NGINXEOF

    # Add UFW rule
    ufw allow "${vps_port}/tcp" comment "Minecraft: ${name}" 2>/dev/null || true

    # Test and reload
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "Minecraft instance '${name}' added (VPS port ${vps_port} -> AMP ${AMP_TS_IP}:${amp_port})"
    else
        error "NGINX config test failed. Removing the added instance..."
        sed -i "/# Minecraft instance: ${name}/,/^}/d" /etc/nginx/streams-available/minecraft.conf
        return 1
    fi
}

remove_minecraft_instance() {
    phase_header "MC" "Remove Minecraft Instance"

    if [[ ! -f /etc/nginx/streams-available/minecraft.conf ]]; then
        error "No Minecraft stream configuration found."
        return 1
    fi

    info "Current Minecraft instances:"
    grep -E "^# Minecraft instance:" /etc/nginx/streams-available/minecraft.conf | sed 's/^# Minecraft instance: /  /'

    echo ""
    local name
    name=$(ask_input "Enter the name of the instance to remove" "")

    if [[ -z "$name" ]]; then
        error "No instance name provided."
        return 1
    fi

    # Extract the port before removing (for UFW cleanup)
    local vps_port
    vps_port=$(grep -A5 "# Minecraft instance: ${name}" /etc/nginx/streams-available/minecraft.conf | grep "listen " | head -1 | awk '{print $2}' | tr -d ';')

    # Remove the server block
    sed -i "/# Minecraft instance: ${name}/,/^}/d" /etc/nginx/streams-available/minecraft.conf

    # Remove UFW rule
    if [[ -n "$vps_port" ]]; then
        ufw delete allow "${vps_port}/tcp" 2>/dev/null || true
    fi

    # Test and reload
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "Minecraft instance '${name}' removed."
    else
        error "NGINX config test failed after removal. Check the config manually."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall_all() {
    banner
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║                    UNINSTALL MODE                            ║${NC}"
    echo -e "${BOLD}${RED}║  This will remove ALL components installed by this script.    ║${NC}"
    echo -e "${BOLD}${RED}║  This action is IRREVERSIBLE.                                ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$FORCE" != true ]]; then
        if ! ask_yes_no "Are you ABSOLUTELY SURE you want to uninstall everything?" "N"; then
            info "Uninstall cancelled."
            return 0
        fi
        echo ""
        warn "This will remove: NGINX, Pi-hole, Tailscale, Certbot, UFW rules,"
        warn "SSL certificates, and all configuration files."
        if ! ask_yes_no "Proceed with full uninstall?" "N"; then
            info "Uninstall cancelled."
            return 0
        fi
    fi

    # Step 1: Remove SSL certificates & certbot
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 1/7: Removing SSL certificates & Certbot${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Remove SSL certificates and Certbot?" "Y"; then
        rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 2>/dev/null || true
        systemctl disable --now certbot.timer 2>/dev/null || true
        apt purge -y certbot python3-certbot-nginx 2>/dev/null || true
        rm -rf /etc/letsencrypt 2>/dev/null || true
        success "SSL certificates and Certbot removed."
    else
        info "Skipping SSL/Certbot removal."
    fi

    # Step 2: Remove NGINX stream configs & Minecraft proxy
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 2/7: Removing NGINX stream configs${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Remove Minecraft stream proxy configs?" "Y"; then
        rm -f /etc/nginx/streams-available/minecraft.conf 2>/dev/null || true
        rm -f /etc/nginx/streams-enabled/minecraft.conf 2>/dev/null || true
        if [[ -f /etc/nginx/nginx.conf ]]; then
            if grep -q "streams-enabled" /etc/nginx/nginx.conf; then
                info "Removing stream block from nginx.conf..."
                sed -i '/^stream {/,/^}/d' /etc/nginx/nginx.conf
                sed -i '/# Stream module configuration for TCP proxying/d' /etc/nginx/nginx.conf
                sed -i '/^$/N;/^\n$/d' /etc/nginx/nginx.conf
                success "Stream block removed from nginx.conf."
            fi
        fi
        rm -rf /etc/nginx/streams-available /etc/nginx/streams-enabled 2>/dev/null || true
        success "Minecraft stream configs removed."
    else
        info "Skipping Minecraft proxy removal."
    fi

    # Step 3: Remove NGINX HTTP configs
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 3/7: Removing NGINX HTTP configs${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Remove NGINX and all configs?" "Y"; then
        rm -f /etc/nginx/sites-enabled/amp.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/pihole.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-available/amp.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-available/pihole.conf 2>/dev/null || true
        systemctl disable --now nginx 2>/dev/null || true
        apt purge -y nginx nginx-extras nginx-common libnginx-mod-stream 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
        success "NGINX uninstalled."
    else
        info "Skipping NGINX removal."
    fi

    # Step 4: Remove Pi-hole
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 4/7: Removing Pi-hole${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Remove Pi-hole?" "Y"; then
        systemctl stop pihole-FTL 2>/dev/null || true
        systemctl disable pihole-FTL 2>/dev/null || true
        apt purge -y pihole-FTL pi-hole 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
        rm -rf /etc/pihole /var/log/pihole /opt/pihole 2>/dev/null || true
        rm -f /tmp/basic-install.sh 2>/dev/null || true
        # Switch Tailscale DNS back
        if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
            tailscale up --reset --accept-dns=false --accept-risk=all --ssh 2>&1 || true
        fi
        success "Pi-hole removed."
    else
        info "Skipping Pi-hole removal."
    fi

    # Step 5: Remove Tailscale + exit node config
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 5/7: Removing Tailscale & exit node config${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Remove Tailscale?" "Y"; then
        if command -v tailscale &>/dev/null; then
            tailscale down 2>/dev/null || true
        fi
        systemctl disable --now tailscaled 2>/dev/null || true
        if dpkg -l tailscale &>/dev/null 2>&1; then
            apt purge -y tailscale 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            success "Tailscale uninstalled."
        fi
        rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/tailscale.list 2>/dev/null || true

        # Remove exit node configuration
        info "Removing exit node network configuration..."
        rm -f /etc/sysctl.d/99-tailscale.conf 2>/dev/null || true
        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
        if command -v nft &>/dev/null; then
            nft delete table ip tailscale 2>/dev/null || true
            rm -f /etc/nftables.d/50-tailscale-exit-node.nft 2>/dev/null || true
        fi
        if command -v iptables &>/dev/null; then
            iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
            for iface in ens3 ens5 enp1s0 wlan0; do
                iptables -t nat -D POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || true
            done
        fi
        success "Exit node configuration removed."
    else
        info "Skipping Tailscale removal."
    fi

    # Step 6: Reset UFW firewall
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 6/7: Resetting UFW firewall${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Reset UFW firewall (keep SSH only)?" "Y"; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment "SSH"
        ufw --force enable
        success "UFW reset to SSH-only."
    else
        info "Skipping UFW reset."
    fi

    # Step 7: Remove markers and restore system
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 7/7: Cleaning up${NC}"
    separator
    if [[ "$FORCE" == true ]] || ask_yes_no "Remove marker files and restore DNS?" "Y"; then
        rm -rf "$MARKER_DIR" 2>/dev/null || true
        # Restore resolv.conf
        if [[ -f /etc/resolv.conf.bak.vps-setup ]]; then
            cp /etc/resolv.conf.bak.vps-setup /etc/resolv.conf 2>/dev/null || true
        fi
        # Optionally restore hostname
        if ask_yes_no "Restore original hostname?" "N"; then
            hostnamectl set-hostname "$(ask_input "Enter original hostname" "ubuntu")"
        fi
        success "Cleanup complete."
    fi

    echo ""
    separator
    echo -e "${BOLD}${GREEN}Uninstall complete.${NC}"
    separator
    echo ""
    warn "You may also need to:"
    echo "  1. Remove the Tailscale exit node approval in the admin console"
    echo "  2. Remove the Tailscale DNS server in the admin console"
    echo "  3. Remove DNS records for your domains"
    echo ""
}

# ---------------------------------------------------------------------------
# Show status
# ---------------------------------------------------------------------------

show_status() {
    echo ""
    echo -e "${CYAN}${BOLD}VPS Setup Status${NC}"
    echo ""
    for i in 1 2 3 4 5 6 7; do
        local phase_name=""
        case $i in
            1) phase_name="Prerequisites & System Update" ;;
            2) phase_name="Tailscale Setup + DNS + Exit Node" ;;
            3) phase_name="Pi-hole Installation" ;;
            4) phase_name="NGINX HTTP Configuration + SSL" ;;
            5) phase_name="NGINX Stream (Minecraft) Configuration" ;;
            6) phase_name="UFW Firewall Configuration" ;;
            7) phase_name="Verification & Summary" ;;
        esac
        if is_phase_completed "phase${i}"; then
            echo -e "  ${GREEN}✓${NC} Phase ${i}: ${phase_name}"
        else
            echo -e "  ${RED}✗${NC} Phase ${i}: ${phase_name}"
        fi
    done
    echo ""
    echo -e "Log file: ${LOG_FILE}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    banner
    check_root
    check_os

    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    log "========== VPS Setup Script v${SCRIPT_VERSION} started =========="

    # Run all phases in order
    phase1_prerequisites
    phase2_tailscale
    phase3_pihole
    phase4_nginx_http
    phase5_nginx_stream
    phase6_ufw
    phase7_verification

    echo ""
    separator
    echo -e "${BOLD}${GREEN}VPS setup complete!${NC}"
    separator
    echo ""
    log "========== VPS Setup Script completed successfully =========="
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

FORCE=false
SKIP_PHASES=()
ACTION="setup"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --uninstall)
            ACTION="uninstall"
            ;;
        --add-mc)
            ACTION="add-mc"
            ;;
        --remove-mc)
            ACTION="remove-mc"
            ;;
        --status)
            ACTION="status"
            ;;
        --force)
            FORCE=true
            ;;
        --skip-phase)
            SKIP_PHASES+=("$2")
            shift
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

case "$ACTION" in
    setup)
        main
        ;;
    uninstall)
        check_root
        check_os
        uninstall_all
        ;;
    add-mc)
        check_root
        check_os
        add_minecraft_instance
        ;;
    remove-mc)
        check_root
        check_os
        remove_minecraft_instance
        ;;
    status)
        show_status
        ;;
esac