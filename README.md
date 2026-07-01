# VPS Setup Script

Interactive Bash script to configure an Ubuntu VPS with **NGINX** (reverse proxy + Minecraft TCP proxy), **Pi-hole** (DNS sinkhole), and **Tailscale** (VPN + exit node).

## Architecture

```
Internet ──► NGINX (VPS)
                ├── HTTP (ports 80/443):
                │   ├── amp.example.com  ──► <AMP_TAILSCALE_IP>:443 (AMP web panel via Tailscale)
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
  _minecraft._tcp.skyblock.example.com → play.example.com:25567

Tailscale Network:
  VPS (exit node) ◄──► <AMP_TAILSCALE_IP> (AMP machine)
  Pi-hole DNS: 100.x.x.x (VPS Tailscale IP) configured as tailnet DNS
```

## Prerequisites

- **Ubuntu VPS** (20.04 LTS or newer) with root/sudo access
- **Domain names** pointing to your VPS public IP (for AMP and Pi-hole)
- **Tailscale account** (free tier works)
- **AMP server** already running on a Tailscale-connected machine (IP prompted during setup)
- **Ports open** on VPS firewall: 22 (SSH), 80/443 (HTTP/HTTPS), 25565+ (Minecraft)

## Security Note

This script is safe for public repositories — **no secrets, tokens, or private IPs are hardcoded**. All sensitive values (AMP server IP, Pi-hole password, domain names, email) are collected interactively at runtime. The default AMP IP shown in prompts is a placeholder (`123.45.67.89`) — replace it with your own when running the script.

## Quick Start

```bash
# Download and run the script
wget https://raw.githubusercontent.com/your-repo/vps-setup/main/vps-setup.sh
chmod +x vps-setup.sh
sudo ./vps-setup.sh
```

Or clone this repository:

```bash
git clone https://github.com/your-repo/vps-setup.git
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
| 2 | Tailscale Setup | Yes (auth, exit node) |
| 3 | Pi-hole Installation | Yes (DNS upstream, password) |
| 4 | NGINX HTTP Configuration | Yes (domain names) |
| 5 | NGINX Stream (Minecraft) | Yes (instance count, names, ports) |
| 6 | SSL/TLS with Let's Encrypt | Yes (email) |
| 7 | UFW Firewall Configuration | Yes (confirm reset) |
| 8 | Tailscale DNS & Exit Node | Manual steps printed |
| 9 | Verification & Summary | No |

## Interactive Questions

During setup, you'll be asked:

1. **VPS hostname** — Set the system hostname
2. **Tailscale authentication** — Browser-based auth flow
3. **Exit node** — Should this VPS be a Tailscale exit node?
4. **Pi-hole DNS upstream** — Cloudflare, Google, Quad9, or custom
5. **Pi-hole admin password** — Set the web UI password
6. **AMP domain name** — e.g., `amp.example.com`
7. **Pi-hole domain name** — e.g., `pihole.example.com`
8. **Let's Encrypt email** — For SSL certificate notifications
9. **Minecraft instance count** — How many MC servers to proxy
10. **Per-instance details** — Name, AMP port, VPS port for each

## Minecraft Proxy

The script configures NGINX's `stream` module to proxy Minecraft Java Edition TCP connections from the VPS to the AMP server on the Tailscale network.

### Adding Instances After Setup

```bash
sudo bash vps-setup.sh --add-mc
```

You'll be prompted for:
- **Instance name** — Used in SRV records (e.g., "survival")
- **AMP server port** — Port on the AMP machine (e.g., 25565)
- **VPS listening port** — Port on the VPS (defaults to same as AMP port)

### Removing Instances

```bash
sudo bash vps-setup.sh --remove-mc
```

### DNS SRV Records

For each Minecraft instance, add an SRV record to your DNS:

```
_minecraft._tcp.<name>.<domain>. 0 5 <port> <domain>.
```

Example:
```
_minecraft._tcp.survival.example.com. 0 5 25565 example.com.
_minecraft._tcp.creative.example.com. 0 5 25566 example.com.
```

Players can then connect using `survival.example.com` in their Minecraft client.

## Post-Setup Manual Steps

After running the script, complete these steps manually:

### 1. DNS Configuration

Point your domain names to the VPS public IP:

| Type | Name | Value |
|------|------|-------|
| A | `amp.example.com` | `YOUR_VPS_IP` |
| A | `pihole.example.com` | `YOUR_VPS_IP` |
| A | `play.example.com` | `YOUR_VPS_IP` (for Minecraft SRV) |
| SRV | `_minecraft._tcp.survival.example.com` | `0 5 25565 play.example.com.` |

### 2. Tailscale DNS

1. Go to [Tailscale Admin Console → DNS](https://login.tailscale.com/admin/dns)
2. Add a custom DNS server: your VPS Tailscale IP (100.x.x.x)
3. This makes all Tailscale devices use Pi-hole for DNS

### 3. Tailscale Exit Node (if configured)

1. Go to [Tailscale Admin Console → Machines](https://login.tailscale.com/admin/machines)
2. Find your VPS in the machine list
3. Click the three-dot menu → "Edit route settings"
4. Enable "Use as exit node"

## Idempotency

The script is **idempotent** — safe to re-run. Completed phases are tracked via marker files in `/etc/vps-setup/`:

```
/etc/vps-setup/phase1.done
/etc/vps-setup/phase2.done
...
/etc/vps-setup/phase9.done
```

To re-run a completed phase, use `--force` or delete the corresponding marker file:

```bash
# Re-run all phases
sudo bash vps-setup.sh --force

