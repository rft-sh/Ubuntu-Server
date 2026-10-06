#!/usr/bin/env bash
#
# server-backup.sh - Multi-directory backup with daily + monthly rotation
#
# - Compresses multiple source directories into a single timestamped tar.gz
# - Stores daily backups in $BACKUP_DIR/daily
# - On the 1st of each month (or if no monthly exists yet this month),
#   also copies the backup into $BACKUP_DIR/monthly
# - Rotates both sets independently, keeping only the newest N of each
# - Logs every run to $LOG_FILE (self-rotating), optionally to syslog,
#   and to the console when run interactively
#
# Usage:  ./server-backup.sh            (normal run)
#         ./server-backup.sh --dry-run  (show what would happen, change nothing)
#
# Recommended cron entry (daily at 2:30 AM). The script writes its own log,
# so there's no need to redirect into it; any stray output (unexpected
# command errors) still reaches cron's mail:
#   30 2 * * * /usr/local/bin/server-backup.sh

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

# Directories to back up (space-separated array, absolute paths)
SOURCE_DIRS=(
    "/etc"
    "/home/user/projects"
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
LOCK_FILE="/var/run/server-backup.sh.lock"

# --- Logging ---------------------------------------------------------------

# Log file (set to "" to disable file logging)
LOG_FILE="/var/log/server-backup.log"

# Rotate the log when it exceeds this size (bytes). 0 = never rotate
# (use 0 if you'd rather manage it with logrotate).
LOG_MAX_BYTES=$((5 * 1024 * 1024))   # 5 MB

# How many rotated logs to keep (server-backup.log.1 ... server-backup.log.N)
LOG_KEEP=5

# Also send messages to syslog/journald via `logger` (1 = yes, 0 = no)
# View with: journalctl -t server-backup.sh   (or grep server-backup.sh /var/log/syslog)
USE_SYSLOG=1
SYSLOG_TAG="server-backup.sh"

# Max lines of tar stderr to copy into the log per run
TAR_LOG_LINES=50

# ---------------------------------------------------------------------------
# INTERNALS
# ---------------------------------------------------------------------------

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
MONTH_TAG="$(date +%Y-%m)"

DAILY_DIR="$BACKUP_DIR/daily"
MONTHLY_DIR="$BACKUP_DIR/monthly"

# State used by the exit/error handlers (must exist before traps are set)
ARCHIVE_PATH=""
ARCHIVE_IN_PROGRESS=0
LOCK_HELD=0
TAR_ERR=""

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------

# log LEVEL message...
#   Writes to LOG_FILE, to syslog (if enabled), and to the console when
#   stdout is a terminal or this is a dry run.
log() {
    local level="$1"; shift
    local tag=""
    [[ $DRY_RUN -eq 1 ]] && tag="[DRY-RUN] "
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [pid $$] ${tag}$*"

    if [[ -n "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi

    if [[ -t 1 || $DRY_RUN -eq 1 ]]; then
        if [[ "$level" == "INFO" ]]; then
            echo "$line"
        else
            echo "$line" >&2
        fi
    fi

    if [[ $USE_SYSLOG -eq 1 ]] && command -v logger >/dev/null 2>&1; then
        local prio
        case "$level" in
            ERROR) prio="err" ;;
            WARN)  prio="warning" ;;
            *)     prio="info" ;;
        esac
        logger -t "$SYSLOG_TAG" -p "user.$prio" -- "${tag}$*" 2>/dev/null || true
    fi
}

info()  { log INFO  "$@"; }
warn()  { log WARN  "$@"; }
error() { log ERROR "$@"; }

fmt_duration() {
    local s="$1"
    printf '%dm%02ds' $((s / 60)) $((s % 60))
}

# Size-based rotation of the log file itself: server-backup.log -> server-backup.log.1 ...
rotate_log() {
    if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" || $LOG_MAX_BYTES -le 0 ]]; then
        return 0
    fi
    local size
    size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"
    if (( size < LOG_MAX_BYTES )); then
        return 0
    fi
    local i
    for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
        if [[ -f "$LOG_FILE.$i" ]]; then
            mv -f "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
        fi
    done
    mv -f "$LOG_FILE" "$LOG_FILE.1"
}

