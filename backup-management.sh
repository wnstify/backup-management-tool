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
  echo -e "${RED}✗ $1${NC}"
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
  chattr +i "$secrets_dir"/.* 2>/dev/null || true
  chattr +i "$secrets_dir" 2>/dev/null || true
}

unlock_secrets() {
  local secrets_dir="$1"
  chattr -i "$secrets_dir" 2>/dev/null || true
  chattr -i "$secrets_dir"/.* 2>/dev/null || true
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
  
  # Check cron jobs
  echo
  echo "Scheduled Backups:"
  if crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/db_backup.sh"; then
    local db_schedule
    db_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/db_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Database backup cron: $db_schedule"
  else
    print_warning "Database backup cron: NOT SCHEDULED"
  fi
  
  if crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/files_backup.sh"; then
    local files_schedule
    files_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/files_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Files backup cron: $files_schedule"
  else
    print_warning "Files backup cron: NOT SCHEDULED"
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
  
  if crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/db_backup.sh"; then
    local db_schedule
    db_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/db_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Database: $db_schedule"
  else
    print_warning "Database: NOT SCHEDULED"
  fi
  
  if crontab -l 2>/dev/null | grep -q "$SCRIPTS_DIR/files_backup.sh"; then
    local files_schedule
    files_schedule=$(crontab -l 2>/dev/null | grep "$SCRIPTS_DIR/files_backup.sh" | awk '{print $1,$2,$3,$4,$5}')
    print_success "Files: $files_schedule"
  else
    print_warning "Files: NOT SCHEDULED"
  fi
  
  echo
  echo "Options:"
  echo "1. Set/change database backup schedule"
  echo "2. Set/change files backup schedule"
  echo "3. Remove database backup schedule"
  echo "4. Remove files backup schedule"
  echo "5. Back to main menu"
  echo
  read -p "Select option [1-5]: " schedule_choice
  
  case "$schedule_choice" in
    1)
      set_cron_schedule "database" "$SCRIPTS_DIR/db_backup.sh"
      ;;
    2)
      set_cron_schedule "files" "$SCRIPTS_DIR/files_backup.sh"
      ;;
    3)
      ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/db_backup.sh" ) | crontab -
      print_success "Database backup schedule removed."
      press_enter_to_continue
      ;;
    4)
      ( crontab -l 2>/dev/null | grep -Fv "$SCRIPTS_DIR/files_backup.sh" ) | crontab -
      print_success "Files backup schedule removed."
      press_enter_to_continue
      ;;
    5|*)
      return
      ;;
  esac
}

set_cron_schedule() {
  local backup_type="$1"
  local script_path="$2"
  
  echo
  echo "Select schedule for $backup_type backup:"
  echo "1. Hourly"
  echo "2. Every 2 hours"
  echo "3. Every 6 hours"
  echo "4. Daily (at midnight)"
  echo "5. Weekly (Sunday at midnight)"
  echo "6. Custom cron expression"
  echo
  read -p "Select option [1-6]: " freq_choice
  
  local cron_schedule
  case "$freq_choice" in
    1) cron_schedule="0 * * * *" ;;
    2) cron_schedule="0 */2 * * *" ;;
    3) cron_schedule="0 */6 * * *" ;;
    4) cron_schedule="0 0 * * *" ;;
    5) cron_schedule="0 0 * * 0" ;;
    6)
      read -p "Enter cron expression (e.g., '0 3 * * *' for 3 AM daily): " cron_schedule
      ;;
    *)
      print_error "Invalid selection."
      press_enter_to_continue
      return
      ;;
  esac
  
  # Remove existing and add new
  local cron_line="$cron_schedule /bin/bash \"$script_path\""
  ( crontab -l 2>/dev/null | grep -Fv "$script_path"; echo "$cron_line" ) | crontab -
  
  print_success "Schedule set: $cron_schedule"
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
  read -sp "Enter encryption password: " ENCRYPTION_PASSWORD
  echo
  read -sp "Confirm encryption password: " ENCRYPTION_PASSWORD_CONFIRM
  echo
  
  if [[ "$ENCRYPTION_PASSWORD" != "$ENCRYPTION_PASSWORD_CONFIRM" ]]; then
    print_error "Passwords don't match. Please restart setup."
    press_enter_to_continue
    return
  fi
  
  if [[ -z "$ENCRYPTION_PASSWORD" ]]; then
    print_error "Password cannot be empty. Please restart setup."
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
    save_config "RCLONE_DB_PATH" "$RCLONE_DB_PATH"
    print_success "Database backups: $RCLONE_REMOTE:$RCLONE_DB_PATH"
  fi
  
  # Files path
  if [[ "$DO_FILES" == "true" ]]; then
    read -p "Enter path for files backups (e.g., backups/files): " RCLONE_FILES_PATH
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
    store_secret "$SECRETS_DIR" "$SECRET_NTFY_URL" "$NTFY_URL"
    
    read -p "Do you have an ntfy auth token? (y/N): " HAS_NTFY_TOKEN
    if [[ "$HAS_NTFY_TOKEN" =~ ^[Yy]$ ]]; then
      read -sp "Enter ntfy token: " NTFY_TOKEN
      echo
      store_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN" "$NTFY_TOKEN"
    fi
    
    print_success "Notifications configured."
  fi
  echo
  
  # ---------- Step 6: Generate Scripts ----------
  echo "Step 6: Generating Backup Scripts"
  echo "----------------------------------"
  
  generate_all_scripts "$SECRETS_DIR" "$DO_DATABASE" "$DO_FILES" "$RCLONE_REMOTE" \
    "${RCLONE_DB_PATH:-}" "${RCLONE_FILES_PATH:-}"
  
  echo
  
  # ---------- Step 7: Schedule Backups ----------
  echo "Step 7: Schedule Backups"
  echo "------------------------"
  
  if [[ "$DO_DATABASE" == "true" ]]; then
    read -p "Schedule automatic database backups? (Y/n): " SCHEDULE_DB
    SCHEDULE_DB=${SCHEDULE_DB:-Y}
    
    if [[ "$SCHEDULE_DB" =~ ^[Yy]$ ]]; then
      set_cron_schedule "database" "$SCRIPTS_DIR/db_backup.sh"
    fi
  fi
  
  if [[ "$DO_FILES" == "true" ]]; then
    read -p "Schedule automatic files backups? (Y/n): " SCHEDULE_FILES
    SCHEDULE_FILES=${SCHEDULE_FILES:-Y}
    
    if [[ "$SCHEDULE_FILES" =~ ^[Yy]$ ]]; then
      set_cron_schedule "files" "$SCRIPTS_DIR/files_backup.sh"
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

