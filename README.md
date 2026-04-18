# wireguard.sh
Minimal WireGuard installer for Ubuntu using only official packages, no external binaries or services.

This script installs and manages a WireGuard VPN on Ubuntu 24+ using only official Ubuntu packages and the kernel WireGuard module.

## Features
- Uses UDP 443 or 80 (for restrictive networks)
- No external scripts, binaries, or IP lookup services
- No BoringTun or userspace fallback
- Simple CLI for client management
- Fully based on Ubuntu `apt` packages

## Requirements
- Ubuntu 24.04+
- Root access
- Kernel supports WireGuard

## Installation

```bash
sudo apt update
sudo apt install git -y

git clone https://github.com/boralp/wireguard.sh
cd wireguard.sh

chmod +x wireguard.sh
sudo mv wireguard.sh /usr/local/sbin/wg-safe

sudo wg-safe install --endpoint YOUR.SERVER.IP --port 443
```

## No GIT installation
```bash
curl -fsSL https://raw.githubusercontent.com/boralp/wireguard.sh/main/wireguard.sh -o wireguard.sh
chmod +x wireguard.sh
sudo mv wireguard.sh /usr/local/sbin/wg-safe

sudo wg-safe install --endpoint YOUR.SERVER.IP --port 443
````

## Usage

Create client:

```bash
sudo wg-safe create username1
```

Delete client:

```bash
sudo wg-safe delete username1
```

List clients:

```bash
sudo wg-safe list
```

Show client info:

```bash
sudo wg-safe show username1
```

Uninstall:

```bash
sudo wg-safe uninstall
```

## Updates
Manual updates:

  ```bash
  sudo apt update && sudo apt upgrade
  ```
Optional automatic security updates:
```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

## Optional: Firewall Hardening

After installation, you can restrict inbound traffic to reduce attack surface.

**Warning:** Misconfiguration can lock you out of your server.  
Always ensure SSH access is allowed before applying restrictive rules.

* Replace `443` with `80` if using UDP 80
* Verify access before disconnecting your session
* Test in a separate SSH session if possible

### Using iptables (manual control)

```bash
# Check current rules
sudo iptables -L -n

# Allow SSH (adjust port if needed)
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# Allow WireGuard (UDP 443 or your chosen port)
sudo iptables -I INPUT -p udp --dport 443 -j ACCEPT

# Allow established/related connections (required)
sudo iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
sudo iptables -I INPUT -i lo -j ACCEPT

# Set default policies
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# Persist rules (Ubuntu)
sudo apt install -y iptables-persistent
sudo iptables-save | sudo tee /etc/iptables/rules.v4
````

### Using UFW (simpler)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (adjust port if needed)
sudo ufw allow 22/tcp

# Allow WireGuard (UDP 443 or your chosen port)
sudo ufw allow 443/udp

sudo ufw enable
```

````md
## Optional: Firewall Hardening

After installation, you can restrict inbound traffic to reduce attack surface.

**Warning:** Misconfiguration can lock you out of your server.  
Always ensure SSH access is allowed before applying restrictive rules.

### Using iptables (manual control)

```bash
# Check current rules
sudo iptables -L -n

# Allow SSH (adjust port if needed)
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT

# Allow WireGuard (UDP 443 or your chosen port)
sudo iptables -I INPUT -p udp --dport 443 -j ACCEPT

# Allow established/related connections (required)
sudo iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow loopback
sudo iptables -I INPUT -i lo -j ACCEPT

# Set default policies
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# Persist rules (Ubuntu)
sudo apt install -y iptables-persistent
sudo iptables-save | sudo tee /etc/iptables/rules.v4
````

### Using UFW (simpler)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH (adjust port if needed)
sudo ufw allow 22/tcp

# Allow WireGuard (UDP 443 or your chosen port)
sudo ufw allow 443/udp

sudo ufw enable
```

---

## Optional: Fail2Ban (SSH protection)

Fail2Ban helps block repeated failed login attempts, especially useful for SSH.

### Install

```bash
sudo apt install fail2ban -y
```

### Basic configuration

```bash
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo nano /etc/fail2ban/jail.local
```

Ensure the SSH jail is enabled:

```ini
[sshd]
enabled = true
port = 22
```

Restart service:

```bash
sudo systemctl restart fail2ban
```

Check status:

```bash
sudo fail2ban-client status sshd
```

## Notes

* WireGuard uses **UDP only**
* Port 443 is recommended for restrictive networks
* This does NOT mimic HTTPS traffic
* Updates are handled via:

## Trust Model

* Only Ubuntu repositories are trusted
* No third-party downloads or auto-update mechanisms
* No external network calls during install
