# VPS Setup Script v2.0

Interactive Bash script to configure an Ubuntu VPS with **NGINX** (reverse proxy + Minecraft TCP proxy), **Pi-hole** (DNS sinkhole), and **Tailscale** (VPN + exit node).

## Architecture

```
Internet ──► NGINX (VPS)
                ├── HTTP (ports 80/443):
                │   ├── mcpanel.example.com  ──► <AMP_TAILSCALE_IP>:8080 (AMP web panel via Tailscale, HTTP)
                │   └── pihole.example.com ──► localhost:8443 (Pi-hole web UI)
                │
                └── Stream/TCP (dynamic ports):
                    ├── :25565 ──► <AMP_TAILSCALE_IP>:25565 (MC instance 1)
                    ├── :25566 ──► <AMP_TAILSCALE_IP>:25566 (MC instance 2)
                    └── :25567 ──► <AMP_TAILSCALE_IP>:25567 (MC instance 3)
                    ... (as many as needed)

DNS SRV Records:
  _minecraft._tcp.survival.example.com → play.example.com:25565
  _minecraft._tcp.creative.example.com → play.example.com:25566

Tailscale Network:
  VPS (exit node) ◄──► <AMP_TAILSCALE_IP> (AMP machine)
  Pi-hole DNS: 100.x.x.x (VPS Tailscale IP) configured as tailnet DNS
```

## Prerequisites

- **Ubuntu VPS** (20.04 LTS or newer) with root/sudo access
- **Domain names** pointing to your VPS public IP (for AMP and Pi-hole)
- **Tailscale account** (free tier works)
- **AMP server** already running on a Tailscale-connected machine (HTTP on port 8080)
- **Ports open** on VPS firewall: 22 (SSH), 80/443 (HTTP/HTTPS), 25565+ (Minecraft)

## Security Note

This script is safe for public repositories — **no secrets, tokens, or private IPs are hardcoded**. All sensitive values (AMP server IP, Pi-hole password, domain names, email) are collected interactively at runtime.

## Quick Start

```bash
# Clone and run
git clone <your-repo-url>
cd vps-setup
sudo bash vps-setup.sh
```

## Usage

```bash
# Run full interactive setup
sudo bash vps-setup.sh

# Add a new Minecraft instance after initial setup
sudo bash vps-setup.sh --add-mc

# Remove a Minecraft instance
sudo bash vps-setup.sh --remove-mc

# Remove everything installed by this script
sudo bash vps-setup.sh --uninstall

# Remove everything without confirmation prompts
sudo bash vps-setup.sh --uninstall --force

# Show current setup status
sudo bash vps-setup.sh --status

# Re-run all phases (ignore completed markers)
sudo bash vps-setup.sh --force

# Skip specific phases
sudo bash vps-setup.sh --skip-phase 3 --skip-phase 6

# Show help
sudo bash vps-setup.sh --help
```

## Setup Phases

| Phase | Description | Interactive? |
|-------|-------------|-------------|
| 1 | Prerequisites & System Update | Yes (hostname) |
| 2 | Tailscale Setup + DNS + Exit Node | Yes (auth, exit node, AMP IP) |
| 3 | Pi-hole Installation | Yes (password — output to console) |
| 4 | NGINX HTTP Configuration + SSL | Yes (domain names, email, certbot) |
| 5 | NGINX Stream (Minecraft TCP) | Yes (instance count, names, ports) |
| 6 | UFW Firewall Configuration | Yes (confirm reset) |
| 7 | Verification & Summary | No |

## Interactive Questions

During setup, you'll be asked:

1. **VPS hostname** — Set the system hostname
2. **Tailscale authentication** — Browser-based auth flow
3. **Exit node** — Should this VPS be a Tailscale exit node?
4. **AMP server Tailscale IP** — e.g., `100.78.246.53`
5. **AMP server port** — Default: `8080` (HTTP)
6. **Pi-hole admin password** — Set the web UI password (displayed in console after setup)
7. **AMP domain name** — e.g., `mcpanel.syko.network`
8. **Pi-hole domain name** — e.g., `pihole.syko.network`
9. **Let's Encrypt email** — For SSL certificate notifications
10. **Minecraft instance count** — How many MC servers to proxy
11. **Per-instance details** — Name, AMP port, VPS port for each

## Exit Node Configuration

When you enable the Tailscale exit node, the script automatically configures:

1. **IP forwarding** — `net.ipv4.ip_forward=1` and `net.ipv6.conf.all.forwarding=1` (persisted to `/etc/sysctl.d/99-tailscale.conf`)
2. **NAT masquerading** — nftables rule `oifname != "tailscale0" masquerade` (or iptables fallback)
3. **UFW forward rule** — `ufw route allow in on tailscale0 out on <wan_interface>`

> **Critical**: UFW blocks forwarded traffic by default. Without the UFW forward rule,
> packets from tailnet clients arrive at the VPS but are dropped before reaching the
> internet. This was the root cause of the "exit node breaks internet" bug in v1.0.

Per Tailscale docs: https://tailscale.com/kb/1019/subnets

## Pi-hole Configuration

