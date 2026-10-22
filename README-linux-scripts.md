# Linux Scripts

Shell scripts for setting up and hardening Linux servers — baseline package installation, kernel tuning for Redis, disabling unused services, nginx hardening, Fail2Ban setup (with optional Cloudflare integration), a locked-down key-only SSH account for the Fail2Ban UI, and pointing the CloudPanel admin panel at a custom domain. Every script is idempotent and safe to re-run.

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
| `php7.1-fpm` … `php8.1-fpm` (`phpX.Y-fpm` or `php-fpmX.Y` unit names) | End-of-life PHP branches: no upstream security fixes, and all of them are affected by the critical core RCEs CVE-2026-109618 / CVE-2026-109619 (CVSS 9.2) |
| `memcached` | Cache not used by the application |
| `postfix` | Local mail transfer agent not required |
| `proftpd` | FTP server replaced by SFTP |
| `ufw` | Firewall managed elsewhere (e.g. cloud security groups) |
| `varnish` | HTTP accelerator not in use |

**Usage:**

```bash
sudo bash disable-services.sh            # disable, stop and mask everything configured
sudo bash disable-services.sh --status   # read-only: what each EOL branch still runs
sudo bash disable-services.sh --help
```

**Workflow:**
1. Resolves each branch in `PHP_VERSIONS` to the unit that actually exists (`phpX.Y-fpm.service`, else `php-fpmX.Y.service`); branches that are not installed are skipped.
2. Refuses to stop a branch that nginx still references (`phpX.Y-fpm` found under `/etc/nginx` or `/home/*/conf`) unless `FORCE_PHP=1`, so a forgotten site is never taken down by accident.
3. Runs `systemctl disable <unit> --now` (disables at boot **and** stops it immediately) and then `systemctl mask <unit>`, so package upgrades and `systemctl preset` cannot re-enable the pool.
4. Repeats steps 1 and 3 for the remaining services in `SERVICES`, recording failures instead of aborting the run.
5. Prints a `Disabled` / `Masked` / `Skipped` / `In use` / `Failed` summary and exits non-zero when something needs attention.
6. Re-checks `pgrep -x php-fpmX.Y` after each pool is stopped and reports a survivor as `Failed: php-fpmX.Y still running`, so a master started outside that unit cannot look contained.

**Configuration variables (edit inline):**

| Variable | Purpose |
|----------|---------|
| `PHP_VERSIONS` | End-of-life PHP branches to disable, stop and mask |
| `SERVICES` | Other systemd unit names to disable and stop |
| `MASK_PHP` | `1` (default) masks the PHP units; `0` only disables and stops them |
| `FORCE_PHP` | `1` stops a PHP branch even when nginx still references it |

> **Note:** `--now` stops the pools immediately, so any site still served by one of these branches goes down — that is why the nginx check blocks the action by default. Migrate sites to a patched branch first (8.3.36+, 8.4.27+ or 8.5.12+; 8.2.35 is also fixed but 8.2 reaches end of life on 2026-12-31). The packages stay installed, so CloudPanel keeps listing the version as unavailable/disabled; revert with `sudo systemctl unmask <unit>` and remove the branch from `PHP_VERSIONS`.

> **Verifying with `--status`:** the report prints `unit=`, `active=`, `enabled=`, `procs=` and `nginx_refs=` per branch. A branch is contained only when `active=inactive`, `procs` is empty and `enabled=masked` (or `disabled`). If `active=inactive` but `procs` is not empty, the master is not started by that unit — another unit, a container or a manual start still runs `/usr/sbin/php-fpmX.Y`, which is also why a `[fpm on]` style audit can keep reporting it.

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
**Purpose:** Configures Fail2Ban, optionally extends banning to the Cloudflare firewall, installs four stack-universal **web jails** that stop nginx attack traffic (probes, failed logins, enumeration, known scanners) on CloudPanel and plain Debian/Ubuntu hosts alike, and — when an OpenVPN *server* is detected — adds an **OpenVPN jail** that bans failed TLS/certificate/authentication/HMAC handshakes on every port, TCP and UDP.

It runs **standalone** (separate from `cloudpanel-fix.sh`) and picks its mode from the
command line:

