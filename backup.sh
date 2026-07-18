#!/usr/bin/env bash
#
# backup.sh - Multi-directory backup with daily + monthly rotation
#
# - Compresses multiple source directories into a single timestamped tar.gz
# - Stores daily backups in $BACKUP_DIR/daily
# - On the 1st of each month (or if no monthly exists yet this month),
#   also copies the backup into $BACKUP_DIR/monthly
# - Rotates both sets independently, keeping only the newest N of each
#
# Usage:  ./backup.sh            (normal run)
#         ./backup.sh --dry-run  (show what would happen, change nothing)
#
# Recommended cron entry (daily at 2:30 AM):
#   30 2 * * * /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1

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

# Where backups are stored
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
    # -P not used: paths stored relative to / (leading slash stripped by tar)
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
    # List matching archives newest-first; delete everything past $keep
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

log "Backup complete."
