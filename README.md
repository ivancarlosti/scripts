# .scripts

Collection of utility scripts for AWS infrastructure management, backup automation, Cloudflare email routing, OCI billing synchronization, Linux server setup and hardening, and read-only Linux/Windows system reporting.  
**Version:** 4.17.0 | **Author:** Ivan Carlos | **License:** MIT

---

## 📁 Project Structure

```
.scripts/
├── LICENSE                                  # MIT License
├── manifest.json                            # Version & author metadata
│
├── README.md                                # This file — project overview
├── .dockerignore                            # Excludes docs/, plans/, docker/, .github/
│
├── docs/                                    # Detailed documentation, one file per module
│   ├── aws-lambda.md                        # AWS Lambda functions & IAM policies
│   ├── backup-scripts.md                    # Linux backup & monitoring scripts
│   ├── cloudflare-worker.md                 # Cloudflare Workers for email routing
│   ├── computerinfo-scripts.md              # Linux & Windows system report scripts
│   ├── linux-scripts.md                     # Linux server setup & hardening scripts
│   └── oci-scripting.md                     # OCI billing sync script
│
├── plans/                                   # Implementation plans (yyyy-mm-dd-name.md)
│
├── aws-lambda/                              # 7 Python Lambda functions + 8 IAM policies
├── backup-scripts/                          # 4 shell scripts for DB/web backup
├── cloudflare-worker/                       # 2 JS workers for email routing
├── computerinfo-scripts/                    # Linux & Windows system report scripts
├── linux-scripts/                           # 7 shell scripts for server setup & hardening
└── oci-scripting/                           # 1 shell script for OCI billing sync
```

---

## 📂 Directory Overview

### ☁️ [`aws-lambda/`](aws-lambda/)

Python Lambda functions (runtime 3.13+) for AWS account management, invoked by **n8n** workflows.

| # | Function | Purpose |
|---|----------|---------|
| 1 | `addtag` | Propagates `Tenant` tags across AMIs, EBS volumes/snapshots, ENIs, EIPs, KMS keys, and Route53 zones |
| 2 | `backup-alert` | Reports failed/expired AWS Backup jobs from the last 24 hours |
| 3 | `counting` | Counts EC2 instances (by SKU) and Route53 zones grouped by `Tenant` tag |
| 4 | `dailyusage` | Daily AWS cost breakdown by tenant and usage type via Cost Explorer |
| 5 | `monthlyusage` | Monthly AWS cost breakdown by tenant and service via Cost Explorer |
| 6 | `route53-bind` | Exports all Route53 hosted zones as BIND zone file format |
| 7 | `s3-to-backblaze` | Chunked, resumable copy of all S3 buckets to Backblaze B2, with incremental skips and optional versioning/lifecycle hardening |

📖 See **[docs/aws-lambda.md](docs/aws-lambda.md)** for full function details, IAM policy mappings, and remote invocation setup.

---

### 💾 [`backup-scripts/`](backup-scripts/)

Shell scripts for Linux server backup automation.

| # | Script | Purpose |
|---|--------|---------|
| 1 | `rclone.sh` | Full backup: DB dump → tar.gz → rclone upload → retention enforcement |
| 2 | `bkppostgres.sh` | Docker Postgres full dump (`pg_dumpall`) with local retention |
| 3 | `checkbackup.sh` | Monitors rclone buckets for freshness, sends SES alerts if outdated |
| 4 | `.dbpassword.cnf` | MySQL/MariaDB credential file for `mariadb-dump` |

📖 See **[docs/backup-scripts.md](docs/backup-scripts.md)** for configuration variables, database support, requirements, and cron setup.

---

### 🌐 [`cloudflare-worker/`](cloudflare-worker/)

JavaScript Cloudflare Workers for **email routing** on domains using Cloudflare Email Routing.

| # | Worker | Strategy |
|---|--------|----------|
| 1 | `worker-bounce-unknown-and-administrative.js` | Forwards admin/security aliases; **rejects** all unknown recipients |
| 2 | `worker-catch-all-and-administrative.js` | Forwards admin/security aliases; **catch-all** forwards everything else |

📖 See **[docs/cloudflare-worker.md](docs/cloudflare-worker.md)** for deployment instructions, customization, and use cases.

---

### 🖥️ [`computerinfo-scripts/`](computerinfo-scripts/)