| Mode | When | What it does |
|------|------|--------------|
| **Cloudflare** | `--cf-token`, or `--cf-email` + `--cf-key`, are provided | Installs `/usr/local/bin/cf-fail2ban.sh` (mode `700`) and wires it into the Fail2Ban `ui-custom-action.conf` action so bans/unbans are also pushed to the Cloudflare Firewall Access Rules API |
| **Local only** | No credentials provided | Removes any leftover Cloudflare helper/wiring and writes an additive `jail.d` override that bans via the server's own action (`nftables-multiport`, else `iptables-multiport`) — **no Cloudflare API calls at all** |

Both modes then enable, validate (`fail2ban-client -t`) and reload Fail2Ban.

**Web protection** (installed by default in both modes, disable with `--no-web`):

| Jail | What it bans |
|------|--------------|
| `web-probe` | Requests for things that are never served on purpose: `/.env`, `/.git/...`, `.../wp-config.php.bak`, database/backup exports, `.php` files under `uploads/` or `assets/`, and 4xx/`000` answers to any of them |
| `web-login` | Failed logins: `POST` to `wp-login.php`, `administrator/index.php`, `.../index.php/login`, Magento customer logins or `xmlrpc.php` answered `200`/`401`/`403` (a `302`, i.e. a successful login, is ignored) |
| `web-enum` | User enumeration through `/wp-json/wp/v2/users` and `.../users/<id>` (default: numeric IDs ≥ 100; `--aggressive-enum` accepts any ID) |
| `web-badbots` | Known scanners by User-Agent (`sqlmap`, `wpscan`, `nuclei`, `masscan`, ...) — on by default, `--no-badbots` drops it |

* The filters are **generated for the discovered logs**, not shipped blind: the script samples the discovered logs to decide which field really holds a bannable client address (`$remote_addr`, or one specific `X-Forwarded-For` hop when Cloudflare fronts the site without `real_ip`) and refuses to guess when guessing would ban the CDN edge; it then runs `fail2ban-regex` self-tests (every built-in reference attack must be caught and no legitimate reference line may match) and only then writes `/etc/fail2ban/filter.d/web-*.conf` plus one jail file, `/etc/fail2ban/jail.d/zz-fail2ban-setup.local`. An inconclusive self-test warns and continues by default; `--strict-selftest` makes it abort before anything is written.
* **IPv6 is handled end to end:** Fail2Ban's `<HOST>`/`<ip>` are dual-stack, the web self-test includes both an IPv6 `$remote_addr` line and an IPv6 `X-Forwarded-For` hop, and the Cloudflare edge-range check performs a real IPv6 prefix comparison (compressed and expanded forms, plus non-group prefixes such as Cloudflare's `2a06:98c0::/29`). The Cloudflare helper passes the address to the API unchanged because the Access Rules `ip` target accepts IPv6 addresses and IPv6 CIDR ranges; no separate target or special case is needed. Local enforcement is dual-stack as well: the stock `nftables*` and `iptables*` actions carry an `[Init?family=inet6]` section, so Fail2Ban keeps an IPv6 set (`addr6-set-<name>`, type `ipv6_addr`) or switches to `ip6tables` with an `icmp6` reject target for IPv6 bans — one jail covers both families, provided `ip6tables`/nft IPv6 support is installed (Fail2Ban ≥ 0.10 for `iptables*`, ≥ 0.10.1 for `nftables*`; the legacy `iptables-ipset-proto4` action, which this script never selects, remains IPv4-only).
* The `ignoreip` of the running `sshd` jail is merged into every web and OpenVPN jail (prose answers such as `No IP address/network is ignored` and trailing comments are dropped) and `127.0.0.1/8 ::1` is always appended, so a generated ban can never lock you out of your own management addresses.
* `backend = auto` is written explicitly: Debian's `defaults-debian.conf` forces `backend = systemd` globally, which would leave these file-based jails monitoring nothing.
* A jail file we did not write (no marker) is backed up (`*.bak.<timestamp>`) before being replaced; re-runs are byte-stable and take no second backup.

**OpenVPN protection** (installed automatically when an OpenVPN *server* is detected; `--no-openvpn` skips it, `--openvpn` forces it, and an explicit `--openvpn-logpath` also enables it):

