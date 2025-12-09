#!/usr/bin/env bash
# ============================================================================
# Backup Management Tool by Webnestify
# https://webnestify.cloud
# 
# Comprehensive backup and restore solution for WordPress/MySQL environments
# Supports: Database backups, Files backups, Remote storage via rclone
# Secure credential storage with machine-bound encryption
#
# DISCLAIMER:
# This script is provided "as is" without warranty of any kind. The author
# (Webnestify) is not responsible for any damages, data loss, or misuse
# arising from the use of this script. Always create a server snapshot
# before running backup/restore operations. Use at your own risk.
# ============================================================================
set -euo pipefail

VERSION="1.0.0"
AUTHOR="Webnestify"
WEBSITE="https://webnestify.cloud"
INSTALL_DIR="/etc/backup-management"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
CONFIG_FILE="$INSTALL_DIR/.config"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------- Helper Functions ----------

print_header() {
  clear
  echo -e "${BLUE}========================================================${NC}"
  echo -e "${BLUE}       Backup Management Tool v${VERSION}${NC}"
  echo -e "${CYAN}                  by ${AUTHOR}${NC}"
  echo -e "${BLUE}========================================================${NC}"
  echo
}

print_disclaimer() {
  echo -e "${YELLOW}┌────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│                      DISCLAIMER                        │${NC}"
  echo -e "${YELLOW}├────────────────────────────────────────────────────────┤${NC}"
  echo -e "${YELLOW}│ This tool is provided \"as is\" without warranty.        │${NC}"
  echo -e "${YELLOW}│ The author is NOT responsible for any damages or       │${NC}"
  echo -e "${YELLOW}│ data loss. Always create a server SNAPSHOT before      │${NC}"
  echo -e "${YELLOW}│ running backup/restore operations. Use at your risk.   │${NC}"
  echo -e "${YELLOW}└────────────────────────────────────────────────────────┘${NC}"
  echo
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}" >&2
}

print_warning() {
  echo -e "${YELLOW}! $1${NC}"
}

print_info() {
  echo -e "${BLUE}→ $1${NC}"
}

press_enter_to_continue() {
  echo
  read -p "Press Enter to continue..."
}

# ---------- Input Validation Functions ----------

