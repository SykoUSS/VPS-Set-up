#!/usr/bin/env bash
# =============================================================================
# VPS Setup Script — NGINX + Pi-hole + Tailscale + Minecraft Proxy
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
#                   │   ├── amp.example.com  ──► <AMP_TAILSCALE_IP>:443 (AMP via Tailscale)
#                   │   └── pihole.example.com ──► localhost:8443 (Pi-hole web UI)
#                   └── Stream/TCP (dynamic ports):
#                       ├── :25565 ──► <AMP_TAILSCALE_IP>:25565 (MC instance 1)
#                       ├── :25566 ──► <AMP_TAILSCALE_IP>:25566 (MC instance 2)
#                       └── ...
#
# Usage:
#   sudo bash vps-setup.sh              # Run full interactive setup
#   sudo bash vps-setup.sh --help       # Show help
#   sudo bash vps-setup.sh --add-mc     # Add a new Minecraft instance
#   sudo bash vps-setup.sh --remove-mc  # Remove a Minecraft instance
#   sudo bash vps-setup.sh --uninstall  # Remove everything installed by this script
#
# Idempotent: Safe to re-run. Completed phases are skipped unless --force is used.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly MARKER_DIR="/etc/vps-setup"
readonly DEFAULT_AMP_TS_IP="123.45.67.89"  # Default — will be prompted interactively
readonly DEFAULT_AMP_TS_PORT="443"
readonly PIHOLE_WEB_PORT="8443"
readonly LOG_FILE="/var/log/vps-setup.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Global variables (populated by interactive prompts)
# ---------------------------------------------------------------------------
VPS_HOSTNAME=""
TS_EXIT_NODE=false
PIHOLE_DNS_UPSTREAM=""
PIHOLE_ADMIN_PASSWORD=""
AMP_DOMAIN=""
PIHOLE_DOMAIN=""
LE_EMAIL=""
MC_INSTANCES=()        # Array of "name:amp_port:vps_port"
TS_IP=""               # VPS Tailscale IP (discovered after tailscale up)
VPS_PUBLIC_IP=""       # VPS public IP (discovered via API)
AMP_TS_IP=""           # AMP server Tailscale IP (prompted interactively)
AMP_TS_PORT=""         # AMP server port (prompted interactively)

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" >> "$LOG_FILE"
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
    echo -e "${RED}[ERROR]${NC} $*"
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
}

