# Usage Guide

Complete usage documentation for **Backup Management Tool** by Webnestify.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Main Menu](#main-menu)
- [Setup Wizard](#setup-wizard)
- [Running Backups](#running-backups)
- [Restoring Backups](#restoring-backups)
- [Managing Schedules](#managing-schedules)
- [Viewing Status & Logs](#viewing-status--logs)
- [Command Line Usage](#command-line-usage)
- [Advanced Configuration](#advanced-configuration)
- [Best Practices](#best-practices)

---

## Prerequisites

Before running the Backup Management Tool, ensure you have the following:

### Required (install manually)

```bash
# Install pigz (parallel gzip - required for compression)
sudo apt update && sudo apt install pigz -y
```

### Auto-installed by the script

The following will be **automatically installed** if missing:
- **rclone** - for remote cloud storage

### Usually pre-installed

These packages are typically already available on most Linux systems:
- `openssl` - credential encryption
- `gpg` - backup encryption  
- `tar` - archive creation
- `curl` - notifications

### Verify prerequisites

```bash
# Check if pigz is installed
which pigz || echo "pigz NOT installed - run: sudo apt install pigz"

# Check other tools (usually pre-installed)
which openssl gpg tar curl
```

---

## Getting Started

### First Run

After installation, run the tool:

```bash
sudo backup-management
```

On first run, you'll see the disclaimer and welcome screen:

```
========================================================
       Backup Management Tool v1.0.0
                  by Webnestify
========================================================

┌────────────────────────────────────────────────────────┐
│                      DISCLAIMER                        │
├────────────────────────────────────────────────────────┤
│ This tool is provided "as is" without warranty.        │
│ The author is NOT responsible for any damages or       │
│ data loss. Always create a server SNAPSHOT before      │
│ running backup/restore operations. Use at your risk.   │
└────────────────────────────────────────────────────────┘

Welcome! This tool needs to be configured first.

  1. Run setup wizard
  2. Exit

Select option [1-2]:
```

Select **1** to begin the setup wizard.

---

## Main Menu

After configuration, you'll see the main menu:

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

Select option [1-8]:
```

### Menu Options

| Option | Description |
|--------|-------------|
| **1. Run backup now** | Manually trigger database and/or file backups |
| **2. Restore from backup** | Restore databases or files from existing backups |
| **3. View status** | Display current configuration and system status |
| **4. View logs** | View backup logs for troubleshooting |
| **5. Manage schedules** | Add, modify, or remove cron schedules |
| **6. Reconfigure** | Run the setup wizard again |
| **7. Uninstall** | Remove the tool completely |
| **8. Exit** | Exit the application |

---

## Setup Wizard

The setup wizard guides you through initial configuration.

### Step 1: Backup Type Selection

```
Step 1: Backup Type Selection
-----------------------------
What would you like to back up?
1. Database only
2. Files only (WordPress sites)
3. Both Database and Files
Select option [1-3]:
```

**Recommendations:**
- Choose **3 (Both)** for complete protection
- Choose **1 (Database only)** if files are managed separately
- Choose **2 (Files only)** if databases are managed separately

### Step 2: Encryption Password

```
Step 2: Encryption Password
---------------------------
Your backups will be encrypted with AES-256.
Enter encryption password:
Confirm encryption password:
```

**Important:**
- Use a strong, unique password
- **Store this password securely** - you'll need it to restore backups
- This password encrypts your database backups
- Credentials are stored with a different machine-bound encryption

### Step 3: Database Authentication

```
Step 3: Database Authentication
--------------------------------
On many systems, root can access MySQL/MariaDB via socket authentication.

Do you need to use a password for database access? (y/N):
```

**Options:**

1. **Socket Authentication (Recommended)**
   - Press Enter or type `N`
   - Works if you can run `mysql` without a password as root
   - More secure - no password stored

2. **Password Authentication**
   - Type `Y`
   - Enter your database root password
   - Password is encrypted and stored securely

### Step 4: Remote Storage (rclone)

```
Step 4: Remote Storage (rclone)
--------------------------------
Available rclone remotes:
b2:
s3:
gdrive:

Enter remote name (without colon): b2
Enter path for database backups (e.g., backups/db): myserver/db-backups
Enter path for files backups (e.g., backups/files): myserver/file-backups
```

**Note:** If rclone is not installed, the setup wizard will automatically install it for you and prompt you to configure a remote.

**Prerequisites:**
- At least one rclone remote must be configured
- If no remotes exist, the wizard will launch `rclone config` for you

**Manual rclone configuration (if needed):**
```bash
# Configure a remote
rclone config
```

### Step 5: Notifications (Optional)

```
Step 5: Notifications (optional)
---------------------------------
Set up ntfy notifications? (y/N): y
Enter ntfy topic URL (e.g., https://ntfy.sh/mytopic): https://ntfy.sh/my-backups
Do you have an ntfy auth token? (y/N):
```

**ntfy.sh Setup:**
1. Go to [ntfy.sh](https://ntfy.sh)
2. Create a unique topic name
3. Install the ntfy app on your phone
4. Subscribe to your topic

### Step 6: Script Generation

The wizard generates all backup and restore scripts automatically.

```
Step 6: Generating Backup Scripts
----------------------------------
✓ Database backup script generated
✓ Database restore script generated
✓ Files backup script generated
✓ Files restore script generated
```

### Step 7: Schedule Backups

```
Step 7: Schedule Backups
------------------------
Schedule automatic database backups? (Y/n): y

Select schedule for database backup:
1. Hourly
2. Every 2 hours
3. Every 6 hours
4. Daily (at midnight)
5. Weekly (Sunday at midnight)
6. Custom cron expression

Select option [1-6]:
```

**Recommended Schedules:**

| Backup Type | Recommendation | Cron |
|-------------|----------------|------|
| Database | Hourly | `0 * * * *` |
| Files | Daily (3 AM) | `0 3 * * *` |

---

## Running Backups

### From Main Menu

```
Run Backup
==========

1. Run database backup
2. Run files backup
3. Run both (database + files)
4. Back to main menu

Select option [1-4]:
```

### Manual Backup Progress

**Database Backup:**
```
==== 2025-01-15 03:00:01 START per-db backup ====
  → Dumping: wordpress_site1
    OK: wordpress_site1
  → Dumping: wordpress_site2
    OK: wordpress_site2
Archive verified.
Uploaded to b2:myserver/db-backups
==== 2025-01-15 03:00:45 END (success) ====
```

**Files Backup:**
```
==== 2025-01-15 03:00:01 START files backup ====
[FILES-BACKUP] Scanning /var/www...
[FILES-BACKUP] [site1.com] Archiving...
[FILES-BACKUP] [site1.com] Uploading...
[FILES-BACKUP] [site2.com] Archiving...
[FILES-BACKUP] [site2.com] Uploading...
==== 2025-01-15 03:05:32 END (success) ====
```

### Direct Script Execution

You can also run backup scripts directly:

```bash
# Database backup
/etc/backup-management/scripts/db_backup.sh

# Files backup
/etc/backup-management/scripts/files_backup.sh
```

---

## Restoring Backups

### Database Restoration

```
========================================================
           Database Restore Utility
========================================================

Step 1: Encryption Password
----------------------------
Enter backup encryption password: ********

Step 2: Select Backup
---------------------
[DB-RESTORE] Fetching backups from b2:myserver/db-backups...
[DB-RESTORE] Found 5 backup(s).

   1) myserver-db_backups-2025-01-15-0300.tar.gz.gpg
   2) myserver-db_backups-2025-01-14-0300.tar.gz.gpg
   3) myserver-db_backups-2025-01-13-0300.tar.gz.gpg

Select backup [1-5]:
```

**Step 3: Select Databases**
```
Step 3: Select Databases
------------------------
   1) wordpress_site1
   2) wordpress_site2
   3) woocommerce_db
  A) All databases
  Q) Quit

Selection: 1,2
```

**Confirmation:**
```
Restoring 2 database(s)...
Confirm? (yes/no): yes

Restoring: wordpress_site1
  ✓ Success
Restoring: wordpress_site2
  ✓ Success

Restore complete!
```

### Files Restoration

```
========================================================
           Files Restore Utility
========================================================

Step 1: Select Backup
---------------------
[FILES-RESTORE] Fetching backups from b2:myserver/file-backups...
[FILES-RESTORE] Found 3 backup(s).

   1) https__site1.com-2025-01-15-0300.tar.gz
   2) https__site2.com-2025-01-15-0300.tar.gz
  Q) Quit

