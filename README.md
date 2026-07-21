# Ubuntu-Server
## Ubuntu Server Setup Scripts

### <ins>server-setup-script.sh</ins>
Server setup script for Ubuntu servers. Sets the prompt, aliases, MOTD, makes a /scripts folder in
your home path for future needs, and finally runs the netplan.sh script if you need. Keep this and
netplan.sh in the same directory when running them together.

### <ins>netplan.sh</ins>
Interactive script to configure netplan on Ubuntu servers. Should work with 24.04 LTS and 26.02 LTS
Displays all available interfaces and their current IP information then allows you to select one, set
either a Static IP or DHCP, and ends with an option to run netplan try which will revert changes in 2
minutes, netplan apply to make the changes permanent, or exit and verify the changes and apply them yourself.

### <ins>backup.sh</ins>
Daily/Monthly Backup Script for Linux servers. Uses compression, file retention, and rotation based on
settings configured in the script.

### <ins>backup-remote.sh</ins>
Same Daily/Monthly Backup Script as backup.sh however this one is designed to send the backups off-server using
rsync. Still offers files retention and rotation.

## Dotfiles

### <ins>.alias</ins>
Common alias settings I use on every single server I manage.\
`cat .alias >> ~/.bashrc`

On modern Ubuntu Servers the alias for ll is already defined so you can use this to search for it and replace it
adding the -h flag for human readable output.\
`sed -i "s/^alias ll=.*/alias ll='ls -alhF'/" ~/.bashrc`

### <ins>.prompt</ins>
A nice prompt I've been using in Bash environments for many, many years.\
`cat .profile >> ~/.bashrc`