SECRET_PASSPHRASE=".c1"
SECRET_DB_USER=".c2"
SECRET_DB_PASS=".c3"
SECRET_NTFY_TOKEN=".c4"
SECRET_NTFY_URL=".c5"

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

# Lock file
TEMP_DIR="$(mktemp -d)"
trap "rm -rf '$TEMP_DIR'" EXIT
exec 9> "$TEMP_DIR/.db_backup.lock"
if ! flock -n 9; then
  echo "[INFO] Another database backup is running. Exiting."
  exit 0
fi

# Logging
STAMP="$(date +%F-%H%M)"
LOG="$LOGS_DIR/db_logfile.log"
mkdir -p "$LOGS_DIR"
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "==== $(date +%F' '%T) START per-db backup ===="

# Get secrets
PASSPHRASE="$(get_secret "$SECRETS_DIR" "$SECRET_PASSPHRASE")"
[[ -z "$PASSPHRASE" ]] && { echo "[ERROR] No passphrase found"; exit 2; }

NTFY_URL="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_URL" || echo "")"
NTFY_TOKEN="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN" || echo "")"

send_notification() {
  local title="$1" message="$2"
  [[ -z "$NTFY_URL" ]] && return 0
  if [[ -n "$NTFY_TOKEN" ]]; then
    curl -s -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null || true
  else
    curl -s -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null || true
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

DB_USER="$(get_secret "$SECRETS_DIR" "$SECRET_DB_USER" || echo "")"
DB_PASS="$(get_secret "$SECRETS_DIR" "$SECRET_DB_PASS" || echo "")"
MYSQL_ARGS=()
[[ -n "$DB_USER" && -n "$DB_PASS" ]] && MYSQL_ARGS+=("-u" "$DB_USER" "-p$DB_PASS")

EXCLUDE_REGEX='^(information_schema|performance_schema|sys|mysql)$'
DBS="$($DB_CLIENT "${MYSQL_ARGS[@]}" -NBe 'SHOW DATABASES' 2>/dev/null | grep -Ev "$EXCLUDE_REGEX" || true)"

DEST="$TEMP_DIR/$STAMP"
mkdir -p "$DEST"

declare -a failures=()
for db in $DBS; do
  echo "  → Dumping: $db"
  if "$DB_DUMP" "${MYSQL_ARGS[@]}" --databases "$db" --single-transaction --quick \
      --routines --events --triggers --hex-blob --default-character-set=utf8mb4 \
      | $COMPRESSOR > "$DEST/${db}-${STAMP}.sql.gz"; then
    echo "    OK: $db"
  else
    echo "    FAILED: $db"
    failures+=("$db")
  fi
done

# Archive + encrypt
ARCHIVE="$TEMP_DIR/${HOSTNAME}-db_backups-${STAMP}.tar.gz.gpg"
tar -C "$TEMP_DIR" -cf - "$STAMP" | $COMPRESSOR | \
  gpg --batch --yes --pinentry-mode=loopback --passphrase "$PASSPHRASE" --symmetric --cipher-algo AES256 -o "$ARCHIVE"

# Verify
if gpg --batch --quiet --pinentry-mode=loopback --passphrase "$PASSPHRASE" -d "$ARCHIVE" | tar -tzf - >/dev/null; then
  echo "Archive verified."
  rclone copy "$ARCHIVE" "$RCLONE_REMOTE:$RCLONE_PATH"
  rclone check "$(dirname "$ARCHIVE")" "$RCLONE_REMOTE:$RCLONE_PATH" --one-way --size-only --include "$(basename "$ARCHIVE")"
  echo "Uploaded to $RCLONE_REMOTE:$RCLONE_PATH"
else
  echo "[ERROR] Archive verification failed"
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Failed on $HOSTNAME" "Verification failed"
  exit 4
fi

if ((${#failures[@]})); then
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Completed with Errors on $HOSTNAME" "Failures: ${failures[*]}"
  echo "==== $(date +%F' '%T) END (with errors) ===="
  exit 1
else
  [[ -n "$NTFY_URL" ]] && send_notification "DB Backup Successful on $HOSTNAME" "All databases backed up"
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

RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_PATH="%%RCLONE_PATH%%"
SECRETS_DIR="%%SECRETS_DIR%%"
LOG_PREFIX="[DB-RESTORE]"

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

echo "========================================================"
echo "           Database Restore Utility"
echo "========================================================"
echo

# DB client
if command -v mariadb >/dev/null 2>&1; then DB_CLIENT="mariadb"
elif command -v mysql >/dev/null 2>&1; then DB_CLIENT="mysql"
else echo "$LOG_PREFIX ERROR: No database client found."; exit 1; fi

DB_USER="$(get_secret "$SECRETS_DIR" "$SECRET_DB_USER" || echo "")"
DB_PASS="$(get_secret "$SECRETS_DIR" "$SECRET_DB_PASS" || echo "")"
MYSQL_ARGS=()
[[ -n "$DB_USER" && -n "$DB_PASS" ]] && MYSQL_ARGS+=("-u" "$DB_USER" "-p$DB_PASS")

TEMP_DIR="$(mktemp -d)"
trap "rm -rf '$TEMP_DIR'" EXIT

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

SECRET_NTFY_TOKEN=".c4"
SECRET_NTFY_URL=".c5"

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

TEMP_DIR="$(mktemp -d)"
trap "rm -rf '$TEMP_DIR'" EXIT
exec 9> "$TEMP_DIR/.files_backup.lock"
if ! flock -n 9; then
  echo "$LOG_PREFIX Another backup running. Exiting."
  exit 0
fi

STAMP="$(date +%F-%H%M)"
LOG="$LOGS_DIR/files_logfile.log"
mkdir -p "$LOGS_DIR"
touch "$LOG" && chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "==== $(date +%F' '%T) START files backup ===="

NTFY_URL="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_URL" || echo "")"
NTFY_TOKEN="$(get_secret "$SECRETS_DIR" "$SECRET_NTFY_TOKEN" || echo "")"

send_notification() {
  local title="$1" message="$2"
  [[ -z "$NTFY_URL" ]] && return 0
  if [[ -n "$NTFY_TOKEN" ]]; then
    curl -s -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null || true
  else
    curl -s -H "Title: $title" -d "$message" "$NTFY_URL" >/dev/null || true
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
declare -a failures=()
success_count=0

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
  
  [[ $tar_status -gt 1 ]] && { failures+=("$site_name"); continue; }
  [[ ! -f "$archive_path" ]] && { failures+=("$site_name"); continue; }
  
  echo "$LOG_PREFIX [$site_name] Uploading..."
  if rclone copy "$archive_path" "$RCLONE_REMOTE:$RCLONE_PATH"; then
    rm -f "$archive_path"
    ((success_count++)) || true
  else
    failures+=("$site_name")
  fi
done

if [[ ${#failures[@]} -gt 0 ]]; then
  [[ -n "$NTFY_URL" ]] && send_notification "Files Backup Errors on $HOSTNAME" "Failed: ${failures[*]}"
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

RCLONE_REMOTE="%%RCLONE_REMOTE%%"
RCLONE_PATH="%%RCLONE_PATH%%"
LOG_PREFIX="[FILES-RESTORE]"
WWW_DIR="/var/www"

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
  if [[ -d "$WWW_DIR/$site" ]]; then
    backup_name="${site}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    mv "$WWW_DIR/$site" "$WWW_DIR/$backup_name"
  fi
  
  if tar -xzf "$BACKUP_FILE" -C "$WWW_DIR" "$site" 2>/dev/null; then
    echo "  ✓ Success"
    [[ -d "$WWW_DIR/$backup_name" ]] && rm -rf "$WWW_DIR/$backup_name"
  else
    echo "  ✗ Failed"
    [[ -d "$WWW_DIR/$backup_name" ]] && mv "$WWW_DIR/$backup_name" "$WWW_DIR/$site"
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