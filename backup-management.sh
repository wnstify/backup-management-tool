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

VERSION="1.4.1"
AUTHOR="Webnestify"
WEBSITE="https://webnestify.cloud"
INSTALL_DIR="/etc/backup-management"
SCRIPTS_DIR="$INSTALL_DIR/scripts"
CONFIG_FILE="$INSTALL_DIR/.config"

# Lock file locations (fixed, not in temp)
LOCK_DIR="/var/lock"
DB_LOCK_FILE="$LOCK_DIR/backup-management-db.lock"
FILES_LOCK_FILE="$LOCK_DIR/backup-management-files.lock"

# Determine script directory (handle symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# ---------- Source Modules ----------

# Check if lib directory exists
if [[ ! -d "$LIB_DIR" ]]; then
  echo "Error: Library directory not found: $LIB_DIR"
  echo "Please ensure the lib/ directory is in the same location as this script."
  exit 1
fi

# Source all modules in order (dependencies first)
source "$LIB_DIR/core.sh"       # Colors, print functions, validation, helpers
source "$LIB_DIR/crypto.sh"     # Encryption, secrets, key derivation
source "$LIB_DIR/config.sh"     # Configuration read/write
source "$LIB_DIR/generators.sh" # Script generation (needed by setup/schedule)
source "$LIB_DIR/status.sh"     # Status display, view logs
source "$LIB_DIR/backup.sh"     # Backup execution, cleanup
source "$LIB_DIR/verify.sh"     # Backup integrity verification
source "$LIB_DIR/restore.sh"    # Restore execution
source "$LIB_DIR/schedule.sh"   # Schedule management
source "$LIB_DIR/setup.sh"      # Setup wizard

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
  echo "  - All backup scripts"
  echo "  - Configuration files"
  echo "  - Secure credential storage"
  echo "  - Systemd timers"
  echo "  - The 'backup-management' command"
  echo
  print_warning "Your actual backups in remote storage will NOT be deleted."
  echo
  read -p "Are you sure? Type 'UNINSTALL' to confirm: " confirm

  if [[ "$confirm" != "UNINSTALL" ]]; then
    echo "Cancelled."
    press_enter_to_continue
    return
  fi

  # Stop and disable timers
  systemctl stop backup-management-db.timer 2>/dev/null || true
  systemctl stop backup-management-files.timer 2>/dev/null || true
  systemctl stop backup-management-verify.timer 2>/dev/null || true
  systemctl disable backup-management-db.timer 2>/dev/null || true
  systemctl disable backup-management-files.timer 2>/dev/null || true
  systemctl disable backup-management-verify.timer 2>/dev/null || true

  # Remove cron jobs (legacy)
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

  # Remove systemd units
  rm -f /etc/systemd/system/backup-management-db.service
  rm -f /etc/systemd/system/backup-management-db.timer
  rm -f /etc/systemd/system/backup-management-files.service
  rm -f /etc/systemd/system/backup-management-files.timer
  rm -f /etc/systemd/system/backup-management-verify.service
  rm -f /etc/systemd/system/backup-management-verify.timer
  systemctl daemon-reload 2>/dev/null || true

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
