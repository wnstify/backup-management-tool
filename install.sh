#!/usr/bin/env bash
# ============================================================================
# Backup Management Tool - Installer
# by Webnestify (https://webnestify.cloud)
#
# One-liner installation:
# curl -fsSL https://raw.githubusercontent.com/wnstify/backup-management-tool/main/install.sh | sudo bash
#
# Or with wget:
# wget -qO- https://raw.githubusercontent.com/wnstify/backup-management-tool/main/install.sh | sudo bash
# ============================================================================
set -euo pipefail

VERSION="1.0.0"
REPO_URL="https://raw.githubusercontent.com/wnstify/backup-management-tool/main"
INSTALL_DIR="/etc/backup-management"
BIN_PATH="/usr/local/bin/backup-management"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
  echo -e "${BLUE}"
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║                                                           ║"
  echo "║        Backup Management Tool Installer v${VERSION}          ║"
  echo "║                    by Webnestify                          ║"
  echo "║                                                           ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

print_step() {
  echo -e "${CYAN}▶ $1${NC}"
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

# Check if running as root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "This installer must be run as root"
    echo "Please run: sudo bash install.sh"
    exit 1
  fi
}

# Check system requirements
check_requirements() {
  print_step "Checking system requirements..."
  
  local missing=()
  
  # Check for required commands
  command -v bash >/dev/null 2>&1 || missing+=("bash")
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=("curl or wget")
  command -v openssl >/dev/null 2>&1 || missing+=("openssl")
  command -v gpg >/dev/null 2>&1 || missing+=("gpg")
  command -v tar >/dev/null 2>&1 || missing+=("tar")
  command -v systemctl >/dev/null 2>&1 || missing+=("systemd")
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    print_error "Missing required packages: ${missing[*]}"
    exit 1
  fi
  
  print_success "System requirements met"
}

# Install dependencies
install_dependencies() {
  print_step "Installing dependencies..."
  
  # Detect package manager
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt-get"
    PKG_UPDATE="apt-get update -qq"
    PKG_INSTALL="apt-get install -y -qq"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
    PKG_UPDATE="yum makecache -q"
    PKG_INSTALL="yum install -y -q"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
    PKG_UPDATE="dnf makecache -q"
    PKG_INSTALL="dnf install -y -q"
  else
    print_warning "Unknown package manager. Please install pigz manually."
    return
  fi
  
  # Install pigz if not present
  if ! command -v pigz >/dev/null 2>&1; then
    print_step "Installing pigz..."
    $PKG_UPDATE >/dev/null 2>&1 || true
    $PKG_INSTALL pigz >/dev/null 2>&1 || print_warning "Could not install pigz automatically"
  fi
  
  # Install rclone if not present
  if ! command -v rclone >/dev/null 2>&1; then
    print_step "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1 || {
      print_warning "Could not install rclone automatically"
      print_warning "Please install manually: https://rclone.org/install/"
    }
  fi
  
  print_success "Dependencies installed"
}

# Download and install the main script
install_tool() {
  print_step "Downloading Backup Management Tool..."
  
  # Create installation directory
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/scripts"
  mkdir -p "$INSTALL_DIR/logs"
  chmod 700 "$INSTALL_DIR"
  
  # Download main script
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_URL/backup-management.sh" -o "$INSTALL_DIR/backup-management.sh"
  else
    wget -qO "$INSTALL_DIR/backup-management.sh" "$REPO_URL/backup-management.sh"
  fi
  
  chmod +x "$INSTALL_DIR/backup-management.sh"
  
  # Create symlink to /usr/local/bin
  ln -sf "$INSTALL_DIR/backup-management.sh" "$BIN_PATH"
  
  print_success "Tool installed to $INSTALL_DIR"
  print_success "Command 'backup-management' is now available"
}