press_enter() {
    echo ""
    read -r -p "Press Enter to continue..."
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

ask_choice() {
    local prompt="$1"
    shift
    local choices=("$@")
    echo -e "${BOLD}${prompt}${NC}"
    local i=1
    for choice in "${choices[@]}"; do
        echo "  $i) $choice"
        ((i++))
    done
    while true; do
        read -r -p "$(echo -e "${BOLD}Enter choice [1-${#choices[@]}]:${NC} ")" answer
        if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1 ]] && [[ "$answer" -le "${#choices[@]}" ]]; then
            echo "$answer"
            return
        fi
        echo "Please enter a number between 1 and ${#choices[@]}."
    done
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
    # Check if DNS resolution works, and fix it if not
    info "Checking DNS resolution..."
    if curl -fsSL --connect-timeout 10 https://pkgs.tailscale.com >/dev/null 2>&1; then
        success "DNS resolution is working."
        return 0
    fi

    warn "DNS resolution failed. Attempting to fix with fallback DNS servers..."
    # Backup existing resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.bak.vps-setup 2>/dev/null || true

    # Add fallback DNS servers (Cloudflare and Google) if not already present
    if ! grep -q "nameserver 1.1.1.1" /etc/resolv.conf 2>/dev/null; then
        {
            echo "# Fallback DNS added by vps-setup.sh"
            echo "nameserver 1.1.1.1"
            echo "nameserver 8.8.8.8"
        } >> /etc/resolv.conf
    fi

    # Test again
    if curl -fsSL --connect-timeout 10 https://pkgs.tailscale.com >/dev/null 2>&1; then
        success "DNS resolution fixed with fallback servers."
        return 0
    fi

    error "Cannot resolve hostnames even with fallback DNS."
    error "Please check your VPS network configuration and try again."
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

# Configure Pi-hole web server port (handles both v5 and v6)
# Pi-hole v6 uses TOML config (/etc/pihole/pihole.toml) and the CLI command
# `pihole-FTL --config webserver.port "8443o,[::]:8443o"`
# Pi-hole v5 uses /etc/pihole/pihole-FTL.conf with `webserver.port=8443`
configure_pihole_web_port() {
    local port="$1"
    # Try v6+ CLI method first (works even before the config file exists)
    if command -v pihole-FTL &>/dev/null; then
        info "Setting Pi-hole web server port to ${port} (v6+ CLI method)..."
        # The port format for v6 is "PORTo,[::]:PORTo" where 'o' = optional
        # This makes FTL listen on both IPv4 and IPv6 on the specified port
        if pihole-FTL --config webserver.port "${port}o,[::]:${port}o" 2>/dev/null; then
            success "Pi-hole web server port set to ${port} via CLI (v6+)."
            return 0
        fi
    fi

    # Fallback: Try v6 TOML file method
    if [[ -f /etc/pihole/pihole.toml ]]; then
        info "Setting Pi-hole web server port to ${port} (v6 TOML method)..."
        # Check if [webserver] section exists
        if grep -q '^\[webserver\]' /etc/pihole/pihole.toml; then
            # Update existing port line under [webserver]
            if grep -q '^port\s*=' /etc/pihole/pihole.toml; then
                sed -i "s/^port\s*=.*/port = \"${port}o,[::]:${port}o\"/" /etc/pihole/pihole.toml
            else
                # Add port line after [webserver] header
                sed -i "/^\[webserver\]/a port = \"${port}o,[::]:${port}o\"" /etc/pihole/pihole.toml
            fi
        else
            # Add [webserver] section with port
            printf '\n[webserver]\nport = "%so,[::]:%so"\n' "$port" "$port" >> /etc/pihole/pihole.toml
        fi
        success "Pi-hole web server port set to ${port} via TOML config (v6)."
        return 0
    fi

    # Fallback: v5 pihole-FTL.conf method
    info "Setting Pi-hole web server port to ${port} (v5 legacy method)..."
    if [[ -f /etc/pihole/pihole-FTL.conf ]]; then
        if grep -q "^webserver.port=" /etc/pihole/pihole-FTL.conf; then
            sed -i "s/^webserver.port=.*/webserver.port=${port}/" /etc/pihole/pihole-FTL.conf
        else
            echo "webserver.port=${port}" >> /etc/pihole/pihole-FTL.conf
        fi
    else
        echo "webserver.port=${port}" > /etc/pihole/pihole-FTL.conf
    fi
    success "Pi-hole web server port set to ${port} via pihole-FTL.conf (v5 legacy)."
}

# ---------------------------------------------------------------------------
# Phase 1: Prerequisites & System Update
# ---------------------------------------------------------------------------

phase1_prerequisites() {
    phase_header "1" "Prerequisites & System Update"

    if is_phase_completed "phase1"; then
        warn "Phase 1 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Set hostname
    VPS_HOSTNAME=$(ask_input "Enter VPS hostname" "$(hostname)")
    if [[ "$VPS_HOSTNAME" != "$(hostname)" ]]; then
        # Save original hostname for potential uninstall
        echo "$(hostname)" > "${MARKER_DIR}/original-hostname"
        info "Setting hostname to $VPS_HOSTNAME..."
        hostnamectl set-hostname "$VPS_HOSTNAME"
        # Also update /etc/hosts
        if ! grep -q "$VPS_HOSTNAME" /etc/hosts; then
            local host_ip
            host_ip=$(hostname -I | awk '{print $1}')
            echo "$host_ip $VPS_HOSTNAME" >> /etc/hosts
        fi
        success "Hostname set to $VPS_HOSTNAME"
    else
        info "Hostname is already $VPS_HOSTNAME"
    fi

    # Ask for AMP server details
    AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "$DEFAULT_AMP_TS_IP")
    AMP_TS_PORT=$(ask_input "Enter AMP server port" "$DEFAULT_AMP_TS_PORT")

    # Ensure DNS works before downloading anything
    ensure_dns || return 1

    # Update system
    info "Updating system packages... (this may take a few minutes)"
    apt update -y && apt upgrade -y
    success "System packages updated."

    # Install dependencies
    info "Installing required dependencies..."
    apt install -y \
        curl \
        wget \
        apt-transport-https \
        software-properties-common \
        ufw \
        ca-certificates \
        gnupg \
        lsb-release \
        netcat-openbsd \
        dnsutils \
        jq
    success "Dependencies installed."

    # Create log file
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true

    phase_completed "phase1"
}

# ---------------------------------------------------------------------------
# Phase 2: Tailscale Setup
# ---------------------------------------------------------------------------

phase2_tailscale() {
    phase_header "2" "Tailscale Setup"

    if is_phase_completed "phase2"; then
        warn "Phase 2 already completed. Skipping. Use --force to re-run."
        # Still discover TS_IP if not set
        if [[ -z "$TS_IP" ]]; then
            TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
        fi
        return 0
    fi

    # Ensure DNS resolution works before attempting downloads
    ensure_dns || return 1

    # Check if Tailscale is already installed
    if command -v tailscale &>/dev/null; then
        info "Tailscale is already installed. Skipping installation."
    else
        # Add Tailscale GPG key and repository
        info "Adding Tailscale repository..."
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null

        # Install Tailscale
        info "Installing Tailscale..."
        apt update -y
        apt install -y tailscale
        success "Tailscale installed."
    fi

    # Enable and start tailscaled
    info "Enabling and starting tailscaled..."
    systemctl enable --now tailscaled
    sleep 2
    success "tailscaled is running."

    # Backup resolv.conf before Tailscale modifies it
    # Tailscale can override /etc/resolv.conf to point to 100.100.100.100,
    # which breaks DNS if tailnet DNS isn't configured yet.
    info "Backing up /etc/resolv.conf before Tailscale authentication..."
    cp /etc/resolv.conf /etc/resolv.conf.bak.pre-tailscale 2>/dev/null || true

    # Authenticate with --accept-dns=false to prevent Tailscale from
    # overriding DNS during setup (Pi-hole will handle DNS later)
    echo ""
    info "You need to authenticate this machine with your Tailscale account."
    info "A URL will be shown below — open it in a browser to log in."
    echo ""
    press_enter
    info "Running 'tailscale up' — look for the login URL below:"
    info "(Using --accept-dns=false to preserve system DNS during setup)"
    echo ""
    tailscale up --accept-risk=all --accept-dns=false --ssh 2>&1 || true
    echo ""

    # Wait for connection
    info "Waiting for Tailscale connection..."
    info "(If you haven't authenticated yet, open the URL shown above in your browser.)"
    local retries=0
    while ! tailscale status 2>/dev/null | grep -q "100\."; do
        retries=$((retries + 1))
        if [[ $retries -ge 60 ]]; then
            error "Tailscale did not connect within 60 seconds."
            error "Please authenticate using the URL above, then re-run this script."
            error "You can also run 'tailscale up' manually and then re-run."
            return 1
        fi
        # Print a dot every 5 seconds to show progress
        if (( retries % 5 == 0 )); then
            info "Still waiting for Tailscale connection... ($retries/60)"
        fi
        sleep 1
    done
    success "Tailscale is connected."

    # Verify DNS still works after Tailscale connection
    info "Verifying DNS resolution still works after Tailscale connection..."
    if ! curl -fsSL --connect-timeout 10 https://github.com >/dev/null 2>&1; then
        warn "DNS resolution broken after Tailscale connection. Restoring backup..."
        cp /etc/resolv.conf.bak.pre-tailscale /etc/resolv.conf 2>/dev/null || true
        # Also try fallback DNS
        if ! curl -fsSL --connect-timeout 10 https://github.com >/dev/null 2>&1; then
            if ! grep -q "nameserver 1.1.1.1" /etc/resolv.conf 2>/dev/null; then
                echo "nameserver 1.1.1.1" >> /etc/resolv.conf
                echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            fi
        fi
        if curl -fsSL --connect-timeout 10 https://github.com >/dev/null 2>&1; then
            success "DNS resolution restored."
        else
            error "Could not restore DNS resolution. Manual intervention needed."
            error "Check /etc/resolv.conf and ensure it has valid nameservers."
            return 1
        fi
    else
        success "DNS resolution is working."
    fi

    # Ask about exit node
    if ask_yes_no "Should this VPS advertise as a Tailscale exit node?" "Y"; then
        TS_EXIT_NODE=true
        info "Configuring as exit node..."
        tailscale up --reset --advertise-exit-node --accept-risk=all --accept-dns=false --ssh
        success "Exit node advertised. You will need to approve it in the Tailscale admin console."
    fi

    # Discover Tailscale IP
    TS_IP=$(tailscale ip -4)
    success "VPS Tailscale IP: $TS_IP"

    # Verify connectivity to AMP
    info "Verifying connectivity to AMP server at ${AMP_TS_IP}..."
    if curl -sk --connect-timeout 5 "https://${AMP_TS_IP}:${AMP_TS_PORT}" >/dev/null 2>&1; then
        success "Successfully connected to AMP at ${AMP_TS_IP}:${AMP_TS_PORT}"
    else
        warn "Could not connect to AMP at ${AMP_TS_IP}:${AMP_TS_PORT}."
        warn "Make sure the AMP server is running and accessible on the Tailscale network."
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

    if is_phase_completed "phase3"; then
        warn "Phase 3 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Ask for DNS upstream
    info "Select Pi-hole upstream DNS provider:"
    local dns_choice
    dns_choice=$(ask_choice "Select Pi-hole upstream DNS provider:" \
        "Cloudflare (1.1.1.1, 1.0.0.1)" \
        "Google (8.8.8.8, 8.8.4.4)" \
        "Quad9 (9.9.9.9, 149.112.112.112)" \
        "Custom (specify your own)")

    case "$dns_choice" in
        1) PIHOLE_DNS_UPSTREAM="1.1.1.1#53,1.0.0.1#53" ;;
        2) PIHOLE_DNS_UPSTREAM="8.8.8.8#53,8.8.4.4#53" ;;
        3) PIHOLE_DNS_UPSTREAM="9.9.9.9#53,149.112.112.112#53" ;;
        4)
            PIHOLE_DNS_UPSTREAM=$(ask_input "Enter custom DNS servers (comma-separated, e.g., 1.1.1.1,8.8.8.8)")
            # Convert to Pi-hole format (add #53 port suffix)
            PIHOLE_DNS_UPSTREAM=$(echo "$PIHOLE_DNS_UPSTREAM" | sed 's/,/#53,/g')#53
            ;;
    esac
    info "Pi-hole upstream DNS set to: $PIHOLE_DNS_UPSTREAM"

    # Ask for admin password
    PIHOLE_ADMIN_PASSWORD=$(ask_input "Set Pi-hole admin password" "" "true")

    # Pre-configure Pi-hole installer variables
    info "Pre-configuring Pi-hole installer..."
    mkdir -p /etc/pihole

    # Extract DNS servers (Pi-hole setupVars uses plain IPs, not IP#port format)
    local dns1 dns2
    dns1=$(echo "$PIHOLE_DNS_UPSTREAM" | cut -d',' -f1 | sed 's/#53//')
    dns2=$(echo "$PIHOLE_DNS_UPSTREAM" | cut -d',' -f2 | sed 's/#53//')

    cat > /etc/pihole/setupVars.conf << EOF
