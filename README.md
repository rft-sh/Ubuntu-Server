# Ubuntu-Server
Ubuntu Server Setup Scripts

### netconfig.sh
Interactive script to configure netplan on Ubuntu servers. Should work with 24.04 LTS and 26.02 LTS
Displays all available interfaces and their current IP information then allows you to select one, set
either a Static IP or DHCP, and ends with an option to run netplan try which will revert changes in 2
minutes, netplan apply to make the changes permanent, or exit and verify the changes and apply them yourself.