| Setting | Value |
|---------|-------|
| Filter | `/etc/fail2ban/filter.d/openvpn-local.conf` — a distinct name, so the distro's `openvpn.conf` and any `openvpn.local` are never touched |
| Jail | `/etc/fail2ban/jail.d/zz-fail2ban-setup-openvpn.local`, section `[openvpn]` |
| Bans | `TLS Auth Error:`, `VERIFY ERROR:`, `TLS Error: TLS handshake failed`, `SIGUSR1[soft,tls-error]`, `SIGUSR1[soft,connection-reset]`, and HMAC/packet-authentication failures (`incoming packet authentication failed`, `cannot locate HMAC in incoming packet`) — IPv4 and IPv6 |
| Ignores | successful connections, `ping-restart`, initial packets, `VERIFY OK`, control-channel lines and `TLS key negotiation failed` timeouts |
| Action | local all-ports action: `nftables[type=allports]` when nftables is usable, else `iptables[type=allports]`, on `protocol = tcp,udp`. **Never** the Cloudflare action (Cloudflare only covers HTTP) |
| Defaults | `maxretry = 3`, `findtime = 10m`, `bantime = 1h`; `ignoreip` merged from the `sshd` jail plus loopback |
| Log | first of `/var/log/openvpn/server.log`, `/var/log/openvpn.log`, `/var/log/openvpn/openvpn.log`, `/var/log/syslog`, `/var/log/messages`; `--openvpn-logpath` overrides |

* Detection is deliberately server-aware: a config under `/etc/openvpn/server/`, any config containing `server`, `mode server` or `tls-server`, or a running `openvpn-server@*.service`. A client-only host is skipped, because a client's own handshake failures carry the remote server's address and would ban it locally.
* The filter matches Debian/Ubuntu syslog prefixes via `_daemon = (?:ovpn-server\d*|openvpn(?:-server)?\d*)` (`ovpn-server[pid]`, `openvpn[pid]`, `openvpn-server[pid]`) and also a dedicated OpenVPN log with no syslog prefix.
* Before installing, a `fail2ban-regex` self-test uses realistic server lines: no legitimate line may match, and every reference attack address must be caught — IPv4, IPv6, a low source port (`:443`) and an ISO-timestamp dedicated-log line. It honours `--no-selftest` and `--strict-selftest`.
* If no OpenVPN/system log file exists, the script warns and skips the jail. If a file exists but its last 200 lines contain no OpenVPN messages (e.g. journald-only logging), it warns that the jail may monitor nothing — feed a file with rsyslog and pass `--openvpn-logpath`, or set `backend = systemd` in the generated jail.
* Re-runs are idempotent: a pre-existing `openvpn-local.conf`/jail file without the managed marker is backed up (`*.bak.<timestamp>`) before replacement.

**Ban thresholds** (defaults; one "retry" is one matching log line from the same source IP, and the ban fires on the Nth match inside `findtime`):

| Filter / jail | One retry is | `maxretry` | `findtime` | `bantime` |
|---|---|---:|---:|---:|
| `web-probe` / `[web-probe]` | A request for a probe/sensitive path (`.env`, `.git`, `wp-config.php.bak`, SQL dumps, PHP under `uploads/`, etc.) answered with **4xx or `000`** | 3 | 1h | Global value; local-mode baseline 1h |
| `web-login` / `[web-login]` | A `POST` to a recognized login form/API answered **200/401/403**, or a **401** on an admin panel | 8 | 10m | Global value; local-mode baseline 1h |
| `web-enum` / `[web-enum]` | A **200** response to `/wp-json/wp/v2/users…`; by default numeric user IDs ≥ 100, or any ID with `--aggressive-enum` | 4 | 1h | Global value; local-mode baseline 1h |
| `web-badbots` / `[web-badbots]` | Any request whose User-Agent matches the scanner list (`sqlmap`, `wpscan`, `nuclei`, `nmap`, `masscan`, etc.) | 2 | 1h | Global value; local-mode baseline 1h |
| `openvpn-local` / `[openvpn]` | One TLS/certificate/authentication/HMAC failure line (`TLS Auth Error`, `VERIFY ERROR`, handshake failed, `SIGUSR1[soft,tls-error]`/`connection-reset`, HMAC failure) | 3 | 10m | 1h |
| `sshd` / `[sshd]` *(not created by this script; enabled in local mode)* | One failed SSH authentication, as detected by the distro `sshd` filter | 5 | 10m | Local-mode baseline 1h; CloudPanel may override |