Read-only system report scripts for Linux and Windows: OS, CPU, memory, disk usage, uptime, load averages and network addressing — plus antivirus and Secure Boot state on Windows. Nothing is installed, changed or written, and no administrator rights are required.

| # | Script | Purpose |
|---|--------|---------|
| 1 | `linuxcomputeinfo.sh` | Linux host report: OS, kernel, CPU and memory usage, disk totals and per-mount usage, uptime, load averages, local and public IPv4/IPv6 |
| 2 | `windowscomputeinfo.ps1` | Windows host report: OS and build, hardware, RAM, physical and logical disks, registered antivirus products, Secure Boot state and mode |
| 3 | `windowscomputeinfo.cmd` | Double-click launcher that runs the report with `-ExecutionPolicy Bypass` and keeps the window open |

Scripts can be run remotely with:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/linuxcomputeinfo.sh | bash
```

```powershell
irm https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/windowscomputeinfo.ps1 | iex
```

📖 See **[docs/computerinfo-scripts.md](docs/computerinfo-scripts.md)** for per-script field sources, switches (`-SkipAntivirus`, `-SkipSecureBoot`, `SKIP_PUBLIC_IP=1`), requirements, and local setup.

---

### 🐧 [`linux-scripts/`](linux-scripts/)

Shell scripts for setting up and hardening Linux servers (Debian/Ubuntu).

| # | Script | Purpose |
|---|--------|---------|
| 1 | `server-prep.sh` | Refreshes packages, upgrades the system, and installs a baseline toolset (`curl`, `wget`, `sudo`, `cron`, `nano`, `fail2ban`) |
| 2 | `redis-setup.sh` | Applies Redis-recommended kernel settings (`vm.overcommit_memory`, `net.ipv4.ip_nonlocal_bind`) |
| 3 | `disable-services.sh` | Disables and stops unused services (outdated PHP-FPM, memcached, postfix, proftpd, ufw, varnish) |
| 4 | `cloudpanel-fix.sh` | Hardens nginx on CloudPanel |
| 5 | `fail2ban-setup.sh` | Configures Fail2Ban — with optional Cloudflare firewall banning, or local-only when no credentials are passed — installs generated nginx/CloudPanel web jails that ban probes, failed logins, enumeration and known scanners, and adds an OpenVPN jail (all ports, TCP+UDP) when an OpenVPN server is detected |
| 6 | `dashboard-domain.sh` | Points the CloudPanel admin panel at a custom domain, registers it with CloudPanel (Settings → "Domain Name" and its renewal cron) and has CloudPanel issue a Let's Encrypt certificate for it |
| 7 | `fail2ban-ui-ssh-user.sh` | Provisions the locked-down, key-only SSH account the [Fail2Ban UI](https://github.com/swissmakers/fail2ban-ui) uses to manage this host, prints its RSA private key and grants it nothing beyond `fail2ban-client`, a Fail2Ban restart and ACL access to `/etc/fail2ban` |

Scripts can be run remotely with:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/<script>.sh | sudo bash
```

📖 See **[docs/linux-scripts.md](docs/linux-scripts.md)** for per-script details, requirements, and remote execution instructions.

---

### 🗄️ [`oci-scripting/`](oci-scripting/)

Shell scripts for Oracle Cloud Infrastructure (OCI) automation.

| # | Script | Purpose |
|---|--------|---------|
| 1 | `sync_billing.sh` | Downloads OCI billing files from Object Storage with incremental sync and local retention cleanup |

📖 See **[docs/oci-scripting.md](docs/oci-scripting.md)** for requirements (OCI CLI, jq), configuration, and cron setup.

<!-- footer -->
---

## 🧑‍💻 Consulting and technical support
* For personal support and queries, please submit a new issue to have it addressed.
* For commercial related questions, please [**contact me**][ivancarlos] for consulting costs.

[cc]: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/adding-a-code-of-conduct-to-your-project
[contributing]: https://docs.github.com/en/articles/setting-guidelines-for-repository-contributors
[security]: https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository
[support]: https://docs.github.com/en/articles/adding-support-resources-to-your-project
[it]: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository#configuring-the-template-chooser
[prt]: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository
[funding]: https://docs.github.com/en/articles/displaying-a-sponsor-button-in-your-repository
[ivancarlos]: https://ivancarlos.me
