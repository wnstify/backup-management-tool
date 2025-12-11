#!/usr/bin/env bash
# ============================================================================
# Backup Management Tool - Generators Module
# Script generation functions for backup/restore/verify scripts
# ============================================================================

# ---------- Generate All Scripts ----------

generate_all_scripts() {
  local SECRETS_DIR="$1"
  local DO_DATABASE="$2"
  local DO_FILES="$3"
  local RCLONE_REMOTE="$4"
  local RCLONE_DB_PATH="$5"
  local RCLONE_FILES_PATH="$6"
  local RETENTION_MINUTES="${7:-0}"

  local LOGS_DIR="$INSTALL_DIR/logs"
  mkdir -p "$LOGS_DIR"

  # Generate database backup script
  if [[ "$DO_DATABASE" == "true" ]]; then
    generate_db_backup_script "$SECRETS_DIR" "$RCLONE_REMOTE" "$RCLONE_DB_PATH" "$LOGS_DIR" "$RETENTION_MINUTES"
    generate_db_restore_script "$SECRETS_DIR" "$RCLONE_REMOTE" "$RCLONE_DB_PATH"
    print_success "Database backup script generated"
    print_success "Database restore script generated"
  fi

  # Generate files backup script
  if [[ "$DO_FILES" == "true" ]]; then
    generate_files_backup_script "$SECRETS_DIR" "$RCLONE_REMOTE" "$RCLONE_FILES_PATH" "$LOGS_DIR" "$RETENTION_MINUTES"
    generate_files_restore_script "$RCLONE_REMOTE" "$RCLONE_FILES_PATH"
    print_success "Files backup script generated"
    print_success "Files restore script generated"
  fi
}

# ---------- Generate Database Backup Script ----------

generate_db_backup_script() {
  local SECRETS_DIR="$1"
  local RCLONE_REMOTE="$2"
  local RCLONE_PATH="$3"
  local LOGS_DIR="$4"
  local RETENTION_MINUTES="${5:-0}"

  cat > "$SCRIPTS_DIR/db_backup.sh" << 'DBBACKUPEOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="%%LOGS_DIR%%"
RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_PATH="%%RCLONE_PATH%%"
SECRETS_DIR="%%SECRETS_DIR%%"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
RETENTION_MINUTES="%%RETENTION_MINUTES%%"

# Lock file in fixed location
LOCK_FILE="/var/lock/backup-management-db.lock"

SECRET_PASSPHRASE=".c1"
SECRET_DB_USER=".c2"
SECRET_DB_PASS=".c3"
SECRET_NTFY_TOKEN=".c4"
SECRET_NTFY_URL=".c5"

# Cleanup function
TEMP_DIR=""
MYSQL_AUTH_FILE=""
cleanup() {
  local exit_code=$?
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  [[ -n "$MYSQL_AUTH_FILE" && -f "$MYSQL_AUTH_FILE" ]] && rm -f "$MYSQL_AUTH_FILE"
  exit $exit_code
}
trap cleanup EXIT INT TERM

derive_key() {
  local secrets_dir="$1"
  local machine_id salt
  if [[ -f /etc/machine-id ]]; then
    machine_id="$(cat /etc/machine-id)"
  elif [[ -f /var/lib/dbus/machine-id ]]; then
    machine_id="$(cat /var/lib/dbus/machine-id)"
  else
    machine_id="$(hostname)$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo 'fallback')"
  fi
  salt="$(cat "$secrets_dir/.s")"
  echo -n "${machine_id}${salt}" | sha256sum | cut -d' ' -f1
}

get_secret() {
  local secrets_dir="$1" secret_name="$2" key
  [[ ! -f "$secrets_dir/$secret_name" ]] && return 1
  key="$(derive_key "$secrets_dir")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt -pass "pass:$key" -base64 -in "$secrets_dir/$secret_name" 2>/dev/null || echo ""
}

# Acquire lock (fixed location so it works across runs)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[INFO] Another database backup is running. Exiting."
  exit 0
fi

# Create temp directory
TEMP_DIR="$(mktemp -d)"

# Log rotation function
rotate_log() {
  local log_file="$1"
  local max_size=$((10 * 1024 * 1024))  # 10MB
  [[ ! -f "$log_file" ]] && return 0
  local log_size
  log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
  if [[ "$log_size" -gt "$max_size" ]]; then
    [[ -f "${log_file}.5" ]] && rm -f "${log_file}.5"
    for ((i=4; i>=1; i--)); do
      [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i+1))"
    done
    mv "$log_file" "${log_file}.1"
  fi
}

# Logging with rotation
STAMP="$(date +%F-%H%M)"
LOG="$LOGS_DIR/db_logfile.log"
mkdir -p "$LOGS_DIR"
rotate_log "$LOG"
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "==== $(date +%F' '%T) START per-db backup ===="

# Check disk space (need at least 1GB free in temp)
AVAIL_MB=$(df -m /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
if [[ "$AVAIL_MB" -lt 1000 ]]; then
  echo "[ERROR] Insufficient disk space in /tmp (${AVAIL_MB}MB available, 1000MB required)"
  exit 3
fi

# Get secrets
PASSPHRASE="$(get_secret "$SECRETS_DIR" "$SECRET_PASSPHRASE")"
[[ -z "$PASSPHRASE" ]] && { echo "[ERROR] No passphrase found"; exit 2; }

NTFY_URL="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_URL" || echo "")"
NTFY_TOKEN="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN" || echo "")"

send_notification() {
  local title="$1" message="$2"
  [[ -z "$NTFY_URL" ]] && return 0
  # Timeout for notification
  if [[ -n "$NTFY_TOKEN" ]]; then
    timeout 10 curl -s -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null 2>&1 || true
  else
    timeout 10 curl -s -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null 2>&1 || true
  fi
}

[[ -n "$NTFY_URL" ]] && send_notification "DB Backup Started on $HOSTNAME" "Starting at $(date)"

# Compressor
if command -v pigz >/dev/null 2>&1; then
  COMPRESSOR="pigz -9 -p $(nproc 2>/dev/null || echo 2)"
else
  COMPRESSOR="gzip -9"
fi

# DB client
if command -v mariadb >/dev/null 2>&1; then
  DB_CLIENT="mariadb"; DB_DUMP="mariadb-dump"
elif command -v mysql >/dev/null 2>&1; then
  DB_CLIENT="mysql"; DB_DUMP="mysqldump"
else
  echo "[ERROR] No database client found"; exit 5
fi