* `findtime` is a **sliding window**, not a fixed clock hour: "3 in 1h" means the third matching event arrives while the oldest of the three is still within the last hour. Events spaced farther apart than the window never reach the threshold.
* The web jails do **not** set `bantime` per jail by default, so a global `bantime`/`bantime.increment` keeps working. In no-Cloudflare local mode the script writes a `1h` baseline; on CloudPanel, check `/etc/fail2ban/jail.local`, whose values take precedence. `--web-bantime` forces a value for every web jail.
* `--web-maxretry` and `--web-findtime` apply to **all** web jails at once, not to one filter. The OpenVPN jail has its own `--openvpn-maxretry`, `--openvpn-findtime` and `--openvpn-bantime`.
* `web-badbots` is included by default; `--no-badbots` removes that jail. Addresses in `ignoreip` never count toward any threshold.
* The `sshd` row is the distro filter, not one this script generates: local mode only enables `[sshd]` and supplies the `[DEFAULT]` baseline timings above; CloudPanel's `/etc/fail2ban/jail.local` may override them.

**Options** (values may also come from the matching environment variable):

| Option | Environment | Purpose |
|--------|-------------|---------|
| `--cf-account <id>` | `CF_ACCOUNT` | Cloudflare Account ID (required with credentials) |
| `--cf-token <token>` | `CF_TOKEN` | Cloudflare API Token with the Account *Firewall Access Rules: Edit* permission |
| `--cf-email <email>` | `CF_EMAIL` | Cloudflare account email (legacy Global API Key auth) |
| `--cf-key <key>` | `CF_KEY` | Cloudflare Global API Key (legacy auth; requires `--cf-email`) |
| `--cf-target <ip\|hostname>` | `CF_TARGET` | Rule target type (default: `ip`) |
| `-h`, `--help` | — | Show usage and exit |

**Web protection options** (the full list is in `--help`; the ones you normally touch):

| Option | Environment | Purpose |
|--------|-------------|---------|
| `--web` / `--no-web` | `WEB` | Install / skip the web jails (default: install) |
| `--badbots` / `--no-badbots` | `WEB_BADBOTS` | Include the scanner User-Agent jail (default: include) |
| `--ip-source <mode>` | `WEB_IP_SOURCE` | `remote` \| `xforwarded` \| `auto` (default). `auto` picks `xforwarded` when Cloudflare edge addresses show up in the logs and nginx `real_ip` is not restored, and refuses to guess when guessing would ban the CDN edge instead of the attacker |
| `--xff-hop <first\|last>` | `WEB_XFF_HOP` | Which `X-Forwarded-For` hop holds the client; `last` (default) is the one Cloudflare appends and a client cannot spoof |
| `--logpath <glob>` / `--extra-logpath <glob>` | `WEB_LOG_GLOB` / `WEB_EXTRA_LOG_GLOB` | Replace / extend the auto-discovered access logs (repeatable) |
| `--ignoreip <ip,cidr>` | `WEB_IGNOREIP` | Extra addresses whitelisted in every web and OpenVPN jail, on top of the merged `sshd` list (repeatable) |
| `--allow-ua <regex>` / `--no-allowlist` | `WEB_ALLOW_UA` / `WEB_ALLOWLIST=0` | Extend / drop the built-in "never banned" User-Agent allow-list (Uptime Kuma, Pingdom, Datadog, ...) |
| `--aggressive-login`, `--aggressive-enum` | `WEB_AGGRESSIVE_LOGIN`, `WEB_AGGRESSIVE_ENUM` | Widen `web-login` to generic `login`/`signin`/`admin` pages and `web-enum` to any `/wp-json/wp/v2/users/<id>` (more coverage, more false positives) |
| `--web-maxretry <n>`, `--web-findtime <t>`, `--web-bantime <t>` | `WEB_MAXRETRY`, `WEB_FINDTIME`, `WEB_BANTIME` | Override the per-jail thresholds (e.g. `--web-findtime 10m --web-bantime 4h`) |
| `--force-ip-source`, `--no-selftest`, `--strict-selftest` | `WEB_FORCE_IP_SOURCE`, `WEB_SELFTEST=0`, `WEB_SELFTEST_STRICT` | Override the safety gates: accept a refused IP source, skip the `fail2ban-regex` self-tests (web and OpenVPN), or make an inconclusive self-test fatal |
| `--openvpn` / `--no-openvpn` | `OPENVPN` | Force / skip the OpenVPN jail (default: install when an OpenVPN server is detected) |
| `--openvpn-logpath <path>` | `OPENVPN_LOG` | OpenVPN/syslog file to watch instead of auto-discovery (also enables the jail) |
| `--openvpn-banaction <action>` | `OPENVPN_BANACTION` | Fail2Ban action for the OpenVPN jail (default: `nftables[type=allports]`, else `iptables[type=allports]`) |
| `--openvpn-maxretry <n>`, `--openvpn-findtime <t>`, `--openvpn-bantime <t>` | `OPENVPN_MAXRETRY`, `OPENVPN_FINDTIME`, `OPENVPN_BANTIME` | OpenVPN thresholds (defaults: `3`, `10m`, `1h`) |
| `--dry-run` | — | Print the filters and the jail files (and write nothing) |
| `--status` | — | Show the web and OpenVPN jails and their current/total bans, then exit |
| `--uninstall-web` | — | Remove the web filters and jail file (keeps the Cloudflare helper, the local jail and the OpenVPN jail), then exit |
| `--uninstall-openvpn` | — | Remove only the OpenVPN filter and jail file, then exit |

