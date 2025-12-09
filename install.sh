#!/bin/bash
#
# Backup Management Tool - One-Line Installer
# by Webnestify (https://webnestify.cloud)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wnstify/backup-management-tool/main/install.sh | sudo bash
#
# Uninstall:
#   curl -fsSL https://raw.githubusercontent.com/wnstify/backup-management-tool/main/install.sh | sudo bash -s -- --uninstall
#

set -e

# GitHub raw URL base
GITHUB_RAW="https://raw.githubusercontent.com/wnstify/backup-management-tool/main"

# Installation paths
INSTALL_DIR="/etc/backup-management"
SCRIPT_NAME="backup-management.sh"
BIN_LINK="/usr/local/bin/backup-management"

# Dedicated user settings
BACKUP_USER="backupmgr"
BACKUP_USER_HOME="/var/lib/backupmgr"
SUDOERS_FILE="/etc/sudoers.d/backupmgr"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Track if dedicated user is set up
USE_DEDICATED_USER=false

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║        Backup Management Tool - Installer                 ║"
    echo "║                  by Webnestify                            ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_disclaimer() {
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}                        DISCLAIMER${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "This tool is provided AS-IS without warranty. By installing,"
    echo "you acknowledge that:"
    echo ""
    echo "  • You are responsible for your own backups and data"
    echo "  • You should test restores before relying on backups"
    echo "  • The authors are not liable for any data loss"
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This installer must be run as root${NC}"
        echo "Please run: curl -fsSL ... | sudo bash"
        exit 1
    fi
}

check_system() {
    echo -e "${BLUE}[1/6] Checking system requirements...${NC}"
    
    # Check OS
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo -e "  OS: ${GREEN}$PRETTY_NAME${NC}"
    fi
    
    # Check required commands
    local required_cmds=("bash" "openssl" "gpg" "tar" "systemctl")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}Error: Required command '$cmd' not found${NC}"
            exit 1
        fi
    done
    echo -e "  Required tools: ${GREEN}OK${NC}"
    
    # Check for curl or wget
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        echo -e "${RED}Error: Either curl or wget is required${NC}"
        exit 1
    fi
    echo -e "  Download tool: ${GREEN}OK${NC}"
    
    # Check systemd
    if ! pidof systemd &> /dev/null; then
        echo -e "${YELLOW}Warning: systemd not detected. Timers may not work.${NC}"
    else
        echo -e "  systemd: ${GREEN}OK${NC}"
    fi
}

install_dependencies() {
    echo -e "${BLUE}[2/6] Installing dependencies...${NC}"
    
    # Update package list (suppress output)
    apt-get update -qq 2>/dev/null || true
    
    # Install pigz if not present
    if ! command -v pigz &> /dev/null; then
        echo -e "  Installing pigz..."
        apt-get install -y -qq pigz 2>/dev/null || echo -e "  ${YELLOW}pigz install failed - will use gzip${NC}"
    fi
    if command -v pigz &> /dev/null; then
        echo -e "  pigz: ${GREEN}OK${NC}"
    fi
    
    # Install rclone if not present
    if ! command -v rclone &> /dev/null; then
        echo -e "  Installing rclone..."
        if command -v curl &> /dev/null; then
            curl -fsSL https://rclone.org/install.sh | bash -s beta 2>/dev/null || true
        fi
    fi
    if command -v rclone &> /dev/null; then
        echo -e "  rclone: ${GREEN}OK${NC}"
    else
        echo -e "  rclone: ${YELLOW}Not installed - install manually or via setup${NC}"
    fi
}

ask_dedicated_user() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                  Security Configuration${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "You can run backups as a dedicated user instead of root."
    echo ""
    echo -e "  ${GREEN}Benefits:${NC}"
    echo "    • Better security isolation"
    echo "    • Audit trail (sudo logs all executions)"
    echo "    • Follows principle of least privilege"
    echo ""
    echo -e "  ${YELLOW}How it works:${NC}"
    echo "    • Creates user: ${BACKUP_USER}"
    echo "    • Grants sudo access only for backup-management"
    echo "    • Systemd timers run as this user"
    echo ""
    read -p "Create dedicated backup user? (Y/n): " create_user
    
    if [[ ! "$create_user" =~ ^[Nn]$ ]]; then
        USE_DEDICATED_USER=true
    fi
}

