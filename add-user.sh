#!/usr/bin/env bash
#
# add-user.sh - Interactively create a new user on an Ubuntu server.
#
#   * Prompts for the username and whether the account needs sudo
#   * Backs up the skeleton .bashrc / .profile to ~/.profile-backup
#   * Appends a custom PS1 prompt to the user's .bashrc
#
# Usage: sudo ./add-user.sh
#
set -Eeuo pipefail

PROMPT_URL="https://raw.githubusercontent.com/rft-sh/Ubuntu-Server/refs/heads/main/prompt.txt"
BACKUP_DIR_NAME=".profile-backup"
MARKER="# --- custom prompt (added by add-user.sh) ---"

# ----- helpers ---------------------------------------------------------------
c_info()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
c_ok()    { printf '\033[0;32m[ok]\033[0m %s\n' "$*"; }
c_warn()  { printf '\033[0;33m[!]\033[0m  %s\n' "$*"; }
c_err()   { printf '\033[0;31m[x]\033[0m  %s\n' "$*" >&2; }
die()     { c_err "$*"; exit 1; }

trap 'c_err "Aborted on line $LINENO."' ERR

# Yes/no prompt. $1 = question, $2 = default (y|n). Returns 0 for yes.
ask_yn() {
  local question=$1 default=${2:-n} reply hint
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  while true; do
    read -r -p "$question $hint " reply || die "No input available (run this script interactively)."
    reply=${reply:-$default}
    case ${reply,,} in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     c_warn "Please answer y or n." ;;
    esac
  done
}

# ----- preflight -------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "This script must be run as root (try: sudo $0)."
[[ -t 0 ]]        || die "This script is interactive and needs a terminal."

for cmd in adduser usermod chpasswd curl install; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# ----- 1. username -----------------------------------------------------------
while true; do
  read -r -p "Username to create: " NEW_USER
  NEW_USER=${NEW_USER// /}
  if [[ -z $NEW_USER ]]; then
    c_warn "Username cannot be empty."
  elif [[ ! $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    c_warn "Invalid username. Use lowercase letters, digits, '-' and '_' (max 32 chars, must not start with a digit)."
  elif id "$NEW_USER" &>/dev/null; then
    c_warn "User '$NEW_USER' already exists. Pick another name."
  else
    break
  fi
done

# ----- 2. sudo ---------------------------------------------------------------
if ask_yn "Should '$NEW_USER' have sudo privileges?" n; then
  GRANT_SUDO=yes
else
  GRANT_SUDO=no
fi

# ----- 3. confirm ------------------------------------------------------------
echo
c_info "About to create:"
printf '      user : %s\n'  "$NEW_USER"
printf '      sudo : %s\n'  "$GRANT_SUDO"
printf '      shell: %s\n'  "/bin/bash"
echo
ask_yn "Proceed?" y || { c_info "Cancelled — nothing was changed."; exit 0; }

# ----- 4. create the account -------------------------------------------------
c_info "Creating user '$NEW_USER'..."
# adduser handles the home directory, group, skel files and password prompt.
adduser --shell /bin/bash --gecos "" "$NEW_USER"
c_ok "User '$NEW_USER' created."

HOME_DIR=$(getent passwd "$NEW_USER" | cut -d: -f6)
[[ -d $HOME_DIR ]] || die "Home directory '$HOME_DIR' was not created."
USER_GROUP=$(id -gn "$NEW_USER")

# ----- 5. sudo group ---------------------------------------------------------
if [[ $GRANT_SUDO == yes ]]; then
  usermod -aG sudo "$NEW_USER"
  c_ok "Added '$NEW_USER' to the 'sudo' group."
else
  c_info "Skipping sudo — standard (non-privileged) account."
fi

# ----- 6. back up .bashrc and .profile ---------------------------------------
BACKUP_DIR="$HOME_DIR/$BACKUP_DIR_NAME"
STAMP=$(date +%Y%m%d-%H%M%S)

install -d -o "$NEW_USER" -g "$USER_GROUP" -m 700 "$BACKUP_DIR"
for f in .bashrc .profile; do
  if [[ -f "$HOME_DIR/$f" ]]; then
    install -o "$NEW_USER" -g "$USER_GROUP" -m 600 \
      "$HOME_DIR/$f" "$BACKUP_DIR/${f}.${STAMP}.bak"
    c_ok "Backed up $f -> $BACKUP_DIR/${f}.${STAMP}.bak"
  else
    c_warn "$HOME_DIR/$f not found — nothing to back up."
  fi
done

# ----- 7. set the 'll' alias -------------------------------------------------
# Ubuntu's default .bashrc ships the ls aliases commented out, so match both the
# active and the commented form; if neither exists, append the alias.
if grep -qE "^[[:space:]]*#?[[:space:]]*alias ll=" "$HOME_DIR/.bashrc" 2>/dev/null; then
  sed -i "s|^[[:space:]]*#\?[[:space:]]*alias ll=.*|alias ll='ls -alhF'|" "$HOME_DIR/.bashrc"
  c_ok "Set alias ll='ls -alhF' in .bashrc"
else
  printf "\n%s\n" "alias ll='ls -alhF'" >> "$HOME_DIR/.bashrc"
  c_ok "Appended alias ll='ls -alhF' to .bashrc"
fi
chown "$NEW_USER:$USER_GROUP" "$HOME_DIR/.bashrc"

# ----- 8. append the custom prompt to .bashrc --------------------------------
if grep -qF "$MARKER" "$HOME_DIR/.bashrc" 2>/dev/null; then
  c_warn "Custom prompt already present in .bashrc — skipping."
else
  c_info "Fetching custom prompt..."
  TMP_PROMPT=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$TMP_PROMPT'" EXIT

  if curl -sfL --max-time 20 "$PROMPT_URL" -o "$TMP_PROMPT" && [[ -s $TMP_PROMPT ]]; then
    if grep -q '^PS1=' "$TMP_PROMPT"; then
      {
        printf '\n%s\n' "$MARKER"
        cat "$TMP_PROMPT"
        printf '\n'
      } >> "$HOME_DIR/.bashrc"
      chown "$NEW_USER:$USER_GROUP" "$HOME_DIR/.bashrc"
      c_ok "Custom prompt appended to $HOME_DIR/.bashrc"
    else
      c_warn "Downloaded file does not look like a PS1 definition — .bashrc left unchanged."
      c_warn "Review it manually: $PROMPT_URL"
    fi
  else
    c_warn "Could not download the prompt from $PROMPT_URL — .bashrc left unchanged."
  fi
fi

# ----- done ------------------------------------------------------------------
echo
c_ok "Finished."
printf '      home    : %s\n' "$HOME_DIR"
printf '      groups  : %s\n' "$(id -nG "$NEW_USER")"
printf '      backups : %s\n' "$BACKUP_DIR"
echo
c_info "Test with:  su - $NEW_USER"