```bash
# With Cloudflare (recommended: a scoped Account Firewall Access Rules API token)
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --cf-account <ACCOUNT_ID> --cf-token <API_TOKEN>

# Without Cloudflare: local banning only
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh | sudo bash

# Full per-command trace
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo VERBOSE=1 bash -s -- --cf-account <ACCOUNT_ID> --cf-token <API_TOKEN>

# Inspect the web jails: what would be installed, then what is running
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --dry-run
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --status

# Cloudflare proxying without nginx real_ip restored: ban the client, not the edge
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --ip-source xforwarded --xff-hop last

# Remove the web jails again (Cloudflare helper, local jail and OpenVPN jail are kept)
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --uninstall-web

# OpenVPN logging to a dedicated file (also enables the jail when detection fails)
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --openvpn-logpath /var/log/openvpn/server.log

# Web jails only: skip the OpenVPN jail
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --no-openvpn

# Remove only the OpenVPN filter and jail
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh \
  | sudo bash -s -- --uninstall-openvpn
```

| Variable | Purpose |
|----------|---------|
| `VERBOSE=1` | Runs the whole script under `set -x` with a `file:line:` prefix |
| `CLEAR_SCREEN=1` | Clears the terminal at the end |

> **Note:** in local mode the jail override is written to `/etc/fail2ban/jail.d/`, which is additive — CloudPanel values in `/etc/fail2ban/jail.local` still take precedence. The web jails live in the same directory (`jail.d/zz-fail2ban-setup.local`) and, because `jail.d` is parsed *after* `jail.local`, their per-jail settings win for those sections only. The OpenVPN jail is separate (`jail.d/zz-fail2ban-setup-openvpn.local` + `filter.d/openvpn-local.conf`), local-only, and removed only by `--uninstall-openvpn`. The Cloudflare helper is stored `700` (root-only) because it contains the credential.

---

### [`dashboard-domain.sh`](linux-scripts/dashboard-domain.sh)
**Purpose:** Points the CloudPanel admin panel at a custom hostname (instead of the default `https://<server-ip>:8443`), has CloudPanel issue a Let's Encrypt certificate for it (falling back to `certbot`), registers the domain with CloudPanel itself so its own settings page and renewal cron see it, and rewrites the domain stored in the CloudPanel database.

