#!/usr/bin/env bash
#
# mysql-backup.sh — dump MySQL/MariaDB databases, archive them, rotate old archives.
#
# Each run produces one archive:  <BACKUP_DIR>/mysql-<host>-YYYYmmdd-HHMMSS.tar.gz
# containing one .sql file per database. Only the newest KEEP archives are kept.
#
# Usage:
#   mysql-backup.sh [-d dir] [-k keep] [-c defaults_file] [-e "db1 db2"] [-l log_file] [-s] [-q] [-n]
#
#   -d DIR    Backup directory              (default: /var/backups/mysql)
#   -k N      Number of archives to keep    (default: 7)
#   -c FILE   MySQL client defaults file    (default: /etc/mysql/backup.cnf)
#   -e LIST   Extra databases to exclude, space-separated
#   -l FILE   Log file, or "none" to disable (default: /var/log/mysql-backup.log)
#   -s        Also send log messages to syslog (tag: mysql-backup)
#   -q        Quiet: print only warnings/errors to the terminal (log file gets everything)
#   -n        Dry run for rotation (show what would be deleted)
#   -h        Help
#
# Credentials file example (chmod 600, owned by the user running the script):
#   [client]
#   user=backup
#   password=secret
#   host=localhost
#
# Minimal privileges for the backup user:
#   GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, PROCESS, RELOAD ON *.* TO 'backup'@'localhost';
#
# Cron example (daily at 02:15). With -q, cron only mails you when something goes wrong:
#   15 2 * * * /usr/local/bin/mysql-backup.sh -k 14 -q
#
# logrotate example (/etc/logrotate.d/mysql-backup):
#   /var/log/mysql-backup.log {
#       monthly
#       rotate 12
#       compress
#       missingok
#       notifempty
#   }

set -Eeuo pipefail
umask 077

# ---- Defaults (can also be overridden via environment) ----
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mysql}"
KEEP="${KEEP:-7}"
DEFAULTS_FILE="${DEFAULTS_FILE:-/etc/mysql/backup.cnf}"
EXTRA_EXCLUDES="${EXTRA_EXCLUDES:-}"
LOG_FILE="${LOG_FILE:-/var/log/mysql-backup.log}"
USE_SYSLOG="${USE_SYSLOG:-0}"
QUIET="${QUIET:-0}"
DRY_RUN=0
SYSTEM_DBS="information_schema performance_schema sys"
LOG_TAG="mysql-backup"
LOG_READY=0

# ---- Logging ----
# log LEVEL message...   LEVEL is INFO, WARN or ERROR.
# Writes to the log file (if enabled), the terminal (INFO suppressed by -q; WARN/ERROR go to stderr),
# and syslog (if -s).
log() {
  local level="$1"; shift
  local line
  line="$(date '+%F %T') [$level] $*"

  if (( LOG_READY )); then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi

  if [[ "$level" == ERROR || "$level" == WARN ]]; then
    printf '%s\n' "$line" >&2
  elif (( ! QUIET )); then
    printf '%s\n' "$line"
  fi

  if (( USE_SYSLOG )); then
    local prio=info
    case "$level" in ERROR) prio=err ;; WARN) prio=warning ;; esac
    logger -t "${LOG_TAG}[$$]" -p "user.$prio" -- "$*" 2>/dev/null || true
  fi
}
die() { log ERROR "$*"; exit 1; }

usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"; exit 0; }

while getopts ":d:k:c:e:l:sqnh" opt; do
  case "$opt" in
    d) BACKUP_DIR="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    c) DEFAULTS_FILE="$OPTARG" ;;
    e) EXTRA_EXCLUDES="$OPTARG" ;;
    l) LOG_FILE="$OPTARG" ;;
    s) USE_SYSLOG=1 ;;
    q) QUIET=1 ;;
    n) DRY_RUN=1 ;;
    h) usage ;;
    :) die "Option -$OPTARG requires an argument" ;;
    *) die "Unknown option -$OPTARG (use -h)" ;;
  esac
done

# ---- Set up the log file (fall back to terminal-only if it can't be written) ----
[[ "$LOG_FILE" == none ]] && LOG_FILE=""
if [[ -n "$LOG_FILE" ]]; then
  if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && touch "$LOG_FILE" 2>/dev/null; then
    LOG_READY=1
  else
    QUIET=0
    log WARN "Cannot write log file '$LOG_FILE'; logging to terminal only"
    LOG_FILE=""
  fi
fi

# ---- Start/finish records (the EXIT trap logs success or failure with duration) ----
START_TS=$(date +%s)
STAGING=""
ARCHIVE=""
on_exit() {
  local rc=$?
  [[ -n "$STAGING" ]] && rm -rf "$STAGING"
  [[ -n "$ARCHIVE" ]] && rm -f "${ARCHIVE}.partial"
  local dur=$(( $(date +%s) - START_TS ))
  if (( rc == 0 )); then
    log INFO "===== Backup finished OK in ${dur}s ====="
  else
    log ERROR "===== Backup FAILED (exit $rc) after ${dur}s ====="
  fi
}
trap on_exit EXIT
trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