init_logging() {
    if [[ -z "$LOG_FILE" ]]; then
        return 0
    fi
    if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
        if [[ $DRY_RUN -eq 0 ]]; then
            rotate_log
        fi
    else
        echo "WARN: cannot write to $LOG_FILE - logging to console/syslog only" >&2
        LOG_FILE=""
    fi
}

# Copy tar's stderr into the log (minus tar's harmless leading-slash notice)
log_tar_output() {
    local level="$1"
    if [[ -z "$TAR_ERR" || ! -s "$TAR_ERR" ]]; then
        return 0
    fi
    local filtered total
    filtered="$(grep -v "Removing leading" "$TAR_ERR" || true)"
    if [[ -z "$filtered" ]]; then
        return 0
    fi
    total="$(printf '%s\n' "$filtered" | wc -l)"
    while IFS= read -r l; do
        log "$level" "tar: $l"
    done < <(printf '%s\n' "$filtered" | head -n "$TAR_LOG_LINES")
    if (( total > TAR_LOG_LINES )); then
        log "$level" "tar: ... $((total - TAR_LOG_LINES)) more line(s) omitted"
    fi
}

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        info "would run: $*"
    else
        local rc=0
        "$@" || rc=$?
        if [[ $rc -ne 0 ]]; then
            error "Command failed (exit $rc): $*"
            exit "$rc"
        fi
    fi
}

# ---------------------------------------------------------------------------
# ERROR / EXIT HANDLING
# ---------------------------------------------------------------------------

on_error() {
    local rc="$1" line="$2" cmd="$3"
    error "Command failed (exit $rc) at line $line: $cmd"
}

on_exit() {
    local rc=$?

    if [[ $ARCHIVE_IN_PROGRESS -eq 1 && -n "$ARCHIVE_PATH" && -f "$ARCHIVE_PATH" ]]; then
        warn "Removing incomplete archive: $ARCHIVE_PATH"
        rm -f "$ARCHIVE_PATH"
    fi
    if [[ -n "$TAR_ERR" ]]; then
        rm -f "$TAR_ERR"
    fi
    if [[ $LOCK_HELD -eq 1 ]]; then
        rm -f "$LOCK_FILE"
    fi

    if [[ $rc -eq 0 ]]; then
        info "===== Run finished OK in $(fmt_duration "$SECONDS") ====="
    else
        error "===== Run FAILED (exit $rc) after $(fmt_duration "$SECONDS") ====="
    fi
    exit "$rc"
}

init_logging

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'warn "Received SIGINT, aborting."; exit 130' INT
trap 'warn "Received SIGTERM, aborting."; exit 143' TERM

info "===== Backup run started on $(hostname) as $(id -un) ====="

case "$COMPRESSION" in
    gz)  TAR_FLAG="-z"; EXT="tar.gz"  ;;
    bz2) TAR_FLAG="-j"; EXT="tar.bz2" ;;
    xz)  TAR_FLAG="-J"; EXT="tar.xz"  ;;
    *)   error "Unknown COMPRESSION '$COMPRESSION'"; exit 1 ;;
esac

ARCHIVE_NAME="${PREFIX}_${TIMESTAMP}.${EXT}"
ARCHIVE_PATH="$DAILY_DIR/$ARCHIVE_NAME"

info "Config: compression=$COMPRESSION keep_daily=$KEEP_DAILY keep_monthly=$KEEP_MONTHLY excludes=[${EXCLUDES[*]}]"

# ---------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------------------------------

# Prevent concurrent runs
if [[ -e "$LOCK_FILE" ]]; then
    PID="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        error "Another backup is already running (PID $PID). Exiting."
        exit 1
    fi
    warn "Stale lock file found (PID ${PID:-unknown}), removing."
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
LOCK_HELD=1

# Verify sources exist
VALID_SOURCES=()
for dir in "${SOURCE_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        VALID_SOURCES+=("$dir")
    else
        warn "Source directory not found, skipping: $dir"
    fi
done