# Validate path input - prevent shell injection
validate_path() {
  local path="$1"
  local name="${2:-path}"
  
  # Check for empty
  if [[ -z "$path" ]]; then
    print_error "$name cannot be empty"
    return 1
  fi
  
  # Check for dangerous characters (shell metacharacters)
  if [[ "$path" =~ [\'\"$\`\;\|\&\>\<\(\)\{\}\[\]\\] ]]; then
    print_error "$name contains invalid characters"
    return 1
  fi
  
  # Check for path traversal attempts
  if [[ "$path" =~ \.\. ]]; then
    print_error "$name cannot contain '..'"
    return 1
  fi
  
  return 0
}

# Validate URL input
validate_url() {
  local url="$1"
  local name="${2:-URL}"
  
  if [[ -z "$url" ]]; then
    print_error "$name cannot be empty"
    return 1
  fi
  
  # Basic URL format check
  if [[ ! "$url" =~ ^https?:// ]]; then
    print_error "$name must start with http:// or https://"
    return 1
  fi
  
  # Check for dangerous characters
  if [[ "$url" =~ [\'\"$\`\;\|\&\>\<\(\)\{\}\\] ]]; then
    print_error "$name contains invalid characters"
    return 1
  fi
  
  return 0
}

# Validate password strength
validate_password() {
  local password="$1"
  local min_length="${2:-8}"
  
  if [[ -z "$password" ]]; then
    print_error "Password cannot be empty"
    return 1
  fi
  
  if [[ ${#password} -lt $min_length ]]; then
    print_error "Password must be at least $min_length characters"
    return 1
  fi
  
  return 0
}

# Check available disk space (in MB)
check_disk_space() {
  local path="$1"
  local required_mb="${2:-1000}"  # Default 1GB
  
  local available_mb
  available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}')
  
  if [[ -z "$available_mb" ]]; then
    print_warning "Could not check disk space"
    return 0
  fi
  
  if [[ "$available_mb" -lt "$required_mb" ]]; then
    print_error "Insufficient disk space. Available: ${available_mb}MB, Required: ${required_mb}MB"
    return 1
  fi
  
  return 0
}

# Check network connectivity
check_network() {
  local host="${1:-1.1.1.1}"
  local timeout="${2:-5}"
  
  if ! ping -c 1 -W "$timeout" "$host" &>/dev/null; then
    if ! curl -s --connect-timeout "$timeout" "https://www.google.com" &>/dev/null; then
      print_error "No network connectivity"
      return 1
    fi
  fi
  
  return 0
}

# Create MySQL credentials file (more secure than command line)
create_mysql_auth_file() {
  local user="$1"
  local pass="$2"
  local auth_file
  
  auth_file="$(mktemp)"
  chmod 600 "$auth_file"
  
  cat > "$auth_file" << EOF
[client]
user=$user
password=$pass
EOF
  
  echo "$auth_file"
}

# Lock file location (fixed, not in temp)
LOCK_DIR="/var/lock"
DB_LOCK_FILE="$LOCK_DIR/backup-management-db.lock"
FILES_LOCK_FILE="$LOCK_DIR/backup-management-files.lock"

# Maximum log file size (10MB)
MAX_LOG_SIZE=$((10 * 1024 * 1024))

# Rotate log file if it exceeds max size
rotate_log() {
  local log_file="$1"
  local max_backups="${2:-5}"
  
  [[ ! -f "$log_file" ]] && return 0
  
  local log_size
  log_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
  
  if [[ "$log_size" -gt "$MAX_LOG_SIZE" ]]; then
    # Remove oldest backup
    [[ -f "${log_file}.${max_backups}" ]] && rm -f "${log_file}.${max_backups}"
    
    # Rotate existing backups
    for ((i=max_backups-1; i>=1; i--)); do
      [[ -f "${log_file}.${i}" ]] && mv "${log_file}.${i}" "${log_file}.$((i+1))"
    done
    
    # Rotate current log
    mv "$log_file" "${log_file}.1"
    touch "$log_file"
    chmod 600 "$log_file"
  fi
}

# Secure temp directory creation (防止symlink attacks)
create_secure_temp() {
  local prefix="${1:-backup-mgmt}"
  local temp_dir
  
  # Create temp dir with restricted permissions
  temp_dir="$(mktemp -d -t "${prefix}.XXXXXXXXXX")"
  
  # Verify it's actually a directory and owned by us
  if [[ ! -d "$temp_dir" ]] || [[ ! -O "$temp_dir" ]]; then
    echo "Failed to create secure temp directory" >&2
    return 1
  fi
  
  # Set restrictive permissions
  chmod 700 "$temp_dir"
  
  echo "$temp_dir"
}

# Verify file integrity (basic check)
verify_file_integrity() {
  local file="$1"
  local expected_type="${2:-}"
  
  [[ ! -f "$file" ]] && return 1
  [[ ! -s "$file" ]] && return 1  # Empty file
  
  case "$expected_type" in
    gzip)
      gzip -t "$file" 2>/dev/null || return 1
      ;;
    gpg)
      file "$file" 2>/dev/null | grep -qi "gpg\|pgp\|encrypted" || return 1
      ;;
  esac
  
  return 0
}

# Safe file write (atomic)
safe_write_file() {
  local target="$1"
  local content="$2"
  local temp_file
  
  temp_file="$(mktemp "${target}.XXXXXXXXXX")"
  
  if echo "$content" > "$temp_file" 2>/dev/null; then
    chmod 600 "$temp_file"
    mv "$temp_file" "$target"
    return 0
  else
    rm -f "$temp_file"
    return 1
  fi
}

# ---------- Secure Credential Storage Functions ----------

generate_random_id() {
  head -c 32 /dev/urandom | md5sum | head -c 12
}

get_secrets_dir() {
  local config_file="$INSTALL_DIR/.secrets_location"
  if [[ -f "$config_file" ]]; then
    cat "$config_file"
  else
    echo ""
  fi
}

init_secure_storage() {
  local existing_dir
  existing_dir="$(get_secrets_dir)"
  
  if [[ -n "$existing_dir" && -d "$existing_dir" ]]; then
    echo "$existing_dir"
    return 0
  fi
  
  local random_name=".$(generate_random_id)"
  local secrets_dir="/etc/$random_name"
  
  mkdir -p "$secrets_dir"
  chmod 700 "$secrets_dir"
  
  head -c 64 /dev/urandom | base64 > "$secrets_dir/.s"
  chmod 600 "$secrets_dir/.s"
  
  echo "$secrets_dir" > "$INSTALL_DIR/.secrets_location"
  chmod 600 "$INSTALL_DIR/.secrets_location"
  
  echo "$secrets_dir"
}

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

store_secret() {
  local secrets_dir="$1"
  local secret_name="$2"
  local secret_value="$3"
  local key
  
  key="$(derive_key "$secrets_dir")"
  
  chattr -i "$secrets_dir/$secret_name" 2>/dev/null || true
  
  echo -n "$secret_value" | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass "pass:$key" -base64 > "$secrets_dir/$secret_name"
  
  chmod 600 "$secrets_dir/$secret_name"
  chattr +i "$secrets_dir/$secret_name" 2>/dev/null || true
}

get_secret() {
  local secrets_dir="$1"
  local secret_name="$2"
  local key
  
  if [[ ! -f "$secrets_dir/$secret_name" ]]; then
    echo ""
    return 1
  fi
  
  key="$(derive_key "$secrets_dir")"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -salt -pass "pass:$key" -base64 -in "$secrets_dir/$secret_name" 2>/dev/null || echo ""
}

secret_exists() {
  local secrets_dir="$1"
  local secret_name="$2"
  [[ -f "$secrets_dir/$secret_name" ]]
}

lock_secrets() {
  local secrets_dir="$1"
  # Only lock our specific secret files, not all files in directory
  local secret_files=(".c1" ".c2" ".c3" ".c4" ".c5")
  for f in "${secret_files[@]}"; do
    [[ -f "$secrets_dir/$f" ]] && chattr +i "$secrets_dir/$f" 2>/dev/null || true
  done
  chattr +i "$secrets_dir" 2>/dev/null || true
}

unlock_secrets() {
  local secrets_dir="$1"
  chattr -i "$secrets_dir" 2>/dev/null || true
  # Only unlock our specific secret files, not all files in directory
  local secret_files=(".c1" ".c2" ".c3" ".c4" ".c5")
  for f in "${secret_files[@]}"; do
    [[ -f "$secrets_dir/$f" ]] && chattr -i "$secrets_dir/$f" 2>/dev/null || true
  done
}

# Secret file names (obscured)
SECRET_PASSPHRASE=".c1"
SECRET_DB_USER=".c2"
SECRET_DB_PASS=".c3"
SECRET_NTFY_TOKEN=".c4"
SECRET_NTFY_URL=".c5"

# ---------- Configuration Check ----------

is_configured() {
  [[ -f "$CONFIG_FILE" ]] && [[ -f "$INSTALL_DIR/.secrets_location" ]]
}

get_config_value() {
  local key="$1"
  if [[ -f "$CONFIG_FILE" ]]; then
    grep "^${key}=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"'
  fi
}

save_config() {
  local key="$1"
  local value="$2"
  
  # Validate key (alphanumeric and underscore only)
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    print_error "Invalid config key: $key"
    return 1
  fi
  
  # Escape double quotes and backslashes in value to prevent injection
  value="${value//\\/\\\\}"  # Escape backslashes first
  value="${value//\"/\\\"}"  # Escape double quotes
  value="${value//$'\n'/}"   # Remove newlines
  
  if [[ -f "$CONFIG_FILE" ]]; then
    # Remove existing key if present
    grep -v "^${key}=" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null || true
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  fi
  
  echo "${key}=\"${value}\"" >> "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

# ---------- Status Display ----------

show_status() {
  print_header
  echo "System Status"
  echo "============="
  echo
  
  local secrets_dir
  secrets_dir="$(get_secrets_dir)"
  
  # Check configuration
  if is_configured; then
    print_success "Configuration: COMPLETE"
  else
    print_error "Configuration: NOT CONFIGURED"
    echo
    echo "Run setup to configure the backup system."
    press_enter_to_continue
    return
  fi
  
  # Check secrets
  if [[ -n "$secrets_dir" ]] && [[ -d "$secrets_dir" ]]; then
    print_success "Secure storage: $secrets_dir"
  else
    print_error "Secure storage: NOT INITIALIZED"
  fi
  
  # Check scripts
  echo
  echo "Backup Scripts:"
  [[ -f "$SCRIPTS_DIR/db_backup.sh" ]] && print_success "Database backup script" || print_error "Database backup script"
  [[ -f "$SCRIPTS_DIR/files_backup.sh" ]] && print_success "Files backup script" || print_error "Files backup script"
  
  echo
  echo "Restore Scripts:"
  [[ -f "$SCRIPTS_DIR/db_restore.sh" ]] && print_success "Database restore script" || print_error "Database restore script"
  [[ -f "$SCRIPTS_DIR/files_restore.sh" ]] && print_success "Files restore script" || print_error "Files restore script"
  
  # Check scheduled backups (systemd timers or cron)
  echo
  echo "Scheduled Backups:"
  
  # Database backup schedule
  if systemctl is-enabled backup-management-db.timer &>/dev/null; then
    local db_schedule
    db_schedule=$(grep -E "^OnCalendar=" /etc/systemd/system/backup-management-db.timer 2>/dev/null | cut -d'=' -f2)
    print_success "Database backup (systemd): $db_schedule"
  elif crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/db_backup.sh"; then
    local db_schedule
    db_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/db_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Database backup (cron): $db_schedule"
  else
    print_warning "Database backup: NOT SCHEDULED"
  fi
  
  # Files backup schedule
  if systemctl is-enabled backup-management-files.timer &>/dev/null; then
    local files_schedule
    files_schedule=$(grep -E "^OnCalendar=" /etc/systemd/system/backup-management-files.timer 2>/dev/null | cut -d'=' -f2)
    print_success "Files backup (systemd): $files_schedule"
  elif crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/files_backup.sh"; then
    local files_schedule
    files_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/files_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Files backup (cron): $files_schedule"
  else
    print_warning "Files backup: NOT SCHEDULED"
  fi
  
  # Check rclone
  echo
  echo "Remote Storage:"
  local rclone_remote rclone_db_path rclone_files_path
  rclone_remote="$(get_config_value 'RCLONE_REMOTE')"
  rclone_db_path="$(get_config_value 'RCLONE_DB_PATH')"
  rclone_files_path="$(get_config_value 'RCLONE_FILES_PATH')"
  
  if [[ -n "$rclone_remote" ]]; then
    print_success "Remote: $rclone_remote"
    [[ -n "$rclone_db_path" ]] && echo "        Database path: $rclone_db_path"
    [[ -n "$rclone_files_path" ]] && echo "        Files path: $rclone_files_path"
  else
    print_error "Remote storage: NOT CONFIGURED"
  fi
  
  # Check recent backups
  echo
  echo "Recent Backup Activity:"
  if [[ -f "$INSTALL_DIR/logs/db_logfile.log" ]]; then
    local last_db_backup
    last_db_backup=$(grep "START per-db backup" "$INSTALL_DIR/logs/db_logfile.log" 2>/dev/null | tail -1 | awk '{print $2, $3}')
    [[ -n "$last_db_backup" ]] && echo "  Last DB backup: $last_db_backup"
  fi
  
  if [[ -f "$INSTALL_DIR/logs/files_logfile.log" ]]; then
    local last_files_backup
    last_files_backup=$(grep "START files backup" "$INSTALL_DIR/logs/files_logfile.log" 2>/dev/null | tail -1 | awk '{print $2, $3}')
    [[ -n "$last_files_backup" ]] && echo "  Last Files backup: $last_files_backup"
  fi
  
  echo
  echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
  echo -e "${CYAN}  $AUTHOR | $WEBSITE${NC}"
  echo -e "${CYAN}───────────────────────────────────────────────────────${NC}"
  
  press_enter_to_continue
}

# ---------- View Logs ----------

view_logs() {
  print_header
  echo "View Logs"
  echo "========="
  echo
  echo "1. Database backup log"
  echo "2. Files backup log"
  echo "3. Back to main menu"
  echo
  read -p "Select option [1-3]: " log_choice
  
  case "$log_choice" in
    1)
      if [[ -f "$INSTALL_DIR/logs/db_logfile.log" ]]; then
        less "$INSTALL_DIR/logs/db_logfile.log"
      else
        print_error "No database backup log found."
        press_enter_to_continue
      fi
      ;;
    2)
      if [[ -f "$INSTALL_DIR/logs/files_logfile.log" ]]; then
        less "$INSTALL_DIR/logs/files_logfile.log"
      else
        print_error "No files backup log found."
        press_enter_to_continue
      fi
      ;;
    3|*)
      return
      ;;
  esac
}

# ---------- Run Backup ----------

run_backup() {
  print_header
  echo "Run Backup"
  echo "=========="
  echo
  
  if ! is_configured; then
    print_error "System not configured. Please run setup first."
    press_enter_to_continue
    return
  fi
  
  echo "1. Run database backup"
  echo "2. Run files backup"
  echo "3. Run both (database + files)"
  echo "4. Back to main menu"
  echo
  read -p "Select option [1-4]: " backup_choice
  
  case "$backup_choice" in
    1)
      if [[ -f "$SCRIPTS_DIR/db_backup.sh" ]]; then
        echo
        print_info "Starting database backup..."
        echo
        bash "$SCRIPTS_DIR/db_backup.sh"
        press_enter_to_continue
      else
        print_error "Database backup script not found."
        press_enter_to_continue
      fi
      ;;
    2)
      if [[ -f "$SCRIPTS_DIR/files_backup.sh" ]]; then
        echo
        print_info "Starting files backup..."
        echo
        bash "$SCRIPTS_DIR/files_backup.sh"
        press_enter_to_continue
      else
        print_error "Files backup script not found."
        press_enter_to_continue
      fi
      ;;
    3)
      echo
      if [[ -f "$SCRIPTS_DIR/db_backup.sh" ]]; then
        print_info "Starting database backup..."
        echo
        bash "$SCRIPTS_DIR/db_backup.sh"
        echo
      else
        print_error "Database backup script not found."
      fi
      
      if [[ -f "$SCRIPTS_DIR/files_backup.sh" ]]; then
        print_info "Starting files backup..."
        echo
        bash "$SCRIPTS_DIR/files_backup.sh"
      else
        print_error "Files backup script not found."
      fi
      press_enter_to_continue
      ;;
    4|*)
      return
      ;;
  esac
}

# ---------- Run Restore ----------

run_restore() {
  print_header
  echo "Restore from Backup"
  echo "==================="
  echo
  
  if ! is_configured; then
    print_error "System not configured. Please run setup first."
    press_enter_to_continue
    return
  fi
  
  echo "1. Restore database(s)"
  echo "2. Restore files/sites"
  echo "3. Back to main menu"
  echo
  read -p "Select option [1-3]: " restore_choice
  
  case "$restore_choice" in
    1)
      if [[ -f "$SCRIPTS_DIR/db_restore.sh" ]]; then
        echo
        bash "$SCRIPTS_DIR/db_restore.sh"
        press_enter_to_continue
      else
        print_error "Database restore script not found."
        press_enter_to_continue
      fi
      ;;
    2)
      if [[ -f "$SCRIPTS_DIR/files_restore.sh" ]]; then
        echo
        bash "$SCRIPTS_DIR/files_restore.sh"
        press_enter_to_continue
      else
        print_error "Files restore script not found."
        press_enter_to_continue
      fi
      ;;
    3|*)
      return
      ;;
  esac
}