PIHOLE_INTERFACE=
IPV4_ADDRESS=
IPV6_ADDRESS=
PIHOLE_DNS_1=${dns1}
PIHOLE_DNS_2=${dns2}
QUERY_LOGGING=true
INSTALL_WEB_INTERFACE=true
INSTALL_WEB_SERVER=true
BLOCKING_ENABLED=true
EOF

    # Pre-configure Pi-hole web server port to 8443 BEFORE installation
    # This prevents Pi-hole from grabbing port 80, which would conflict with NGINX
    info "Pre-configuring Pi-hole web server port to ${PIHOLE_WEB_PORT}..."
    configure_pihole_web_port "${PIHOLE_WEB_PORT}"

    # Set environment variables for unattended install
    export PIHOLE_SKIP_OS_CHECK=true

    # Install Pi-hole
    info "Installing Pi-hole... (this may take a few minutes)"
    info "The installer will run in unattended mode using pre-configured settings."
    wget -O /tmp/basic-install.sh https://install.pi-hole.net
    bash /tmp/basic-install.sh --unattended

    # Post-install: Set admin password
    info "Setting Pi-hole admin password..."
    # Pi-hole v6+ uses 'pihole setpassword', older versions use 'pihole -a -p'
    if pihole setpassword "$PIHOLE_ADMIN_PASSWORD" 2>/dev/null; then
        success "Pi-hole admin password set (v6+ method)."
    else
        info "Trying legacy password method..."
        pihole -a -p "$PIHOLE_ADMIN_PASSWORD" 2>/dev/null || true
    fi

    # Ensure Pi-hole web server port is set to 8443 (to avoid conflict with NGINX on 80/443)
    # This was also set pre-install, but we verify and enforce it again here
    info "Ensuring Pi-hole web UI is on port ${PIHOLE_WEB_PORT}..."
    configure_pihole_web_port "${PIHOLE_WEB_PORT}"

    # Restart Pi-hole FTL service to apply the port change
    info "Restarting Pi-hole FTL service..."
    systemctl restart pihole-FTL 2>/dev/null || pihole restartdns 2>/dev/null || true
    sleep 3

    # Verify Pi-hole is NOT listening on port 80 (which would conflict with NGINX)
    info "Checking that port 80 is free for NGINX..."
    local port80_user
    port80_user=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 || true)
    if [[ -n "$port80_user" ]]; then
        warn "Port 80 is still in use by another process:"
        warn "  $port80_user"
        warn "Attempting to restart Pi-hole FTL to release port 80..."
        systemctl stop pihole-FTL 2>/dev/null || true
        sleep 2
        systemctl start pihole-FTL 2>/dev/null || true
        sleep 3
        # Check again
        port80_user=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 || true)
        if [[ -n "$port80_user" ]]; then
            # Last resort: kill whatever is on port 80 if it's pihole-FTL
            local pid_on_80
            pid_on_80=$(ss -tlnp 2>/dev/null | grep ':80 ' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
            if [[ -n "$pid_on_80" ]]; then
                local proc_name
                proc_name=$(ps -p "$pid_on_80" -o comm= 2>/dev/null || echo "unknown")
                if [[ "$proc_name" == "pihole-FTL" ]]; then
                    warn "Killing pihole-FTL on port 80 and restarting on port ${PIHOLE_WEB_PORT}..."
                    kill "$pid_on_80" 2>/dev/null || true
                    sleep 2
                    systemctl start pihole-FTL 2>/dev/null || true
                    sleep 3
                fi
            fi
            # Final check
            port80_user=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 || true)
            if [[ -n "$port80_user" ]]; then
                error "Port 80 is still occupied. NGINX will not be able to start."
                error "Please stop the process using port 80 and re-run this script."
                error "  Process: $port80_user"
                return 1
            fi
        fi
    fi
    success "Port 80 is free for NGINX."

    # Verify Pi-hole is running
    if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
        success "Pi-hole FTL is running."
    elif pihole status 2>/dev/null | grep -qi "running"; then
        success "Pi-hole is running."
    else
        warn "Pi-hole may not be fully running. Check with: pihole status"
        warn "You can try: systemctl restart pihole-FTL"
    fi

    # Configure Pi-hole to listen on all interfaces (needed for Tailscale DNS)
    info "Configuring Pi-hole to listen on all interfaces..."
    if [[ -f /etc/pihole/setupVars.conf ]]; then
        if grep -q "^PIHOLE_INTERFACE=" /etc/pihole/setupVars.conf; then
            sed -i 's/^PIHOLE_INTERFACE=.*/PIHOLE_INTERFACE=/' /etc/pihole/setupVars.conf
        fi
    fi

    # Now that Pi-hole is running, switch Tailscale to use it for DNS
    # (During setup we used --accept-dns=false to preserve system DNS)
    if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
        info "Switching Tailscale to use Pi-hole for DNS..."
        # Use --reset to avoid needing to specify all current non-default flags
        # (tailscale up requires mentioning all non-default flags unless --reset is used)
        if [[ "$TS_EXIT_NODE" == true ]]; then
            tailscale up --reset --accept-dns=true --advertise-exit-node --accept-risk=all --ssh 2>&1 || true
        else
            tailscale up --reset --accept-dns=true --accept-risk=all --ssh 2>&1 || true
        fi
        # Verify DNS still works after switching to Pi-hole
        if curl -fsSL --connect-timeout 10 https://github.com >/dev/null 2>&1; then
            success "Tailscale DNS switched to Pi-hole. DNS resolution working."
        else
            warn "DNS resolution failed after switching to Pi-hole DNS."
            warn "Restoring system DNS and disabling Tailscale DNS override..."
            # Restore system DNS
            cp /etc/resolv.conf.bak.pre-tailscale /etc/resolv.conf 2>/dev/null || true
            if [[ "$TS_EXIT_NODE" == true ]]; then
                tailscale up --reset --accept-dns=false --advertise-exit-node --accept-risk=all --ssh 2>&1 || true
            else
                tailscale up --reset --accept-dns=false --accept-risk=all --ssh 2>&1 || true
            fi
            warn "Tailscale DNS override disabled. You can enable it later from the Tailscale admin console."
        fi
    fi

    success "Pi-hole installation complete."
    success "  Web UI: http://localhost:${PIHOLE_WEB_PORT}/admin"
    success "  Admin password: (set above)"

    phase_completed "phase3"
}

# ---------------------------------------------------------------------------
# Phase 4: NGINX HTTP Configuration
# ---------------------------------------------------------------------------

phase4_nginx_http() {
    phase_header "4" "NGINX HTTP Reverse Proxy Configuration"

    if is_phase_completed "phase4"; then
        warn "Phase 4 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Install NGINX
    info "Installing NGINX..."
    apt install -y nginx

    # Check if port 80 is already in use before starting NGINX
    info "Checking if port 80 is available..."
    local port80_user
    port80_user=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 || true)
    if [[ -n "$port80_user" ]]; then
        # Check if NGINX itself is already on port 80 (from a previous run)
        if echo "$port80_user" | grep -q "nginx"; then
            info "NGINX is already running on port 80 (likely from a previous run). Will reload it."
        else
            warn "Port 80 is in use by another process:"
            warn "  $port80_user"
            warn "Attempting to stop the conflicting service..."
            # Try to stop common services that use port 80
            systemctl stop lighttpd 2>/dev/null || true
            systemctl stop pihole-FTL 2>/dev/null || true
            sleep 2
            # Re-check
            port80_user=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1 || true)
            if [[ -n "$port80_user" ]]; then
                error "Port 80 is still in use. Cannot start NGINX."
                error "Please stop the process using port 80 and re-run this script."
                return 1
            fi
            success "Port 80 is now free."
        fi
    fi

    systemctl enable --now nginx
    success "NGINX installed and running."

    # Create directories for stream configs
    mkdir -p /etc/nginx/streams-available
    mkdir -p /etc/nginx/streams-enabled

    # Ensure AMP connection details are set (may be empty if Phase 1 was skipped)
    if [[ -z "$AMP_TS_IP" ]]; then
        AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "$DEFAULT_AMP_TS_IP")
    fi
    if [[ -z "$AMP_TS_PORT" ]]; then
        AMP_TS_PORT=$(ask_input "Enter AMP server port" "$DEFAULT_AMP_TS_PORT")
    fi

    # Ask for domain names
    AMP_DOMAIN=$(ask_input "Enter domain name for AMP control panel" "amp.example.com")
    PIHOLE_DOMAIN=$(ask_input "Enter domain name for Pi-hole admin panel" "pihole.example.com")

    # Discover VPS public IP for reference
    VPS_PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "UNKNOWN")
    info "VPS Public IP: $VPS_PUBLIC_IP"
    info "Make sure your domains ($AMP_DOMAIN, $PIHOLE_DOMAIN) point to this IP."

    # Validate AMP connection details before writing config
    if [[ -z "$AMP_TS_IP" || -z "$AMP_TS_PORT" ]]; then
        error "AMP server IP and port are required for NGINX configuration."
        error "Please re-run Phase 1 or provide these values when prompted."
        return 1
    fi

    # Create AMP reverse proxy config (HTTP-only initially; SSL added in Phase 6)
    info "Creating NGINX server block for AMP..."
    cat > /etc/nginx/sites-available/amp.conf << EOF
