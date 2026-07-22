# Backup Scripts

Shell scripts for automating Linux server backups — database dumps, web directory compression, offsite transfer via rclone, and bucket freshness monitoring with email alerts.

---

## 📋 Scripts

### [`rclone.sh`](rclone.sh)
**Purpose:** Full backup workflow: dump database → compress → upload to remote → enforce retention.

**Workflow:**
1. Dumps a **MariaDB/MySQL** database (or optionally Postgres) to a `.sql` file.
2. Compresses the dump into a timestamped `.tar.gz` archive.
3. Compresses one or more **web directories** into separate `.tar.gz` archives.
4. Moves all archives to a remote rclone destination (e.g., Backblaze B2).
5. Deletes remote files older than the configured retention period (default: 7 days) using `rclone delete --min-age`.

**Configuration variables (edit inline):**

| Variable | Purpose |
|----------|---------|
| `DATABASE` | Database name to dump |
| `USER` | Database username with read access |
| `RCLONEREMOTE` | rclone remote name (configured via `rclone config`) |
| `BUCKET` | Destination bucket/path on the remote |
| `WEBDIR1` / `WEBFOLDER1` | Path prefix and folder name for the first web directory |
| `WEBDIR2` / `WEBFOLDER2` | (Optional) Path prefix and folder name for a second web directory |
| `RETENTION` | Age threshold for remote file deletion (e.g., `7d`) |
| `PGPASSWORD` | (Optional) Postgres password if using Postgres instead of MariaDB |

**Database support:**
- **MariaDB/MySQL:** Uses `mariadb-dump` (or `mysqldump`) with credentials from [`.dbpassword.cnf`](.dbpassword.cnf).
- **Postgres:** Commented out by default — uses `pg_dump` with `PGPASSWORD` environment variable.

---

### [`bkppostgres.sh`](bkppostgres.sh)
**Purpose:** Backs up an entire **Postgres instance running in Docker** using `pg_dumpall`.

**Workflow:**
1. Runs `pg_dumpall` inside the specified Docker container to dump all databases.
2. Compresses the dump into a timestamped `.tar.gz` archive.
3. Deletes local archives older than the configured retention period (default: 3 days).
4. Sets file permissions to `0600` for security.

**Configuration variables:**

| Variable | Purpose |
|----------|---------|
| `DOCKERNAME` | Docker container name running Postgres |
| `PGUSER` | Postgres user with `pg_dumpall` access (usually `postgres`) |
| `RELATPATH` | Relative path where backup files are stored (e.g., `/backups`) |
| `RETDAYS` | Number of days to retain local backup files before deletion |

---

### [`checkbackup.sh`](checkbackup.sh)
**Purpose:** Monitors rclone remote buckets for backup freshness and sends alerts via Amazon SES.

**Workflow:**
1. Iterates over a configured list of `repo:bucket` pairs.
2. Runs `rclone lsl --max-age 2d` on each to check for recent files.
3. If no files are found within the threshold (default: 2 days), sends an **Amazon SES email** alert with the bucket name and a warning message.

**Configuration variables:**

| Variable | Purpose |
|----------|---------|
| `BUCKET_PATHS` | Array of `"remote:bucket"` strings to monitor |
| `DAYS_THRESHOLD` | Max allowed age since last backup (default: 2 days) |
| `MAILFROM` | Sender email address for SES alerts |
| `MAILTO` | Recipient email address for SES alerts |

---

### [`.dbpassword.cnf`](.dbpassword.cnf)
**Purpose:** MySQL/MariaDB credential file used by `rclone.sh` via `--defaults-extra-file`.

**Contents:**
```ini
[mysqldump]
password="yourdbpassword"
```

**⚠️ Security:** Lock down permissions: `chmod 0600 .dbpassword.cnf`

---

## 🚀 Setup Instructions

1. **Make scripts executable:**
   ```bash
   chmod +x rclone.sh bkppostgres.sh checkbackup.sh
   ```

2. **Configure credentials** for MariaDB/MySQL:
   ```bash
   nano .dbpassword.cnf
   chmod 0600 .dbpassword.cnf
   ```

3. **Schedule via cron** (example: run daily at 02:00):
   ```bash
   crontab -e
   ```
   ```
   0 2 * * * cd /home/username/backup-scripts; ./rclone.sh >/dev/null 2>&1
   ```

---

## 📦 Requirements

| Dependency | Purpose |
|------------|---------|
| Linux Server | Execution environment |
| MariaDB / MySQL / Postgres | Database to back up (optional) |
| Docker | Required for `bkppostgres.sh` |
| [rclone](https://rclone.org/) | Offsite backup transfer (optional) |
| Backblaze B2 (or other rclone-supported storage) | Offsite backup destination (optional) |
| [AWS CLI](https://aws.amazon.com/cli/) | Required for `checkbackup.sh` SES email sending |
| Amazon SES (configured) | Email delivery for backup alerts |

---

## 📖 Additional Resources

- [Setting up a script to notify by email that a repository in Rclone is without a recent backup](https://suporte.ivancarlos.com.br/hc/pt-br/articles/25861271868301)
- [Configuring Rclone to send backup to its destination](https://suporte.ivancarlos.com.br/hc/pt-br/articles/25731464664461)

---

<!-- footer -->
---

## 🧑‍💻 Consulting and technical support

- For personal support and queries, please submit a new issue to have it addressed.
- For commercial related questions, please [**contact me**][ivancarlos] for consulting costs.

| 🩷 Project support |
| :---: |
| If you found this project helpful, consider [**buying me a coffee**][buymeacoffee] |
| Thanks for your support, it is much appreciated! |

[ivancarlos]: https://ivancarlos.me
[buymeacoffee]: https://www.buymeacoffee.com/ivancarlos