# Re-run only phase 6 (SSL)
sudo rm /etc/vps-setup/phase6.done
sudo bash vps-setup.sh
```

## Uninstalling

The `--uninstall` flag removes everything the setup script installed. It reverses all 9 phases in reverse order:

```bash
# Interactive uninstall (confirms each step)
sudo bash vps-setup.sh --uninstall

# Uninstall without confirmation prompts
sudo bash vps-setup.sh --uninstall --force
```

### What gets removed

| Step | What's removed |
|------|---------------|
| 1 | SSL certificates & certbot (`/etc/letsencrypt/`, certbot package) |
| 2 | Minecraft proxy configs (`/etc/nginx/streams-*`) & UFW rules |
| 3 | NGINX site configs & NGINX package |
| 4 | Pi-hole (service, packages, `/etc/pihole/`, `/var/log/pihole/`) |
| 5 | Tailscale (service, package, repo files, GPG key) |
| 6 | UFW firewall rules (reset to SSH-only) |
| 7 | Prerequisite packages (curl, wget, etc. — common ones are kept) |
| 8 | System changes (resolv.conf restored, hostname optionally restored, markers & logs deleted) |

### What's NOT removed

- **DNS records** — You must manually remove A records, SRV records, etc. from your domain
- **Tailscale admin console** — Remove the machine from [Tailscale Admin Console](https://login.tailscale.com/admin/machines)
- **Tailscale exit node approval** — Revoke in the admin console
- **`/etc/hosts` entries** — Review and remove any entries added by the script
- **Common packages** — `ufw`, `ca-certificates`, `gnupg`, `lsb-release`, `curl`, `wget` are kept

### After uninstalling

1. Verify `/etc/resolv.conf` has valid nameservers (the script restores from backup or sets `1.1.1.1`/`8.8.8.8`)
2. Remove DNS records pointing to this VPS
3. Remove the machine from the Tailscale admin console
4. Review `/etc/hosts` for stale entries

## Files Modified on Target VPS

| File | Purpose |
|------|---------|
| `/etc/pihole/pihole-FTL.conf` | Pi-hole webserver port config |
| `/etc/pihole/setupVars.conf` | Pi-hole installer variables |
| `/etc/nginx/sites-available/amp.conf` | AMP reverse proxy config |
| `/etc/nginx/sites-available/pihole.conf` | Pi-hole reverse proxy config |
| `/etc/nginx/streams-available/minecraft.conf` | Minecraft TCP stream proxy |
| `/etc/nginx/nginx.conf` | Stream include directive |
| `/etc/nginx/sites-enabled/` | Symlinks to HTTP configs |
| `/etc/nginx/streams-enabled/` | Symlinks to stream configs |
| `/etc/letsencrypt/` | SSL certificates (managed by certbot) |
| `/etc/vps-setup/` | Phase completion markers & original hostname backup |
| `/var/log/vps-setup.log` | Setup script log |

## Troubleshooting

### NGINX won't start

```bash
# Test configuration
sudo nginx -t

