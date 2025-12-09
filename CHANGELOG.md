# Changelog

All notable changes to the Backup Management Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
| 1.1.0 | 2024-12-09 | Retention policy, security hardening, log rotation |
| 1.0.0 | 2024-12-08 | Initial release |

---

<p align="center">
  <strong>Built with ❤️ by <a href="https://webnestify.cloud">Webnestify</a></strong>
</p>