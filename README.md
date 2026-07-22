# .scripts

Collection of utility scripts for AWS infrastructure management, backup automation, Cloudflare email routing, and OCI billing synchronization.  
**Version:** 4.0.11 | **Author:** Ivan Carlos | **License:** MIT

---

## 📁 Project Structure

```
.scripts/
├── LICENSE                                  # MIT License
├── manifest.json                            # Version & author metadata
├── rclone.sh                                # Standalone backup script (DB + web dirs → rclone)
│
├── README.md                                # This file — project overview
├── README-aws-lambda.md                     # AWS Lambda functions & IAM policies
├── README-backup-scripts.md                 # Linux backup & monitoring scripts
├── README-cloudflare-worker.md              # Cloudflare Workers for email routing
├── README-oci-scripting.md                  # OCI billing sync script
│
├── aws-lambda/                              # 7 Python Lambda functions + 8 IAM policies
├── backup-scripts/                          # 4 shell scripts for DB/web backup
├── cloudflare-worker/                       # 2 JS workers for email routing
└── oci-scripting/                           # 1 shell script for OCI billing sync
```

---

## 📂 Directory Overview

### ☁️ [`aws-lambda/`](README-aws-lambda.md)

Python Lambda functions (runtime 3.13+) for AWS account management, invoked by **n8n** workflows.

| # | Function | Purpose |
|---|----------|---------|
| 1 | `addtag` | Propagates `Tenant` tags across AMIs, EBS volumes/snapshots, ENIs, EIPs, KMS keys, and Route53 zones |
| 2 | `backup-alert` | Reports failed/expired AWS Backup jobs from the last 24 hours |
| 3 | `counting` | Counts EC2 instances (by SKU) and Route53 zones grouped by `Tenant` tag |
| 4 | `dailyusage` | Daily AWS cost breakdown by tenant and usage type via Cost Explorer |
| 5 | `monthlyusage` | Monthly AWS cost breakdown by tenant and service via Cost Explorer |
| 6 | `route53-bind` | Exports all Route53 hosted zones as BIND zone file format |
| 7 | `s3-to-backblaze` | Copies all S3 buckets to Backblaze B2 with timestamps and exclusions |

📖 See **[README-aws-lambda.md](README-aws-lambda.md)** for full function details, IAM policy mappings, and remote invocation setup.

---

### 💾 [`backup-scripts/`](README-backup-scripts.md)

Shell scripts for Linux server backup automation.

| # | Script | Purpose |
|---|--------|---------|
| 1 | `rclone.sh` | Full backup: DB dump → tar.gz → rclone upload → retention enforcement |
| 2 | `bkppostgres.sh` | Docker Postgres full dump (`pg_dumpall`) with local retention |
| 3 | `checkbackup.sh` | Monitors rclone buckets for freshness, sends SES alerts if outdated |
| 4 | `.dbpassword.cnf` | MySQL/MariaDB credential file for `mariadb-dump` |

📖 See **[README-backup-scripts.md](README-backup-scripts.md)** for configuration variables, database support, requirements, and cron setup.

---

### 🌐 [`cloudflare-worker/`](README-cloudflare-worker.md)

JavaScript Cloudflare Workers for **email routing** on domains using Cloudflare Email Routing.

| # | Worker | Strategy |
|---|--------|----------|
| 1 | `worker-bounce-unknown-and-administrative.js` | Forwards admin/security aliases; **rejects** all unknown recipients |
| 2 | `worker-catch-all-and-administrative.js` | Forwards admin/security aliases; **catch-all** forwards everything else |

📖 See **[README-cloudflare-worker.md](README-cloudflare-worker.md)** for deployment instructions, customization, and use cases.

---

### 🗄️ [`oci-scripting/`](README-oci-scripting.md)

Shell scripts for Oracle Cloud Infrastructure (OCI) automation.

| # | Script | Purpose |
|---|--------|---------|
| 1 | `sync_billing.sh` | Downloads OCI billing files from Object Storage with incremental sync and local retention cleanup |

📖 See **[README-oci-scripting.md](README-oci-scripting.md)** for requirements (OCI CLI, jq), configuration, and cron setup.

---

## 🔧 Root Files

| File | Description |
|------|-------------|
| [`LICENSE`](LICENSE) | MIT License (Copyright © 2025 Ivan Carlos de Almeida) |
| [`manifest.json`](manifest.json) | Version (`4.0.11`) and author metadata |
| [`rclone.sh`](rclone.sh) | Standalone backup — dumps DB, compresses web dirs, uploads to rclone remote with retention |

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
