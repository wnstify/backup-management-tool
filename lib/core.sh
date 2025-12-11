#!/usr/bin/env bash
# ============================================================================
# Backup Management Tool - Core Module
# Core functions: colors, printing, validation, and helper utilities
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ---------- Print Functions ----------

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

# ---------- System Check Functions ----------

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

# ---------- MySQL Helper Functions ----------

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

# ---------- Logging Functions ----------

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

# ---------- Secure File Operations ----------

# Secure temp directory creation (prevent symlink attacks)
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