log INFO "===== Backup started (pid $$, host $(hostname -s), dir $BACKUP_DIR, keep $KEEP$( (( DRY_RUN )) && echo ', rotation dry run')) ====="

# ---- Sanity checks ----
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "KEEP must be a positive integer (got '$KEEP')"
[[ -r "$DEFAULTS_FILE" ]]      || die "Defaults file not readable: $DEFAULTS_FILE"
for bin in mysql mysqldump tar gzip flock; do
  command -v "$bin" >/dev/null || die "Required command not found: $bin"
done
if (( USE_SYSLOG )) && ! command -v logger >/dev/null; then
  USE_SYSLOG=0
  log WARN "logger not found; syslog output disabled"
fi

mkdir -p "$BACKUP_DIR" || die "Cannot create backup directory $BACKUP_DIR"

# ---- Prevent overlapping runs ----
exec 9>"$BACKUP_DIR/.mysql-backup.lock"
flock -n 9 || die "Another backup is already running"

MYSQL_OPTS=(--defaults-extra-file="$DEFAULTS_FILE")
HOST_TAG="$(hostname -s)"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$BACKUP_DIR/mysql-${HOST_TAG}-${STAMP}.tar.gz"
STAGING="$(mktemp -d "$BACKUP_DIR/.staging-${STAMP}.XXXXXX")"

# ---- Build database list (errors from mysql are captured into the log) ----
EXCLUDES=" $SYSTEM_DBS $EXTRA_EXCLUDES "
if ! DB_LIST="$(mysql "${MYSQL_OPTS[@]}" -N -B -e 'SHOW DATABASES' 2>&1)"; then
  die "Cannot list databases: $(tr '\n' ' ' <<< "$DB_LIST")"
fi
mapfile -t ALL_DBS <<< "$DB_LIST"
DBS=()
SKIPPED=()
for db in "${ALL_DBS[@]}"; do
  [[ -z "$db" ]] && continue
  if [[ "$EXCLUDES" == *" $db "* ]]; then SKIPPED+=("$db"); else DBS+=("$db"); fi
done
(( ${#DBS[@]} > 0 )) || die "No databases to back up"

log INFO "Found ${#ALL_DBS[@]} database(s); backing up ${#DBS[@]}, skipping: ${SKIPPED[*]:-none}"

# ---- Dump each database ----
FAILED=0
for db in "${DBS[@]}"; do
  out="$STAGING/${db}.sql"
  db_start=$SECONDS
  if mysqldump "${MYSQL_OPTS[@]}" \
        --single-transaction --quick \
        --routines --triggers --events \
        --hex-blob --default-character-set=utf8mb4 \
        --databases "$db" > "$out" 2> "$STAGING/${db}.err"; then
    # mysqldump can print warnings even on success; keep them in the log
    if [[ -s "$STAGING/${db}.err" ]]; then
      log WARN "  $db: mysqldump warnings: $(tr '\n' ' ' < "$STAGING/${db}.err")"
    fi
    rm -f "$STAGING/${db}.err"
    log INFO "  dumped $db ($(du -h "$out" | cut -f1), $((SECONDS - db_start))s)"
  else
    log ERROR "  dump FAILED for $db after $((SECONDS - db_start))s: $(tr '\n' ' ' < "$STAGING/${db}.err")"
    rm -f "$out"
    FAILED=$((FAILED + 1))
  fi
done

(( FAILED == 0 )) || die "$FAILED of ${#DBS[@]} database(s) failed to dump; archive not created, rotation skipped"

# ---- Archive (write to .partial, then rename so a half-written file is never counted) ----
log INFO "Creating archive"
if ! err="$(tar -C "$STAGING" -czf "${ARCHIVE}.partial" . 2>&1)"; then
  die "tar failed: $err"
fi
if ! err="$(gzip -t "${ARCHIVE}.partial" 2>&1)"; then
  die "Archive integrity check failed: $err"
fi
mv "${ARCHIVE}.partial" "$ARCHIVE"
log INFO "Archive created: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

# ---- Rotate: keep newest $KEEP archives for this host ----
mapfile -t OLD < <(
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "mysql-${HOST_TAG}-*.tar.gz" -printf '%T@ %p\n' \
    | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2-
)
DELETED=0
for f in "${OLD[@]}"; do
  [[ -z "$f" ]] && continue
  if (( DRY_RUN )); then
    log INFO "Would delete old archive: $f"
  elif rm -f -- "$f"; then
    log INFO "Deleted old archive: $f"
    DELETED=$((DELETED + 1))
  else
    log WARN "Could not delete old archive: $f"
  fi
done

KEPT=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "mysql-${HOST_TAG}-*.tar.gz" | wc -l)
FREE=$(df -h "$BACKUP_DIR" | awk 'NR==2 {print $4}')
log INFO "Rotation: $DELETED deleted, $KEPT archive(s) on disk, $FREE free in $BACKUP_DIR"
