#!/usr/bin/env bash
#
# backup-remote.sh - Multi-directory backup with daily + monthly rotation
#                    and rsync push to a remote server over SSH
#
# - Compresses multiple source directories into a single timestamped tar.gz
# - Stores daily backups in $BACKUP_DIR/daily
# - On the first run of each month, also copies the backup into $BACKUP_DIR/monthly
# - Rotates both sets independently, keeping only the newest N of each
# - Mirrors the entire backup tree to a remote server via rsync over SSH
#   (--delete keeps remote rotation in sync with local rotation)
#
# Usage:  ./backup-remote.sh            (normal run)
#         ./backup-remote.sh --dry-run  (show what would happen, change nothing)
#
# Recommended cron entry (daily at 2:30 AM):
#   30 2 * * * /usr/local/bin/backup-remote.sh >> /var/log/backup.log 2>&1
#
# SSH setup (one-time):
#   ssh-keygen -t ed25519 -f ~/.ssh/backup_key -N ""
#   ssh-copy-id -i ~/.ssh/backup_key.pub user@remote-host

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

# Directories to back up (space-separated array, absolute paths)
SOURCE_DIRS=(
    "/etc"
    "/home/brad/projects"
    "/var/www"
)

# Where backups are stored locally
BACKUP_DIR="/mnt/backups"

# Retention: how many backups to keep in each tier
KEEP_DAILY=7      # keep last 7 daily backups
KEEP_MONTHLY=6    # keep last 6 monthly archives

# Backup filename prefix
PREFIX="backup"

# Compression: gz (fast, common), bz2 (smaller, slower), xz (smallest, slowest)
COMPRESSION="gz"

# Optional: exclude patterns (tar --exclude syntax). Leave empty if unneeded.
EXCLUDES=(
    "*.tmp"
    "*/cache/*"
    "*/node_modules/*"
)

# Lock file to prevent overlapping runs
LOCK_FILE="/var/run/backup.sh.lock"

# --- Remote sync settings ---------------------------------------------------

REMOTE_ENABLED=1                          # set to 0 to skip remote sync
REMOTE_USER="brad"
REMOTE_HOST="vps.example.com"
REMOTE_PORT=22
REMOTE_DIR="/home/brad/backups"           # remote destination (will mirror daily/ + monthly/)
SSH_KEY="$HOME/.ssh/backup_key"           # dedicated key recommended (no passphrase)

# If 1, remote mirror is exact: files rotated away locally are deleted remotely.
# If 0, remote only accumulates (never deletes) - manage remote cleanup yourself.
REMOTE_MIRROR_DELETE=1

# rsync bandwidth limit in KB/s (0 = unlimited)
BWLIMIT=0

# ---------------------------------------------------------------------------
# INTERNALS
# ---------------------------------------------------------------------------

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
MONTH_TAG="$(date +%Y-%m)"

DAILY_DIR="$BACKUP_DIR/daily"
MONTHLY_DIR="$BACKUP_DIR/monthly"

case "$COMPRESSION" in
    gz)  TAR_FLAG="-z"; EXT="tar.gz"  ;;
    bz2) TAR_FLAG="-j"; EXT="tar.bz2" ;;
    xz)  TAR_FLAG="-J"; EXT="tar.xz"  ;;
    *)   echo "ERROR: unknown COMPRESSION '$COMPRESSION'" >&2; exit 1 ;;
esac

ARCHIVE_NAME="${PREFIX}_${TIMESTAMP}.${EXT}"
ARCHIVE_PATH="$DAILY_DIR/$ARCHIVE_NAME"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        log "DRY-RUN: $*"
    else
        "$@"
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------

# Prevent concurrent runs
if [[ -e "$LOCK_FILE" ]]; then
    PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        log "ERROR: another backup is already running (PID $PID). Exiting."
        exit 1
    fi
    log "WARN: stale lock file found, removing."
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap cleanup EXIT INT TERM

# Verify sources exist
VALID_SOURCES=()
for dir in "${SOURCE_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        VALID_SOURCES+=("$dir")
    else
        log "WARN: source directory not found, skipping: $dir"
    fi
done

