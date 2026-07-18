#!/usr/bin/env bash
#
# netconfig.sh - Interactive DHCP <-> Static IP switcher for Ubuntu Server (Netplan)
# Tested against Ubuntu Server 24.04+ / 26.04 (netplan.io renderer: networkd)
#
# Must be run as root:  sudo ./netconfig.sh
#

set -euo pipefail

NETPLAN_DIR="/etc/netplan"
CONFIG_FILE="${NETPLAN_DIR}/01-netconfig.yaml"
BACKUP_DIR="/etc/netplan/backups"
CLOUD_INIT_DISABLE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"

# ---------- colors ----------
C_RESET='\033[0m'
C_AMBER='\033[38;5;214m'
C_GREEN='\033[38;5;114m'
C_RED='\033[38;5;203m'
C_DIM='\033[2m'

msg()  { echo -e "${C_AMBER}==>${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN} OK${C_RESET} $*"; }
err()  { echo -e "${C_RED}ERR${C_RESET} $*" >&2; }

# ---------- sanity checks ----------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root. Try: sudo $0"
    exit 1
fi

if ! command -v netplan >/dev/null 2>&1; then
    err "netplan not found. This script targets Ubuntu Server with netplan.io."
    exit 1
fi

# ---------- helpers ----------

valid_ipv4() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    for octet in "$a" "$b" "$c" "$d"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

valid_cidr() {
    local cidr=$1
    [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    valid_ipv4 "${cidr%/*}"
}

list_interfaces() {
    # Physical + virtual ethernet interfaces, excluding loopback/docker/veth/bridges
    ip -o link show | awk -F': ' '{print $2}' \
        | grep -Ev '^(lo|docker|veth|br-|virbr|tap|tun)' \
        | sed 's/@.*//'
}

iface_summary() {
    # One-line summary: state, IPv4 address(es), MAC
    local iface=$1
    local state addrs mac
    state=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'state \K\S+' || echo "?")
    mac=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'link/ether \K\S+' || echo "no MAC")
    addrs=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | paste -sd ', ' -)
    [[ -z $addrs ]] && addrs="no IPv4"
    printf '%-10s %-6s %-22s %s' "$iface" "$state" "$addrs" "$mac"
}

show_current() {
    local iface=$1
    echo
    echo -e "${C_DIM}--- Current state of ${iface} ---${C_RESET}"
    ip -4 addr show "$iface" | grep -E 'inet |state' || echo "  (no IPv4 address)"
    echo -e "${C_DIM}Default route:${C_RESET}"
    ip route show default dev "$iface" 2>/dev/null || echo "  (none via $iface)"
    echo -e "${C_DIM}DNS (resolved):${C_RESET}"
    resolvectl status "$iface" 2>/dev/null | grep -E 'DNS Servers' || echo "  (unknown)"
    echo -e "${C_DIM}-------------------------------${C_RESET}"
    echo
}

backup_netplan() {
    mkdir -p "$BACKUP_DIR"
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    local made_backup=0
    shopt -s nullglob
    for f in "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml; do
        cp -a "$f" "$BACKUP_DIR/$(basename "$f").$stamp.bak"
        made_backup=1
    done
    shopt -u nullglob
    if [[ $made_backup -eq 1 ]]; then
        ok "Existing netplan configs backed up to $BACKUP_DIR (*.$stamp.bak)"
    else
        msg "No existing netplan yaml files found to back up."
    fi
}

disable_cloud_init_network() {
    # Prevent cloud-init from regenerating 50-cloud-init.yaml on reboot
    if [[ -d /etc/cloud/cloud.cfg.d && ! -f $CLOUD_INIT_DISABLE ]]; then
        echo "network: {config: disabled}" > "$CLOUD_INIT_DISABLE"
        ok "cloud-init network management disabled ($CLOUD_INIT_DISABLE)"
    fi
}

archive_other_yamls() {
    # Move any other netplan yamls aside so ours is authoritative
    shopt -s nullglob
    for f in "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml; do
        [[ "$f" == "$CONFIG_FILE" ]] && continue
        mv "$f" "$f.disabled"
        msg "Moved aside: $f -> $f.disabled"
    done
    shopt -u nullglob
}

apply_netplan() {
    chmod 600 "$CONFIG_FILE"
    echo
    msg "Generated config:"
    echo -e "${C_DIM}"
    sed 's/^/    /' "$CONFIG_FILE"
    echo -e "${C_RESET}"

    msg "How would you like to apply this configuration?"
    echo
    echo "  1) netplan try   - safe: auto-reverts in 120s unless you confirm"
    echo "                     (recommended over SSH, but the revert timer can't"
    echo "                      be confirmed if your session drops)"
    echo "  2) netplan apply - immediate and permanent, no revert safety net"
    echo "                     (use when changing the IP over SSH and you plan"
    echo "                      to reconnect on the new address)"
    echo "  3) skip          - write config only; apply manually later"
    echo
    read -rp "Select an option [1-3] (default 1): " apply_choice
    apply_choice=${apply_choice:-1}

    case $apply_choice in
        1)
            msg "Running 'netplan try' (auto-reverts in 120s if not confirmed)."
            msg "If you're on SSH and the IP changes, your session may drop."
            if netplan try --timeout 120; then
                ok "Configuration applied and confirmed."
            else
                err "netplan try failed or was not confirmed; config reverted."
                exit 1
            fi
            ;;
        2)
            msg "Running 'netplan apply' (no auto-revert)."
            msg "If you're on SSH and the IP changes, reconnect on the new address."
            if netplan apply; then
                ok "Configuration applied."
            else
                err "netplan apply failed. Restore a backup from $BACKUP_DIR if needed."
                exit 1
            fi
            ;;
        3)
            msg "Skipped apply. Run 'sudo netplan try' or 'sudo netplan apply' when ready."
            ;;
        *)
            err "Invalid option. Config written but not applied."
            msg "Run 'sudo netplan try' or 'sudo netplan apply' manually."
            ;;
    esac
}