# ---------- Manage Schedules ----------

manage_schedules() {
  print_header
  echo "Manage Backup Schedules"
  echo "======================="
  echo
  
  if ! is_configured; then
    print_error "System not configured. Please run setup first."
    press_enter_to_continue
    return
  fi
  
  # Show current schedules
  echo "Current Schedules:"
  echo
  
  # Check systemd timers first, fall back to cron
  if systemctl is-enabled backup-management-db.timer &>/dev/null; then
    local db_schedule
    db_schedule=$(systemctl show backup-management-db.timer --property=TimersCalendar 2>/dev/null | cut -d'=' -f2)
    if [[ -z "$db_schedule" ]]; then
      db_schedule=$(grep -E "^OnCalendar=" /etc/systemd/system/backup-management-db.timer 2>/dev/null | cut -d'=' -f2)
    fi
    print_success "Database (systemd): $db_schedule"
  elif crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/db_backup.sh"; then
    local db_schedule
    db_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/db_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Database (cron): $db_schedule"
  else
    print_warning "Database: NOT SCHEDULED"
  fi
  
  if systemctl is-enabled backup-management-files.timer &>/dev/null; then
    local files_schedule
    files_schedule=$(systemctl show backup-management-files.timer --property=TimersCalendar 2>/dev/null | cut -d'=' -f2)
    if [[ -z "$files_schedule" ]]; then
      files_schedule=$(grep -E "^OnCalendar=" /etc/systemd/system/backup-management-files.timer 2>/dev/null | cut -d'=' -f2)
    fi
    print_success "Files (systemd): $files_schedule"
  elif crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/files_backup.sh"; then
    local files_schedule
    files_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/files_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Files (cron): $files_schedule"
  else
    print_warning "Files: NOT SCHEDULED"
  fi
  
  echo
  echo "Options:"
  echo "1. Set/change database backup schedule"
  echo "2. Set/change files backup schedule"
  echo "3. Disable database backup schedule"
  echo "4. Disable files backup schedule"
  echo "5. View timer status"
  echo "6. Back to main menu"
  echo
  read -p "Select option [1-6]: " schedule_choice
  
  case "$schedule_choice" in
    1)
      set_systemd_schedule "db" "Database"
      ;;
    2)
      set_systemd_schedule "files" "Files"
      ;;
    3)
      disable_schedule "db" "Database"
      ;;
    4)
      disable_schedule "files" "Files"
      ;;
    5)
      view_timer_status
      ;;
    6|*)
      return
      ;;
  esac
}