if [[ ${#VALID_SOURCES[@]} -eq 0 ]]; then
    error "No valid source directories. Nothing to back up."
    exit 1
fi

# Create destination directories
run mkdir -p "$DAILY_DIR" "$MONTHLY_DIR"

# ---------------------------------------------------------------------------
# CREATE BACKUP
# ---------------------------------------------------------------------------

info "Sources: ${VALID_SOURCES[*]}"
info "Destination: $ARCHIVE_PATH"

# Build tar exclude arguments
EXCLUDE_ARGS=()
for pattern in "${EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=(--exclude="$pattern")
done

if [[ $DRY_RUN -eq 1 ]]; then
    info "would run: tar -c $TAR_FLAG -f $ARCHIVE_PATH ${EXCLUDE_ARGS[*]} ${VALID_SOURCES[*]}"
else
    TAR_ERR="$(mktemp)"
    ARCHIVE_IN_PROGRESS=1
    TAR_START=$SECONDS
    TAR_RC=0

    # -P not used: paths stored relative to / (leading slash stripped by tar)
    tar -c "$TAR_FLAG" -f "$ARCHIVE_PATH" "${EXCLUDE_ARGS[@]}" "${VALID_SOURCES[@]}" 2>"$TAR_ERR" || TAR_RC=$?

    if [[ $TAR_RC -eq 0 ]]; then
        log_tar_output INFO
    elif [[ $TAR_RC -eq 1 && -s "$ARCHIVE_PATH" ]]; then
        # tar exits 1 for "file changed as we read it" - warning, not fatal
        warn "tar reported minor issues (files changed during read); archive kept."
        log_tar_output WARN
    else
        error "tar failed (exit $TAR_RC). Removing partial archive."
        log_tar_output ERROR
        exit 1   # on_exit removes the partial archive
    fi

    SIZE="$(du -h "$ARCHIVE_PATH" | cut -f1)"
    info "Backup created: $ARCHIVE_NAME ($SIZE) in $(fmt_duration $((SECONDS - TAR_START)))"

    # Verify archive integrity
    : > "$TAR_ERR"
    if tar -t "$TAR_FLAG" -f "$ARCHIVE_PATH" > /dev/null 2>"$TAR_ERR"; then
        info "Archive integrity verified."
    else
        error "Archive verification failed. Removing corrupt archive."
        log_tar_output ERROR
        exit 1   # on_exit removes the corrupt archive
    fi

    ARCHIVE_IN_PROGRESS=0
fi

# ---------------------------------------------------------------------------
# MONTHLY ARCHIVE
# ---------------------------------------------------------------------------

# Copy today's backup to monthly if no monthly archive exists for this month
if ! compgen -G "$MONTHLY_DIR/${PREFIX}_${MONTH_TAG}-*.${EXT}" > /dev/null; then
    MONTHLY_NAME="${PREFIX}_${TIMESTAMP}.${EXT}"
    info "No monthly archive for $MONTH_TAG yet - creating $MONTHLY_NAME."
    run cp "$ARCHIVE_PATH" "$MONTHLY_DIR/$MONTHLY_NAME"
else
    info "Monthly archive for $MONTH_TAG already exists, skipping."
fi

# ---------------------------------------------------------------------------
# ROTATION
# ---------------------------------------------------------------------------

count_archives() {
    { find "$1" -maxdepth 1 -type f -name "${PREFIX}_*.${EXT}" 2>/dev/null || true; } | wc -l
}

rotate() {
    local dir="$1" keep="$2" label="$3"
    # List matching archives newest-first; delete everything past $keep
    local old_files
    old_files="$(ls -1t "$dir"/${PREFIX}_*.${EXT} 2>/dev/null | tail -n "+$((keep + 1))" || true)"

    if [[ -z "$old_files" ]]; then
        info "Rotation ($label): nothing to remove ($(count_archives "$dir")/$keep kept)."
        return 0
    fi

    local removed=0
    while IFS= read -r f; do
        info "Rotation ($label): removing $(basename "$f")"
        run rm -f "$f"
        removed=$((removed + 1))
    done <<< "$old_files"
    info "Rotation ($label): removed $removed, $(count_archives "$dir")/$keep kept."
}

rotate "$DAILY_DIR" "$KEEP_DAILY" "daily"
rotate "$MONTHLY_DIR" "$KEEP_MONTHLY" "monthly"

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

if [[ -d "$BACKUP_DIR" ]]; then
    TOTAL_SIZE="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo '?')"
    DISK_FREE="$(df -h "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4 " free of " $2 " (" $5 " used)"}' || echo '?')"
    info "Backup storage: $TOTAL_SIZE used by backups; disk: $DISK_FREE"
fi