**Workflow:**
1. Normalises the argument (lowercases it, strips a leading `http(s)://` and any trailing path) and validates it against a hostname pattern.
2. Backs up the CloudPanel SQLite database to `/root/db.sq3.<timestamp>.bak` and creates the SSL certificate directory and CloudPanel's ACME challenge directory.
3. (Re)writes `/etc/nginx/sites-enabled/custom-domain.conf` from CloudPanel's own modern template: a **443 listener** (QUIC/HTTP3 + HTTP/2 when the installed nginx build supports those directives, `listen 443 ssl http2` on older ones, plain `listen 443 ssl` as a fallback) that reverse-proxies the domain to the panel on `https://127.0.0.1:8443`. An existing vhost is backed up to `/root/custom-domain.conf.<timestamp>.bak` before being rewritten; its `server_name` is reported and reused as the previous domain of step 8, and a vhost without any `server_name` is refused rather than overwritten.
4. Installs `sqlite3` / `openssl` if missing and **registers the domain with CloudPanel**: `clpctl app:set:config-value custom_domain <domain>` when the installed CLI provides that command, otherwise an idempotent `INSERT … WHERE NOT EXISTS` + `UPDATE` on the `config` table. That is the value behind **Settings → General → "Domain Name"** and the one CloudPanel's own `lets-encrypt:renew:custom-domain:certificate` cron reads. `/etc/.clp_custom_domain` is written too, so the SSH login banner shows the panel URL.
5. Generates a temporary self-signed certificate when the vhost's certificate files are absent (otherwise nginx refuses to load), tests and reloads nginx — falling back to the plain 443 listener when the build rejects the QUIC flavour — then **verifies that the vhost is part of the configuration nginx actually loaded** (`nginx -T`); when it is not, the run ends with a warning that names the file and the include directive to fix.
6. Issues the certificate with **CloudPanel itself**: it probes `clpctl list` (as the `clp` user, exactly like CloudPanel's cron entries) and uses the first command the installed CLI provides — `lets-encrypt:install:custom-domain:certificate`, `lets-encrypt:renew:custom-domain:certificate` (CloudPanel's own cron job) or `lets-encrypt:install:certificate` (needs a site for the domain) — and only trusts it once a real Let's Encrypt certificate for the domain is on disk.
7. Installs the certificate as `/etc/nginx/ssl-certificates/custom-domain.crt` / `.key`, points the vhost at them and reloads nginx. When CloudPanel's own commands are unavailable or do nothing, `certbot` is installed and used with the `--webroot` plugin into CloudPanel's own challenge directory, plus a `--deploy-hook` that reinstalls the files and reloads nginx on every renewal. Re-runs that find a valid certificate already in place are skipped.
8. Rewrites every value exactly equal to the **old** domain inside the CloudPanel database (the `site` table is intentionally excluded) and prints the new panel URL.

> **Why the probe?** CloudPanel exposes no stable CLI command for the admin panel's *own* certificate: the `renew` namespace was removed in CLI 6.0.8 and the "CloudPanel Custom Domain" UI setting is a [known-flaky](https://github.com/cloudpanel-io/cloudpanel-ce/issues/301) path. `lets-encrypt:renew:custom-domain:certificate` also exits `0` without issuing anything while the `custom_domain` config key is empty or while the certificate on disk is self-signed or more than 7 days from expiry, so its exit code alone proves nothing — hence the registration in step 4 and the on-disk verification. `certbot` writes to `/etc/letsencrypt`, which CloudPanel's renewal cron never touches, so the two cannot fight over the certificate files.

> **Why the port-443 vhost matters:** CloudPanel serves the admin panel itself from a listener of its own whose only server name is the catch-all `_` on port 8443, so `https://<domain>:8443` answers for **any** hostname pointed at the server. That is why the panel keeps working even when `/etc/nginx/sites-enabled/custom-domain.conf` does not exist — that file is only the panel's port-443 entry point (it reverse-proxies to `https://127.0.0.1:8443`). Without it, `https://<domain>` (port 443) is answered by the default server, which rejects the TLS handshake with `unrecognized name`. CloudPanel's own site vhosts live in `/etc/nginx/sites-enabled/` as well, and CloudPanel's renewal cron rewrites `custom-domain.conf` from its bundled template — so keep an eye on that file after a renewal.

> **Why the certificate still validates without a port-80 vhost:** the file holds a single 443 server block, exactly like CloudPanel's current `custom-domain` template ([`cloudpanel-fix.sh`](linux-scripts/cloudpanel-fix.sh) writes the same one, with the same three build-dependent variants). The HTTP-01 token is written to CloudPanel's own challenge directory, `/home/clp/htdocs/app/files/public/.well-known/acme-challenge/`, which the panel listener serves with `auth_basic off`; the port-80 catch-all only has to redirect `http://<domain>/.well-known/...` to HTTPS, and Let's Encrypt follows that redirect (up to 10 hops) **without validating the certificate on the redirect target** — "since this challenge is intended to bootstrap valid certificates, it may encounter self-signed or expired certificates along the way" ([challenge types](https://letsencrypt.org/docs/challenge-types/)). That is also why the temporary self-signed placeholder cannot break issuance, and why `certbot --webroot` uses that same directory.

**Usage:**

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/dashboard-domain.sh \
  | sudo bash -s -- cp.example.com