Select backup [1-2]:
```

**Step 2: Select Sites**
```
Step 2: Select Sites
--------------------
   1) [EXISTS]   site1.com
   2) [NEW]      site3.com
  A) All sites
  Q) Quit

Selection: 1
```

**Safety Features:**
- Existing sites are backed up before overwriting
- If restore fails, original is automatically restored
- Clear labeling of existing vs. new sites

---

## Managing Schedules

```
Manage Backup Schedules
=======================

Current Schedules:

✓ Database: 0 * * * *
✓ Files: 0 3 * * *

Options:
1. Set/change database backup schedule
2. Set/change files backup schedule
3. Remove database backup schedule
4. Remove files backup schedule
5. Back to main menu

Select option [1-5]:
```

### Schedule Options

| Option | Cron Expression | Description |
|--------|-----------------|-------------|
| Hourly | `0 * * * *` | Every hour at :00 |
| Every 2 hours | `0 */2 * * *` | Every 2 hours at :00 |
| Every 6 hours | `0 */6 * * *` | At 00:00, 06:00, 12:00, 18:00 |
| Daily | `0 0 * * *` | Daily at midnight |
| Weekly | `0 0 * * 0` | Sundays at midnight |
| Custom | Your expression | Any valid cron expression |

### Custom Cron Examples

```
# Every 30 minutes
*/30 * * * *

# At 3:30 AM daily
30 3 * * *

# Every Monday and Thursday at 2 AM
0 2 * * 1,4

# First day of every month at 4 AM
0 4 1 * *
```

---

## Viewing Status & Logs

### System Status

```
System Status
=============

