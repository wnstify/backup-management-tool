# Backup Management Tool

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-blue.svg" alt="Version 1.0.0">
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT License">
  <img src="https://img.shields.io/badge/platform-Linux-lightgrey.svg" alt="Linux">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25.svg" alt="Bash">
</p>

<p align="center">
  <strong>A comprehensive backup and restore solution for WordPress/MySQL environments</strong>
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#requirements">Requirements</a> •
  <a href="#installation">Installation</a> •
  <a href="#usage">Usage</a> •
  <a href="#security">Security</a> •
  <a href="#license">License</a>
</p>

---

## Overview

**Backup Management Tool** by [Webnestify](https://webnestify.cloud) is a powerful, menu-driven backup solution designed for WordPress hosting environments. It provides automated database and file backups with secure credential storage, remote cloud storage integration, and easy restoration capabilities.

```
========================================================
       Backup Management Tool v1.0.0
                  by Webnestify
========================================================

Main Menu
=========

  1. Run backup now
  2. Restore from backup
  3. View status
  4. View logs
  5. Manage schedules
  6. Reconfigure
  7. Uninstall
  8. Exit
```

## Features

### 🗄️ Database Backups
- Automatic discovery of all MySQL/MariaDB databases
- Individual database dumps (not one massive file)
- Excludes system databases (information_schema, performance_schema, mysql, sys)
- Full dump including routines, events, triggers
- GPG encryption (AES-256) for security

### 📁 File Backups
- Automatic WordPress site detection in `/var/www/`
- Preserves file ownership and permissions
- Compressed archives (tar.gz with pigz)
- Site URL-based naming for easy identification

### ☁️ Remote Storage
- **rclone integration** - supports 40+ cloud providers:
  - Backblaze B2
  - Amazon S3
  - Google Cloud Storage
  - Wasabi
  - DigitalOcean Spaces
  - And many more...
- Automatic upload verification
- No local storage required

### 🔐 Security
- **Machine-bound encryption** - credentials only work on the original server
- AES-256 encrypted credential storage
- Random directory names for obscurity
- Immutable file flags to prevent tampering
- No plain-text passwords anywhere

### 📱 Notifications
- **ntfy.sh integration** for push notifications
- Backup start/completion alerts
- Error notifications
- Support for authenticated ntfy servers

### ⏰ Scheduling
- Flexible cron-based scheduling
- Preset options (hourly, daily, weekly)
- Custom cron expressions supported
- Independent schedules for database and file backups

### 🔄 Easy Restoration
- Interactive restore wizard
- Select specific databases or restore all
- Select specific sites or restore all
- Safety backups before overwriting
- Automatic rollback on failure

## Requirements

### System Requirements
- **OS**: Linux (Ubuntu 20.04+, Debian 10+, or compatible)
- **Shell**: Bash 4.0+
- **Privileges**: Root access required

### Required Packages

**Install manually before running:**
| Package | Purpose | Install Command |
|---------|---------|-----------------|
| `pigz` | Parallel compression | `apt install pigz` |

**Auto-installed by the script (if missing):**
| Package | Purpose |
|---------|---------|
| `rclone` | Remote storage |

**Usually pre-installed on most systems:**
| Package | Purpose |
|---------|---------|
| `openssl` | Credential encryption |
| `gpg` | Backup encryption |
| `tar` | Archive creation |
| `curl` | Notifications |

### Database
- MySQL 5.7+ or MariaDB 10.3+
- Root access (socket auth or password)

## Installation

### Prerequisites

```bash
# Install pigz (required)
sudo apt update && sudo apt install pigz -y
```

### Quick Install

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/wnstify/backup-management-tool/main/backup-management.sh -o backup-management.sh

# Make executable
chmod +x backup-management.sh

# Run (will auto-install to /usr/local/bin)
sudo ./backup-management.sh
```

### Manual Install

```bash
# Clone the repository
git clone https://github.com/webnestify/backup-management.git
cd backup-management

# Make executable and run
chmod +x backup-management.sh
sudo ./backup-management.sh
```

### After Installation

The tool automatically installs itself to `/usr/local/bin/backup-management`, so you can run it from anywhere:

```bash
backup-management
```

## Quick Start

1. **Run the tool**:
   ```bash
   sudo backup-management
   ```

2. **Complete the setup wizard**:
   - Select backup type (Database, Files, or Both)
   - Set encryption password
   - Configure database access
   - Set up rclone remote storage
   - (Optional) Configure ntfy notifications
   - Set backup schedules

3. **You're done!** Backups will run automatically on schedule.

## Directory Structure

```
/etc/backup-management/           # Main installation directory
├── .config                       # Configuration file
├── .secrets_location             # Pointer to secrets directory
├── logs/
│   ├── db_logfile.log           # Database backup logs
│   └── files_logfile.log        # File backup logs
└── scripts/
    ├── db_backup.sh             # Database backup script
    ├── db_restore.sh            # Database restore script
    ├── files_backup.sh          # Files backup script
    └── files_restore.sh         # Files restore script

/etc/.{random}/                   # Secure credential storage
├── .s                            # Encryption salt
├── .c1                           # Encrypted passphrase
├── .c2                           # Encrypted DB username
├── .c3                           # Encrypted DB password
├── .c4                           # Encrypted ntfy token
└── .c5                           # Encrypted ntfy URL

/usr/local/bin/backup-management  # Symlink for easy access
```

## Configuration

### rclone Setup

Before running the backup tool, configure rclone with your cloud provider:

```bash
rclone config
```

Example for Backblaze B2:
1. Choose `n` for new remote
2. Name it (e.g., `b2`)
3. Select `Backblaze B2` from the list
4. Enter your Application Key ID
5. Enter your Application Key
6. Complete the configuration

### Notification Setup (Optional)

The tool supports [ntfy.sh](https://ntfy.sh) for push notifications:

1. Create a topic at ntfy.sh or use self-hosted ntfy
2. During setup, enter your topic URL (e.g., `https://ntfy.sh/my-backups`)
3. If using authentication, provide your token

## Backup Storage Format

### Database Backups
```
{hostname}-db_backups-{YYYY-MM-DD-HHMM}.tar.gz.gpg
└── {timestamp}/
    ├── database1-{timestamp}.sql.gz
    ├── database2-{timestamp}.sql.gz
    └── database3-{timestamp}.sql.gz
```

### File Backups
```
{site-url}-{YYYY-MM-DD-HHMM}.tar.gz
└── {site-directory}/
    ├── public_html/
    ├── wp-config.php
    └── ...
```

## Security

### The Challenge

Storing sensitive credentials (database passwords, API tokens) in plain text is a well-known security risk. However, for automated backups to work (via cron jobs), the system needs to access these credentials without human intervention. This creates a fundamental challenge: **if the server can decrypt credentials automatically, anyone with root access can too.**

On a typical VPS without hardware security modules (HSM) or Trusted Platform Module (TPM), we cannot achieve "unbreakable" credential storage. Instead, this tool implements **defense-in-depth** — multiple layers of security that make unauthorized access significantly harder.

### How Credentials Are Protected

```
┌─────────────────────────────────────────────────────────────┐
│                    Encryption Process                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│   /etc/machine-id ──────┐                                   │
│   (unique to server)     │                                   │
│                          ├──► SHA256 ──► Encryption Key     │
│   Random Salt ──────────┘                     │              │
│   (64 bytes)                                  │              │
│                                               ▼              │
│   Plain Credential ──► AES-256-CBC ──► Encrypted File       │
│                        (PBKDF2, 100k iterations)             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

1. **Machine-bound encryption**: The encryption key is derived from:
   - `/etc/machine-id` — unique identifier for each Linux installation
   - Random salt — 64 bytes generated during setup
   - Combined using SHA-256 hash
   
   This means credentials **only work on the original server**. Copying the encrypted files to another machine renders them useless.

2. **AES-256-CBC encryption**: Industry-standard encryption with:
   - PBKDF2 key derivation (100,000 iterations)
   - Random salt per encryption
   - Prevents brute-force attacks

3. **Obscured storage locations**:
   - Secrets stored in `/etc/.{random-12-chars}/` (e.g., `/etc/.a7x9m2k4q1/`)
   - Files named `.c1`, `.c2`, `.c3` instead of descriptive names
   - Not obvious what to look for

4. **Immutable file flags**: Files marked with `chattr +i`:
   - Prevents accidental deletion or modification
   - Even root must explicitly remove the flag first
   - Adds friction to unauthorized changes

5. **No command-line exposure**: Credentials are never passed as command arguments:
   - Won't appear in `ps aux` output
   - Won't be logged in shell history
   - Reduces exposure to process monitoring

### Protection Matrix

| Threat Vector | Protected? | How |
|---------------|------------|-----|
| Plain-text file discovery | ✅ Yes | All credentials encrypted |
| Stolen disk/backup image | ✅ Yes | Encrypted + machine-bound |
| Copied to another server | ✅ Yes | Different machine-id = different key |
| Casual browsing by unauthorized user | ✅ Yes | Random paths, obscured names |
| Process list snooping (`ps aux`) | ✅ Yes | No credentials in arguments |
| Accidental deletion | ✅ Yes | Immutable flags |
| Script kiddie attacks | ✅ Yes | Complexity barrier |
| **Experienced attacker with root** | ⚠️ Partial | See limitations below |

### Realistic Security Assessment

**What this DOES protect against:**

- ✅ **Opportunistic attacks**: Automated scanners looking for plain-text credentials in common locations (`/root/.my.cnf`, environment variables, etc.) will find nothing useful.

- ✅ **Low-skill attackers**: The multiple layers of obscurity (random directories, encrypted files, machine-binding) create significant barriers. Most attackers will move on to easier targets.

- ✅ **Credential reuse attacks**: Even if an attacker obtains the encrypted files, they cannot use them on another system or decrypt them offline without the machine-id.

- ✅ **Backup exposure**: If your server backup images are compromised, the credentials remain protected (encrypted + won't work elsewhere).

**What this CANNOT protect against:**

- ⚠️ **Determined attacker with root access**: An experienced threat actor with root access to your running server could:
  1. Read the backup-management script
  2. Understand the encryption scheme
  3. Extract machine-id and salt
  4. Derive the key and decrypt credentials
  
  This is a fundamental limitation — not a flaw in this tool. Any automated system that can decrypt credentials can be reverse-engineered by someone with the same access level.

- ⚠️ **Compromised server**: If your server is already compromised with a rootkit or persistent backdoor, no credential storage method will help.

- ⚠️ **Physical access**: Someone with physical access (or boot media access) to the server could potentially extract data.

### The Bottom Line

> **This tool raises the bar significantly, but it's not impenetrable.**

Think of it like a good lock on your door: it won't stop a determined burglar with specialized tools, but it will:
- Stop opportunistic thieves
- Make your server a less attractive target
- Buy you time to detect and respond to attacks
- Protect against accidental exposure

### Security Best Practices

To maximize security, also implement:

1. **Keep your server updated**: `apt update && apt upgrade`
2. **Use SSH keys** instead of passwords
3. **Enable a firewall**: `ufw enable`
4. **Use fail2ban** to block brute-force attempts
5. **Monitor access logs** regularly
6. **Limit root access** to trusted administrators only
7. **Enable 2FA** on your cloud storage provider
8. **Regular security audits** of your server

**Always maintain server security best practices.**

## Troubleshooting

### Common Issues

**"rclone not found"**
```bash
curl https://rclone.org/install.sh | sudo bash
```

**"Database connection failed"**
- Check if MySQL/MariaDB is running: `systemctl status mysql`
- Verify credentials are correct
- Try socket authentication (run setup without password)

**"Permission denied"**
- Ensure running as root: `sudo backup-management`

**"No backups found in remote storage"**
- Verify rclone remote is configured: `rclone listremotes`
- Check the path exists: `rclone ls remote:path`
- Ensure backups have been created first

### Logs

View backup logs:
```bash
# Via menu
backup-management → View logs

# Direct access
less /etc/backup-management/logs/db_logfile.log
less /etc/backup-management/logs/files_logfile.log
```

## Uninstalling

To completely remove the tool:

```bash
backup-management → Uninstall → Type 'UNINSTALL'
```

This removes:
- All scripts and configuration
- Secure credential storage
- Cron jobs
- The `backup-management` command

**Note**: Your backups in remote storage are NOT deleted.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Disclaimer

This script is provided "as is" without warranty of any kind. The author (Webnestify) is not responsible for any damages, data loss, or misuse arising from the use of this script. Always create a server snapshot before running backup/restore operations. Use at your own risk.

See [DISCLAIMER.md](DISCLAIMER.md) for full details.

## Support

- 🌐 Website: [webnestify.cloud](https://webnestify.cloud)
- 🐛 Issues: [GitHub Issues](https://github.com/wnstify/backup-management-tool/issues)
- 📖 Documentation: [USAGE.md](USAGE.md)

---

<p align="center">
  Made with ❤️ by <a href="https://webnestify.cloud">Webnestify</a>
</p>