set_systemd_schedule() {
  local timer_type="$1"
  local display_name="$2"
  local timer_name="backup-management-${timer_type}.timer"
  local service_name="backup-management-${timer_type}.service"
  
  echo
  echo "Select schedule for $display_name backup:"
  echo "1. Hourly"
  echo "2. Every 2 hours"
  echo "3. Every 6 hours"
  echo "4. Daily at midnight"
  echo "5. Daily at 3 AM (recommended for files)"
  echo "6. Weekly (Sunday at midnight)"
  echo "7. Custom schedule"
  echo
  read -p "Select option [1-7]: " freq_choice
  
  local on_calendar
  case "$freq_choice" in
    1) on_calendar="hourly" ;;
    2) on_calendar="*-*-* 0/2:00:00" ;;
    3) on_calendar="*-*-* 0/6:00:00" ;;
    4) on_calendar="*-*-* 00:00:00" ;;
    5) on_calendar="*-*-* 03:00:00" ;;
    6) on_calendar="Sun *-*-* 00:00:00" ;;
    7)
      echo
      echo "Enter systemd OnCalendar expression."
      echo "Examples:"
      echo "  hourly              - Every hour"
      echo "  daily               - Every day at midnight"
      echo "  *-*-* 03:00:00      - Every day at 3 AM"
      echo "  Mon,Fri *-*-* 02:00 - Monday and Friday at 2 AM"
      echo "  *-*-* *:0/30:00     - Every 30 minutes"
      echo
      read -p "OnCalendar: " on_calendar
      ;;
    *)
      print_error "Invalid selection."
      press_enter_to_continue
      return
      ;;
  esac
  
  # Update the timer file
  cat > "/etc/systemd/system/$timer_name" << EOF