```

> The domain argument is required when the script runs non-interactively (piped through `curl`); when run from a terminal without it, the domain is prompted for. Pass `-h` / `--help` to print usage.

> **Requirements:** root, an existing CloudPanel install (nginx, `clpctl`, the CloudPanel SQLite database) and a DNS `A`/`AAAA` record that **already** resolves the domain to the server (HTTP-01 validation, so port 80 must be reachable). `sqlite3` and `openssl` are installed automatically when missing; `certbot` is only installed when CloudPanel's own `clpctl` cannot issue the certificate. When the vhost's certificate files do not exist yet, a temporary self-signed certificate is generated so nginx can load the 443 listener and answer the ACME challenge. When `clpctl` has no `app:set:config-value` command, the domain is written straight into the `config` table (`custom_domain` key) — the very value the admin UI stores, so the two cannot diverge. The database and the existing vhost are backed up before any change so you can roll back.

---

### [`fail2ban-ui-ssh-user.sh`](linux-scripts/fail2ban-ui-ssh-user.sh)
**Purpose:** Creates (or updates) the dedicated, key-only SSH account that the [Fail2Ban UI](https://github.com/swissmakers/fail2ban-ui) uses to manage this host's Fail2Ban, grants it exactly the access that connector needs — and nothing more — and prints the generated RSA private key so it can be pasted into the UI.

**Workflow:**
1. Creates the account (`sa_fail2ban` by default) with a home directory and `/bin/bash`, then strips **every** way into it: no password hash at all (`usermod -p '!'`) and removal from `sudo`/`wheel` if it turns out to be a member of either, since that membership alone would silently grant full root.
2. Generates a 4096-bit RSA key in **PEM** format (`ssh-keygen -t rsa -b 4096 -m PEM` — the PKCS#1 `BEGIN RSA PRIVATE KEY` form the UI's Go SSH client expects), installs the public key in `~/.ssh/authorized_keys` (mode `600`) with OpenSSH's `restrict` option (no pty, agent, port or X11 forwarding), and **prints the private key once** between copy markers.
3. Writes `/etc/sudoers.d/fail2ban-ui-<user>` (mode `0440`, `root:root`), validating it with `visudo -cf` **before** installing it and with `visudo -c` afterwards (rolling back to the previous file — or removing it — if the whole configuration would stop parsing). Only two commands are granted, next to `Defaults:<user> !requiretty` (the connector runs `sudo -n` with no tty): `fail2ban-client *`, because jail names are dynamic, and `systemctl restart fail2ban`.
4. Grants read/write access to `/etc/fail2ban` through **POSIX ACLs** (`setfacl -R -m u:<user>:rwX`, plus a default ACL on every directory so new files inherit it): the connector reads the config tree and stages its writes (`action.d`, `filter.d`, `jail.d`, `.f2bui.bak` files) **as the login user**, so the ACLs — not a broad group membership — are what make that work.
5. Runs a **local self-test** before deleting anything: logs in over `127.0.0.1` with the key it just generated, runs `sudo -n fail2ban-client ping` as the account, and prints `sudo -l -U <user>` as sudo itself reports the rules. Only then is the private key shredded from the server.

**Options** (values may also come from the matching environment variable):

| Option | Environment | Purpose |
|--------|-------------|---------|
| `--user <name>` | `SA_USER` | Service account name (default: `sa_fail2ban`) |
| `--key-bits <n>` | `KEY_BITS` | RSA key size (default: `4096`, minimum `2048`) |
| `--from <addr[,addr]>` | `KEY_FROM` | Restrict the key to these source addresses / CIDRs |
| `--reverse-tunnel <port>` | — | Let the key listen on `localhost:<port>` only, as the UI's reverse tunnel for events needs (uses explicit `permitlisten`, `no-pty`, `no-port-forwarding`… instead of `restrict`) |
| `--with-log-read` | — | Add the account to `adm`, so the UI's logpath test can read `/var/log` (Debian/Ubuntu) |
| `--log-group <group>` | `LOG_GROUP` | Same, with an explicit group name |
| `--rotate-key` | — | Generate a new private key even when a managed key already exists |
| `--output <path>` | `OUTPUT_PATH` | Also write the private key to `<path>` (mode `600`, `root`) |
| `--dry-run` | — | Print every planned change (account, `authorized_keys` entry, sudoers file, ACLs) and modify nothing |
| `-h`, `--help` | — | Show usage and exit |

```bash
# First run: create the account and print the private key
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-ui-ssh-user.sh | sudo bash