# Get DB credentials and create auth file (more secure than command line)
DB_USER="$(get_secret "$SECRETS_DIR" "$SECRET_DB_USER" || echo "")"
DB_PASS="$(get_secret "$SECRETS_DIR" "$SECRET_DB_PASS" || echo "")"
MYSQL_ARGS=()

if [[ -n "$DB_USER" && -n "$DB_PASS" ]]; then
  # Use defaults-extra-file to hide password from process list
  MYSQL_AUTH_FILE="$(mktemp)"
  chmod 600 "$MYSQL_AUTH_FILE"
  cat > "$MYSQL_AUTH_FILE" << AUTHEOF
[client]
user=$DB_USER
password=$DB_PASS
AUTHEOF
  MYSQL_ARGS=("--defaults-extra-file=$MYSQL_AUTH_FILE")
fi

EXCLUDE_REGEX='^(information_schema|performance_schema|sys|mysql)$'
DBS="$($DB_CLIENT "${MYSQL_ARGS[@]}" -NBe 'SHOW DATABASES' 2>/dev/null | grep -Ev "$EXCLUDE_REGEX" || true)"

if [[ -z "$DBS" ]]; then
  echo "[ERROR] No databases found or cannot connect to database"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "No databases found"
  exit 6
fi

DEST="$TEMP_DIR/$STAMP"
mkdir -p "$DEST"

declare -a failures=()
db_count=0
for db in $DBS; do
  echo "  -> Dumping: $db"
  if "$DB_DUMP" "${MYSQL_ARGS[@]}" --databases "$db" --single-transaction --quick \
      --routines --events --triggers --hex-blob --default-character-set=utf8mb4 \
      2>/dev/null | $COMPRESSOR > "$DEST/${db}-${STAMP}.sql.gz"; then
    echo "    OK: $db"
    ((db_count++)) || true
  else
    echo "    FAILED: $db"
    failures+=("$db")
  fi
done

if [[ $db_count -eq 0 ]]; then
  echo "[ERROR] All database dumps failed"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "All dumps failed"
  exit 7
fi

# Archive + encrypt
ARCHIVE="$TEMP_DIR/${HOSTNAME}-db_backups-${STAMP}.tar.gz.gpg"
echo "Creating encrypted archive..."
tar -C "$TEMP_DIR" -cf - "$STAMP" | $COMPRESSOR | \
  gpg --batch --yes --pinentry-mode=loopback --passphrase "$PASSPHRASE" --symmetric --cipher-algo AES256 -o "$ARCHIVE"

# Verify archive
echo "Verifying archive..."
if ! gpg --batch --quiet --pinentry-mode=loopback --passphrase "$PASSPHRASE" -d "$ARCHIVE" 2>/dev/null | tar -tzf - >/dev/null 2>&1; then
  echo "[ERROR] Archive verification failed"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "Archive verification failed"
  exit 4
fi
echo "Archive verified."

# Generate checksum
echo "Generating checksum..."
CHECKSUM_FILE="${ARCHIVE}.sha256"
sha256sum "$ARCHIVE" | awk '{print $1}' > "$CHECKSUM_FILE"
echo "Checksum: $(cat "$CHECKSUM_FILE")"

# Upload with timeout and retry
echo "Uploading to remote storage..."
RCLONE_TIMEOUT=1800  # 30 minutes
if ! timeout $RCLONE_TIMEOUT rclone copy "$ARCHIVE" "$RCLONE_REMOTE:$RCLONE_PATH" --retries 3 --low-level-retries 10; then
  echo "[ERROR] Upload failed"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "Upload failed"
  exit 8
fi

# Upload checksum file
if ! timeout 60 rclone copy "$CHECKSUM_FILE" "$RCLONE_REMOTE:$RCLONE_PATH" --retries 3; then
  echo "[WARNING] Checksum upload failed, but backup succeeded"
fi

# Verify upload
if ! timeout 60 rclone check "$(dirname "$ARCHIVE")" "$RCLONE_REMOTE:$RCLONE_PATH" --one-way --size-only --include "$(basename "$ARCHIVE")" 2>/dev/null; then
  echo "[WARNING] Upload verification could not complete, but upload may have succeeded"
fi

echo "Uploaded to $RCLONE_REMOTE:$RCLONE_PATH"

# Retention cleanup
if [[ "$RETENTION_MINUTES" -gt 0 ]]; then
  echo "Running retention cleanup (keeping backups newer than $RETENTION_MINUTES minutes)..."
  cleanup_count=0
  cleanup_errors=0
  cutoff_time=$(date -d "-$RETENTION_MINUTES minutes" +%s 2>/dev/null || date -v-${RETENTION_MINUTES}M +%s 2>/dev/null || echo 0)

  if [[ "$cutoff_time" -gt 0 ]]; then
    # List remote files and check their age
    while IFS= read -r remote_file; do
      [[ -z "$remote_file" ]] && continue
      # Get file modification time from rclone
      file_time=$(rclone lsl "$RCLONE_REMOTE:$RCLONE_PATH/$remote_file" 2>&1 | awk '{print $2" "$3}' | head -1)
      if [[ -n "$file_time" && ! "$file_time" =~ ^ERROR ]]; then
        file_epoch=$(date -d "$file_time" +%s 2>/dev/null || echo 0)
        if [[ "$file_epoch" -gt 0 && "$file_epoch" -lt "$cutoff_time" ]]; then
          echo "  Deleting old backup: $remote_file"
          delete_output=$(rclone delete "$RCLONE_REMOTE:$RCLONE_PATH/$remote_file" 2>&1)
          if [[ $? -eq 0 ]]; then
            ((cleanup_count++)) || true
            # Also delete corresponding checksum file
            rclone delete "$RCLONE_REMOTE:$RCLONE_PATH/${remote_file}.sha256" 2>/dev/null || true
          else
            echo "  [ERROR] Failed to delete $remote_file: $delete_output"
            ((cleanup_errors++)) || true
          fi
        fi
      fi
    done < <(rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --include "*-db_backups-*.tar.gz.gpg" 2>&1)

    if [[ $cleanup_errors -gt 0 ]]; then
      echo "[WARNING] Retention cleanup completed with $cleanup_errors error(s). Removed $cleanup_count old backup(s)."
      [[ -n "$NTFY_URL" ]] && send_notification "DB Retention Cleanup Warning on $HOSTNAME" "Removed: $cleanup_count, Errors: $cleanup_errors"
    elif [[ $cleanup_count -gt 0 ]]; then
      echo "Retention cleanup complete. Removed $cleanup_count old backup(s)."
      [[ -n "$NTFY_URL" ]] && send_notification "DB Retention Cleanup on $HOSTNAME" "Removed $cleanup_count old backup(s)"
    else
      echo "Retention cleanup complete. No old backups to remove."
    fi
  else
    echo "  [WARNING] Could not calculate cutoff time, skipping cleanup"
    [[ -n "$NTFY_URL" ]] && send_notification "DB Retention Cleanup Failed on $HOSTNAME" "Could not calculate cutoff time"
  fi