[Unit]
Description=Backup Management - $display_name Backup Timer
Requires=$service_name

[Timer]
OnCalendar=$on_calendar
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Ensure service file exists
  if [[ ! -f "/etc/systemd/system/$service_name" ]]; then
    local script_path="$SCRIPTS_DIR/${timer_type}_backup.sh"
    cat > "/etc/systemd/system/$service_name" << EOF
[Unit]
Description=Backup Management - $display_name Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$script_path
StandardOutput=append:$INSTALL_DIR/logs/${timer_type}_logfile.log
StandardError=append:$INSTALL_DIR/logs/${timer_type}_logfile.log
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF
  fi
  
  # Reload and enable
  systemctl daemon-reload
  systemctl enable "$timer_name" 2>/dev/null || true
  systemctl start "$timer_name" 2>/dev/null || true
  
  # Remove any cron entries for this backup
  if [[ "$timer_type" == "db" ]]; then
    ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/db_backup.sh" ) | crontab - 2>/dev/null || true
  else
    ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/files_backup.sh" ) | crontab - 2>/dev/null || true
  fi
  
  echo
  print_success "$display_name backup schedule set: $on_calendar"
  print_info "Timer enabled and started"
  press_enter_to_continue
}

disable_schedule() {
  local timer_type="$1"
  local display_name="$2"
  local timer_name="backup-management-${timer_type}.timer"
  
  # Disable systemd timer
  systemctl stop "$timer_name" 2>/dev/null || true
  systemctl disable "$timer_name" 2>/dev/null || true
  
  # Also remove cron entries
  if [[ "$timer_type" == "db" ]]; then
    ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/db_backup.sh" ) | crontab - 2>/dev/null || true
  else
    ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/files_backup.sh" ) | crontab - 2>/dev/null || true
  fi
  
  print_success "$display_name backup schedule disabled."
  press_enter_to_continue
}

view_timer_status() {
  print_header
  echo "Systemd Timer Status"
  echo "===================="
  echo
  
  echo -e "${CYAN}Database Backup Timer:${NC}"
  systemctl status backup-management-db.timer --no-pager 2>/dev/null || echo "  Not installed or not running"
  echo
  
  echo -e "${CYAN}Files Backup Timer:${NC}"
  systemctl status backup-management-files.timer --no-pager 2>/dev/null || echo "  Not installed or not running"
  echo
  
  echo -e "${CYAN}Next scheduled runs:${NC}"
  systemctl list-timers backup-management-* --no-pager 2>/dev/null || echo "  No timers scheduled"
  
  press_enter_to_continue
}

# ---------- Setup Wizard ----------

