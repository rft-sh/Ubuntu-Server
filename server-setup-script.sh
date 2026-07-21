#!/bin/bash

### SERVER SETUP SCRIPT #########################################

# Require root/sudo
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi

# Define User
read -p "Enter your user name: " USER

# Create backup of .bashrc and .profile
mkdir ~/.profile-backup
mkdir /home/$USER/.profile-backup
cp ~/.bashrc ~/.profile ~/.profile-backup/
cp /home/$USER/.bashrc /home/$USER/.profile /home/$USER/.profile-backup/

# Set prompt
curl -sf https://raw.githubusercontent.com/rft-sh/Ubuntu-Server/refs/heads/main/.prompt >> ~/.bashrc
curl -sf https://raw.githubusercontent.com/rft-sh/Ubuntu-Server/refs/heads/main/.prompt >> /home/$USER/.bashrc

# Change alias for LL
sed -i "s/^alias ll=.*/alias ll='ls -alhF'/" ~/.bashrc
sed -i "s/^alias ll=.*/alias ll='ls -alhF'/" /home/$USER/.bashrc

# Set MOTD to neofetch.dev
sudo curl -sSL https://neofetch.dev/scripts/2v1v2zfy54.sh | sudo bash

# Create our update script, make a future scripts directory, and Update the system
echo "sudo apt update && sudo apt full-upgrade" > /home/$USER/update
chmod +x /home/$USER/update
mkdir /home/$USER/scripts
sudo chown $USER:$USER /home/$USER/update
sudo chown $USER:$USER /home/$USER/scripts
sudo apt update && sudo apt full-upgrade

# Optionally run netplan configuration script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read -rp "Run the netplan network configuration script now? [y/N]: " run_netplan
case "$run_netplan" in
    [Yy]*)
        if [ -f "$SCRIPT_DIR/netplan.sh" ]; then
            bash "$SCRIPT_DIR/netplan.sh"
        else
            echo "netplan.sh not found in $SCRIPT_DIR" >&2
            exit 1
        fi
        ;;
    *)
        echo "Skipping netplan configuration."
        exit 0
        ;;
esac
