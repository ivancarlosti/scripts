# OCI Scripting

Shell scripts for automating Oracle Cloud Infrastructure (OCI) operations.

---

## 📋 Scripts

### [`sync_billing.sh`](sync_billing.sh)
**Purpose:** Downloads OCI billing files from OCI Object Storage to a local directory with date-based filtering and automatic cleanup.

**Workflow:**
1. Lists all objects in the configured OCI billing bucket using `oci os object list`.
2. Filters objects by modification date, keeping only those modified within the last `FETCH_DAYS_AGO` (default: 7 days), using `jq`.
3. Skips files that already exist locally (incremental sync).
4. Downloads new/missing files to the local destination, preserving directory structure.
5. Cleans up local files older than `RETAIN_DAYS` (default: 45 days).
6. Removes empty directories after cleanup.

**Configuration variables (edit inline):**

| Variable | Purpose |
|----------|---------|
| `SYSTEM_USER` | Linux username executing the script (used for home directory paths) |
| `BILLING_NAMESPACE` | OCI Object Storage namespace |
| `BILLING_BUCKET` | OCI bucket name/OCID containing billing files |
| `DEST_DIR` | Local destination directory for downloaded files |
| `FETCH_DAYS_AGO` | How many days back to look for modified files (default: 7) |
| `RETAIN_DAYS` | How many days to keep local files before deletion (default: 45) |

**Cron compatibility:**
- Explicitly sets `PATH` to include `/usr/local/bin`, `/usr/bin`, `/bin`, and the user's `~/bin` — required because cron runs with a minimal environment.
- Uses absolute paths for destination directory resolution.

---

## 📦 Requirements

| Dependency | Purpose |
|------------|---------|
| [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm) | Installed and configured with valid credentials (`oci setup config`) |
| [jq](https://stedolan.github.io/jq/) | JSON parsing for filtering object lists by date |
| Linux Server | Execution environment |

---

## 🚀 Setup

1. **Install OCI CLI:**
   ```bash
   bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
   ```

2. **Configure OCI credentials:**
   ```bash
   oci setup config
   ```

3. **Install jq:**
   ```bash
   sudo apt install jq   # Debian/Ubuntu
   sudo yum install jq   # RHEL/CentOS
   ```

4. **Make executable:**
   ```bash
   chmod +x sync_billing.sh
   ```

5. **Schedule via cron** (example: daily at 03:00):
   ```bash
   crontab -e
   ```
   ```
   0 3 * * * /home/n8nbilling/oci-scripting/sync_billing.sh >/dev/null 2>&1
   ```

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