run_setup() {
  print_header
  echo "Setup Wizard"
  echo "============"
  echo
  
  # Check if already configured
  if is_configured; then
    echo "Existing configuration detected."
    echo
    echo "1. Reconfigure everything (overwrites existing)"
    echo "2. Cancel and return to menu"
    echo
    read -p "Select option [1-2]: " reconfig_choice
    
    if [[ "$reconfig_choice" != "1" ]]; then
      return
    fi
    
    # Unlock secrets for modification
    local secrets_dir
    secrets_dir="$(get_secrets_dir)"
    if [[ -n "$secrets_dir" ]]; then
      unlock_secrets "$secrets_dir"
    fi
  fi
  
  # Create directories
  mkdir -p "$INSTALL_DIR" "$SCRIPTS_DIR" "$INSTALL_DIR/logs"
  chmod 700 "$INSTALL_DIR" "$SCRIPTS_DIR"
  
  # Initialize secure storage
  local SECRETS_DIR
  SECRETS_DIR="$(init_secure_storage)"
  print_success "Secure storage initialized: $SECRETS_DIR"
  echo
  
  # ---------- Step 1: Backup Type Selection ----------
  echo "Step 1: Backup Type Selection"
  echo "-----------------------------"
  echo "What would you like to back up?"
  echo "1. Database only"
  echo "2. Files only (WordPress sites)"
  echo "3. Both Database and Files"
  read -p "Select option [1-3]: " BACKUP_TYPE
  BACKUP_TYPE=${BACKUP_TYPE:-3}
  
  local DO_DATABASE=false
  local DO_FILES=false
  
  case "$BACKUP_TYPE" in
    1) DO_DATABASE=true ;;
    2) DO_FILES=true ;;
    3) DO_DATABASE=true; DO_FILES=true ;;
    *) DO_DATABASE=true; DO_FILES=true ;;
  esac
  
  save_config "DO_DATABASE" "$DO_DATABASE"
  save_config "DO_FILES" "$DO_FILES"
  
  echo
  [[ "$DO_DATABASE" == "true" ]] && print_success "Database backup: ENABLED"
  [[ "$DO_FILES" == "true" ]] && print_success "Files backup: ENABLED"
  echo
  
  # ---------- Step 2: Encryption Password ----------
  echo "Step 2: Encryption Password"
  echo "---------------------------"
  echo "Your backups will be encrypted with AES-256."
  echo "Password must be at least 8 characters."
  echo
  read -sp "Enter encryption password: " ENCRYPTION_PASSWORD
  echo
  read -sp "Confirm encryption password: " ENCRYPTION_PASSWORD_CONFIRM
  echo
  
  if [[ "$ENCRYPTION_PASSWORD" != "$ENCRYPTION_PASSWORD_CONFIRM" ]]; then
    print_error "Passwords don't match. Please restart setup."
    press_enter_to_continue
    return
  fi
  
  if ! validate_password "$ENCRYPTION_PASSWORD" 8; then
    press_enter_to_continue
    return
  fi
  
  store_secret "$SECRETS_DIR" "$SECRET_PASSPHRASE" "$ENCRYPTION_PASSWORD"
  print_success "Encryption password stored securely."
  echo
  
  # ---------- Step 3: Database Authentication (if enabled) ----------
  local HAVE_DB_CREDS=false
  
  if [[ "$DO_DATABASE" == "true" ]]; then
    echo "Step 3: Database Authentication"
    echo "--------------------------------"
    echo "On many systems, root can access MySQL/MariaDB via socket authentication."
    echo
    read -p "Do you need to use a password for database access? (y/N): " USE_DB_PASSWORD
    USE_DB_PASSWORD=${USE_DB_PASSWORD:-N}
    
    # Detect DB client
    local DB_CLIENT=""
    if command -v mariadb >/dev/null 2>&1; then
      DB_CLIENT="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
      DB_CLIENT="mysql"
    else
      print_error "Neither MariaDB nor MySQL client found."
      press_enter_to_continue
      return
    fi
    
    if [[ "$USE_DB_PASSWORD" =~ ^[Yy]$ ]]; then
      read -sp "Enter database root password: " DB_ROOT_PASSWORD
      echo
      
      if "$DB_CLIENT" -u root -p"$DB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
        print_success "Database connection successful."
        store_secret "$SECRETS_DIR" "$SECRET_DB_USER" "root"
        store_secret "$SECRETS_DIR" "$SECRET_DB_PASS" "$DB_ROOT_PASSWORD"
        HAVE_DB_CREDS=true
        print_success "Database credentials stored securely."
      else
        print_error "Could not connect to database. Please check password."
        press_enter_to_continue
        return
      fi
    else
      if "$DB_CLIENT" -e "SELECT 1" >/dev/null 2>&1; then
        print_success "Socket authentication successful."
      else
        print_error "Socket authentication failed. Please restart setup with password."
        press_enter_to_continue
        return
      fi
    fi
    echo
  fi
  
  # ---------- Step 4: rclone Remote Storage ----------
  echo "Step 4: Remote Storage (rclone)"
  echo "--------------------------------"
  
  if ! command -v rclone &>/dev/null; then
    print_warning "rclone is not installed."
    read -p "Install rclone now? (Y/n): " INSTALL_RCLONE
    INSTALL_RCLONE=${INSTALL_RCLONE:-Y}
    
    if [[ "$INSTALL_RCLONE" =~ ^[Yy]$ ]]; then
      print_info "Installing rclone..."
      curl -fsSL https://rclone.org/install.sh | sudo bash
      
      if ! command -v rclone &>/dev/null; then
        print_error "Failed to install rclone."
        press_enter_to_continue
        return
      fi
      print_success "rclone installed."
    else
      print_error "rclone is required. Please install it and restart setup."
      press_enter_to_continue
      return
    fi
  fi
  
  # Check for remotes
  local REMOTES
  REMOTES="$(rclone listremotes || true)"
  
  if [[ -z "$REMOTES" ]]; then
    print_warning "No rclone remotes configured."
    read -p "Configure rclone now? (Y/n): " CONFIG_RCLONE
    CONFIG_RCLONE=${CONFIG_RCLONE:-Y}
    
    if [[ "$CONFIG_RCLONE" =~ ^[Yy]$ ]]; then
      rclone config
      REMOTES="$(rclone listremotes || true)"
    fi
    
    if [[ -z "$REMOTES" ]]; then
      print_error "No remotes configured. Please configure rclone and restart setup."
      press_enter_to_continue
      return
    fi
  fi
  
  echo "Available rclone remotes:"
  echo "$REMOTES"
  echo
  read -p "Enter remote name (without colon): " RCLONE_REMOTE
  
  if ! rclone listremotes | grep -q "^$RCLONE_REMOTE:$"; then
    print_error "Remote '$RCLONE_REMOTE' not found."
    press_enter_to_continue
    return
  fi
  
  save_config "RCLONE_REMOTE" "$RCLONE_REMOTE"
  
  # Database path
  if [[ "$DO_DATABASE" == "true" ]]; then
    read -p "Enter path for database backups (e.g., backups/db): " RCLONE_DB_PATH
    if ! validate_path "$RCLONE_DB_PATH" "Database backup path"; then
      press_enter_to_continue
      return
    fi
    save_config "RCLONE_DB_PATH" "$RCLONE_DB_PATH"
    print_success "Database backups: $RCLONE_REMOTE:$RCLONE_DB_PATH"
  fi
  
  # Files path
  if [[ "$DO_FILES" == "true" ]]; then
    read -p "Enter path for files backups (e.g., backups/files): " RCLONE_FILES_PATH
    if ! validate_path "$RCLONE_FILES_PATH" "Files backup path"; then
      press_enter_to_continue
      return
    fi
    save_config "RCLONE_FILES_PATH" "$RCLONE_FILES_PATH"
    print_success "Files backups: $RCLONE_REMOTE:$RCLONE_FILES_PATH"
  fi
  echo
  
  # ---------- Step 5: Notifications (ntfy) ----------
  echo "Step 5: Notifications (optional)"
  echo "---------------------------------"
  read -p "Set up ntfy notifications? (y/N): " SETUP_NTFY
  SETUP_NTFY=${SETUP_NTFY:-N}
  
  if [[ "$SETUP_NTFY" =~ ^[Yy]$ ]]; then
    read -p "Enter ntfy topic URL (e.g., https://ntfy.sh/mytopic): " NTFY_URL
    if ! validate_url "$NTFY_URL" "ntfy URL"; then
      print_warning "Skipping notifications due to invalid URL"
    else
      store_secret "$SECRETS_DIR" "$SECRET_NTFY_URL" "$NTFY_URL"
      
      read -p "Do you have an ntfy auth token? (y/N): " HAS_NTFY_TOKEN
      if [[ "$HAS_NTFY_TOKEN" =~ ^[Yy]$ ]]; then
        read -sp "Enter ntfy token: " NTFY_TOKEN
        echo
        store_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN" "$NTFY_TOKEN"
      fi
      
      print_success "Notifications configured."
    fi
  fi
  echo
  
  # ---------- Step 6: Generate Scripts ----------
  echo "Step 6: Generating Backup Scripts"
  echo "----------------------------------"
  
  generate_all_scripts "$SECRETS_DIR" "$DO_DATABASE" "$DO_FILES" "$RCLONE_REMOTE" \
    "${RCLONE_DB_PATH:-}" "${RCLONE_FILES_PATH:-}"
  
  echo
  
  # ---------- Step 7: Schedule Backups ----------
  echo "Step 7: Schedule Backups (systemd timers)"
  echo "------------------------------------------"
  
  if [[ "$DO_DATABASE" == "true" ]]; then
    read -p "Schedule automatic database backups? (Y/n): " SCHEDULE_DB
    SCHEDULE_DB=${SCHEDULE_DB:-Y}
    
    if [[ "$SCHEDULE_DB" =~ ^[Yy]$ ]]; then
      set_systemd_schedule "db" "Database"
    fi
  fi
  
  if [[ "$DO_FILES" == "true" ]]; then
    read -p "Schedule automatic files backups? (Y/n): " SCHEDULE_FILES
    SCHEDULE_FILES=${SCHEDULE_FILES:-Y}
    
    if [[ "$SCHEDULE_FILES" =~ ^[Yy]$ ]]; then
      set_systemd_schedule "files" "Files"
    fi
  fi
  
  # Lock secrets
  lock_secrets "$SECRETS_DIR"
  
  # ---------- Complete ----------
  echo
  echo "========================================================"
  echo "                 Setup Complete!"
  echo "========================================================"
  echo
  print_success "Backup management system is ready."
  echo
  echo "You can now use 'backup-management' command from anywhere."
  echo
  echo "Systemd timers are managing your backup schedules."
  echo "View status anytime with: systemctl list-timers backup-management-*"
  echo
  
  press_enter_to_continue
}