# AMP Control Panel Reverse Proxy
# Proxies to AMP server on Tailscale network at ${AMP_TS_IP}:${AMP_TS_PORT}
# SSL will be added by certbot in Phase 6
server {
    listen 80;
    listen [::]:80;
    server_name ${AMP_DOMAIN};

    # Proxy to AMP via Tailscale
    location / {
        proxy_pass https://${AMP_TS_IP}:${AMP_TS_PORT};
        proxy_ssl_verify off;
        proxy_ssl_server_name on;

        # Proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (AMP uses WebSockets)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;

        # Buffering
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

    # Create Pi-hole reverse proxy config (HTTP-only initially; SSL added in Phase 6)
    info "Creating NGINX server block for Pi-hole..."
    cat > /etc/nginx/sites-available/pihole.conf << EOF
# Pi-hole Admin Panel Reverse Proxy
# Proxies to Pi-hole web UI on localhost:${PIHOLE_WEB_PORT}
# SSL will be added by certbot in Phase 6
server {
    listen 80;
    listen [::]:80;
    server_name ${PIHOLE_DOMAIN};

    # Proxy to Pi-hole web UI
    location / {
        proxy_pass http://127.0.0.1:${PIHOLE_WEB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (Pi-hole may use WebSockets)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Pi-hole API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:${PIHOLE_WEB_PORT}/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Remove default site and enable custom sites
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/amp.conf /etc/nginx/sites-enabled/amp.conf
    ln -sf /etc/nginx/sites-available/pihole.conf /etc/nginx/sites-enabled/pihole.conf

    # Test and reload NGINX
    info "Testing NGINX configuration..."
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "NGINX configured and reloaded."
    else
        error "NGINX configuration test failed. Please check the config files."
        nginx -t 2>&1 || true
        return 1
    fi

    phase_completed "phase4"
}

# ---------------------------------------------------------------------------
# Phase 5: NGINX Stream Configuration (Minecraft TCP Proxy)
# ---------------------------------------------------------------------------

phase5_nginx_stream() {
    phase_header "5" "NGINX Stream Configuration (Minecraft TCP Proxy)"

    if is_phase_completed "phase5"; then
        warn "Phase 5 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Verify NGINX has stream module
    info "Checking NGINX stream module..."

    # Ensure AMP connection details are available
    if [[ -z "$AMP_TS_IP" || -z "$AMP_TS_PORT" ]]; then
        error "AMP server IP and port are required for Minecraft proxy configuration."
        error "Please re-run Phase 1 or provide these values when prompted."
        return 1
    fi

    if ! nginx -V 2>&1 | grep -q "stream"; then
        error "NGINX does not have the stream module. Installing nginx-extras..."
        apt install -y nginx-extras
        if ! nginx -V 2>&1 | grep -q "stream"; then
            error "Could not enable NGINX stream module. Cannot proxy Minecraft."
            return 1
        fi
    fi
    success "NGINX stream module is available."

    # Ask how many Minecraft instances
    local mc_count
    mc_count=$(ask_input "How many Minecraft instances do you want to configure?" "1")

    # Validate input
    if ! [[ "$mc_count" =~ ^[0-9]+$ ]] || [[ "$mc_count" -lt 1 ]]; then
        error "Invalid number of instances. Must be a positive integer."
        return 1
    fi

    MC_INSTANCES=()
    local default_port=25565

    for ((i=1; i<=mc_count; i++)); do
        echo ""
        info "--- Minecraft Instance $i of $mc_count ---"

        local name amp_port vps_port

        name=$(ask_input "  Instance name (e.g., survival, creative, skyblock)" "server${i}")
        amp_port=$(ask_input "  AMP server port on ${AMP_TS_IP}" "$default_port")
        vps_port=$(ask_input "  VPS listening port (what players connect to)" "$amp_port")

        MC_INSTANCES+=("${name}:${amp_port}:${vps_port}")

        # Auto-increment default port for next instance
        default_port=$((default_port + 1))
    done

    # Create stream config
    info "Creating NGINX stream configuration for Minecraft..."
    {
        echo "# Minecraft Java Edition TCP Proxy"
        echo "# Proxies Minecraft connections from VPS to AMP server on Tailscale network"
        echo "# Generated by vps-setup.sh on $(date)"
        echo ""
    } > /etc/nginx/streams-available/minecraft.conf

    for instance in "${MC_INSTANCES[@]}"; do
        local name amp_port vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        amp_port="${remainder%%:*}"
        vps_port="${remainder##*:}"

        {
            echo "# Minecraft instance: ${name}"
            echo "server {"
            echo "    listen ${vps_port};"
            echo "    listen [::]:${vps_port};"
            echo "    proxy_pass ${AMP_TS_IP}:${amp_port};"
            echo "    proxy_timeout 30s;"
            echo "    proxy_connect_timeout 5s;"
            echo "    proxy_socket_keepalive on;"
            echo "}"
            echo ""
        } >> /etc/nginx/streams-available/minecraft.conf
    done

    # Enable stream config
    ln -sf /etc/nginx/streams-available/minecraft.conf /etc/nginx/streams-enabled/minecraft.conf

    # Add stream include to nginx.conf if not already present
    if ! grep -q "include /etc/nginx/streams-enabled" /etc/nginx/nginx.conf; then
        info "Adding stream include to nginx.conf..."
        # Insert before the last closing brace or at the end of the main context
        # We need to add it in the main context, not inside http block
        sed -i '/^http {/i \
# Stream module configuration for TCP proxying\
include /etc/nginx/streams-enabled/*.conf;\

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
    info "=== DNS SRV Records to Configure ==="
    info "You need to add the following SRV records to your DNS:"
    echo ""
    for instance in "${MC_INSTANCES[@]}"; do
        local name vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        vps_port="${remainder##*:}"
        echo -e "  ${CYAN}_minecraft._tcp.${name}.${AMP_DOMAIN}. 0 5 ${vps_port} ${AMP_DOMAIN}.${NC}"
    done
    echo ""
    info "Players can connect using: <instance_name>.${AMP_DOMAIN}"
    info "Or directly using: <VPS_IP>:<port>"

    phase_completed "phase5"
}

# ---------------------------------------------------------------------------
# Phase 6: SSL/TLS with Let's Encrypt
# ---------------------------------------------------------------------------

phase6_ssl() {
    phase_header "6" "SSL/TLS with Let's Encrypt"

    if is_phase_completed "phase6"; then
        warn "Phase 6 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    # Install certbot
    info "Installing Certbot..."
    apt install -y certbot python3-certbot-nginx
    success "Certbot installed."

    # Ask for email
    LE_EMAIL=$(ask_input "Enter email address for Let's Encrypt notifications" "")

    if [[ -z "$LE_EMAIL" ]]; then
        warn "No email provided. Certbot will use register-unsafely-without-email."
        LE_EMAIL_FLAG="--register-unsafely-without-email"
    else
        LE_EMAIL_FLAG="--email $LE_EMAIL --agree-tos"
    fi

    # Validate required variables before writing SSL configs
    if [[ -z "$AMP_TS_IP" || -z "$AMP_TS_PORT" ]]; then
        error "AMP server IP and port are required for SSL configuration."
        error "Please re-run Phase 1 or provide these values when prompted."
        return 1
    fi
    if [[ -z "$AMP_DOMAIN" || -z "$PIHOLE_DOMAIN" ]]; then
        error "Domain names are required for SSL configuration."
        error "Please re-run Phase 4 or provide these values when prompted."
        return 1
    fi

    # Write full NGINX configs with SSL blocks (replacing HTTP-only configs from Phase 4)
    info "Writing NGINX configs with SSL support..."
    cat > /etc/nginx/sites-available/amp.conf << EOF
# AMP Control Panel Reverse Proxy
# Proxies to AMP server on Tailscale network at ${AMP_TS_IP}:${AMP_TS_PORT}
server {
    listen 80;
    listen [::]:80;
    server_name ${AMP_DOMAIN};

    # Managed by Certbot - redirect HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${AMP_DOMAIN};

    # SSL certificates (managed by certbot)
    ssl_certificate /etc/letsencrypt/live/${AMP_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${AMP_DOMAIN}/privkey.pem;

    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Proxy to AMP via Tailscale
    location / {
        proxy_pass https://${AMP_TS_IP}:${AMP_TS_PORT};
        proxy_ssl_verify off;
        proxy_ssl_server_name on;

        # Proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (AMP uses WebSockets)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 300s;

        # Buffering
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
EOF

    cat > /etc/nginx/sites-available/pihole.conf << EOF
# Pi-hole Admin Panel Reverse Proxy
# Proxies to Pi-hole web UI on localhost:${PIHOLE_WEB_PORT}
server {
    listen 80;
    listen [::]:80;
    server_name ${PIHOLE_DOMAIN};

    # Managed by Certbot - redirect HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${PIHOLE_DOMAIN};

    # SSL certificates (managed by certbot)
    ssl_certificate /etc/letsencrypt/live/${PIHOLE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PIHOLE_DOMAIN}/privkey.pem;

    # SSL settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Proxy to Pi-hole web UI
    location / {
        proxy_pass http://127.0.0.1:${PIHOLE_WEB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (Pi-hole may use WebSockets)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Pi-hole API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:${PIHOLE_WEB_PORT}/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # First, get certs with standalone mode (NGINX needs to be temporarily stopped)
    info "Obtaining SSL certificates from Let's Encrypt..."
    info "This requires NGINX to be temporarily stopped."
    info "Make sure your domains ($AMP_DOMAIN, $PIHOLE_DOMAIN) point to this VPS ($VPS_PUBLIC_IP)."

    if ! ask_yes_no "Are your DNS records configured and pointing to this VPS?" "Y"; then
        warn "Please configure your DNS records first, then re-run this phase with --force."
        warn "Skipping SSL certificate installation."
        return 0
    fi

    # Stop NGINX temporarily for standalone certbot
    systemctl stop nginx

    # Obtain certificates
    local cert_success=true
    for domain in "$AMP_DOMAIN" "$PIHOLE_DOMAIN"; do
        info "Obtaining certificate for ${domain}..."
        if ! certbot certonly --standalone ${LE_EMAIL_FLAG} -d "$domain" --non-interactive --agree-tos 2>&1; then
            error "Failed to obtain certificate for ${domain}."
            cert_success=false
        else
            success "Certificate obtained for ${domain}."
        fi
    done

    # Start NGINX again
    systemctl start nginx

    if [[ "$cert_success" == true ]]; then
        # Install certificates in NGINX
        info "Installing SSL certificates in NGINX..."
        certbot install --nginx --non-interactive 2>&1 || true

        # Set up auto-renewal
        info "Setting up automatic certificate renewal..."
        systemctl enable certbot.timer 2>/dev/null || true
        systemctl start certbot.timer 2>/dev/null || true

        # Add renewal hook to reload NGINX
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'EOF'
#!/bin/bash
systemctl reload nginx
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

        success "SSL certificates installed and auto-renewal configured."
    else
        warn "Some certificates failed. You can re-run this phase with --force."
        warn "HTTP-only mode will be used for now."
    fi

    phase_completed "phase6"
}

# ---------------------------------------------------------------------------
# Phase 7: UFW Firewall Configuration
# ---------------------------------------------------------------------------

phase7_firewall() {
    phase_header "7" "UFW Firewall Configuration"

    if is_phase_completed "phase7"; then
        warn "Phase 7 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    info "Configuring UFW firewall..."

    # Reset UFW to defaults (with confirmation)
    if ask_yes_no "Reset UFW to default rules? (This will remove existing rules)" "Y"; then
        ufw --force reset
    fi

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH (critical - don't lock yourself out!)
    ufw allow 22/tcp comment "SSH"
    info "Allowed SSH (port 22)"

    # Allow HTTP and HTTPS
    ufw allow 80/tcp comment "HTTP"
    ufw allow 443/tcp comment "HTTPS"
    info "Allowed HTTP (80) and HTTPS (443)"

    # Allow Tailscale traffic
    ufw allow in on tailscale0 comment "Tailscale interface"
    ufw allow 41641/udp comment "Tailscale direct"
    info "Allowed Tailscale traffic"

    # Allow DNS from Tailscale interface only
    ufw allow in on tailscale0 to any port 53 proto tcp comment "DNS TCP (Tailscale only)"
    ufw allow in on tailscale0 to any port 53 proto udp comment "DNS UDP (Tailscale only)"
    info "Allowed DNS on Tailscale interface"

    # Allow Pi-hole web UI from localhost only (NGINX proxies to it)
    ufw allow from 127.0.0.1 to any port "${PIHOLE_WEB_PORT}" proto tcp comment "Pi-hole web UI (localhost only)"
    info "Allowed Pi-hole web UI on port ${PIHOLE_WEB_PORT} (localhost only)"

    # Allow Minecraft ports
    for instance in "${MC_INSTANCES[@]}"; do
        local name vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        vps_port="${remainder##*:}"
        ufw allow "${vps_port}/tcp" comment "Minecraft: ${name}"
        info "Allowed Minecraft port ${vps_port}/tcp (${name})"
    done

    # Enable UFW
    info "Enabling UFW..."
    ufw --force enable

    # Show status
    echo ""
    info "UFW Firewall Rules:"
    ufw status verbose

    success "UFW firewall configured."

    phase_completed "phase7"
}

# ---------------------------------------------------------------------------
# Phase 8: Tailscale DNS & Exit Node Instructions
# ---------------------------------------------------------------------------

phase8_tailscale_dns() {
    phase_header "8" "Tailscale DNS & Exit Node Configuration"

    if is_phase_completed "phase8"; then
        warn "Phase 8 already completed. Skipping. Use --force to re-run."
        return 0
    fi

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║        TAILSCALE DNS & EXIT NODE — MANUAL STEPS             ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}The following steps must be completed manually in the Tailscale admin console.${NC}"
    echo ""

    echo -e "${BOLD}1. Configure Pi-hole as Tailnet DNS Server:${NC}"
    echo "   a. Go to: https://login.tailscale.com/admin/dns"
    echo "   b. Under 'Add DNS Server', add: ${TS_IP}"
    echo "   c. This will make all Tailscale devices use Pi-hole for DNS resolution."
    echo "   d. (Optional) Enable 'Override local DNS' to force all DNS through Pi-hole."
    echo ""

    echo -e "${BOLD}2. Approve Exit Node (if configured):${NC}"
    if [[ "$TS_EXIT_NODE" == true ]]; then
        echo "   a. Go to: https://login.tailscale.com/admin/machines"
        echo "   b. Find this VPS in the machine list."
        echo "   c. Click the three-dot menu → 'Edit route settings'."
        echo "   d. Enable the 'Use as exit node' option."
        echo ""
    else
        echo "   (Exit node was not configured — skip this step.)"
        echo ""
    fi

    echo -e "${BOLD}3. Configure DNS SRV Records for Minecraft:${NC}"
    echo "   Add the following SRV records to your DNS registrar:"
    echo ""
    for instance in "${MC_INSTANCES[@]}"; do
        local name vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        vps_port="${remainder##*:}"
        echo "   _minecraft._tcp.${name}.${AMP_DOMAIN}. 0 5 ${vps_port} ${AMP_DOMAIN}."
    done
    echo ""

    press_enter
    phase_completed "phase8"
}

# ---------------------------------------------------------------------------
# Phase 9: Verification & Summary
# ---------------------------------------------------------------------------

phase9_verification() {
    phase_header "9" "Verification & Summary"

    local all_ok=true

    # Check Tailscale
    echo -e "${BOLD}Checking Tailscale...${NC}"
    if systemctl is-active --quiet tailscaled; then
        success "  tailscaled is running"
    else
        error "  tailscaled is NOT running"
        all_ok=false
    fi
    if [[ -n "$TS_IP" ]]; then
        success "  Tailscale IP: $TS_IP"
    else
        warn "  Tailscale IP not discovered"
        all_ok=false
    fi

    # Check Pi-hole
    echo -e "${BOLD}Checking Pi-hole...${NC}"
    if pihole status 2>/dev/null | grep -q "running"; then
        success "  Pi-hole is running"
    else
        warn "  Pi-hole may not be running — check with: pihole status"
        all_ok=false
    fi

    # Check NGINX
    echo -e "${BOLD}Checking NGINX...${NC}"
    if systemctl is-active --quiet nginx; then
        success "  NGINX is running"
    else
        error "  NGINX is NOT running"
        all_ok=false
    fi
    if nginx -t 2>&1 | grep -q "successful"; then
        success "  NGINX configuration is valid"
    else
        error "  NGINX configuration has errors"
        all_ok=false
    fi

    # Check UFW
    echo -e "${BOLD}Checking UFW...${NC}"
    if ufw status | grep -q "active"; then
        success "  UFW is active"
    else
        warn "  UFW is not active"
        all_ok=false
    fi

    # Check SSL certificates
    echo -e "${BOLD}Checking SSL certificates...${NC}"
    if certbot certificates 2>/dev/null | grep -q "VALID"; then
        success "  SSL certificates are valid"
    else
        warn "  No valid SSL certificates found (HTTP-only mode may be active)"
    fi

    # Check AMP connectivity
    echo -e "${BOLD}Checking AMP connectivity...${NC}"
    if curl -sk --connect-timeout 5 "https://${AMP_TS_IP}:${AMP_TS_PORT}" >/dev/null 2>&1; then
        success "  AMP server is reachable at ${AMP_TS_IP}:${AMP_TS_PORT}"
    else
        warn "  AMP server at ${AMP_TS_IP}:${AMP_TS_PORT} is not reachable"
    fi

    # Check Minecraft ports
    echo -e "${BOLD}Checking Minecraft proxy ports...${NC}"
    for instance in "${MC_INSTANCES[@]}"; do
        local name vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        vps_port="${remainder##*:}"
        if nc -z -w 3 127.0.0.1 "$vps_port" 2>/dev/null; then
            success "  Minecraft port ${vps_port} (${name}) is listening"
        else
            warn "  Minecraft port ${vps_port} (${name}) is not yet listening (may need NGINX reload)"
        fi
    done

    # Print summary
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                    SETUP SUMMARY                             ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}VPS Information:${NC}"
    echo "  Hostname:          $VPS_HOSTNAME"
    echo "  Public IP:         $VPS_PUBLIC_IP"
    echo "  Tailscale IP:      $TS_IP"
    echo ""
    echo -e "${BOLD}Web Services:${NC}"
    echo "  AMP Panel:         https://${AMP_DOMAIN}"
    echo "  Pi-hole Admin:     https://${PIHOLE_DOMAIN}"
    echo "  Pi-hole Local:     http://localhost:${PIHOLE_WEB_PORT}/admin"
    echo ""
    echo -e "${BOLD}Minecraft Instances:${NC}"
    for instance in "${MC_INSTANCES[@]}"; do
        local name amp_port vps_port
        name="${instance%%:*}"
        local remainder="${instance#*:}"
        amp_port="${remainder%%:*}"
        vps_port="${remainder##*:}"
        echo "  ${name}:"
        echo "    Direct:       ${VPS_PUBLIC_IP}:${vps_port}"
        echo "    SRV Record:   _minecraft._tcp.${name}.${AMP_DOMAIN}. 0 5 ${vps_port} ${AMP_DOMAIN}."
    done
    echo ""
    echo -e "${BOLD}Tailscale:${NC}"
    echo "  Exit Node:         $([ "$TS_EXIT_NODE" == true ] && echo "Yes (advertised)" || echo "No")"
    echo "  AMP Server:        ${AMP_TS_IP}:${AMP_TS_PORT}"
    echo ""
    echo -e "${BOLD}Pi-hole:${NC}"
    echo "  DNS Upstream:      $PIHOLE_DNS_UPSTREAM"
    echo "  Web UI Port:       $PIHOLE_WEB_PORT"
    echo "  Admin Password:    (set during installation)"
    echo ""
    echo -e "${BOLD}Firewall (UFW):${NC}"
    ufw status | head -20
    echo ""
    echo -e "${YELLOW}${BOLD}Next Steps:${NC}"
    echo "  1. Configure DNS records to point ${AMP_DOMAIN} and ${PIHOLE_DOMAIN} to ${VPS_PUBLIC_IP}"
    echo "  2. Add SRV records for Minecraft instances (see above)"
    echo "  3. Configure Tailscale DNS to use Pi-hole (see Phase 8 instructions)"
    echo "  4. Approve exit node in Tailscale admin console (if configured)"
    echo "  5. Re-run this script with --force if SSL certificate installation was skipped"
    echo ""
    echo -e "${BOLD}Useful Commands:${NC}"
    echo "  pihole status          — Check Pi-hole status"
    echo "  pihole setpassword <pass> — Change Pi-hole admin password (v6+)"
    echo "  tailscale status       — Check Tailscale connection"
    echo "  nginx -t               — Test NGINX configuration"
    echo "  systemctl reload nginx — Reload NGINX after config changes"
    echo "  ufw status verbose     — Show firewall rules"
    echo "  certbot renew --dry-run — Test SSL certificate renewal"
    echo ""

    if [[ "$all_ok" == true ]]; then
        success "All checks passed! Your VPS is ready."
    else
        warn "Some checks failed. Please review the output above."
    fi

    phase_completed "phase9"
}

# ---------------------------------------------------------------------------
# Add Minecraft Instance (standalone operation)
# ---------------------------------------------------------------------------

add_minecraft_instance() {
    echo ""
    info "=== Add New Minecraft Instance ==="
    echo ""

    # Check prerequisites
    if ! command -v nginx &>/dev/null; then
        error "NGINX is not installed. Run the full setup first."
        return 1
    fi

    if [[ ! -d /etc/nginx/streams-available ]]; then
        error "NGINX stream directories not found. Run the full setup first."
        return 1
    fi

    # Prompt for AMP IP if not already set
    if [[ -z "$AMP_TS_IP" ]]; then
        AMP_TS_IP=$(ask_input "Enter AMP server Tailscale IP" "$DEFAULT_AMP_TS_IP")
    fi
    if [[ -z "$AMP_TS_PORT" ]]; then
        AMP_TS_PORT=$(ask_input "Enter AMP server port" "$DEFAULT_AMP_TS_PORT")
    fi

    local name amp_port vps_port

    name=$(ask_input "Instance name (e.g., survival, creative, skyblock)" "")
    amp_port=$(ask_input "AMP server port on ${AMP_TS_IP}" "25565")
    vps_port=$(ask_input "VPS listening port (what players connect to)" "$amp_port")

    # Check if port is already in use
    if ss -tlnp | grep -q ":${vps_port} "; then
        error "Port ${vps_port} is already in use!"
        return 1
    fi

    # Add to stream config
    {
        echo "# Minecraft instance: ${name} (added $(date))"
        echo "server {"
        echo "    listen ${vps_port};"
        echo "    listen [::]:${vps_port};"
        echo "    proxy_pass ${AMP_TS_IP}:${amp_port};"
        echo "    proxy_timeout 30s;"
        echo "    proxy_connect_timeout 5s;"
        echo "    proxy_socket_keepalive on;"
        echo "}"
        echo ""
    } >> /etc/nginx/streams-available/minecraft.conf

    # Test and reload NGINX
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "Minecraft instance '${name}' added on port ${vps_port} → ${AMP_TS_IP}:${amp_port}"
    else
        error "NGINX configuration test failed. Reverting..."
        # Remove the last server block we added
        sed -i "/# Minecraft instance: ${name}/,/^}$/d" /etc/nginx/streams-available/minecraft.conf
        return 1
    fi

    # Add UFW rule
    ufw allow "${vps_port}/tcp" comment "Minecraft: ${name}"
    success "Firewall rule added for port ${vps_port}/tcp"

    echo ""
    info "SRV Record to add:"
    echo "  _minecraft._tcp.${name}.${AMP_DOMAIN}. 0 5 ${vps_port} ${AMP_DOMAIN}."
    echo ""
    info "Players can connect using: ${name}.${AMP_DOMAIN} or ${VPS_PUBLIC_IP}:${vps_port}"
}

# ---------------------------------------------------------------------------
# Remove Minecraft Instance
# ---------------------------------------------------------------------------

remove_minecraft_instance() {
    echo ""
    info "=== Remove Minecraft Instance ==="
    echo ""

    if [[ ! -f /etc/nginx/streams-available/minecraft.conf ]]; then
        error "No Minecraft configuration found."
        return 1
    fi

    # List current instances
    echo -e "${BOLD}Current Minecraft instances:${NC}"
    grep -E "^# Minecraft instance:" /etc/nginx/streams-available/minecraft.conf || echo "  (none found)"
    echo ""

    local name
    name=$(ask_input "Enter the name of the instance to remove" "")

    if [[ -z "$name" ]]; then
        error "No instance name provided."
        return 1
    fi

    # Find the port for this instance (for UFW removal)
    local vps_port
    vps_port=$(grep -A5 "# Minecraft instance: ${name}" /etc/nginx/streams-available/minecraft.conf | grep "listen " | head -1 | awk '{print $2}' | tr -d ';')

    # Remove the server block
    sed -i "/# Minecraft instance: ${name}/,/^}$/d" /etc/nginx/streams-available/minecraft.conf

    # Remove empty lines at end of file
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' /etc/nginx/streams-available/minecraft.conf

    # Test and reload NGINX
    if nginx -t 2>&1; then
        systemctl reload nginx
        success "Minecraft instance '${name}' removed from NGINX."
    else
        error "NGINX configuration test failed after removal. Manual intervention needed."
        return 1
    fi

    # Remove UFW rule
    if [[ -n "$vps_port" ]]; then
        ufw delete allow "${vps_port}/tcp" 2>/dev/null || true
        success "Firewall rule removed for port ${vps_port}/tcp"
    fi

    success "Instance '${name}' removed."
}

# ---------------------------------------------------------------------------
# Uninstall — Remove everything installed by this script
# ---------------------------------------------------------------------------

uninstall_all() {
    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║                    ⚠  UNINSTALL MODE  ⚠                     ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}This will remove EVERYTHING installed by this script:${NC}"
    echo "  • SSL certificates (Let's Encrypt / certbot)"
    echo "  • NGINX reverse proxy configs and the NGINX package"
    echo "  • Minecraft TCP proxy configs"
    echo "  • Pi-hole DNS sinkhole"
    echo "  • Tailscale VPN"
    echo "  • UFW firewall rules (reset to SSH-only)"
    echo "  • Prerequisite packages installed by this script"
    echo "  • All marker files and logs"
    echo ""
    echo -e "${YELLOW}This action is destructive and cannot be easily undone.${NC}"
    echo ""

    if [[ "$FORCE" != true ]]; then
        if ! ask_yes_no "Are you sure you want to uninstall everything?" "N"; then
            info "Uninstall cancelled."
            exit 0
        fi
    fi

    log "=== UNINSTALL STARTED ==="

    # ------------------------------------------------------------------
    # Step 1: Remove SSL certificates & certbot (reverse of Phase 6)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 1/8: Removing SSL certificates & certbot${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Remove SSL certificates and certbot?" "Y"; then
        # Remove certbot renewal hook
        if [[ -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh ]]; then
            info "Removing certbot renewal hook..."
            rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
            success "Certbot renewal hook removed."
        else
            info "No certbot renewal hook found."
        fi

        # Remove SSL certificates
        if [[ -d /etc/letsencrypt/live ]]; then
            info "Removing Let's Encrypt certificates..."
            # Get list of certificate names
            local cert_names
            cert_names=$(certbot certificates 2>/dev/null | grep "Certificate Name:" | awk '{print $3}' || true)
            if [[ -n "$cert_names" ]]; then
                echo "$cert_names" | while read -r cert_name; do
                    if [[ -n "$cert_name" ]]; then
                        info "Deleting certificate: $cert_name"
                        certbot delete --cert-name "$cert_name" --non-interactive 2>/dev/null || true
                    fi
                done
            else
                # Fallback: remove the directories directly
                rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal 2>/dev/null || true
            fi
            success "SSL certificates removed."
        else
            info "No Let's Encrypt certificates found."
        fi

        # Disable certbot timer
        info "Disabling certbot renewal timer..."
        systemctl disable --now certbot.timer 2>/dev/null || true

        # Uninstall certbot
        if command -v certbot &>/dev/null || dpkg -l certbot &>/dev/null 2>&1; then
            info "Uninstalling certbot..."
            apt purge -y certbot python3-certbot-nginx 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            success "Certbot uninstalled."
        else
            info "Certbot is not installed."
        fi
    else
        info "Skipping SSL/certbot removal."
    fi

    # ------------------------------------------------------------------
    # Step 2: Remove NGINX stream configs & Minecraft proxy (reverse of Phase 5)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 2/8: Removing Minecraft proxy & NGINX stream configs${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Remove Minecraft proxy configs?" "Y"; then
        # Parse Minecraft ports from config for UFW rule removal
        local mc_ports=()
        if [[ -f /etc/nginx/streams-available/minecraft.conf ]]; then
            mc_ports=($(grep -E "^\s*listen\s+" /etc/nginx/streams-available/minecraft.conf 2>/dev/null | awk '{print $2}' | tr -d ';' || true))
            info "Found Minecraft ports: ${mc_ports[*]}"
        fi

        # Remove stream config files
        rm -f /etc/nginx/streams-enabled/minecraft.conf 2>/dev/null || true
        rm -f /etc/nginx/streams-available/minecraft.conf 2>/dev/null || true
        success "Minecraft stream configs removed."

        # Remove stream include from nginx.conf
        if [[ -f /etc/nginx/nginx.conf ]]; then
            if grep -q "include /etc/nginx/streams-enabled" /etc/nginx/nginx.conf; then
                info "Removing stream include from nginx.conf..."
                sed -i '/include \/etc\/nginx\/streams-enabled/d' /etc/nginx/nginx.conf
                success "Stream include removed from nginx.conf."
            fi
        fi

        # Remove Minecraft UFW rules
        if [[ ${#mc_ports[@]} -gt 0 ]]; then
            info "Removing Minecraft UFW rules..."
            for port in "${mc_ports[@]}"; do
                ufw delete allow "${port}/tcp" 2>/dev/null || true
            done
            success "Minecraft UFW rules removed."
        fi
    else
        info "Skipping Minecraft proxy removal."
    fi

    # ------------------------------------------------------------------
    # Step 3: Remove NGINX HTTP configs & NGINX package (reverse of Phase 4)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 3/8: Removing NGINX configs and package${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Remove NGINX (configs and package)?" "Y"; then
        # Stop NGINX
        if systemctl is-active --quiet nginx 2>/dev/null; then
            info "Stopping NGINX..."
            systemctl stop nginx 2>/dev/null || true
        fi
        systemctl disable nginx 2>/dev/null || true

        # Remove site configs
        rm -f /etc/nginx/sites-enabled/amp.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/pihole.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-available/amp.conf 2>/dev/null || true
        rm -f /etc/nginx/sites-available/pihole.conf 2>/dev/null || true
        success "NGINX site configs removed."

        # Remove stream directories
        rm -rf /etc/nginx/streams-available 2>/dev/null || true
        rm -rf /etc/nginx/streams-enabled 2>/dev/null || true

        # Uninstall NGINX
        if dpkg -l nginx &>/dev/null 2>&1; then
            info "Uninstalling NGINX..."
            apt purge -y nginx nginx-extras nginx-common 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            success "NGINX uninstalled."
        else
            info "NGINX is not installed."
        fi
    else
        info "Skipping NGINX removal."
    fi

    # ------------------------------------------------------------------
    # Step 4: Remove Pi-hole (reverse of Phase 3)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 4/8: Removing Pi-hole${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Remove Pi-hole?" "Y"; then
        # Try Pi-hole's built-in uninstaller first
        if command -v pihole &>/dev/null; then
            info "Attempting Pi-hole uninstaller..."
            # Pi-hole uninstaller is interactive, so we use the manual approach
            info "Stopping Pi-hole FTL service..."
            systemctl stop pihole-FTL 2>/dev/null || true
            systemctl disable pihole-FTL 2>/dev/null || true
        fi

        # Remove Pi-hole packages
        info "Removing Pi-hole packages..."
        apt purge -y pihole-FTL pi-hole 2>/dev/null || true
        apt autoremove -y 2>/dev/null || true

        # Remove Pi-hole directories
        rm -rf /etc/pihole 2>/dev/null || true
        rm -rf /var/log/pihole 2>/dev/null || true
        rm -rf /opt/pihole 2>/dev/null || true
        rm -f /tmp/basic-install.sh 2>/dev/null || true
        success "Pi-hole removed."

        # Switch Tailscale DNS back to default (if Tailscale is still installed)
        if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
            info "Switching Tailscale DNS back to default (no Pi-hole)..."
            tailscale up --reset --accept-dns=false --accept-risk=all --ssh 2>&1 || true
            success "Tailscale DNS switched back to default."
        fi
    else
        info "Skipping Pi-hole removal."
    fi

    # ------------------------------------------------------------------
    # Step 5: Remove Tailscale (reverse of Phase 2)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 5/8: Removing Tailscale${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Remove Tailscale?" "Y"; then
        # Disconnect and stop Tailscale
        if command -v tailscale &>/dev/null; then
            info "Disconnecting Tailscale..."
            tailscale down 2>/dev/null || true
        fi

        # Stop and disable tailscaled
        systemctl disable --now tailscaled 2>/dev/null || true

        # Remove Tailscale package
        if dpkg -l tailscale &>/dev/null 2>&1; then
            info "Uninstalling Tailscale..."
            apt purge -y tailscale 2>/dev/null || true
            apt autoremove -y 2>/dev/null || true
            success "Tailscale uninstalled."
        else
            info "Tailscale is not installed."
        fi

        # Remove Tailscale repo files
        rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || true
        rm -f /etc/apt/sources.list.d/tailscale.list 2>/dev/null || true
        success "Tailscale repository files removed."
    else
        info "Skipping Tailscale removal."
    fi

    # ------------------------------------------------------------------
    # Step 6: Reset UFW firewall (reverse of Phase 7)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 6/8: Resetting UFW firewall${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Reset UFW firewall rules (keep SSH only)?" "Y"; then
        info "Resetting UFW firewall..."
        ufw --force reset

        # Re-add SSH rule to avoid lockout
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment "SSH"
        ufw --force enable

        success "UFW firewall reset. Only SSH (port 22) is allowed."
        info "Review your firewall rules with: ufw status verbose"
    else
        info "Skipping UFW reset."
    fi

    # ------------------------------------------------------------------
    # Step 7: Remove prerequisite packages (reverse of Phase 1)
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 7/8: Removing prerequisite packages${NC}"
    separator
    echo ""

    if [[ "$FORCE" == true ]] || ask_yes_no "Remove packages installed by this script (curl, wget, etc.)?" "Y"; then
        info "Removing script-installed packages..."
        # Note: We use 'remove' not 'purge' for these common utilities
        # to preserve user data/configs. They're small and commonly needed.
        apt remove -y \
            apt-transport-https \
            software-properties-common \
            netcat-openbsd \
            dnsutils \
            jq \
            2>/dev/null || true
        apt autoremove -y 2>/dev/null || true
        success "Prerequisite packages removed."
        info "Note: curl, wget, ufw, ca-certificates, gnupg, and lsb-release are kept"
        info "      as they are commonly needed by other software."
    else
        info "Skipping prerequisite package removal."
    fi

    # ------------------------------------------------------------------
    # Step 8: Clean up system changes & restore configs
    # ------------------------------------------------------------------
    echo ""
    separator
    echo -e "${BOLD}${RED}Step 8/8: Cleaning up system changes${NC}"
    separator
    echo ""

    # Restore resolv.conf from backup
    if [[ -f /etc/resolv.conf.bak.vps-setup ]]; then
        info "Restoring /etc/resolv.conf from backup..."
        cp /etc/resolv.conf.bak.vps-setup /etc/resolv.conf
        rm -f /etc/resolv.conf.bak.vps-setup
        success "/etc/resolv.conf restored."
    elif [[ -f /etc/resolv.conf.bak.pre-tailscale ]]; then
        info "Restoring /etc/resolv.conf from Tailscale backup..."
        cp /etc/resolv.conf.bak.pre-tailscale /etc/resolv.conf
        rm -f /etc/resolv.conf.bak.pre-tailscale
        success "/etc/resolv.conf restored."
    else
        # Ensure resolv.conf has valid nameservers
        info "No resolv.conf backup found. Ensuring valid DNS nameservers..."
        if ! grep -q "nameserver" /etc/resolv.conf 2>/dev/null; then
            echo "nameserver 1.1.1.1" > /etc/resolv.conf
            echo "nameserver 8.8.8.8" >> /etc/resolv.conf
            success "DNS nameservers set to 1.1.1.1 and 8.8.8.8."
        fi
    fi
    rm -f /etc/resolv.conf.bak.pre-tailscale 2>/dev/null || true
    rm -f /etc/resolv.conf.bak.vps-setup 2>/dev/null || true

    # Ask about hostname restoration
    if [[ "$FORCE" == true ]] || ask_yes_no "Restore original hostname? (Current: $(hostname))" "N"; then
        local original_hostname
        original_hostname=$(cat /etc/vps-setup/original-hostname 2>/dev/null || echo "")
        if [[ -n "$original_hostname" ]]; then
            info "Restoring hostname to: $original_hostname"
            hostnamectl set-hostname "$original_hostname"
            success "Hostname restored to: $original_hostname"
        else
            warn "Original hostname not found in marker file."
            local new_hostname
            new_hostname=$(ask_input "Enter hostname to set" "ubuntu")
            hostnamectl set-hostname "$new_hostname"
            success "Hostname set to: $new_hostname"
        fi
    fi

    # Remove marker directory and log file
    info "Removing marker files and log..."
    rm -rf "${MARKER_DIR}" 2>/dev/null || true
    rm -f "${LOG_FILE}" 2>/dev/null || true
    success "Marker files and log removed."

    # Clean up apt cache
    info "Cleaning up apt cache..."
    apt clean 2>/dev/null || true
    apt autoremove -y 2>/dev/null || true

    log "=== UNINSTALL COMPLETED ==="

    echo ""
    separator
    echo -e "${GREEN}${BOLD}Uninstall complete!${NC}"
    separator
    echo ""
    echo "The following have been removed:"
    echo "  ✓ SSL certificates & certbot"
    echo "  ✓ NGINX (configs and package)"
    echo "  ✓ Minecraft TCP proxy configs"
    echo "  ✓ Pi-hole DNS sinkhole"
    echo "  ✓ Tailscale VPN"
    echo "  ✓ UFW firewall rules (reset to SSH-only)"
    echo "  ✓ Prerequisite packages"
    echo "  ✓ Marker files and logs"
    echo ""
    echo -e "${YELLOW}Manual steps you may still need to do:${NC}"
    echo "  1. Remove DNS records pointing to this VPS (A records, SRV records)"
    echo "  2. Remove this machine from the Tailscale admin console"
    echo "  3. Review /etc/hosts for any entries added by this script"
    echo "  4. Remove the Tailscale exit node approval in the admin console"
    echo "  5. Verify /etc/resolv.conf has valid nameservers"
    echo ""
    echo -e "${YELLOW}If you want to re-run setup, use:${NC} sudo bash $0"
    echo ""
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

show_help() {
    echo "VPS Setup Script v${SCRIPT_VERSION}"
    echo ""
    echo "Usage: sudo bash $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help          Show this help message"
    echo "  --force         Re-run completed phases (ignore markers)"
    echo "  --add-mc        Add a new Minecraft instance"
    echo "  --remove-mc     Remove a Minecraft instance"
    echo "  --uninstall     Remove everything installed by this script"
    echo "  --status        Show current setup status"
    echo "  --skip-phase N  Skip a specific phase (e.g., --skip-phase 3)"
    echo ""
    echo "Phases:"
    echo "  1. Prerequisites & System Update"
    echo "  2. Tailscale Setup"
    echo "  3. Pi-hole Installation"
    echo "  4. NGINX HTTP Configuration"
    echo "  5. NGINX Stream (Minecraft) Configuration"
    echo "  6. SSL/TLS with Let's Encrypt"
    echo "  7. UFW Firewall Configuration"
    echo "  8. Tailscale DNS & Exit Node Instructions"
    echo "  9. Verification & Summary"
    echo ""
    echo "Examples:"
    echo "  sudo bash $0                    # Run full interactive setup"
    echo "  sudo bash $0 --add-mc           # Add a Minecraft instance"
    echo "  sudo bash $0 --force            # Re-run all phases"
    echo "  sudo bash $0 --uninstall        # Remove everything installed by this script"
    echo "  sudo bash $0 --skip-phase 3     # Skip Pi-hole installation"
}

show_status() {
    echo ""
    echo -e "${CYAN}${BOLD}VPS Setup Status${NC}"
    echo ""
    for i in 1 2 3 4 5 6 7 8 9; do
        local phase_name=""
        case $i in
            1) phase_name="Prerequisites & System Update" ;;
            2) phase_name="Tailscale Setup" ;;
            3) phase_name="Pi-hole Installation" ;;
            4) phase_name="NGINX HTTP Configuration" ;;
            5) phase_name="NGINX Stream (Minecraft) Configuration" ;;
            6) phase_name="SSL/TLS with Let's Encrypt" ;;
            7) phase_name="UFW Firewall Configuration" ;;
            8) phase_name="Tailscale DNS & Exit Node Instructions" ;;
            9) phase_name="Verification & Summary" ;;
        esac
        if is_phase_completed "phase${i}"; then
            echo -e "  ${GREEN}✓${NC} Phase ${i}: ${phase_name}"
        else
            echo -e "  ${RED}✗${NC} Phase ${i}: ${phase_name}"
        fi
    done
    echo ""
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
        --force)
            FORCE=true
            shift
            ;;
        --add-mc)
            ACTION="add-mc"
            shift
            ;;
        --remove-mc)
            ACTION="remove-mc"
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
            shift
            ;;
        --status)
            show_status
            exit 0
            ;;
        --skip-phase)
            SKIP_PHASES+=("$2")
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# If --force, remove all marker files
if [[ "$FORCE" == true ]]; then
    warn "Force mode: removing all phase markers..."
    rm -rf "${MARKER_DIR}"/*.done 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------

main() {
    check_root
    check_os

    case "$ACTION" in
        setup)
            banner

            echo -e "${BOLD}This script will set up your VPS with:${NC}"
            echo "  • Tailscale (VPN + exit node)"
            echo "  • Pi-hole (DNS sinkhole + ad blocker)"
            echo "  • NGINX (reverse proxy with SSL)"
            echo "  • Minecraft Java Edition TCP proxy"
            echo "  • UFW firewall"
            echo ""
            echo -e "${YELLOW}This is an interactive setup. You will be prompted for configuration details.${NC}"
            echo ""

            if ! ask_yes_no "Do you want to proceed with the setup?" "Y"; then
                info "Setup cancelled."
                exit 0
            fi

            # Run phases
            if [[ ! " ${SKIP_PHASES[*]} " =~ " 1 " ]]; then
                phase1_prerequisites
            else
                info "Skipping Phase 1 (Prerequisites) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 2 " ]]; then
                phase2_tailscale
            else
                info "Skipping Phase 2 (Tailscale) per user request."
                # Still try to discover TS_IP
                TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 3 " ]]; then
                phase3_pihole
            else
                info "Skipping Phase 3 (Pi-hole) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 4 " ]]; then
                phase4_nginx_http
            else
                info "Skipping Phase 4 (NGINX HTTP) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 5 " ]]; then
                phase5_nginx_stream
            else
                info "Skipping Phase 5 (Minecraft Stream) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 6 " ]]; then
                phase6_ssl
            else
                info "Skipping Phase 6 (SSL) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 7 " ]]; then
                phase7_firewall
            else
                info "Skipping Phase 7 (Firewall) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 8 " ]]; then
                phase8_tailscale_dns
            else
                info "Skipping Phase 8 (Tailscale DNS) per user request."
            fi

            if [[ ! " ${SKIP_PHASES[*]} " =~ " 9 " ]]; then
                phase9_verification
            else
                info "Skipping Phase 9 (Verification) per user request."
            fi

            echo ""
            success "Setup complete! Review the summary above for next steps."
            ;;
        add-mc)
            # Discover existing values
            TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
            VPS_PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "UNKNOWN")
            AMP_DOMAIN=$(grep "server_name" /etc/nginx/sites-available/amp.conf 2>/dev/null | head -1 | awk '{print $2}' | tr -d ';' || echo "unknown")
            add_minecraft_instance
            ;;
        remove-mc)
            remove_minecraft_instance
            ;;
        uninstall)
            uninstall_all
            ;;
    esac
}

main "$@"