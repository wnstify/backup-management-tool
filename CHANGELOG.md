# Changelog

All notable changes to the Backup Management Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.3.0] - 2024-12-11

### Added

- **Modular Architecture**
  - Refactored monolithic 3,200-line script into 10 separate modules
  - New `lib/` directory contains all functional modules
  - Each module handles a specific responsibility (core, crypto, config, etc.)
  - Easier to maintain, test, and extend

### Changed

- **Code Organization**
  - `core.sh` - Colors, print functions, input validation, helper utilities
  - `crypto.sh` - Encryption, secrets, key derivation functions
  - `config.sh` - Configuration file read/write operations
  - `generators.sh` - Script generation for backup/restore/verify
  - `status.sh` - Status display and log viewing
  - `backup.sh` - Backup execution and cleanup functions
  - `verify.sh` - Backup integrity verification
  - `restore.sh` - Restore execution functions
  - `schedule.sh` - Schedule management and systemd timer setup
  - `setup.sh` - Interactive setup wizard

- **Main Script**
  - `backup-management.sh` reduced from 3,200 to ~210 lines
  - Sources all modules from `lib/` directory
  - Handles symlink resolution for correct lib path
  - Cleaner entry point with only main menu and install/uninstall logic

- **Installer**
  - Now downloads all library modules individually
  - Creates `lib/` directory in installation path
  - Shows download progress for each module
  - Fails gracefully if any module download fails

### Technical

- Modules are sourced in dependency order
- Symlink resolution ensures lib path works when called via `/usr/local/bin/backup-management`
- All module functions remain globally accessible after sourcing
- No functional changes to backup/restore/verify operations

---

## [1.2.0] - 2024-12-09

### Added

- **SHA256 Checksums**
  - Every backup now generates a `.sha256` checksum file
  - Checksum uploaded alongside backup to cloud storage
  - Enables verification of backup integrity

- **Verify Backup Integrity**
  - New menu option: "Run backup now" → "Verify backup integrity"
  - Downloads latest backup and verifies checksum
  - Tests decryption (for database backups)
  - Tests archive extraction (for files backups)
  - Lists archive contents without restoring
  - Sends notification with verification result

- **Scheduled Integrity Check (Optional)**
  - New menu option: "Manage schedules" → "Set/change integrity check schedule"
  - Automatic weekly/monthly verification of backups
  - Runs non-interactively using stored encryption passphrase
  - Logs results to `/etc/backup-management/logs/verify_logfile.log`
  - Sends notification with pass/fail status
  - Schedule presets: Weekly, bi-weekly, monthly, daily, or custom

- **Checksum Verification on Restore**
  - Restore scripts now verify checksum before restoring
  - Warning shown if checksum mismatch detected
  - Option to continue anyway or abort

### Changed

- Manage Schedules menu now has 9 options (added integrity check schedule)
- Retention cleanup also deletes corresponding `.sha256` files
- Files backup listing excludes `.sha256` files

### Security

- Backups can now be verified for tampering/corruption
- End-to-end integrity verification from upload to restore
- Scheduled verification catches silent backup corruption early

---

## [1.1.1] - 2024-12-09

### Added

- **Retention Cleanup Notifications**
  - Push notification when old backups are removed
  - Warning notification if cleanup encounters errors
  - Failure notification if cutoff time calculation fails
  - Notifications sent via ntfy (if configured)

### Changed

- Retention cleanup now reports "No old backups to remove" when nothing to clean
- Notifications include count of removed backups and errors

---

## [1.1.0] - 2024-12-09

### Added

- **Retention Policy System**
  - Configurable retention periods (1 minute to 365 days, or disabled)
  - Automatic cleanup of old backups after each backup run
  - Manual cleanup option via "Run backup now" → "Run cleanup now"
  - Retention policy display in status page
  - Change retention policy via "Manage schedules" menu

- **Testing Options**
  - 1 minute retention for quick testing
  - 1 hour retention for extended testing

- **Log Rotation**
  - Automatic log rotation at 10MB
  - Keeps 5 backup log files
  - Prevents disk space issues from growing logs

- **Retention Error Logging**
  - Cleanup errors now logged instead of silently ignored
  - Shows specific error messages from rclone
  - Summary shows both success count and error count

- **Run Cleanup Now**
  - Manual trigger for retention cleanup
  - Shows cutoff time and files being deleted
  - Works independently of backup schedule

### Changed

- Setup wizard now includes Step 6: Retention Policy
- Schedule management menu expanded with retention option
- Status page now displays current retention policy
- Backup scripts regenerated when retention policy changes

### Security

- **MySQL Password Protection**
  - Passwords no longer visible in `ps aux` output
  - Uses `--defaults-extra-file` with secure temp auth file
  - Auth file cleaned up on exit (including on errors)

- **Fixed Lock Files**
  - Lock files now in fixed location (`/var/lock/backup-management-*.lock`)
  - Properly prevents concurrent backup/restore operations
  - Restore scripts wait up to 60 seconds if backup is running

- **Input Validation**
  - Added `validate_path()` - blocks shell metacharacters and path traversal
  - Added `validate_url()` - validates HTTP/HTTPS URLs
  - Added `validate_password()` - enforces minimum 8 characters
  - Config values are escaped to prevent injection

- **Disk Space Checks**
  - Database backups require 1GB free in /tmp
  - Files backups require 2GB free in /tmp
  - Prevents failed backups due to full disk

- **Timeout Protection**
  - rclone uploads: 30 minute timeout with retries
  - rclone verification: 60 second timeout
  - curl notifications: 10 second timeout
  - Prevents indefinite hangs on network issues

- **Improved Cleanup**
  - All temp files cleaned up on EXIT/INT/TERM signals
  - MySQL auth files always removed
  - Salt file (.s) now properly unlocked during uninstall

- **umask 077**
  - All scripts now set restrictive umask
  - Temp files created with secure permissions

### Fixed

- Lock file bug where each run created new temp directory (lock was useless)
- `chattr` now only affects specific secret files, not all dotfiles
- `backup_name` variable scope bug in files restore
- Uninstall now properly unlocks `.s` salt file before removal
- Installer works when piped from curl (reads from /dev/tty)

---

## [1.0.0] - 2024-12-08

### Added

- Initial release
- Database backup with GPG encryption
- WordPress files backup with compression
- Secure credential storage (AES-256, machine-bound)
- Systemd timer scheduling
- Interactive setup wizard
- Database restore wizard
- Files restore wizard
- ntfy.sh notification support
- Detailed logging
- One-line installer

### Security

- Machine-bound encryption keys
- Random hidden directory for secrets
- Immutable file flags (chattr +i)
- No plain-text credential storage

---

## Version History Summary

| Version | Date | Highlights |
|---------|------|------------|
| 1.3.0 | 2024-12-11 | Modular architecture, code refactoring |
| 1.2.0 | 2024-12-09 | Checksums, backup integrity verification |
| 1.1.1 | 2024-12-09 | Retention cleanup notifications |
| 1.1.0 | 2024-12-09 | Retention policy, security hardening, log rotation |
| 1.0.0 | 2024-12-08 | Initial release |

---

<p align="center">
  <strong>Built with ❤️ by <a href="https://webnestify.cloud">Webnestify</a></strong>
</p>