if [[ ${#VALID_SOURCES[@]} -eq 0 ]]; then
    log "ERROR: no valid source directories. Nothing to back up."
    exit 1
fi

# Verify rsync is available if remote sync is enabled
if [[ $REMOTE_ENABLED -eq 1 ]] && ! command -v rsync > /dev/null 2>&1; then
    log "ERROR: rsync not found but REMOTE_ENABLED=1. Install rsync or disable remote sync."
    exit 1
fi

# Create destination directories
run mkdir -p "$DAILY_DIR" "$MONTHLY_DIR"

# ---------------------------------------------------------------------------
# CREATE BACKUP
# ---------------------------------------------------------------------------

log "Starting backup: ${VALID_SOURCES[*]}"
log "Destination: $ARCHIVE_PATH"

# Build tar exclude arguments
EXCLUDE_ARGS=()
for pattern in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$pattern")
done

if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: tar -c $TAR_FLAG -f $ARCHIVE_PATH ${EXCLUDE_ARGS[*]} ${VALID_SOURCES[*]}"
else
    if tar -c "$TAR_FLAG" -f "$ARCHIVE_PATH" "${EXCLUDE_ARGS[@]}" "${VALID_SOURCES[@]}" 2>/dev/null; then
        SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"
        log "Backup created: $ARCHIVE_NAME ($SIZE)"
    else
        # tar exits 1 for "file changed as we read it" - treat as warning, not fatal
        if [[ $? -eq 1 && -s "$ARCHIVE_PATH" ]]; then
            log "WARN: tar reported minor issues (files changed during read), archive kept."
        else
            log "ERROR: tar failed. Removing partial archive."
            rm -f "$ARCHIVE_PATH"
            exit 1
        fi
    fi

    # Verify archive integrity
    if tar -t "$TAR_FLAG" -f "$ARCHIVE_PATH" > /dev/null 2>&1; then
        log "Archive integrity verified."
    else
        log "ERROR: archive verification failed. Removing corrupt archive."
        rm -f "$ARCHIVE_PATH"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# MONTHLY ARCHIVE
# ---------------------------------------------------------------------------

# Copy today's backup to monthly if no monthly archive exists for this month
if ! compgen -G "$MONTHLY_DIR/${PREFIX}_${MONTH_TAG}-*.${EXT}" > /dev/null; then
    MONTHLY_NAME="${PREFIX}_${TIMESTAMP}.${EXT}"
    log "No monthly archive for $MONTH_TAG yet - creating one."
    run cp "$ARCHIVE_PATH" "$MONTHLY_DIR/$MONTHLY_NAME"
else
    log "Monthly archive for $MONTH_TAG already exists, skipping."
fi

# ---------------------------------------------------------------------------
# ROTATION
# ---------------------------------------------------------------------------

rotate() {
    local dir="$1" keep="$2" label="$3"
    local old_files
    old_files="$(ls -1t "$dir"/${PREFIX}_*.${EXT} 2>/dev/null | tail -n "+$((keep + 1))" || true)"

    if [[ -z "$old_files" ]]; then
        log "Rotation ($label): nothing to remove ($(ls -1 "$dir"/${PREFIX}_*.${EXT} 2>/dev/null | wc -l)/$keep kept)."
        return
    fi

    while IFS= read -r f; do
        log "Rotation ($label): removing $f"
        run rm -f "$f"
    done <<< "$old_files"
}

rotate "$DAILY_DIR" "$KEEP_DAILY" "daily"
rotate "$MONTHLY_DIR" "$KEEP_MONTHLY" "monthly"

# ---------------------------------------------------------------------------
# REMOTE SYNC (rsync over SSH)
# ---------------------------------------------------------------------------

if [[ $REMOTE_ENABLED -eq 1 ]]; then
    log "Syncing to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}"

    RSYNC_ARGS=(-a --partial --timeout=120)
    [[ $REMOTE_MIRROR_DELETE -eq 1 ]] && RSYNC_ARGS+=(--delete)
    [[ $BWLIMIT -gt 0 ]] && RSYNC_ARGS+=(--bwlimit="$BWLIMIT")
    [[ $DRY_RUN -eq 1 ]] && RSYNC_ARGS+=(--dry-run --verbose)

    SSH_CMD="ssh -p $REMOTE_PORT -o BatchMode=yes -o ConnectTimeout=15"
    [[ -f "$SSH_KEY" ]] && SSH_CMD+=" -i $SSH_KEY"

    # Ensure remote directory exists
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! $SSH_CMD "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '$REMOTE_DIR'"; then
            log "ERROR: cannot reach remote host or create remote directory."
            log "Local backup succeeded; remote sync FAILED. Will retry next run."
            exit 2
        fi
    fi

    # Trailing slash on source: sync contents of BACKUP_DIR (daily/ + monthly/)
    if rsync "${RSYNC_ARGS[@]}" -e "$SSH_CMD" "$BACKUP_DIR/" \
         "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/"; then
        log "Remote sync complete."
    else
        log "ERROR: rsync failed. Local backup succeeded; remote copy is stale."
        log "Will retry on next run (rsync only transfers what's missing)."
        exit 2
    fi
fi

log "Backup complete."