setup_dedicated_user() {
    if [[ "$USE_DEDICATED_USER" != true ]]; then
        return
    fi
    
    echo -e "${BLUE}[3/6] Setting up dedicated backup user...${NC}"
    
    # Create user if doesn't exist
    if id "$BACKUP_USER" &>/dev/null; then
        echo -e "  User ${BACKUP_USER}: ${GREEN}Already exists${NC}"
    else
        useradd -r -s /bin/bash -m -d "$BACKUP_USER_HOME" "$BACKUP_USER"
        echo -e "  User ${BACKUP_USER}: ${GREEN}Created${NC}"
    fi
    
    # Create sudoers file
    cat > "$SUDOERS_FILE" << EOF
# Backup Management Tool - Allow backupmgr to run backup commands
# This file was auto-generated by the installer

# Allow running the main backup-management script
${BACKUP_USER} ALL=(root) NOPASSWD: ${BIN_LINK}
${BACKUP_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/${SCRIPT_NAME}

# Allow running the generated backup scripts
${BACKUP_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/scripts/db_backup.sh
${BACKUP_USER} ALL=(root) NOPASSWD: ${INSTALL_DIR}/scripts/files_backup.sh

# Allow systemctl commands for backup timers only
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start backup-management-*
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop backup-management-*
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart backup-management-*
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl enable backup-management-*
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl disable backup-management-*
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl status backup-management-*
${BACKUP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload
EOF
    
    # Secure the sudoers file
    chmod 440 "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"
    
    # Validate sudoers file
    if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
        echo -e "  Sudoers file: ${GREEN}Created and validated${NC}"
    else
        echo -e "${RED}Error: Invalid sudoers file. Removing...${NC}"
        rm -f "$SUDOERS_FILE"
        USE_DEDICATED_USER=false
        return
    fi
    
    # Create a wrapper script for easier invocation
    cat > "${BIN_LINK}-as-user" << EOF
#!/bin/bash
# Run backup-management as dedicated user
exec sudo -u ${BACKUP_USER} sudo ${BIN_LINK} "\$@"
EOF
    chmod +x "${BIN_LINK}-as-user"
    echo -e "  Wrapper script: ${GREEN}${BIN_LINK}-as-user${NC}"
}

download_script() {
    local step="3"
    [[ "$USE_DEDICATED_USER" == true ]] && step="4"
    
    echo -e "${BLUE}[${step}/6] Downloading backup-management.sh...${NC}"
    
    # Create installation directory
    mkdir -p "$INSTALL_DIR"
    mkdir -p "${INSTALL_DIR}/scripts"
    mkdir -p "${INSTALL_DIR}/logs"
    
    # Download main script
    local script_url="${GITHUB_RAW}/${SCRIPT_NAME}"
    local target_path="${INSTALL_DIR}/${SCRIPT_NAME}"
    
    echo -e "  Downloading from: ${script_url}"
    
    if command -v curl &> /dev/null; then
        if ! curl -fsSL "$script_url" -o "$target_path"; then
            echo -e "${RED}Error: Failed to download script with curl${NC}"
            exit 1
        fi
    elif command -v wget &> /dev/null; then
        if ! wget -q "$script_url" -O "$target_path"; then
            echo -e "${RED}Error: Failed to download script with wget${NC}"
            exit 1
        fi
    fi
    
    # Verify download
    if [[ ! -s "$target_path" ]]; then
        echo -e "${RED}Error: Downloaded file is empty${NC}"
        exit 1
    fi
    
    # Check if it looks like a bash script
    if ! head -1 "$target_path" | grep -q "^#!"; then
        echo -e "${RED}Error: Downloaded file does not appear to be a valid script${NC}"
        echo -e "${RED}First line: $(head -1 "$target_path")${NC}"
        exit 1
    fi
    
    # Make executable
    chmod +x "$target_path"
    
    # Create symlink
    ln -sf "$target_path" "$BIN_LINK"
    
    # Set ownership if dedicated user
    if [[ "$USE_DEDICATED_USER" == true ]]; then
        chown -R root:${BACKUP_USER} "${INSTALL_DIR}/logs"
        chmod 775 "${INSTALL_DIR}/logs"
    fi
    
    echo -e "  Script: ${GREEN}${target_path}${NC}"
    echo -e "  Command: ${GREEN}backup-management${NC}"
}

create_systemd_units() {
    local step="4"
    [[ "$USE_DEDICATED_USER" == true ]] && step="5"
    
    echo -e "${BLUE}[${step}/6] Creating systemd service units...${NC}"
    
    # Determine user/group for services
    local service_user="root"
    local exec_prefix=""
    if [[ "$USE_DEDICATED_USER" == true ]]; then
        service_user="$BACKUP_USER"
        exec_prefix="/usr/bin/sudo "
    fi
    
    # Database backup service
    cat > /etc/systemd/system/backup-management-db.service << EOF
[Unit]
Description=Backup Management - Database Backup
After=network-online.target mysql.service mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
User=${service_user}
ExecStart=${exec_prefix}${INSTALL_DIR}/scripts/db_backup.sh
StandardOutput=append:${INSTALL_DIR}/logs/db_logfile.log
StandardError=append:${INSTALL_DIR}/logs/db_logfile.log
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
OnCalendar=*-*-* 0/2:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Files backup service
    cat > /etc/systemd/system/backup-management-files.service << EOF
[Unit]
Description=Backup Management - Files Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${service_user}
ExecStart=${exec_prefix}${INSTALL_DIR}/scripts/files_backup.sh
StandardOutput=append:${INSTALL_DIR}/logs/files_logfile.log
StandardError=append:${INSTALL_DIR}/logs/files_logfile.log
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
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    echo -e "  Services: ${GREEN}Created${NC}"
    if [[ "$USE_DEDICATED_USER" == true ]]; then
        echo -e "  Running as: ${GREEN}${service_user} (via sudo)${NC}"
    fi
    echo -e "  Timers: ${GREEN}Created (not enabled yet)${NC}"
}

print_success() {
    local step="5"
    [[ "$USE_DEDICATED_USER" == true ]] && step="6"
    
    echo -e "${BLUE}[${step}/6] Installation complete!${NC}"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}            Installation Successful!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ "$USE_DEDICATED_USER" == true ]]; then
        echo -e "  ${CYAN}To get started, run:${NC}"
        echo ""
        echo -e "    ${YELLOW}sudo -u ${BACKUP_USER} sudo backup-management${NC}"
        echo ""
        echo -e "  ${CYAN}Or use the shortcut:${NC}"
        echo ""
        echo -e "    ${YELLOW}backup-management-as-user${NC}"
        echo ""
        echo -e "  ${CYAN}Dedicated user setup:${NC}"
        echo "    • User: ${BACKUP_USER}"
        echo "    • Home: ${BACKUP_USER_HOME}"
        echo "    • Sudoers: ${SUDOERS_FILE}"
        echo ""
    else
        echo -e "  ${CYAN}To get started, run:${NC}"
        echo ""
        echo -e "    ${YELLOW}sudo backup-management${NC}"
        echo ""
    fi
    
    echo -e "  ${CYAN}This will guide you through:${NC}"
    echo "    1. Database credentials setup"
    echo "    2. Cloud storage configuration (rclone)"
    echo "    3. Backup scheduling"
    echo "    4. Notification settings (optional)"
    echo ""
    echo -e "  ${CYAN}Documentation:${NC}"
    echo -e "    https://github.com/wnstify/backup-management-tool"
    echo ""
}