✓ Configuration: COMPLETE
✓ Secure storage: /etc/.a7x9m2k4q1

Backup Scripts:
✓ Database backup script
✓ Files backup script

Restore Scripts:
✓ Database restore script
✓ Files restore script

Scheduled Backups:
✓ Database backup cron: 0 * * * *
✓ Files backup cron: 0 3 * * *

Remote Storage:
✓ Remote: b2
        Database path: myserver/db-backups
        Files path: myserver/file-backups

Recent Backup Activity:
  Last DB backup: 2025-01-15 03:00
  Last Files backup: 2025-01-15 03:00

───────────────────────────────────────────────────────
  Webnestify | https://webnestify.cloud
───────────────────────────────────────────────────────
```

### Viewing Logs

```
View Logs
=========

1. Database backup log
2. Files backup log
3. Back to main menu

Select option [1-3]:
```

Logs are displayed using `less` for easy navigation:
- Use arrow keys to scroll
- Press `q` to quit
- Press `/` to search
- Press `G` to go to end

---

## Command Line Usage

### Basic Commands

```bash
# Run the interactive menu
backup-management

# The tool must be run as root
sudo backup-management
```

### Direct Script Access

For automation or scripting, access the generated scripts directly:

```bash
# Run database backup
/etc/backup-management/scripts/db_backup.sh

# Run files backup
/etc/backup-management/scripts/files_backup.sh

# Run database restore (interactive)
/etc/backup-management/scripts/db_restore.sh

# Run files restore (interactive)
/etc/backup-management/scripts/files_restore.sh
```

### Log File Locations

```bash
# Database backup log
/etc/backup-management/logs/db_logfile.log

# Files backup log
/etc/backup-management/logs/files_logfile.log

# Tail logs in real-time
tail -f /etc/backup-management/logs/db_logfile.log
```

---

## Advanced Configuration

### Manual Configuration File

Configuration is stored in `/etc/backup-management/.config`:

```bash
DO_DATABASE="true"
DO_FILES="true"
RCLONE_REMOTE="b2"
RCLONE_DB_PATH="myserver/db-backups"
RCLONE_FILES_PATH="myserver/file-backups"
```

### Secure Credentials Location

The path to encrypted credentials is stored in:
```
/etc/backup-management/.secrets_location
```

This points to a randomly-named directory like `/etc/.a7x9m2k4q1/`

### Modifying Backup Scripts

The generated scripts are fully customizable:

```bash
# Database backup script
/etc/backup-management/scripts/db_backup.sh

# Files backup script
/etc/backup-management/scripts/files_backup.sh
```

**Common Modifications:**

1. **Exclude specific databases:**
   ```bash
   EXCLUDE_REGEX='^(information_schema|performance_schema|sys|mysql|test_db)$'
   ```

2. **Change WWW directory:**
   ```bash
   WWW_DIR="/home/websites"
   ```

3. **Exclude directories from file backup:**
   Add `--exclude` flags to the tar command

---

## Best Practices

### Before You Start

1. **Create a server snapshot** before any restore operation
2. **Test your backups** regularly by doing test restores
3. **Store encryption password** in a secure password manager
4. **Monitor notifications** to catch backup failures early

### Backup Strategy

| Data Type | Frequency | Retention |
|-----------|-----------|-----------|
| Databases | Hourly | 7 days |
| Files | Daily | 30 days |
| Full snapshot | Weekly | 90 days |

### Security Recommendations

1. **Limit SSH access** to your server
2. **Use strong passwords** for encryption
3. **Enable 2FA** on your cloud storage provider
4. **Regularly rotate** cloud storage credentials
5. **Monitor backup logs** for anomalies

### Disaster Recovery Plan

1. Document your rclone remote configuration
2. Store encryption password securely (not on the server)
3. Test restore procedure quarterly
4. Keep a local copy of backup-management.sh
5. Document your server configuration

### Storage Management

Set up lifecycle rules on your cloud storage:
- Delete database backups older than 7-14 days
- Delete file backups older than 30-60 days
- Move older backups to cold storage for cost savings

---

## Troubleshooting

### Backup Failures

**Check logs first:**
```bash
tail -100 /etc/backup-management/logs/db_logfile.log
tail -100 /etc/backup-management/logs/files_logfile.log
```

**Common issues:**

1. **rclone errors**: Run `rclone ls remote:path` to test connectivity
2. **Database errors**: Check MySQL is running with `systemctl status mysql`
3. **Permission errors**: Ensure running as root
4. **Disk space**: Check with `df -h`

### Restore Failures

1. **Wrong password**: Double-check your encryption password
2. **Corrupted backup**: Try an older backup
3. **Network issues**: Check rclone connectivity

### Getting Help

1. Check the logs in `/etc/backup-management/logs/`
2. Run `rclone` commands manually to test
3. Review [GitHub Issues](https://github.com/webnestify/backup-management/issues)
4. Contact support at [webnestify.cloud](https://webnestify.cloud)

---

<p align="center">
  <strong>Backup Management Tool</strong> by <a href="https://webnestify.cloud">Webnestify</a>
</p>