# ---------- Generate All Scripts ----------

generate_all_scripts() {
  local SECRETS_DIR="$1"
  local DO_DATABASE="$2"
  local DO_FILES="$3"
  local RCLONE_REMOTE="$4"
  local RCLONE_DB_PATH="$5"
  local RCLONE_FILES_PATH="$6"
  
  local LOGS_DIR="$INSTALL_DIR/logs"
  mkdir -p "$LOGS_DIR"
  
  # Generate database backup script
  if [[ "$DO_DATABASE" == "true" ]]; then
    generate_db_backup_script "$SECRETS_DIR" "$RCLONE_REMOTE" "$RCLONE_DB_PATH" "$LOGS_DIR"
    generate_db_restore_script "$SECRETS_DIR" "$RCLONE_REMOTE" "$RCLONE_DB_PATH"
    print_success "Database backup script generated"
    print_success "Database restore script generated"
  fi
  
  # Generate files backup script
  if [[ "$DO_FILES" == "true" ]]; then
    generate_files_backup_script "$SECRETS_DIR" "$RCLONE_REMOTE" "$RCLONE_FILES_PATH" "$LOGS_DIR"
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
  echo "  → Dumping: $db"
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

# Upload with timeout and retry
echo "Uploading to remote storage..."
RCLONE_TIMEOUT=1800  # 30 minutes
if ! timeout $RCLONE_TIMEOUT rclone copy "$ARCHIVE" "$RCLONE_REMOTE:$RCLONE_PATH" --retries 3 --low-level-retries 10; then
  echo "[ERROR] Upload failed"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "Upload failed"
  exit 8
fi

# Verify upload
if ! timeout 60 rclone check "$(dirname "$ARCHIVE")" "$RCLONE_REMOTE:$RCLONE_PATH" --one-way --size-only --include "$(basename "$ARCHIVE")" 2>/dev/null; then
  echo "[WARNING] Upload verification could not complete, but upload may have succeeded"
fi

echo "Uploaded to $RCLONE_REMOTE:$RCLONE_PATH"

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
    echo "  ✓ Success"
  else
    echo "  ✗ Failed"
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
  if timeout 3600 rclone copy "$archive_path" "$RCLONE_REMOTE:$RCLONE_PATH" --retries 3 --low-level-retries 10; then
    rm -f "$archive_path"
    ((success_count++)) || true
    echo "$LOG_PREFIX [$site_name] Done"
  else
    echo "$LOG_PREFIX [$site_name] Upload failed"
    failures+=("$site_name")
  fi
done

if [[ $site_count -eq 0 ]]; then
  echo "$LOG_PREFIX [WARNING] No sites found in $WWW_DIR"
  [[ -n "$NTFY_URL" ]] && send_notification "Files Backup Warning on $HOSTNAME" "No sites found"
  echo "==== $(date +%F' '%T) END (no sites) ===="
  exit 0
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
remote_files="$(rclone lsf "$RCLONE_REMOTE:$RCLONE_PATH" --include "*.tar.gz" 2>/dev/null | sort -r)" || true
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
    echo "  ✓ Success"
    # Only remove backup if we created one and restore succeeded
    [[ -n "$backup_name" && -d "$WWW_DIR/$backup_name" ]] && rm -rf "$WWW_DIR/$backup_name"
  else
    echo "  ✗ Failed"
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

# ---------- Install Command ----------

install_command() {
  local target="/usr/local/bin/backup-management"
  local script_path
  script_path="$(readlink -f "$0")"
  
  if [[ -L "$target" ]] || [[ -f "$target" ]]; then
    rm -f "$target"
  fi
  
  ln -s "$script_path" "$target"
  chmod +x "$target"
  
  print_success "Command 'backup-management' installed."
  echo "You can now run 'backup-management' from anywhere."
}

# ---------- Uninstall ----------

uninstall_tool() {
  print_header
  echo "Uninstall Backup Management"
  echo "==========================="
  echo
  print_warning "This will remove:"
  echo "  • All backup scripts"
  echo "  • Configuration files"
  echo "  • Secure credential storage"
  echo "  • Cron jobs"
  echo "  • The 'backup-management' command"
  echo
  print_warning "Your actual backups in remote storage will NOT be deleted."
  echo
  read -p "Are you sure? Type 'UNINSTALL' to confirm: " confirm
  
  if [[ "$confirm" != "UNINSTALL" ]]; then
    echo "Cancelled."
    press_enter_to_continue
    return
  fi
  
  # Remove cron jobs
  ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/db_backup.sh" | grep -Fv "$SCRIPTS_DIR/files_backup.sh" ) | crontab - 2>/dev/null || true
  
  # Remove secrets
  local secrets_dir
  secrets_dir="$(get_secrets_dir)"
  if [[ -n "$secrets_dir" && -d "$secrets_dir" ]]; then
    unlock_secrets "$secrets_dir"
    rm -rf "$secrets_dir"
  fi
  
  # Remove install directory
  rm -rf "$INSTALL_DIR"
  
  # Remove command
  rm -f "/usr/local/bin/backup-management"
  
  print_success "Uninstall complete."
  echo
  exit 0
}

# ---------- Main Menu ----------

main_menu() {
  while true; do
    print_header
    
    if is_configured; then
      echo "Main Menu"
      echo "========="
      echo
      echo "  1. Run backup now"
      echo "  2. Restore from backup"
      echo "  3. View status"
      echo "  4. View logs"
      echo "  5. Manage schedules"
      echo "  6. Reconfigure"
      echo "  7. Uninstall"
      echo "  8. Exit"
      echo
      read -p "Select option [1-8]: " choice
      
      case "$choice" in
        1) run_backup ;;
        2) run_restore ;;
        3) show_status ;;
        4) view_logs ;;
        5) manage_schedules ;;
        6) run_setup ;;
        7) uninstall_tool ;;
        8) exit 0 ;;
        *) print_error "Invalid option" ; sleep 1 ;;
      esac
    else
      print_disclaimer
      echo "Welcome! This tool needs to be configured first."
      echo
      echo "  1. Run setup wizard"
      echo "  2. Exit"
      echo
      read -p "Select option [1-2]: " choice
      
      case "$choice" in
        1) run_setup ;;
        2) exit 0 ;;
        *) print_error "Invalid option" ; sleep 1 ;;
      esac
    fi
  done
}

# ---------- Entry Point ----------

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "This tool must be run as root."
  exit 1
fi

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Install command if not already installed
if [[ ! -L "/usr/local/bin/backup-management" ]]; then
  install_command
fi

# Run main menu
main_menu