fi

if ((${#failures[@]})); then
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Completed with Errors on $HOSTNAME" "Backed up: $db_count, Failed: ${failures[*]}"
  echo "==== $(date +%F' '%T) END (with errors) ===="
  exit 1
else
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Successful on $HOSTNAME" "All $db_count databases backed up"
  echo "==== $(date +%F' '%T) END (success) ===="
fi
DBBACKUPEOF

  sed -i \
    -e "s|%%LOGS_DIR%%|$LOGS_DIR|g" \
    -e "s|%%RCLONE_REMOTE%%|$RCLONE_REMOTE|g" \
    -e "s|%%RCLONE_PATH%%|$RCLONE_PATH|g" \
    -e "s|%%SECRETS_DIR%%|$SECRETS_DIR|g" \
    -e "s|%%RETENTION_MINUTES%%|$RETENTION_MINUTES|g" \
    "$SCRIPTS_DIR/db_backup.sh"

  chmod +x "$SCRIPTS_DIR/db_backup.sh"
}

# ---------- Generate Database Restore Script ----------

generate_db_restore_script() {
  local SECRETS_DIR="$1"
  local RCLONE_REMOTE="$2"
  local RCLONE_PATH="$3"

  cat > "$SCRIPTS_DIR/db_restore.sh" << 'DBRESTOREEOF'
#!/usr/bin/env bash
set -uo pipefail
umask 077

RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_PATH="%%RCLONE_PATH%%"
SECRETS_DIR="%%SECRETS_DIR%%"
LOG_PREFIX="[DB-RESTORE]"

# Use same lock as backup to prevent conflicts
LOCK_FILE="/var/lock/backup-management-db.lock"

SECRET_DB_USER=".c2"
SECRET_DB_PASS=".c3"

derive_key() {
  local secrets_dir="$1" machine_id salt
  if [[ -f /etc/machine-id ]]; then machine_id="$(cat /etc/machine-id)"
  elif [[ -f /var/lib/dbus/machine-id ]]; then machine_id="$(cat /var/lib/dbus/machine-id)"
  else machine_id="$(hostname)$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo 'fallback')"; fi
  salt="$(cat "$secrets_dir/.s")"
  echo -n "${machine_id}${salt}" | sha256sum | cut -d' ' -f1
}

get_secret() {
  local secrets_dir="$1" secret_name="$2" key
  [[ ! -f "$secrets_dir/$secret_name" ]] && return 1
  key="$(derive_key "$secrets_dir")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt -pass "pass:$key" -base64 -in "$secrets_dir/$secret_name" 2>/dev/null || echo ""
}

# Acquire lock (wait up to 60 seconds if backup is running)
exec 9>"$LOCK_FILE"
if ! flock -w 60 9; then
  echo "$LOG_PREFIX ERROR: Could not acquire lock. A backup may be running."
  echo "$LOG_PREFIX Please wait for the backup to complete and try again."
  exit 1
fi

echo "========================================================"
echo "           Database Restore Utility"
echo "========================================================"
echo

# DB client
if command -v mariadb >/dev/null 2>&1; then DB_CLIENT="mariadb"
elif command -v mysql >/dev/null 2>&1; then DB_CLIENT="mysql"
else echo "$LOG_PREFIX ERROR: No database client found."; exit 1; fi

# Get DB credentials and create auth file (more secure than command line)
DB_USER="$(get_secret "$SECRETS_DIR" "$SECRET_DB_USER" || echo "")"
DB_PASS="$(get_secret "$SECRETS_DIR" "$SECRET_DB_PASS" || echo "")"
MYSQL_ARGS=()
MYSQL_AUTH_FILE=""

if [[ -n "$DB_USER" && -n "$DB_PASS" ]]; then
  MYSQL_AUTH_FILE="$(mktemp)"
  chmod 600 "$MYSQL_AUTH_FILE"
  cat > "$MYSQL_AUTH_FILE" << AUTHEOF
[client]
user=$DB_USER
password=$DB_PASS
AUTHEOF
  MYSQL_ARGS=("--defaults-extra-file=$MYSQL_AUTH_FILE")
fi

# Cleanup function
cleanup_restore() {
  [[ -n "$MYSQL_AUTH_FILE" && -f "$MYSQL_AUTH_FILE" ]] && rm -f "$MYSQL_AUTH_FILE"
}

TEMP_DIR="$(mktemp -d)"
trap "rm -rf '$TEMP_DIR'; cleanup_restore" EXIT

echo "Step 1: Encryption Password"
echo "----------------------------"
read -sp "Enter backup encryption password: " RESTORE_PASSWORD
echo
echo

echo "Step 2: Select Backup"
echo "---------------------"
echo "$LOG_PREFIX Fetching backups from $RCLONE_REMOTE:$RCLONE_PATH..."

declare -a ALL_BACKUPS=()
remote_files="$(rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --include "*.tar.gz.gpg" 2>/dev/null | sort -r)" || true
while IFS= read -r f; do [[ -n "$f" ]] && ALL_BACKUPS+=("$f"); done <<< "$remote_files"

echo "$LOG_PREFIX Found ${#ALL_BACKUPS[@]} backup(s)."
[[ ${#ALL_BACKUPS[@]} -eq 0 ]] && { echo "$LOG_PREFIX No backups found."; exit 1; }

echo
for i in "${!ALL_BACKUPS[@]}"; do
  printf "  %2d) %s\n" "$((i+1))" "${ALL_BACKUPS[$i]}"
done
echo
read -p "Select backup [1-${#ALL_BACKUPS[@]}]: " sel
[[ ! "$sel" =~ ^[0-9]+$ ]] && exit 1
SELECTED="${ALL_BACKUPS[$((sel-1))]}"

echo
echo "$LOG_PREFIX Downloading $SELECTED..."
rclone copy "$RCLONE_REMOTE:$RCLONE_PATH/$SELECTED" "$TEMP_DIR/" --progress

# Download and verify checksum if available
CHECKSUM_FILE="${SELECTED}.sha256"
if rclone copy "$RCLONE_REMOTE:$RCLONE_PATH/$CHECKSUM_FILE" "$TEMP_DIR/" 2>/dev/null; then
  echo "$LOG_PREFIX Verifying checksum..."
  STORED_CHECKSUM=$(cat "$TEMP_DIR/$CHECKSUM_FILE")
  CALCULATED_CHECKSUM=$(sha256sum "$TEMP_DIR/$SELECTED" | awk '{print $1}')
  if [[ "$STORED_CHECKSUM" == "$CALCULATED_CHECKSUM" ]]; then
    echo "$LOG_PREFIX Checksum verified"
  else
    echo "$LOG_PREFIX [ERROR] Checksum mismatch! Backup may be corrupted."
    echo "$LOG_PREFIX   Expected: $STORED_CHECKSUM"
    echo "$LOG_PREFIX   Got:      $CALCULATED_CHECKSUM"
    read -p "Continue anyway? (y/N): " continue_anyway
    [[ ! "$continue_anyway" =~ ^[Yy]$ ]] && exit 1
  fi
else
  echo "$LOG_PREFIX [INFO] No checksum file found (backup may predate checksum feature)"
fi

echo "$LOG_PREFIX Decrypting..."
EXTRACT_DIR="$TEMP_DIR/extracted"
mkdir -p "$EXTRACT_DIR"
gpg --batch --quiet --pinentry-mode=loopback --passphrase "$RESTORE_PASSWORD" -d "$TEMP_DIR/$SELECTED" | tar -xzf - -C "$EXTRACT_DIR"

EXTRACTED_DIR="$(find "$EXTRACT_DIR" -maxdepth 1 -type d ! -path "$EXTRACT_DIR" | head -1)"
[[ -z "$EXTRACTED_DIR" ]] && EXTRACTED_DIR="$EXTRACT_DIR"

echo
echo "Step 3: Select Databases"
echo "------------------------"
mapfile -t SQL_FILES < <(find "$EXTRACTED_DIR" -name "*.sql.gz" -type f | sort)
[[ ${#SQL_FILES[@]} -eq 0 ]] && { echo "No databases found in backup."; exit 1; }

for i in "${!SQL_FILES[@]}"; do
  db_name="$(basename "${SQL_FILES[$i]}" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.sql\.gz$//')"
  printf "  %2d) %s\n" "$((i+1))" "$db_name"
done
echo "  A) All databases"
echo "  Q) Quit"
echo
read -p "Selection: " db_sel

[[ "$db_sel" =~ ^[Qq]$ ]] && exit 0

declare -a SELECTED_DBS=()
if [[ "$db_sel" =~ ^[Aa]$ ]]; then
  SELECTED_DBS=("${SQL_FILES[@]}")
else
  IFS=',' read -ra sels <<< "$db_sel"
  for s in "${sels[@]}"; do
    s="$(echo "$s" | tr -d ' ')"
    [[ "$s" =~ ^[0-9]+$ ]] && SELECTED_DBS+=("${SQL_FILES[$((s-1))]}")
  done
fi

echo
echo "Restoring ${#SELECTED_DBS[@]} database(s)..."
read -p "Confirm? (yes/no): " confirm
[[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]] && exit 0

for sql_file in "${SELECTED_DBS[@]}"; do
  db_name="$(basename "$sql_file" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\.sql\.gz$//')"
  echo "Restoring: $db_name"
  if gunzip -c "$sql_file" | $DB_CLIENT "${MYSQL_ARGS[@]}" 2>/dev/null; then
    echo "  Success"
  else
    echo "  Failed"
  fi
done

echo
echo "Restore complete!"
DBRESTOREEOF

  sed -i \
    -e "s|%%RCLONE_REMOTE%%|$RCLONE_REMOTE|g" \
    -e "s|%%RCLONE_PATH%%|$RCLONE_PATH|g" \
    -e "s|%%SECRETS_DIR%%|$SECRETS_DIR|g" \
    "$SCRIPTS_DIR/db_restore.sh"

  chmod +x "$SCRIPTS_DIR/db_restore.sh"
}

# ---------- Generate Files Backup Script ----------

generate_files_backup_script() {
  local SECRETS_DIR="$1"
  local RCLONE_REMOTE="$2"
  local RCLONE_PATH="$3"
  local LOGS_DIR="$4"
  local RETENTION_MINUTES="${5:-0}"

  cat > "$SCRIPTS_DIR/files_backup.sh" << 'FILESBACKUPEOF'
#!/usr/bin/env bash
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="%%LOGS_DIR%%"
RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_PATH="%%RCLONE_PATH%%"
SECRETS_DIR="%%SECRETS_DIR%%"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
LOG_PREFIX="[FILES-BACKUP]"
WWW_DIR="/var/www"
RETENTION_MINUTES="%%RETENTION_MINUTES%%"

# Lock file in fixed location
LOCK_FILE="/var/lock/backup-management-files.lock"

SECRET_NTFY_TOKEN=".c4"
SECRET_NTFY_URL=".c5"

# Cleanup function
TEMP_DIR=""
cleanup() {
  local exit_code=$?
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit $exit_code
}
trap cleanup EXIT INT TERM

derive_key() {
  local secrets_dir="$1" machine_id salt
  if [[ -f /etc/machine-id ]]; then machine_id="$(cat /etc/machine-id)"
  elif [[ -f /var/lib/dbus/machine-id ]]; then machine_id="$(cat /var/lib/dbus/machine-id)"
  else machine_id="$(hostname)$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo 'fallback')"; fi
  salt="$(cat "$secrets_dir/.s")"
  echo -n "${machine_id}${salt}" | sha256sum | cut -d' ' -f1
}

get_secret() {
  local secrets_dir="$1" secret_name="$2" key
  [[ ! -f "$secrets_dir/$secret_name" ]] && return 1
  key="$(derive_key "$secrets_dir")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt -pass "pass:$key" -base64 -in "$secrets_dir/$secret_name" 2>/dev/null || echo ""
}

# Acquire lock (fixed location)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "$LOG_PREFIX Another backup running. Exiting."
  exit 0
fi

# Create temp directory
TEMP_DIR="$(mktemp -d)"

# Log rotation function
rotate_log() {
  local log_file="$1"
  local max_size=$((10 * 1024 * 1024))  # 10MB
  [[ ! -f "$log_file" ]] && return 0
  local log_size
  log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
  if [[ "$log_size" -gt "$max_size" ]]; then
    [[ -f "${log_file}.5" ]] && rm -f "${log_file}.5"
    for ((i=4; i>=1; i--)); do
      [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i+1))"
    done
    mv "$log_file" "${log_file}.1"
  fi
}

STAMP="$(date +%F-%H%M)"
LOG="$LOGS_DIR/files_logfile.log"
mkdir -p "$LOGS_DIR"
rotate_log "$LOG"
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "==== $(date +%F' '%T) START files backup ===="

# Check disk space (need at least 2GB free in temp)
AVAIL_MB=$(df -m /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
if [[ "$AVAIL_MB" -lt 2000 ]]; then
  echo "$LOG_PREFIX [ERROR] Insufficient disk space in /tmp (${AVAIL_MB}MB available, 2000MB required)"
  exit 3
fi

NTFY_URL="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_URL" || echo "")"
NTFY_TOKEN="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN" || echo "")"

send_notification() {
  local title="$1" message="$2"
  [[ -z "$NTFY_URL" ]] && return 0
  if [[ -n "$NTFY_TOKEN" ]]; then
    timeout 10 curl -s -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null 2>&1 || true
  else
    timeout 10 curl -s -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null 2>&1 || true
  fi
}

[[ -n "$NTFY_URL" ]] && send_notification "Files Backup Started on $HOSTNAME" "Starting at $(date)"

command -v pigz >/dev/null 2>&1 || { echo "$LOG_PREFIX pigz not found"; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "$LOG_PREFIX tar not found"; exit 1; }

sanitize_for_filename() {
  local s="$1"
  s="$(echo -n "$s" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  s="${s//:\/\//__}"; s="${s//\//__}"
  s="$(echo -n "$s" | sed -E 's/[^a-z0-9._-]+/_/g')"
  s="${s%.}"
  [[ -z "$s" ]] && s="unknown-site"
  printf "%s" "$s"
}

get_wp_site_url() {
  local user="$1" wp_root="$2" url=""
  if su -l -s /bin/bash "$user" -c "command -v wp >/dev/null 2>&1" 2>/dev/null; then
    url="$(su -l -s /bin/bash "$user" -c "cd '$wp_root' && wp option get siteurl 2>/dev/null" 2>/dev/null || true)"
  fi
  if [[ -z "$url" && -f "$wp_root/wp-config.php" ]]; then
    url="$(grep -E "define\s*\(\s*['\"]WP_HOME['\"]" "$wp_root/wp-config.php" 2>/dev/null | head -1 | sed -E "s/.*['\"]https?:\/\/([^'\"]+)['\"].*/https:\/\/\1/" || true)"
  fi
  [[ -z "$url" ]] && url="$(basename "$wp_root")"
  echo "$url"
}

echo "$LOG_PREFIX Scanning $WWW_DIR..."

# Check if WWW_DIR exists
if [[ ! -d "$WWW_DIR" ]]; then
  echo "$LOG_PREFIX [ERROR] $WWW_DIR does not exist"
  [[ -n "$NTFY_URL" ]] && send_notification "Files Backup Failed on $HOSTNAME" "$WWW_DIR not found"
  exit 4
fi

declare -a failures=()
success_count=0
site_count=0

for site_path in "$WWW_DIR"/*/; do
  [[ ! -d "$site_path" ]] && continue
  site_name="$(basename "$site_path")"
  [[ "$site_name" == "default" || "$site_name" == "html" ]] && continue

  wp_root=""
  if [[ -d "$site_path/public_html" ]]; then
    wp_root="$site_path/public_html"
  elif [[ -f "$site_path/wp-config.php" ]]; then
    wp_root="$site_path"
  else
    continue
  fi

  ((site_count++)) || true

  owner="$(stat -c '%U' "$site_path" 2>/dev/null || echo "www-data")"
  site_url="$(get_wp_site_url "$owner" "$wp_root")"
  base_name="$(sanitize_for_filename "$site_url")"
  archive_path="$TEMP_DIR/${base_name}-${STAMP}.tar.gz"

  echo "$LOG_PREFIX [$site_name] Archiving..."
  if tar --numeric-owner --warning=no-file-changed --ignore-failed-read -I pigz -cpf "$archive_path" -C "$WWW_DIR" "$site_name" 2>/dev/null; then
    tar_status=0
  else
    tar_status=$?
  fi

  # tar exit code 1 = files changed during archive (acceptable)
  # tar exit code > 1 = actual error
  [[ $tar_status -gt 1 ]] && { echo "$LOG_PREFIX [$site_name] Archive failed"; failures+=("$site_name"); continue; }
  [[ ! -f "$archive_path" ]] && { echo "$LOG_PREFIX [$site_name] Archive file not created"; failures+=("$site_name"); continue; }

  echo "$LOG_PREFIX [$site_name] Uploading..."

  # Generate checksum
  checksum_file="${archive_path}.sha256"
  sha256sum "$archive_path" | awk '{print $1}' > "$checksum_file"
  echo "$LOG_PREFIX [$site_name] Checksum: $(cat "$checksum_file")"

  if timeout 3600 rclone copy "$archive_path" "$RCLONE_REMOTE:$RCLONE_PATH" --retries 3 --low-level-retries 10; then
    # Upload checksum file
    timeout 60 rclone copy "$checksum_file" "$RCLONE_REMOTE:$RCLONE_PATH" --retries 3 || echo "$LOG_PREFIX [$site_name] Checksum upload failed (backup OK)"
    rm -f "$archive_path" "$checksum_file"
    ((success_count++)) || true
    echo "$LOG_PREFIX [$site_name] Done"
  else
    echo "$LOG_PREFIX [$site_name] Upload failed"
    rm -f "$checksum_file"
    failures+=("$site_name")
  fi
done

if [[ $site_count -eq 0 ]]; then
  echo "$LOG_PREFIX [WARNING] No sites found in $WWW_DIR"
  [[ -n "$NTFY_URL" ]] && send_notification "Files Backup Warning on $HOSTNAME" "No sites found"
  echo "==== $(date +%F' '%T) END (no sites) ===="
  exit 0
fi

# Retention cleanup
if [[ "$RETENTION_MINUTES" -gt 0 ]]; then
  echo "$LOG_PREFIX Running retention cleanup (keeping backups newer than $RETENTION_MINUTES minutes)..."
  cleanup_count=0
  cleanup_errors=0
  cutoff_time=$(date -d "-$RETENTION_MINUTES minutes" +%s 2>/dev/null || date -v-${RETENTION_MINUTES}M +%s 2>/dev/null || echo 0)

  if [[ "$cutoff_time" -gt 0 ]]; then
    # List remote files and check their age
    while IFS= read -r remote_file; do
      [[ -z "$remote_file" ]] && continue
      # Get file modification time from rclone
      file_time=$(rclone lsl "$RCLONE_REMOTE:$RCLONE_PATH/$remote_file" 2>&1 | awk '{print $2" "$3}' | head -1)
      if [[ -n "$file_time" && ! "$file_time" =~ ^ERROR ]]; then
        file_epoch=$(date -d "$file_time" +%s 2>/dev/null || echo 0)
        if [[ "$file_epoch" -gt 0 && "$file_epoch" -lt "$cutoff_time" ]]; then
          echo "$LOG_PREFIX   Deleting old backup: $remote_file"
          delete_output=$(rclone delete "$RCLONE_REMOTE:$RCLONE_PATH/$remote_file" 2>&1)
          if [[ $? -eq 0 ]]; then
            ((cleanup_count++)) || true
            # Also delete corresponding checksum file
            rclone delete "$RCLONE_REMOTE:$RCLONE_PATH/${remote_file}.sha256" 2>/dev/null || true
          else
            echo "$LOG_PREFIX   [ERROR] Failed to delete $remote_file: $delete_output"
            ((cleanup_errors++)) || true
          fi
        fi
      fi
    done < <(rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --include "*.tar.gz" --exclude "*.sha256" 2>&1)

    if [[ $cleanup_errors -gt 0 ]]; then
      echo "$LOG_PREFIX [WARNING] Retention cleanup completed with $cleanup_errors error(s). Removed $cleanup_count old backup(s)."
      [[ -n "$NTFY_URL" ]] && send_notification "Files Retention Cleanup Warning on $HOSTNAME" "Removed: $cleanup_count, Errors: $cleanup_errors"
    elif [[ $cleanup_count -gt 0 ]]; then
      echo "$LOG_PREFIX Retention cleanup complete. Removed $cleanup_count old backup(s)."
      [[ -n "$NTFY_URL" ]] && send_notification "Files Retention Cleanup on $HOSTNAME" "Removed $cleanup_count old backup(s)"
    else
      echo "$LOG_PREFIX Retention cleanup complete. No old backups to remove."
    fi
  else
    echo "$LOG_PREFIX [WARNING] Could not calculate cutoff time, skipping cleanup"
    [[ -n "$NTFY_URL" ]] && send_notification "Files Retention Cleanup Failed on $HOSTNAME" "Could not calculate cutoff time"
  fi
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  [[ -n "$NTFY_URL" ]] && send_notification "Files Backup Errors on $HOSTNAME" "Success: $success_count, Failed: ${failures[*]}"
  echo "==== $(date +%F' '%T) END (with errors) ===="
  exit 1
else
  [[ -n "$NTFY_URL" ]] && send_notification "Files Backup Success on $HOSTNAME" "$success_count sites backed up"
  echo "==== $(date +%F' '%T) END (success) ===="
fi
FILESBACKUPEOF

  sed -i \
    -e "s|%%LOGS_DIR%%|$LOGS_DIR|g" \
    -e "s|%%RCLONE_REMOTE%%|$RCLONE_REMOTE|g" \
    -e "s|%%RCLONE_PATH%%|$RCLONE_PATH|g" \
    -e "s|%%SECRETS_DIR%%|$SECRETS_DIR|g" \
    -e "s|%%RETENTION_MINUTES%%|$RETENTION_MINUTES|g" \
    "$SCRIPTS_DIR/files_backup.sh"

  chmod +x "$SCRIPTS_DIR/files_backup.sh"
}

# ---------- Generate Files Restore Script ----------

generate_files_restore_script() {
  local RCLONE_REMOTE="$1"
  local RCLONE_PATH="$2"

  cat > "$SCRIPTS_DIR/files_restore.sh" << 'FILESRESTOREEOF'
#!/usr/bin/env bash
set -uo pipefail
umask 077

RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_PATH="%%RCLONE_PATH%%"
LOG_PREFIX="[FILES-RESTORE]"
WWW_DIR="/var/www"

# Use same lock as backup to prevent conflicts
LOCK_FILE="/var/lock/backup-management-files.lock"

# Acquire lock (wait up to 60 seconds if backup is running)
exec 9>"$LOCK_FILE"
if ! flock -w 60 9; then
  echo "$LOG_PREFIX ERROR: Could not acquire lock. A backup may be running."
  echo "$LOG_PREFIX Please wait for the backup to complete and try again."
  exit 1
fi

echo "========================================================"
echo "           Files Restore Utility"
echo "========================================================"
echo

TEMP_DIR="$(mktemp -d)"
trap "rm -rf '$TEMP_DIR'" EXIT

echo "Step 1: Select Backup"
echo "---------------------"
echo "$LOG_PREFIX Fetching backups from $RCLONE_REMOTE:$RCLONE_PATH..."

declare -a ALL_BACKUPS=()
remote_files="$(rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --include "*.tar.gz" --exclude "*.sha256" 2>/dev/null | sort -r)" || true
while IFS= read -r f; do [[ -n "$f" ]] && ALL_BACKUPS+=("$f"); done <<< "$remote_files"

echo "$LOG_PREFIX Found ${#ALL_BACKUPS[@]} backup(s)."
[[ ${#ALL_BACKUPS[@]} -eq 0 ]] && { echo "$LOG_PREFIX No backups found."; exit 1; }

echo
for i in "${!ALL_BACKUPS[@]}"; do
  printf "  %2d) %s\n" "$((i+1))" "${ALL_BACKUPS[$i]}"
done
echo "  Q) Quit"
echo
read -p "Select backup [1-${#ALL_BACKUPS[@]}]: " sel
[[ "$sel" =~ ^[Qq]$ ]] && exit 0
[[ ! "$sel" =~ ^[0-9]+$ ]] && exit 1
SELECTED="${ALL_BACKUPS[$((sel-1))]}"

echo
echo "$LOG_PREFIX Downloading $SELECTED..."
rclone copy "$RCLONE_REMOTE:$RCLONE_PATH/$SELECTED" "$TEMP_DIR/" --progress
BACKUP_FILE="$TEMP_DIR/$SELECTED"

# Download and verify checksum if available
CHECKSUM_FILE="${SELECTED}.sha256"
if rclone copy "$RCLONE_REMOTE:$RCLONE_PATH/$CHECKSUM_FILE" "$TEMP_DIR/" 2>/dev/null; then
  echo "$LOG_PREFIX Verifying checksum..."
  STORED_CHECKSUM=$(cat "$TEMP_DIR/$CHECKSUM_FILE")
  CALCULATED_CHECKSUM=$(sha256sum "$BACKUP_FILE" | awk '{print $1}')
  if [[ "$STORED_CHECKSUM" == "$CALCULATED_CHECKSUM" ]]; then
    echo "$LOG_PREFIX Checksum verified"
  else
    echo "$LOG_PREFIX [ERROR] Checksum mismatch! Backup may be corrupted."
    echo "$LOG_PREFIX   Expected: $STORED_CHECKSUM"
    echo "$LOG_PREFIX   Got:      $CALCULATED_CHECKSUM"
    read -p "Continue anyway? (y/N): " continue_anyway
    [[ ! "$continue_anyway" =~ ^[Yy]$ ]] && exit 1
  fi
else
  echo "$LOG_PREFIX [INFO] No checksum file found (backup may predate checksum feature)"
fi

echo
echo "Step 2: Select Sites"
echo "--------------------"
mapfile -t SITES < <(tar -tzf "$BACKUP_FILE" 2>/dev/null | grep -E '^[^/]+/$' | sed 's|/$||' | sort -u)
[[ ${#SITES[@]} -eq 0 ]] && { echo "No sites found in backup."; exit 1; }

for i in "${!SITES[@]}"; do
  site="${SITES[$i]}"
  [[ -d "$WWW_DIR/$site" ]] && tag="[EXISTS]" || tag="[NEW]"
  printf "  %2d) %-10s %s\n" "$((i+1))" "$tag" "$site"
done
echo "  A) All sites"
echo "  Q) Quit"
echo
read -p "Selection: " site_sel
[[ "$site_sel" =~ ^[Qq]$ ]] && exit 0

declare -a SELECTED_SITES=()
if [[ "$site_sel" =~ ^[Aa]$ ]]; then
  SELECTED_SITES=("${SITES[@]}")
else
  IFS=',' read -ra sels <<< "$site_sel"
  for s in "${sels[@]}"; do
    s="$(echo "$s" | tr -d ' ')"
    [[ "$s" =~ ^[0-9]+$ ]] && SELECTED_SITES+=("${SITES[$((s-1))]}")
  done
fi

echo
echo "Sites to restore: ${SELECTED_SITES[*]}"
read -p "This will OVERWRITE existing sites. Continue? (yes/no): " confirm
[[ ! "$confirm" =~ ^[Yy][Ee][Ss]$ ]] && exit 0

for site in "${SELECTED_SITES[@]}"; do
  echo "Restoring: $site"
  backup_name=""  # Reset for each iteration

  if [[ -d "$WWW_DIR/$site" ]]; then
    backup_name="${site}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    mv "$WWW_DIR/$site" "$WWW_DIR/$backup_name"
  fi

  if tar -xzf "$BACKUP_FILE" -C "$WWW_DIR" "$site" 2>/dev/null; then
    echo "  Success"
    # Only remove backup if we created one and restore succeeded
    [[ -n "$backup_name" && -d "$WWW_DIR/$backup_name" ]] && rm -rf "$WWW_DIR/$backup_name"
  else
    echo "  Failed"
    # Restore the backup if we made one
    [[ -n "$backup_name" && -d "$WWW_DIR/$backup_name" ]] && mv "$WWW_DIR/$backup_name" "$WWW_DIR/$site"
  fi
done

echo
echo "Restore complete!"
FILESRESTOREEOF

  sed -i \
    -e "s|%%RCLONE_REMOTE%%|$RCLONE_REMOTE|g" \
    -e "s|%%RCLONE_PATH%%|$RCLONE_PATH|g" \
    "$SCRIPTS_DIR/files_restore.sh"

  chmod +x "$SCRIPTS_DIR/files_restore.sh"
}

# ---------- Generate Verify Script ----------

generate_verify_script() {
  local secrets_dir rclone_remote rclone_db_path rclone_files_path
  secrets_dir="$(get_secrets_dir)"
  rclone_remote="$(get_config_value 'RCLONE_REMOTE')"
  rclone_db_path="$(get_config_value 'RCLONE_DB_PATH')"
  rclone_files_path="$(get_config_value 'RCLONE_FILES_PATH')"

  cat > "$SCRIPTS_DIR/verify_backup.sh" << 'VERIFYEOF'
#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="%%LOGS_DIR%%"
RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_DB_PATH="%%RCLONE_DB_PATH%%"
RCLONE_FILES_PATH="%%RCLONE_FILES_PATH%%"
SECRETS_DIR="%%SECRETS_DIR%%"
HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
LOG_FILE="$LOGS_DIR/verify_logfile.log"

SECRET_PASSPHRASE=".c1"
SECRET_NTFY_TOKEN=".c4"
SECRET_NTFY_URL=".c5"

# Cleanup function
TEMP_DIR=""
cleanup() {
  local exit_code=$?
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit $exit_code
}
trap cleanup EXIT INT TERM

derive_key() {
  local secrets_dir="$1"
  local machine_id salt
  if [[ -f /etc/machine-id ]]; then
    machine_id="$(cat /etc/machine-id)"
  elif [[ -f /var/lib/dbus/machine-id ]]; then
    machine_id="$(cat /var/lib/dbus/machine-id)"
  else
    machine_id="$(hostname)$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo 'fallback')"
  fi
  salt="$(cat "$secrets_dir/.s")"
  echo -n "${machine_id}${salt}" | sha256sum | cut -d' ' -f1
}

get_secret() {
  local secrets_dir="$1" secret_name="$2" key
  [[ ! -f "$secrets_dir/$secret_name" ]] && return 1
  key="$(derive_key "$secrets_dir")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt -pass "pass:$key" -base64 -in "$secrets_dir/$secret_name" 2>/dev/null || echo ""
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

send_notification() {
  local title="$1" body="$2"
  local ntfy_url ntfy_token
  ntfy_url="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_URL")"
  ntfy_token="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN")"
  [[ -z "$ntfy_url" ]] && return 0
  if [[ -n "$ntfy_token" ]]; then
    curl -s -H "Authorization: Bearer $ntfy_token" -H "Title: $title" -d "$body" "$ntfy_url" -o /dev/null --max-time 10 || true
  else
    curl -s -H "Title: $title" -d "$body" "$ntfy_url" -o /dev/null --max-time 10 || true
  fi
}

# Log rotation
rotate_log() {
  local log_file="$1"
  local max_size=$((10 * 1024 * 1024))  # 10MB
  [[ ! -f "$log_file" ]] && return 0
  local log_size
  log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
  if [[ "$log_size" -gt "$max_size" ]]; then
    [[ -f "${log_file}.5" ]] && rm -f "${log_file}.5"
    for ((i=4; i>=1; i--)); do
      [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i+1))"
    done
    mv "$log_file" "${log_file}.1"
  fi
}

# Main
rotate_log "$LOG_FILE"
TEMP_DIR=$(mktemp -d)

log "==== INTEGRITY CHECK START ===="

PASSPHRASE="$(get_secret "$SECRETS_DIR" "$SECRET_PASSPHRASE")"
if [[ -z "$PASSPHRASE" ]]; then
  log "[ERROR] Could not retrieve encryption passphrase"
  send_notification "Integrity Check FAILED on $HOSTNAME" "Could not retrieve encryption passphrase"
  exit 1
fi

db_result="SKIPPED"
db_details=""
files_result="SKIPPED"
files_details=""

# Verify database backup
if [[ -n "$RCLONE_DB_PATH" ]]; then
  log "Checking database backup..."
  latest_db=$(rclone lsf "$RCLONE_REMOTE:$RCLONE_DB_PATH" --include "*-db_backups-*.tar.gz.gpg" 2>/dev/null | sort -r | head -1)

  if [[ -z "$latest_db" ]]; then
    log "[WARNING] No database backups found"
    db_result="WARNING"
    db_details="No backups found"
  else
    log "Latest: $latest_db"

    # Download
    if ! rclone copy "$RCLONE_REMOTE:$RCLONE_DB_PATH/$latest_db" "$TEMP_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
      log "[ERROR] Download failed"
      db_result="FAILED"
      db_details="Download failed"
    else
      # Checksum verification
      checksum_file="${latest_db}.sha256"
      checksum_ok=true
      if rclone copy "$RCLONE_REMOTE:$RCLONE_DB_PATH/$checksum_file" "$TEMP_DIR/" 2>/dev/null; then
        stored=$(cat "$TEMP_DIR/$checksum_file")
        calculated=$(sha256sum "$TEMP_DIR/$latest_db" | awk '{print $1}')
        if [[ "$stored" == "$calculated" ]]; then
          log "Checksum: OK"
        else
          log "[ERROR] Checksum mismatch!"
          log "  Expected: $stored"
          log "  Got:      $calculated"
          db_result="FAILED"
          db_details="Checksum mismatch"
          checksum_ok=false
        fi
      else
        log "[INFO] No checksum file (backup may predate checksum feature)"
      fi

      # Decrypt test
      if $checksum_ok; then
        if gpg --batch --quiet --pinentry-mode=loopback --passphrase "$PASSPHRASE" -d "$TEMP_DIR/$latest_db" 2>/dev/null | tar -tzf - >/dev/null 2>&1; then
          file_count=$(gpg --batch --quiet --pinentry-mode=loopback --passphrase "$PASSPHRASE" -d "$TEMP_DIR/$latest_db" 2>/dev/null | tar -tzf - 2>/dev/null | wc -l)
          log "Decryption: OK ($file_count files)"
          db_result="PASSED"
          db_details="$file_count files"
        else
          log "[ERROR] Decryption or archive verification failed"
          db_result="FAILED"
          db_details="Decryption failed"
        fi
      fi
    fi
    rm -f "$TEMP_DIR/$latest_db" "$TEMP_DIR/$checksum_file" 2>/dev/null
  fi
fi

# Verify files backup
if [[ -n "$RCLONE_FILES_PATH" ]]; then
  log "Checking files backup..."
  latest_files=$(rclone lsf "$RCLONE_REMOTE:$RCLONE_FILES_PATH" --include "*.tar.gz" --exclude "*.sha256" 2>/dev/null | sort -r | head -1)

  if [[ -z "$latest_files" ]]; then
    log "[WARNING] No files backups found"
    files_result="WARNING"
    files_details="No backups found"
  else
    log "Latest: $latest_files"

    # Download
    if ! rclone copy "$RCLONE_REMOTE:$RCLONE_FILES_PATH/$latest_files" "$TEMP_DIR/" 2>&1 | tee -a "$LOG_FILE"; then
      log "[ERROR] Download failed"
      files_result="FAILED"
      files_details="Download failed"
    else
      # Checksum verification
      checksum_file="${latest_files}.sha256"
      checksum_ok=true
      if rclone copy "$RCLONE_REMOTE:$RCLONE_FILES_PATH/$checksum_file" "$TEMP_DIR/" 2>/dev/null; then
        stored=$(cat "$TEMP_DIR/$checksum_file")
        calculated=$(sha256sum "$TEMP_DIR/$latest_files" | awk '{print $1}')
        if [[ "$stored" == "$calculated" ]]; then
          log "Checksum: OK"
        else
          log "[ERROR] Checksum mismatch!"
          files_result="FAILED"
          files_details="Checksum mismatch"
          checksum_ok=false
        fi
      else
        log "[INFO] No checksum file"
      fi

      # Archive test
      if $checksum_ok; then
        if tar -tzf "$TEMP_DIR/$latest_files" >/dev/null 2>&1; then
          file_count=$(tar -tzf "$TEMP_DIR/$latest_files" 2>/dev/null | wc -l)
          log "Archive: OK ($file_count files)"
          files_result="PASSED"
          files_details="$file_count files"
        else
          log "[ERROR] Archive verification failed"
          files_result="FAILED"
          files_details="Archive corrupted"
        fi
      fi
    fi
    rm -f "$TEMP_DIR/$latest_files" "$TEMP_DIR/$checksum_file" 2>/dev/null
  fi
fi

# Summary
log "==== SUMMARY ===="
log "Database: $db_result ${db_details:+- $db_details}"
log "Files: $files_result ${files_details:+- $files_details}"
log "==== INTEGRITY CHECK END ===="

# Send notification
if [[ "$db_result" == "FAILED" || "$files_result" == "FAILED" ]]; then
  send_notification "Integrity Check FAILED on $HOSTNAME" "DB: $db_result, Files: $files_result"
  exit 1
elif [[ "$db_result" == "WARNING" || "$files_result" == "WARNING" ]]; then
  send_notification "Integrity Check WARNING on $HOSTNAME" "DB: $db_result, Files: $files_result"
else
  send_notification "Integrity Check PASSED on $HOSTNAME" "DB: $db_result ($db_details), Files: $files_result ($files_details)"
fi

exit 0
VERIFYEOF

  # Replace placeholders
  sed -i \
    -e "s|%%LOGS_DIR%%|$INSTALL_DIR/logs|g" \
    -e "s|%%RCLONE_REMOTE%%|$rclone_remote|g" \
    -e "s|%%RCLONE_DB_PATH%%|$rclone_db_path|g" \
    -e "s|%%RCLONE_FILES_PATH%%|$rclone_files_path|g" \
    -e "s|%%SECRETS_DIR%%|$secrets_dir|g" \
    "$SCRIPTS_DIR/verify_backup.sh"

  chmod 700 "$SCRIPTS_DIR/verify_backup.sh"
}