# Restrict the key to the UI host, allow the reverse tunnel and log reading
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-ui-ssh-user.sh \
  | sudo bash -s -- --from 203.0.113.10 --reverse-tunnel 2222 --with-log-read
```

Then, in the UI's *Manage Servers* form, set **SSH user** to `sa_fail2ban` and provide the private key (inside the container it belongs at `/config/.ssh/id_rsa`, mode `600`). The script prints that same summary — host, port, user, key path — when it finishes.

**Diagnostics:** every step is printed as `==> [step NN] …`, and if any command fails the script prints the failing line, the command and the exit code instead of stopping silently:

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-ui-ssh-user.sh | sudo VERBOSE=1 bash
```

| Variable | Purpose |
|----------|---------|
| `VERBOSE=1` | Runs the whole script under `set -x` with a `file:line:` prefix |
| `CLEAR_SCREEN` | Deliberately **not** supported — the terminal is never cleared, so the printed private key cannot be wiped off the screen |

> **This script never touches `/etc/ssh`.** Per-user sshd hardening (`Match User …`) depends on each host's own configuration, so it is left alone; password logins are impossible for the account anyway, because it has no password hash at all. `sshd -T` is only *read*, to report the effective posture (`PasswordAuthentication`, `PubkeyAuthentication`, `PermitEmptyPasswords`, the port) and to warn when the host would refuse key logins.

> **Re-runs are safe and keep the UI working.** The managed key is identified by its comment (`fail2ban-ui@<host>`), so its `authorized_keys` entry is refreshed — options included — on every run while any other key of the account is preserved, and the existing private key is **kept** unless `--rotate-key` is passed. Sudo rules and ACLs are applied idempotently, and a replaced sudoers file is copied to `/root/sudoers.d-fail2ban-ui-<user>.<timestamp>.bak` first.

> **Revoking everything:** `userdel -r sa_fail2ban`, `rm -f /etc/sudoers.d/fail2ban-ui-sa_fail2ban`, `setfacl -R -x u:sa_fail2ban /etc/fail2ban` and `find /etc/fail2ban -type d -exec setfacl -d -x u:sa_fail2ban {} +` (the same commands are printed at the end of every run).

> **Requirements:** root, a running Fail2Ban with `/etc/fail2ban` in place (`server-prep.sh` installs it, `fail2ban-setup.sh` configures it) and an SSH server for the UI's own connection. `setfacl` is installed automatically when the `acl` package is missing; `ssh-keygen` (openssh-client), `visudo` (sudo) and `fail2ban-client` are required. `--with-log-read` additionally expects the `adm` group, and the UI's ban-notification callback needs `curl` and `jq` on this host — the script warns when either is missing.

---

## 📦 Requirements

| Dependency | Purpose |
|------------|---------|
| Debian / Ubuntu server | Target operating system (scripts use `apt`) |
| `systemd` | Required by `disable-services.sh` |
| `nginx` | Required by `cloudpanel-fix.sh` |
| [Fail2Ban](https://www.fail2ban.org/) | Required by `fail2ban-setup.sh`; also the service whose SSH access `fail2ban-ui-ssh-user.sh` provisions |
| [OpenVPN](https://openvpn.net/) | Optional: when installed (or when `--openvpn-logpath`/`--openvpn` is given), `fail2ban-setup.sh` adds the local-only `[openvpn]` jail |
| `curl` | Required by `fail2ban-setup.sh` in Cloudflare mode (API calls) and by the Fail2Ban UI's ban-notification callback on the managed host |
| `jq` | Required by `fail2ban-setup.sh` in Cloudflare mode to parse API responses, and by the Fail2Ban UI's ban-notification callback on the managed host |
| `openssh-server` | Required by `fail2ban-ui-ssh-user.sh`: the Fail2Ban UI connects to this host over SSH, and `sshd -T` feeds its read-only posture report |
| `sudo` (`visudo`) | Required by `fail2ban-ui-ssh-user.sh` to install and validate the sudoers drop-in of the service account |
| `acl` (`setfacl`) | Required by `fail2ban-ui-ssh-user.sh` to grant the service account read/write access to `/etc/fail2ban`; installed automatically when missing |
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