- **DNS upstream**: Cloudflare (1.1.1.1) + Google (8.8.8.8)
- **Web UI port**: 8443 (configured via `pihole-FTL --config` for v6, `pihole-FTL.conf` for v5)
- **Password**: Set interactively, displayed in console after setup
- **Service restart**: `systemctl restart pihole-FTL` (v6) or `pihole restartdns` (v5)

## NGINX Configuration

### AMP Reverse Proxy (Phase 4)

The AMP proxy uses the configuration template from CubeCoders with:
- HTTP proxy to `<AMP_TS_IP>:8080` via Tailscale
- WebSocket support (`Upgrade` / `Connection` headers)
- `X-AMP-Scheme` header for AMP
- 86400s read/send timeouts
- 10240M max body size
- Proxy buffering disabled

### SSL (Phase 4)

SSL certificates are obtained automatically via **Certbot** (Let's Encrypt):
- HTTP-only configs are created first
- Certbot runs with `--nginx --redirect` to add SSL and HTTP→HTTPS redirect
- Certificates auto-renew via certbot timer

### Minecraft TCP Stream Proxy (Phase 5)

- Uses NGINX `stream` module (tested with `nginx -t` before use)
- Installs `libnginx-mod-stream` if the module isn't available
- Each Minecraft instance gets a `server` block in `/etc/nginx/streams-available/minecraft.conf`
- The `stream {}` block is added to `nginx.conf` before the `http {}` block

## Minecraft Proxy

The script configures NGINX's `stream` module to proxy Minecraft Java Edition TCP connections from the VPS to the AMP server on the Tailscale network.

After setup, add SRV DNS records so players can connect without specifying a port:

```
_minecraft._tcp.survival.example.com. 0 5 25565 mcpanel.example.com.
_minecraft._tcp.creative.example.com. 0 5 25566 mcpanel.example.com.
```

## Manual Steps After Setup

### 1. Tailscale DNS

1. Go to [Tailscale Admin Console → DNS](https://login.tailscale.com/admin/dns)
2. Add a custom DNS server: your VPS Tailscale IP (100.x.x.x)
3. This makes all Tailscale devices use Pi-hole for DNS

### 2. Tailscale Exit Node (if configured)

1. Go to [Tailscale Admin Console → Machines](https://login.tailscale.com/admin/machines)
2. Find your VPS in the machine list
3. Click the three-dot menu → "Edit route settings"
4. Enable "Use as exit node"

> **Note:** The script automatically configures IP forwarding, NAT masquerading, and
> UFW forward rules. No additional network configuration is needed on the VPS.

### 3. Minecraft SRV Records

Add SRV records to your DNS registrar (printed at the end of setup).

## Idempotency

The script is **idempotent** — safe to re-run. Completed phases are tracked via marker files in `/etc/vps-setup/`:

```
/etc/vps-setup/phase1.done
/etc/vps-setup/phase2.done
...
/etc/vps-setup/phase7.done
```

To re-run a completed phase, use `--force` or delete the corresponding marker file:

```bash
rm /etc/vps-setup/phase4.done
sudo bash vps-setup.sh
```

## Logging

All setup actions are logged to `/var/log/vps-setup.log` with timestamps:

```
[2026-07-01 04:49:29] [INFO] Checking NGINX stream module...
[2026-07-01 04:49:30] [OK] NGINX stream module is available.
```

## Uninstalling

To remove everything installed by this script:

```bash
sudo bash vps-setup.sh --uninstall
```

This reverses all 7 phases in reverse order:
1. Removes SSL certificates and Certbot
2. Removes NGINX stream configs (Minecraft proxy)
3. Removes NGINX HTTP configs and uninstalls NGINX
4. Removes Pi-hole
5. Removes Tailscale and exit node configuration (IP forwarding, NAT, UFW forward rules)
6. Resets UFW firewall to SSH-only
7. Removes marker files and restores DNS

You may also need to manually:
- Remove the Tailscale exit node approval in the admin console
- Remove the Tailscale DNS server in the admin console
- Remove DNS records for your domains

## Troubleshooting

### Exit node doesn't route internet traffic

The script configures IP forwarding, NAT masquerading, and UFW forward rules automatically. If traffic still doesn't route:

```bash
# Check IP forwarding is enabled
sysctl net.ipv4.ip_forward
# Should return: net.ipv4.ip_forward = 1

# Check UFW forward rule exists
ufw status verbose | grep tailscale
# Should show: tailscale0 -> <wan_interface> ALLOW

# Check NAT masquerade rule
nft list table ip tailscale
# Should show: oifname != "tailscale0" masquerade

# Check the exit node is approved in Tailscale admin console
tailscale status
```

### 502 Bad Gateway on AMP domain

This means NGINX can't connect to the AMP upstream. Check:

```bash
# Test connectivity to AMP from the VPS
curl http://<AMP_TS_IP>:8080

# Check Tailscale is connected
tailscale status

# Check NGINX error logs
tail -f /var/log/nginx/error.log
```

### NGINX stream module not available

The script tests for the stream module using `nginx -t` with a temp config. If it's not available, it installs `libnginx-mod-stream` automatically. If that fails:

```bash
sudo apt install libnginx-mod-stream
sudo nginx -t
```

## File Structure

```
vps-setup.sh              # Main setup script (v2.0)
archive/
  vps-setup-v1.sh         # Previous version (archived)
README.md                 # This file
.gitignore                # Ignores archive/ and .env
```