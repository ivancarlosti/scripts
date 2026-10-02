# Linux Scripts

Shell scripts for setting up and hardening Linux servers — baseline package installation, kernel tuning for Redis, disabling unused services, and nginx/Fail2Ban hardening. Every script is idempotent and safe to re-run.

---

## 🚀 Remote execution

Every script can be executed straight from GitHub without cloning the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/<script>.sh | sudo bash
```

For example, to prepare a fresh server:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/server-prep.sh | sudo bash
```

> **Note:** the scripts call `sudo` internally, so piping to `sudo bash` (as shown) is recommended. Review the script content before running it on a production host.

---

## 📋 Scripts

### [`server-prep.sh`](linux-scripts/server-prep.sh)
**Purpose:** Baseline preparation of a freshly provisioned Debian/Ubuntu server.

**Workflow:**
1. Refreshes the package index (`apt-get update`).
2. Upgrades all installed packages (`apt-get -y upgrade`).
3. Installs a baseline toolset: `curl`, `wget`, `sudo`, `cron`, `nano`, `fail2ban`.
4. Runs with `DEBIAN_FRONTEND=noninteractive` so the upgrade never blocks on a prompt.

**Configuration variables (edit inline):**

| Variable | Purpose |
|----------|---------|
| `PACKAGES` | Array of packages installed on every host |

---

### [`redis-setup.sh`](linux-scripts/redis-setup.sh)
**Purpose:** Applies the kernel settings Redis recommends for stable persistence and cluster operation.

**Settings applied** (written to `/etc/sysctl.conf`, existing values replaced in place):

| Setting | Value | Why Redis needs it |
|---------|-------|--------------------|
| `vm.overcommit_memory` | `1` | Allows the `fork()` used by `BGSAVE` / `BGREWRITEAOF` to succeed even when free memory is low |
| `net.ipv4.ip_nonlocal_bind` | `1` | Lets `redis-server` bind to addresses not yet present on the host (Redis Cluster) |

**Workflow:**
1. Replaces or appends each setting in `/etc/sysctl.conf` (idempotent).
2. Applies the changes immediately with `sysctl -p`.

**Configuration variables (edit inline):**

| Variable | Purpose |
|----------|---------|
| `SYSCTL_FILE` | Path to the sysctl configuration file (default: `/etc/sysctl.conf`) |

---

### [`disable-services.sh`](linux-scripts/disable-services.sh)
**Purpose:** Disables and stops services that are not needed on a typical web/application server, reducing resource usage and attack surface.

**Services disabled:**

| Service | Typically disabled because |
|---------|----------------------------|
| `php7.1-fpm`, `php7.2-fpm`, `php7.3-fpm` | Outdated PHP versions replaced by a newer one |
| `memcached` | Cache not used by the application |
| `postfix` | Local mail transfer agent not required |
| `proftpd` | FTP server replaced by SFTP |
| `ufw` | Firewall managed elsewhere (e.g. cloud security groups) |
| `varnish` | HTTP accelerator not in use |

**Workflow:**
1. Iterates over the `SERVICES` array.
2. Skips any service that is not installed.
3. Runs `systemctl disable <service> --now` for the rest (disables at boot **and** stops it immediately).

**Configuration variables (edit inline):**

| Variable | Purpose |
|----------|---------|
| `SERVICES` | Array of systemd unit names to disable and stop |

---

### [`cloudpanel-fix.sh`](linux-scripts/cloudpanel-fix.sh)
**Purpose:** Hardens nginx on CloudPanel and integrates Fail2Ban with Cloudflare's firewall.

**Workflow:**
1. Detects the installed nginx version and optional modules (HTTP/3, `http2` directive, modern SSL, brotli).
2. Installs `/usr/local/bin/cf-fail2ban.sh`, which bans/unbans IPs through the Cloudflare Firewall Access Rules API.
3. Wires the Cloudflare action into the Fail2Ban `ui-custom-action.conf` jail.
4. Rewrites `nginx.conf`, `global_settings`, `brotli.conf`, `ssl_ktls.conf` and the custom-domain vhost using only the directives the installed nginx build accepts.
5. Generates `cloudflare_realip.conf` from the Cloudflare IP ranges and adds a cron job to refresh it.
6. Tests and reloads Fail2Ban and nginx.

**Diagnostics:** every step is printed as `==> [step NN] …`, and if any command fails the script prints the failing line, the command and the exit code instead of stopping silently:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/cloudpanel-fix.sh | sudo bash
# full per-command trace (useful when a step fails):
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/cloudpanel-fix.sh | sudo VERBOSE=1 bash
```

| Variable | Purpose |
|----------|---------|
| `VERBOSE=1` | Runs the whole script under `set -x` with a `file:line:` prefix |
| `CLEAR_SCREEN=1` | Restores the old behaviour of clearing the terminal before the final reload |

**⚠️ Before running:** set the `CF_ACCOUNT` and `CF_TOKEN` values inside the script (Cloudflare account ID and an Account Firewall Access Rules token).

---

## 📦 Requirements

| Dependency | Purpose |
|------------|---------|
| Debian / Ubuntu server | Target operating system (scripts use `apt`) |
| `systemd` | Required by `disable-services.sh` |
| `nginx` | Required by `cloudpanel-fix.sh` |
| [Fail2Ban](https://www.fail2ban.org/) | Required by `cloudpanel-fix.sh` |
| `jq` | Required by `cloudpanel-fix.sh` to parse Cloudflare API responses |

---

## 🧰 Local setup

1. **Clone the repository** (or download a single script):
   ```bash
   git clone https://github.com/ivancarlosti/scripts.git
   cd scripts/linux-scripts
   ```

2. **Make a script executable:**
   ```bash
   chmod +x server-prep.sh
   ```

3. **Run it with sudo:**
   ```bash
   sudo ./server-prep.sh
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
