# Linux Scripts

Shell scripts for setting up and hardening Linux servers — baseline package installation, kernel tuning for Redis, disabling unused services, nginx hardening, Fail2Ban setup (with optional Cloudflare integration), and pointing the CloudPanel admin panel at a custom domain. Every script is idempotent and safe to re-run.

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
**Purpose:** Hardens nginx on CloudPanel.

**Workflow:**
1. Detects the installed nginx version and optional modules (HTTP/3, `http2` directive, modern SSL, brotli).
2. Rewrites `nginx.conf`, `global_settings`, `security_headers`, `brotli.conf`, `ssl_ktls.conf`, `default.conf` and the custom-domain vhost using only the directives the installed nginx build accepts.
3. Generates `cloudflare_realip.conf` from the Cloudflare IP ranges and adds a cron job to refresh it.
4. Tests and reloads nginx.

> The Fail2Ban / Cloudflare ban integration now lives in its own script — see [`fail2ban-setup.sh`](#fail2ban-setupsh).

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

---

### [`fail2ban-setup.sh`](linux-scripts/fail2ban-setup.sh)
**Purpose:** Configures Fail2Ban and, optionally, extends banning to the Cloudflare firewall.

It runs **standalone** (separate from `cloudpanel-fix.sh`) and picks its mode from the
command line:

| Mode | When | What it does |
|------|------|--------------|
| **Cloudflare** | `--cf-token`, or `--cf-email` + `--cf-key`, are provided | Installs `/usr/local/bin/cf-fail2ban.sh` (mode `700`) and wires it into the Fail2Ban `ui-custom-action.conf` action so bans/unbans are also pushed to the Cloudflare Firewall Access Rules API |
| **Local only** | No credentials provided | Removes any leftover Cloudflare helper/wiring and writes an additive `jail.d` override that bans via the server's own action (`nftables-multiport`, else `iptables-multiport`) — **no Cloudflare API calls at all** |

Both modes then enable, validate (`fail2ban-client -t`) and reload Fail2Ban.

**Options** (values may also come from the matching environment variable):

| Option | Environment | Purpose |
|--------|-------------|---------|
| `--cf-account <id>` | `CF_ACCOUNT` | Cloudflare Account ID (required with credentials) |
| `--cf-token <token>` | `CF_TOKEN` | Cloudflare API Token with the Account *Firewall Access Rules: Edit* permission |
| `--cf-email <email>` | `CF_EMAIL` | Cloudflare account email (legacy Global API Key auth) |
| `--cf-key <key>` | `CF_KEY` | Cloudflare Global API Key (legacy auth; requires `--cf-email`) |
| `--cf-target <ip\|hostname>` | `CF_TARGET` | Rule target type (default: `ip`) |
| `-h`, `--help` | — | Show usage and exit |

```bash
# With Cloudflare (recommended: a scoped Account Firewall Access Rules API token)
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --cf-account <ACCOUNT_ID> --cf-token <API_TOKEN>

# Without Cloudflare: local banning only
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh | sudo bash

# Full per-command trace
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo VERBOSE=1 bash -s -- --cf-account <ACCOUNT_ID> --cf-token <API_TOKEN>
```

| Variable | Purpose |
|----------|---------|
| `VERBOSE=1` | Runs the whole script under `set -x` with a `file:line:` prefix |
| `CLEAR_SCREEN=1` | Clears the terminal at the end |

> **Note:** in local mode the jail override is written to `/etc/fail2ban/jail.d/`, which is additive — CloudPanel values in `/etc/fail2ban/jail.local` still take precedence. The Cloudflare helper is stored `700` (root-only) because it contains the credential.

---

### [`dashboard-domain.sh`](linux-scripts/dashboard-domain.sh)
**Purpose:** Points the CloudPanel admin panel at a custom hostname (instead of the default `https://<server-ip>:8443`), has CloudPanel issue a Let's Encrypt certificate for it (falling back to `certbot`), registers the domain with CloudPanel itself so its own settings page and renewal cron see it, and rewrites the domain stored in the CloudPanel database.

**Workflow:**
1. Normalises the argument (lowercases it, strips a leading `http(s)://` and any trailing path) and validates it against a hostname pattern.
2. Backs up the CloudPanel SQLite database to `/root/db.sq3.<timestamp>.bak` and creates the ACME webroot and SSL certificate directories.
3. Rewrites the `server_name` in `/etc/nginx/sites-enabled/custom-domain.conf` when that vhost exists (filling in an empty `server_name ;` already declared by CloudPanel), otherwise writes a fresh vhost that serves the ACME challenge on port 80 and reverse-proxies the domain to the panel on `https://127.0.0.1:8443`; ensures the `/.well-known/acme-challenge/` location is present.
4. Installs `sqlite3` / `openssl` if missing and **registers the domain with CloudPanel**: `clpctl app:set:config-value custom_domain <domain>` when the installed CLI provides that command, otherwise an idempotent `INSERT … WHERE NOT EXISTS` + `UPDATE` on the `config` table. That is the value behind **Settings → General → "Domain Name"** and the one CloudPanel's own `lets-encrypt:renew:custom-domain:certificate` cron reads. `/etc/.clp_custom_domain` is written too, so the SSH login banner shows the panel URL.
5. Generates a temporary self-signed certificate when the vhost's certificate files are absent (otherwise nginx refuses to load), tests and reloads nginx, then **verifies that the vhost is part of the configuration nginx actually loaded** (`nginx -T`) — when it is not, the run ends with a warning that names the file and the include directive to fix.
6. Issues the certificate with **CloudPanel itself**: it probes `clpctl list` (as the `clp` user, exactly like CloudPanel's cron entries) and uses the first command the installed CLI provides — `lets-encrypt:install:custom-domain:certificate`, `lets-encrypt:renew:custom-domain:certificate` (CloudPanel's own cron job) or `lets-encrypt:install:certificate` (needs a site for the domain) — and only trusts it once a real Let's Encrypt certificate for the domain is on disk.
7. Installs the certificate as `/etc/nginx/ssl-certificates/custom-domain.crt` / `.key`, points the vhost at them and reloads nginx. When CloudPanel's own commands are unavailable or do nothing, `certbot` is installed and used with the `--webroot` plugin instead. Re-runs that find a valid certificate already in place are skipped.
8. Rewrites every value exactly equal to the **old** domain inside the CloudPanel database (the `site` table is intentionally excluded) and prints the new panel URL.

> **Why the probe?** CloudPanel exposes no stable CLI command for the admin panel's *own* certificate: the `renew` namespace was removed in CLI 6.0.8 and the "CloudPanel Custom Domain" UI setting is a [known-flaky](https://github.com/cloudpanel-io/cloudpanel-ce/issues/301) path. `lets-encrypt:renew:custom-domain:certificate` also exits `0` without issuing anything while the `custom_domain` config key is empty or while the certificate on disk is self-signed or more than 7 days from expiry, so its exit code alone proves nothing — hence the registration in step 4 and the on-disk verification. `certbot` writes to `/etc/letsencrypt`, which CloudPanel's renewal cron never touches, so the two cannot fight over the certificate files.

> **Why the port-443 vhost matters:** CloudPanel serves the admin panel itself from a listener of its own whose only server name is the catch-all `_` on port 8443, so `https://<domain>:8443` answers for **any** hostname pointed at the server. That is why the panel keeps working even when `/etc/nginx/sites-enabled/custom-domain.conf` does not exist — that file is only the panel's port-80/443 entry point (it serves the ACME challenge and reverse-proxies to `https://127.0.0.1:8443`). Without it, `https://<domain>` (port 443) is answered by the default server, which rejects the TLS handshake with `unrecognized name`. CloudPanel's own site vhosts live in `/etc/nginx/sites-enabled/` as well, and CloudPanel's renewal cron rewrites `custom-domain.conf` from its bundled template — so keep an eye on that file after a renewal.

**Usage:**

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/dashboard-domain.sh \
  | sudo bash -s -- cp.example.com
```

> The domain argument is required when the script runs non-interactively (piped through `curl`); when run from a terminal without it, the domain is prompted for. Pass `-h` / `--help` to print usage.

> **Requirements:** root, an existing CloudPanel install (nginx, `clpctl`, the CloudPanel SQLite database) and a DNS `A`/`AAAA` record that **already** resolves the domain to the server (HTTP-01 validation, so port 80 must be reachable). `sqlite3` and `openssl` are installed automatically when missing; `certbot` is only installed when CloudPanel's own `clpctl` cannot issue the certificate. When the vhost's certificate files do not exist yet, a temporary self-signed certificate is generated so nginx can load and answer the ACME challenge. When `clpctl` has no `app:set:config-value` command, the domain is written straight into the `config` table (`custom_domain` key) — the very value the admin UI stores, so the two cannot diverge. The database is backed up before any change so you can roll back.

---

## 📦 Requirements

| Dependency | Purpose |
|------------|---------|
| Debian / Ubuntu server | Target operating system (scripts use `apt`) |
| `systemd` | Required by `disable-services.sh` |
| `nginx` | Required by `cloudpanel-fix.sh` |
| [Fail2Ban](https://www.fail2ban.org/) | Required by `fail2ban-setup.sh` |
| `curl` | Required by `fail2ban-setup.sh` in Cloudflare mode (API calls) |
| `jq` | Required by `fail2ban-setup.sh` in Cloudflare mode to parse API responses |
| `CloudPanel` + `clpctl` | Required by `dashboard-domain.sh` to change the admin panel domain and register it (`app:set:config-value`, when the CLI provides it); it also issues the certificate when its CLI supports it |
| `sqlite3`, `openssl` | Used by `dashboard-domain.sh`; installed automatically if missing |
| `certbot` | Fallback certificate issuer for `dashboard-domain.sh`, installed only when CloudPanel's own `clpctl` cannot issue the certificate |

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