# ---------- modes ----------

configure_static() {
    local iface=$1
    echo
    msg "Configuring STATIC IP on ${iface}"

    # Suggest current address as default
    local current_cidr
    current_cidr=$(ip -o -4 addr show "$iface" | awk '{print $4}' | head -n1)
    local current_gw
    current_gw=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -n1)

    local addr gw dns1 dns2 search_domain

    while true; do
        read -rp "IP address with CIDR [${current_cidr:-e.g. 192.168.1.50/24}]: " addr
        addr=${addr:-$current_cidr}
        if valid_cidr "$addr"; then break; fi
        err "Invalid format. Use x.x.x.x/nn (e.g. 192.168.1.50/24)"
    done

    while true; do
        read -rp "Gateway [${current_gw:-e.g. 192.168.1.1}]: " gw
        gw=${gw:-$current_gw}
        if valid_ipv4 "$gw"; then break; fi
        err "Invalid IPv4 address."
    done

    while true; do
        read -rp "Primary DNS [1.1.1.1]: " dns1
        dns1=${dns1:-1.1.1.1}
        if valid_ipv4 "$dns1"; then break; fi
        err "Invalid IPv4 address."
    done

    while true; do
        read -rp "Secondary DNS (blank to skip) [9.9.9.9]: " dns2
        dns2=${dns2:-9.9.9.9}
        [[ -z $dns2 ]] && break
        if valid_ipv4 "$dns2"; then break; fi
        err "Invalid IPv4 address."
    done

    read -rp "Search domain (blank to skip): " search_domain

    backup_netplan
    disable_cloud_init_network
    archive_other_yamls

    {
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    ${iface}:"
        echo "      dhcp4: false"
        echo "      dhcp6: false"
        echo "      addresses:"
        echo "        - ${addr}"
        echo "      routes:"
        echo "        - to: default"
        echo "          via: ${gw}"
        echo "      nameservers:"
        if [[ -n $dns2 ]]; then
            echo "        addresses: [${dns1}, ${dns2}]"
        else
            echo "        addresses: [${dns1}]"
        fi
        if [[ -n $search_domain ]]; then
            echo "        search: [${search_domain}]"
        fi
    } > "$CONFIG_FILE"

    apply_netplan
}

configure_dhcp() {
    local iface=$1
    echo
    msg "Configuring DHCP on ${iface}"

    backup_netplan
    disable_cloud_init_network
    archive_other_yamls

    cat > "$CONFIG_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: true
      dhcp6: false
EOF

    apply_netplan
}

# ---------- main ----------

clear
echo -e "${C_AMBER}"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  NETCONFIG :: Ubuntu Netplan IP Switch  │"
echo "  └─────────────────────────────────────────┘"
echo -e "${C_RESET}"

# Interface selection
mapfile -t IFACES < <(list_interfaces)

if [[ ${#IFACES[@]} -eq 0 ]]; then
    err "No usable network interfaces found."
    exit 1
elif [[ ${#IFACES[@]} -eq 1 ]]; then
    IFACE=${IFACES[0]}
    msg "Using interface:"
    echo -e "     ${C_DIM}$(iface_summary "$IFACE")${C_RESET}"
else
    msg "Available interfaces:"
    echo
    printf '     %-3s %-10s %-6s %-22s %s\n' "#" "IFACE" "STATE" "IPv4" "MAC"
    echo -e "${C_DIM}"
    for i in "${!IFACES[@]}"; do
        printf '     %-3s %s\n' "$((i + 1)))" "$(iface_summary "${IFACES[$i]}")"
    done
    echo -e "${C_RESET}"
    while true; do
        read -rp "Select an interface [1-${#IFACES[@]}]: " sel
        if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#IFACES[@]} )); then
            IFACE=${IFACES[$((sel - 1))]}
            break
        fi
        err "Invalid selection."
    done
fi

show_current "$IFACE"

# Detect current mode (best effort, from netplan configs)
CURRENT_MODE="unknown"
if grep -rqsE 'dhcp4:\s*(true|yes)' "$NETPLAN_DIR"/*.y*ml 2>/dev/null; then
    CURRENT_MODE="DHCP"
elif grep -rqs 'addresses:' "$NETPLAN_DIR"/*.y*ml 2>/dev/null; then
    CURRENT_MODE="STATIC"
fi
msg "Detected netplan mode: ${CURRENT_MODE}"
echo

echo "  1) Switch to STATIC IP"
echo "  2) Switch to DHCP"
echo "  3) Quit"
echo
read -rp "Select an option [1-3]: " choice

case $choice in
    1) configure_static "$IFACE" ;;
    2) configure_dhcp "$IFACE" ;;
    3) msg "No changes made."; exit 0 ;;
    *) err "Invalid option."; exit 1 ;;
esac

echo
show_current "$IFACE"
ok "Done."
