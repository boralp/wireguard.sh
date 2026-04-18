#!/usr/bin/env bash
set -euo pipefail

WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_CONF="${WG_DIR}/${WG_IF}.conf"
WG_SUBNET="10.7.0"
WG_SERVER_ADDR="${WG_SUBNET}.1/24"
SYSCTL_CONF="/etc/sysctl.d/99-wireguard-forward.conf"
IPTABLES_SERVICE="/etc/systemd/system/wg-iptables.service"
STATE_DIR="/var/lib/wg-safe"
META_ENV="${STATE_DIR}/server.env"
DEFAULT_DNS="9.9.9.9, 149.112.112.112"

need_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "Run as root."; exit 1; }
}

need_ubuntu_24() {
  [[ -r /etc/os-release ]] || { echo "Cannot detect OS."; exit 1; }
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || { echo "Ubuntu only."; exit 1; }
  case "${VERSION_ID:-}" in
    24.04|24.10|25.04|25.10) ;;
    *) echo "This script expects Ubuntu 24.x or newer."; exit 1 ;;
  esac
}

need_kernel_wireguard() {
  modprobe wireguard 2>/dev/null || true
  lsmod | grep -q '^wireguard[[:space:]]' || {
    echo "Kernel WireGuard module unavailable. Refusing userspace fallback."
    exit 1
  }
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_name() {
  local raw="${1:-}"
  sed 's/[^0-9A-Za-z_-]/_/g' <<< "${raw}" | cut -c1-15
}

default_iface() {
  ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

default_ip() {
  ip -4 route get 9.9.9.9 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

load_meta() {
  [[ -f "${META_ENV}" ]] || return 1
  # shellcheck disable=SC1090
  . "${META_ENV}"
}

save_meta() {
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  cat > "${META_ENV}" <<EOF
ENDPOINT='${ENDPOINT}'
PORT='${PORT}'
DNS='${DNS}'
EXT_IFACE='${EXT_IFACE}'
EOF
  chmod 600 "${META_ENV}"
}

install_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard qrencode iptables
}

enable_forwarding() {
  cat > "${SYSCTL_CONF}" <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

write_iptables_service() {
  local iface="$1"
  local port="$2"
  local iptables_path
  iptables_path="$(command -v iptables)"

  cat > "${IPTABLES_SERVICE}" <<EOF
[Unit]
Description=WireGuard iptables rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${iptables_path} -w 5 -t nat -A POSTROUTING -s ${WG_SUBNET}.0/24 -o ${iface} -j MASQUERADE
ExecStart=${iptables_path} -w 5 -I INPUT -p udp --dport ${port} -j ACCEPT
ExecStart=${iptables_path} -w 5 -I FORWARD -i ${WG_IF} -j ACCEPT
ExecStart=${iptables_path} -w 5 -I FORWARD -i ${WG_IF} -o ${iface} -j ACCEPT
ExecStart=${iptables_path} -w 5 -I FORWARD -i ${iface} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ExecStop=${iptables_path} -w 5 -t nat -D POSTROUTING -s ${WG_SUBNET}.0/24 -o ${iface} -j MASQUERADE
ExecStop=${iptables_path} -w 5 -D INPUT -p udp --dport ${port} -j ACCEPT
ExecStop=${iptables_path} -w 5 -D FORWARD -i ${WG_IF} -j ACCEPT
ExecStop=${iptables_path} -w 5 -D FORWARD -i ${WG_IF} -o ${iface} -j ACCEPT
ExecStop=${iptables_path} -w 5 -D FORWARD -i ${iface} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now wg-iptables.service
}

server_public_key() {
  wg show "${WG_IF}" public-key 2>/dev/null || wg pubkey < <(awk '/^PrivateKey/ {print $3}' "${WG_CONF}")
}

client_exists() {
  local client="$1"
  grep -q "^# BEGIN_PEER ${client}$" "${WG_CONF}" 2>/dev/null
}

next_octet() {
  local octet=2
  while grep -q "AllowedIPs = ${WG_SUBNET}.${octet}/32" "${WG_CONF}" 2>/dev/null; do
    octet=$((octet + 1))
  done
  (( octet <= 254 )) || { echo "Subnet full."; exit 1; }
  echo "${octet}"
}

reload_live_config() {
  wg syncconf "${WG_IF}" <(wg-quick strip "${WG_IF}")
}

usage() {
  cat <<'EOF'
Usage:
  wg-safe install --endpoint <host_or_ip> [--port 443|80] [--dns "9.9.9.9, 149.112.112.112"]
  wg-safe create <client>
  wg-safe delete <client>
  wg-safe list
  wg-safe show <client>
  wg-safe uninstall

Notes:
  - WireGuard is UDP only.
  - Use UDP 443 or UDP 80.
  - 443 is generally preferred on restrictive networks.
EOF
}

install_cmd() {
  [[ ! -f "${WG_CONF}" ]] || { echo "Already installed."; exit 1; }

  local endpoint=""
  local port="443"
  local dns="${DEFAULT_DNS}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --endpoint) endpoint="${2:-}"; shift 2 ;;
      --port) port="${2:-}"; shift 2 ;;
      --dns) dns="${2:-}"; shift 2 ;;
      *) echo "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  [[ -n "${endpoint}" ]] || { echo "--endpoint is required."; exit 1; }
  [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { echo "Invalid port."; exit 1; }

  EXT_IFACE="$(default_iface)"
  [[ -n "${EXT_IFACE}" ]] || { echo "Could not detect external interface."; exit 1; }

  ENDPOINT="${endpoint}"
  PORT="${port}"
  DNS="${dns}"

  install_packages
  need_kernel_wireguard

  mkdir -p "${WG_DIR}" "${STATE_DIR}"
  chmod 700 "${WG_DIR}" "${STATE_DIR}"

  local server_priv
  server_priv="$(wg genkey)"

  cat > "${WG_CONF}" <<EOF
# Managed by wg-safe
# ENDPOINT ${ENDPOINT}

[Interface]
Address = ${WG_SERVER_ADDR}
PrivateKey = ${server_priv}
ListenPort = ${PORT}
SaveConfig = false
EOF

  chmod 600 "${WG_CONF}"

  enable_forwarding
  write_iptables_service "${EXT_IFACE}" "${PORT}"
  systemctl enable --now "wg-quick@${WG_IF}.service"

  save_meta

  echo "Installed."
  echo "Port: UDP ${PORT}"
  echo "Endpoint: ${ENDPOINT}"
  echo "External interface: ${EXT_IFACE}"
  echo "Add a client with: wg-safe create bora"
}

create_cmd() {
  load_meta || { echo "Not installed."; exit 1; }

  local raw="${1:-}"
  [[ -n "${raw}" ]] || { echo "Client name required."; exit 1; }

  local client
  client="$(sanitize_name "${raw}")"
  [[ -n "${client}" ]] || { echo "Invalid client name."; exit 1; }

  client_exists "${client}" && { echo "Client exists."; exit 1; }

  local octet client_priv client_pub psk out
  octet="$(next_octet)"
  client_priv="$(wg genkey)"
  client_pub="$(printf '%s' "${client_priv}" | wg pubkey)"
  psk="$(wg genpsk)"
  out="${PWD}/${client}.conf"

  cat >> "${WG_CONF}" <<EOF

# BEGIN_PEER ${client}
[Peer]
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${WG_SUBNET}.${octet}/32
# END_PEER ${client}
EOF

  reload_live_config

  cat > "${out}" <<EOF
[Interface]
Address = ${WG_SUBNET}.${octet}/24
DNS = ${DNS}
PrivateKey = ${client_priv}

[Peer]
PublicKey = $(server_public_key)
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ENDPOINT}:${PORT}
PersistentKeepalive = 25
EOF

  chmod 600 "${out}"

  echo "Created client ${client}"
  echo "Config: ${out}"
  if cmd_exists qrencode; then
    echo
    qrencode -t ANSIUTF8 < "${out}" || true
    echo
  fi
}