# Check error logs
sudo tail -f /var/log/nginx/error.log
```

### Pi-hole not accessible

```bash
# Check Pi-hole status
pihole status

# Check if port 8443 is listening
sudo ss -tlnp | grep 8443

# Restart Pi-hole FTL service (v6+)
sudo systemctl restart pihole-FTL

# Legacy restart (v5)
pihole restartdns
```

### Tailscale not connected

```bash
# Check status
tailscale status

# Re-authenticate (use --reset to avoid flag accumulation errors)
sudo tailscale up --reset --accept-risk=all

# If you get "changing settings requires mentioning all non-default flags", use --reset:
sudo tailscale up --reset --accept-risk=all --accept-dns=false --ssh

# Check logs
sudo journalctl -u tailscaled -f
```

### SSL certificate issues

```bash
# Check certificates
sudo certbot certificates

# Force renewal (dry run)
sudo certbot renew --dry-run

# Re-obtain certificates
sudo bash vps-setup.sh --force
```

### Minecraft can't connect

```bash
# Check if port is open
nc -zv YOUR_VPS_IP 25565

# Check NGINX stream config
sudo nginx -t

# Check if NGINX is listening on the port
sudo ss -tlnp | grep 25565

# Check firewall
sudo ufw status | grep 25565
```

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pi-hole deployment | Bare-metal | Per user preference; simpler than Docker |
| Pi-hole version | v6+ compatible | Uses `pihole setpassword` and `systemctl restart pihole-FTL` |
| Pi-hole web port | 8443 | Avoids conflict with NGINX on 80/443 |
| AMP connection | HTTPS with `proxy_ssl_verify off` | AMP uses self-signed certs on Tailscale |
| Minecraft proxy | NGINX `stream` module | TCP proxying for Java Edition |
| MC routing | SRV records with subdomains | Clean player experience |
| RCON proxy | Not included | Stays within Tailscale network |
| SSL | Let's Encrypt via certbot | Free, auto-renewing certificates |
| Firewall | UFW | Simpler than iptables, Ubuntu default |
| Script language | Bash | Universal on Ubuntu, no dependencies |
| Idempotency | Marker files | Safe to re-run, skip completed phases |

## Excluded from Scope

- AMP server installation/configuration (already running on remote machine)
- Tailscale admin console configuration (manual steps provided)
- Pi-hole blocklist configuration (post-install customization)
- Monitoring/logging setup
- Automated backups
- DNS registrar configuration (manual steps provided)
- Minecraft Bedrock Edition (UDP) — only Java Edition (TCP) is supported
- RCON proxying — stays within Tailscale network
- SSL/TLS on Minecraft game traffic (not standard for Java Edition)

## License

This script is provided as-is for personal use. See individual software projects for their licenses:

- [Pi-hole](https://pi-hole.net/) — [EUPL](https://docs.pi-hole.net/guides/github/dco/)
- [NGINX](https://nginx.org/) — [BSD-2-Clause](https://nginx.org/LICENSE)
- [Tailscale](https://tailscale.com/) — [BSD-3-Clause](https://github.com/tailscale/tailscale/blob/main/LICENSE)
- [Certbot](https://certbot.eff.org/) — [Apache 2.0](https://github.com/certbot/certbot/blob/main/LICENSE.txt)