uninstall() {
    echo -e "${YELLOW}Uninstalling Backup Management Tool...${NC}"
    
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
    
    # Remove symlinks
    rm -f "$BIN_LINK"
    rm -f "${BIN_LINK}-as-user"
    
    # Ask about dedicated user
    if id "$BACKUP_USER" &>/dev/null; then
        echo ""
        read -p "Remove dedicated backup user (${BACKUP_USER})? (y/N): " remove_user
        if [[ "$remove_user" =~ ^[Yy]$ ]]; then
            userdel -r "$BACKUP_USER" 2>/dev/null || true
            rm -f "$SUDOERS_FILE"
            echo -e "  ${GREEN}User ${BACKUP_USER} removed${NC}"
        fi
    fi
    
    # Ask about config/secrets
    echo ""
    read -p "Remove configuration and encrypted secrets? (y/N): " remove_config
    if [[ "$remove_config" =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        # Try to find and remove secrets directory
        if [[ -f "${INSTALL_DIR}/.secrets_location" ]]; then
            local secrets_dir=$(cat "${INSTALL_DIR}/.secrets_location" 2>/dev/null)
            if [[ -n "$secrets_dir" ]] && [[ -d "$secrets_dir" ]]; then
                # Unlock files first
                chattr -i "$secrets_dir" 2>/dev/null || true
                for f in ".c1" ".c2" ".c3" ".c4" ".c5"; do
                    [[ -f "$secrets_dir/$f" ]] && chattr -i "$secrets_dir/$f" 2>/dev/null || true
                done
                rm -rf "$secrets_dir"
                echo -e "  ${GREEN}Removed secrets directory${NC}"
            fi
        fi
        # Fallback: search for secrets directories
        for dir in /etc/.*; do
            if [[ -d "$dir" ]] && [[ -f "$dir/.c1" ]]; then
                chattr -i "$dir" 2>/dev/null || true
                for f in ".c1" ".c2" ".c3" ".c4" ".c5"; do
                    [[ -f "$dir/$f" ]] && chattr -i "$dir/$f" 2>/dev/null || true
                done
                rm -rf "$dir"
                echo -e "  ${GREEN}Removed secrets directory: $dir${NC}"
            fi
        done
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}Configuration and secrets removed.${NC}"
    else
        rm -f "${INSTALL_DIR}/${SCRIPT_NAME}"
        echo -e "${GREEN}Script removed. Configuration preserved at ${INSTALL_DIR}${NC}"
    fi
    
    echo -e "${GREEN}Uninstallation complete.${NC}"
    exit 0
}

# Main
main() {
    # Check for uninstall flag
    if [[ "$1" == "--uninstall" ]] || [[ "$1" == "-u" ]]; then
        check_root
        uninstall
    fi
    
    print_banner
    print_disclaimer
    check_root
    check_system
    install_dependencies
    ask_dedicated_user
    [[ "$USE_DEDICATED_USER" == true ]] && setup_dedicated_user
    download_script
    create_systemd_units
    print_success
}

main "$@"