delete_cmd() {
  load_meta || { echo "Not installed."; exit 1; }

  local raw="${1:-}"
  [[ -n "${raw}" ]] || { echo "Client name required."; exit 1; }

  local client pubkey
  client="$(sanitize_name "${raw}")"
  client_exists "${client}" || { echo "Client not found."; exit 1; }

  pubkey="$(sed -n "/^# BEGIN_PEER ${client}$/,/^# END_PEER ${client}$/p" "${WG_CONF}" | awk '/^PublicKey/ {print $3; exit}')"
  [[ -n "${pubkey}" ]] && wg set "${WG_IF}" peer "${pubkey}" remove || true
  sed -i "/^# BEGIN_PEER ${client}$/,/^# END_PEER ${client}$/d" "${WG_CONF}"

  echo "Deleted client ${client}"
}

list_cmd() {
  [[ -f "${WG_CONF}" ]] || { echo "Not installed."; exit 1; }
  grep '^# BEGIN_PEER ' "${WG_CONF}" | awk '{print $3}' || true
}

show_cmd() {
  load_meta || { echo "Not installed."; exit 1; }

  local raw="${1:-}"
  [[ -n "${raw}" ]] || { echo "Client name required."; exit 1; }

  local client ip_line client_ip out
  client="$(sanitize_name "${raw}")"
  client_exists "${client}" || { echo "Client not found."; exit 1; }

  ip_line="$(sed -n "/^# BEGIN_PEER ${client}$/,/^# END_PEER ${client}$/p" "${WG_CONF}" | awk -F'= ' '/^AllowedIPs/ {print $2; exit}')"
  client_ip="${ip_line%/32}"
  out="${PWD}/${client}.conf"

  echo "Client: ${client}"
  echo "Assigned IP: ${client_ip}"
  echo "Endpoint: ${ENDPOINT}:${PORT}"
  echo
  if [[ -f "${out}" ]]; then
    cat "${out}"
  else
    echo "No local ${client}.conf in current directory."
    echo "Client exists on server, but saved config file is not present here."
  fi
}

uninstall_cmd() {
  [[ -f "${WG_CONF}" ]] || { echo "Not installed."; exit 1; }

  systemctl disable --now "wg-quick@${WG_IF}.service" 2>/dev/null || true
  systemctl disable --now wg-iptables.service 2>/dev/null || true
  rm -f "${IPTABLES_SERVICE}"
  systemctl daemon-reload || true

  rm -f "${SYSCTL_CONF}"
  rm -rf "${WG_DIR}" "${STATE_DIR}"

  apt-get remove --purge -y wireguard wireguard-tools qrencode || true
  apt-get autoremove -y || true

  echo "Uninstalled."
}

main() {
  need_root
  need_ubuntu_24

  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    install) install_cmd "$@" ;;
    create) need_kernel_wireguard; create_cmd "$@" ;;
    delete) need_kernel_wireguard; delete_cmd "$@" ;;
    list) list_cmd ;;
    show) show_cmd "$@" ;;
    uninstall) uninstall_cmd ;;
    ""|-h|--help|help) usage ;;
    *) echo "Unknown command: ${cmd}"; usage; exit 1 ;;
  esac
}

main "$@"
