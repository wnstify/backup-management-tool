#!/usr/bin/env bash
# ============================================================================
# Backup Management Tool - Setup Module
# Setup wizard for initial configuration
# ============================================================================

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
  local RCLONE_DB_PATH=""
  local RCLONE_FILES_PATH=""

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

  # ---------- Step 6: Retention Policy ----------
  echo "Step 6: Retention Policy"
  echo "------------------------"
  echo "How long should backups be kept before automatic cleanup?"
  echo
  echo "  1) 1 minute (TESTING ONLY)"
  echo "  2) 1 hour (TESTING)"
  echo "  3) 7 days"
  echo "  4) 14 days"
  echo "  5) 30 days"
  echo "  6) 60 days"
  echo "  7) 90 days"
  echo "  8) 365 days (1 year)"
  echo "  9) No automatic cleanup"
  echo
  read -p "Select retention period [1-9] (default: 5): " RETENTION_CHOICE
  RETENTION_CHOICE=${RETENTION_CHOICE:-5}

  local RETENTION_MINUTES=0
  local RETENTION_DESC=""
  case "$RETENTION_CHOICE" in
    1) RETENTION_MINUTES=1; RETENTION_DESC="1 minute (TESTING)" ;;
    2) RETENTION_MINUTES=60; RETENTION_DESC="1 hour (TESTING)" ;;
    3) RETENTION_MINUTES=$((7 * 24 * 60)); RETENTION_DESC="7 days" ;;
    4) RETENTION_MINUTES=$((14 * 24 * 60)); RETENTION_DESC="14 days" ;;
    5) RETENTION_MINUTES=$((30 * 24 * 60)); RETENTION_DESC="30 days" ;;
    6) RETENTION_MINUTES=$((60 * 24 * 60)); RETENTION_DESC="60 days" ;;
    7) RETENTION_MINUTES=$((90 * 24 * 60)); RETENTION_DESC="90 days" ;;
    8) RETENTION_MINUTES=$((365 * 24 * 60)); RETENTION_DESC="365 days" ;;
    9) RETENTION_MINUTES=0; RETENTION_DESC="No automatic cleanup" ;;
    *) RETENTION_MINUTES=$((30 * 24 * 60)); RETENTION_DESC="30 days (default)" ;;
  esac

  save_config "RETENTION_MINUTES" "$RETENTION_MINUTES"
  save_config "RETENTION_DESC" "$RETENTION_DESC"
  print_success "Retention policy: $RETENTION_DESC"
  echo

  # ---------- Step 7: Generate Scripts ----------
  echo "Step 7: Generating Backup Scripts"
  echo "----------------------------------"

  generate_all_scripts "$SECRETS_DIR" "$DO_DATABASE" "$DO_FILES" "$RCLONE_REMOTE" \
    "${RCLONE_DB_PATH:-}" "${RCLONE_FILES_PATH:-}" "$RETENTION_MINUTES"

  echo

  # ---------- Step 8: Schedule Backups ----------
  echo "Step 8: Schedule Backups (systemd timers)"
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