# Create systemd service and timer units
install_systemd_units() {
  print_step "Installing systemd units..."
  
  # Database backup service
  cat > /etc/systemd/system/backup-management-db.service << 'EOF'
[Unit]
Description=Backup Management - Database Backup
After=network-online.target mysql.service mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/backup-management/scripts/db_backup.sh
StandardOutput=append:/etc/backup-management/logs/db_logfile.log
StandardError=append:/etc/backup-management/logs/db_logfile.log
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF

  # Database backup timer
  cat > /etc/systemd/system/backup-management-db.timer << 'EOF'
[Unit]
Description=Backup Management - Database Backup Timer
Requires=backup-management-db.service

[Timer]
OnCalendar=hourly
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Files backup service
  cat > /etc/systemd/system/backup-management-files.service << 'EOF'
[Unit]
Description=Backup Management - Files Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/backup-management/scripts/files_backup.sh
StandardOutput=append:/etc/backup-management/logs/files_logfile.log
StandardError=append:/etc/backup-management/logs/files_logfile.log
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF

  # Files backup timer
  cat > /etc/systemd/system/backup-management-files.timer << 'EOF'
[Unit]
Description=Backup Management - Files Backup Timer
Requires=backup-management-files.service

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Reload systemd
  systemctl daemon-reload
  
  print_success "Systemd units installed"
}

# Print completion message
print_completion() {
  echo
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║           Installation Complete!                          ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "To get started, run:"
  echo -e "  ${CYAN}backup-management${NC}"
  echo
  echo -e "This will launch the setup wizard to configure:"
  echo -e "  • Encryption password"
  echo -e "  • Database credentials"
  echo -e "  • Remote storage (rclone)"
  echo -e "  • Notifications (optional)"
  echo -e "  • Backup schedules"
  echo
  echo -e "After setup, backups will run automatically via systemd timers."
  echo
  echo -e "${YELLOW}Documentation:${NC} https://github.com/wnstify/backup-management-tool"
  echo -e "${YELLOW}Support:${NC} https://webnestify.cloud"
  echo
}

# Uninstall function (can be called with --uninstall flag)
uninstall() {
  print_banner
  print_step "Uninstalling Backup Management Tool..."
  
  # Stop and disable timers
  systemctl stop backup-management-db.timer 2>/dev/null || true
  systemctl stop backup-management-files.timer 2>/dev/null || true
  systemctl disable backup-management-db.timer 2>/dev/null || true
  systemctl disable backup-management-files.timer 2>/dev/null || true
  
  # Remove systemd units
  rm -f /etc/systemd/system/backup-management-db.service
  rm -f /etc/systemd/system/backup-management-db.timer
  rm -f /etc/systemd/system/backup-management-files.service
  rm -f /etc/systemd/system/backup-management-files.timer
  systemctl daemon-reload
  
  # Remove binary
  rm -f "$BIN_PATH"
  
  # Ask about config removal
  echo
  read -p "Remove configuration and secrets? (y/N): " remove_config
  if [[ "$remove_config" =~ ^[Yy]$ ]]; then
    # Get secrets location
    if [[ -f "$INSTALL_DIR/.secrets_location" ]]; then
      secrets_dir="$(cat "$INSTALL_DIR/.secrets_location")"
      if [[ -n "$secrets_dir" && -d "$secrets_dir" ]]; then
        chattr -i "$secrets_dir"/* 2>/dev/null || true
        chattr -i "$secrets_dir" 2>/dev/null || true
        rm -rf "$secrets_dir"
      fi
    fi
    rm -rf "$INSTALL_DIR"
    print_success "Configuration and secrets removed"
  else
    print_warning "Configuration kept at $INSTALL_DIR"
  fi
  
  print_success "Uninstallation complete"
  exit 0
}

# Main installation flow
main() {
  # Check for uninstall flag
  if [[ "${1:-}" == "--uninstall" ]] || [[ "${1:-}" == "-u" ]]; then
    check_root
    uninstall
  fi
  
  print_banner
  
  echo -e "${YELLOW}┌────────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│                      DISCLAIMER                        │${NC}"
  echo -e "${YELLOW}├────────────────────────────────────────────────────────┤${NC}"
  echo -e "${YELLOW}│ This tool is provided \"as is\" without warranty.        │${NC}"
  echo -e "${YELLOW}│ Always create a server SNAPSHOT before using.          │${NC}"
  echo -e "${YELLOW}│ Use at your own risk.                                  │${NC}"
  echo -e "${YELLOW}└────────────────────────────────────────────────────────┘${NC}"
  echo
  
  read -p "Continue with installation? (Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Installation cancelled."
    exit 0
  fi
  
  echo
  
  check_root
  check_requirements
  install_dependencies
  install_tool
  install_systemd_units
  print_completion
}

main "$@"
