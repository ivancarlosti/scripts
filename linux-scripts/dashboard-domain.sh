#!/bin/bash
# CloudPanel admin-panel custom domain
#
# Points the CloudPanel admin panel at a custom hostname (instead of the
# default https://<server-ip>:8443), issues a Let's Encrypt certificate for it
# and rewrites the domain stored in the CloudPanel database so the panel keeps
# working under the new hostname.
#
# Usage:
#   dashboard-domain.sh <domain>
#   curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/dashboard-domain.sh | sudo bash -s -- cp.example.com
#
# <domain> is required when the script runs non-interactively (piped through
# curl); from a terminal it is prompted for when omitted. -h/--help shows usage.
#
# Workflow:
#   1. normalise + validate the domain;
#   2. back up the CloudPanel SQLite database (/root/db.sq3.<timestamp>.bak);
#   3. (re)write the custom-domain nginx vhost from CloudPanel's own template: a
#      443 listener - with QUIC/HTTP3 and HTTP/2 whenever the installed nginx
#      build accepts those directives - that reverse-proxies the domain to
#      https://127.0.0.1:8443. An existing vhost is backed up first and its
#      server_name is reported (it becomes the "old domain" of step 8); a vhost
#      without any server_name is refused instead of overwritten;
#   4. register the domain with CloudPanel itself (config key "custom_domain"),
#      so Settings -> General -> "Domain Name" shows it and CloudPanel's own
#      certificate cron acts on it;
#   5. create a temporary self-signed placeholder when the certificate files are
#      missing so nginx can load the vhost, load it, and verify that the vhost
#      really is part of the configuration nginx loaded (CloudPanel's panel
#      listener on port 8443 is a catch-all, so https://<domain>:8443 answers for
#      any hostname even when this vhost - the panel's port-443 entry point - is
#      missing or unused);
#   6. obtain the certificate with CloudPanel itself, probing clpctl and using
#      the first command the installed CLI actually provides (see below); only
#      when CloudPanel cannot issue it is certbot installed and used;
#   7. install the certificate as
#      /etc/nginx/ssl-certificates/custom-domain.{crt,key} and reload nginx;
#   8. rewrite every "old domain" value in the CloudPanel database (the site
#      table is intentionally left untouched).
#
# Certificate issuance: CloudPanel does not expose the admin panel's own
# custom-domain certificate through a stable CLI command, so the script probes
# `clpctl list` (as the clp user, exactly like CloudPanel's own cron entries) and
# uses the first of
#   lets-encrypt:install:custom-domain:certificate  (undocumented, if present)
#   lets-encrypt:renew:custom-domain:certificate    (CloudPanel's own cron job)
#   lets-encrypt:install:certificate                (documented; needs a site)
# that the installed CLI provides, and only trusts it when a real Let's Encrypt
# certificate for <domain> actually landed on disk. certbot (--webroot into
# CloudPanel's own challenge directory, /home/clp/htdocs/app/files/public; it
# writes the certificate itself to /etc/letsencrypt, which CloudPanel's renewal
# cron never touches) is used only when none of those commands works.
#
# `lets-encrypt:renew:custom-domain:certificate` reads the "custom_domain" config
# key and exits 0 without issuing anything while that key is empty (and also
# while the certificate on disk is self-signed or valid for more than 7 more
# days), which is why the domain is registered in step 4 before it is called.
#
# Requirements: root, an existing CloudPanel install (nginx + clpctl) and a DNS
# A/AAAA record that already resolves <domain> to this server.
set -euo pipefail

DB="/home/clp/htdocs/app/data/db.sq3"
VHOST="/etc/nginx/sites-enabled/custom-domain.conf"
SSL_DIR="/etc/nginx/ssl-certificates"
# CloudPanel's own challenge directory for the panel's custom domain: the panel
# listener on port 8443 serves "/.well-known" from this root with auth_basic off,
# which is the directory CloudPanel itself writes the HTTP-01 token into.
WEBROOT="/home/clp/htdocs/app/files/public"

usage() {
  cat >&2 <<'EOF'
Point the CloudPanel admin panel at a custom domain.

Usage:
  dashboard-domain.sh <domain>
  curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/dashboard-domain.sh | sudo bash -s -- cp.example.com

The script rewrites the panel vhost, has CloudPanel issue a Let's Encrypt
certificate for <domain> (falling back to certbot when its own clpctl cannot)
and updates the domain stored in the CloudPanel database.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [[ -n "${1:-}" ]]; then
  DOMAIN="$1"
elif [[ -t 0 ]]; then
  read -rp "CloudPanel domain (example: cp.example.com): " DOMAIN
else
  usage
  exit 1
fi

DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || {
  echo "Invalid domain: $DOMAIN" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -f "$DB" ]] || { echo "CloudPanel database not found: $DB" >&2; exit 1; }

cp -a "$DB" "/root/db.sq3.$(date +%Y-%m-%d-%H-%M-%S).bak"
install -d -m 755 "$SSL_DIR" "${WEBROOT}/.well-known/acme-challenge"

OLD_DOMAIN=""
if [[ -f "$VHOST" ]]; then
  # The vhost is rewritten from the template further down, so the only thing read
  # out of an existing file is its server_name: it becomes the "old domain" that
  # the database rewrite at the end replaces. An empty "server_name ;" (the state
  # before a domain is configured) and an unrendered CloudPanel placeholder
  # ("{{server_name}}", "{{dashboardURL}}") are reported but are not a previous
  # domain; a file without any server_name is refused instead of overwritten.
  if grep -qE '^[[:space:]]*server_name[[:space:]]+' "$VHOST"; then
    OLD_DOMAIN="$(grep -m1 -E '^[[:space:]]*server_name[[:space:]]+' "$VHOST" \
      | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/[[:space:]]*;.*//')"
    if [[ "$OLD_DOMAIN" =~ ^\{\{.*\}\}$ ]]; then
      echo "unrendered placeholder in ${VHOST}: ${OLD_DOMAIN}"
      OLD_DOMAIN=""
    elif [[ -z "$OLD_DOMAIN" ]]; then
      echo "empty server_name set to: ${DOMAIN}"
    elif [[ "$OLD_DOMAIN" == "$DOMAIN" ]]; then
      echo "server_name already set to: ${DOMAIN}"
    else
      echo "server_name changed: ${OLD_DOMAIN} -> ${DOMAIN}"
    fi
    cp -a "$VHOST" "/root/custom-domain.conf.$(date +%Y-%m-%d-%H-%M-%S).bak"
  else
    echo "No server_name in $VHOST (refusing to overwrite it)" >&2
    exit 1
  fi
else
  echo "no existing ${VHOST}; writing it"
fi

# --- Panel vhost -------------------------------------------------------------
# CloudPanel's own modern custom-domain vhost: a 443 listener in front of the
# reverse proxy to the panel on https://127.0.0.1:8443. There is deliberately no
# port-80 server block here: Let's Encrypt follows the port-80 catch-all's
# redirect to https and does not validate the certificate on an https redirect
# target, and the panel listener itself serves "/.well-known" (auth_basic off)
# from its own root - that is the directory the HTTP-01 token is written into,
# both by CloudPanel and by the certbot fallback below.
#
# QUIC/HTTP3 and the standalone http2/http3 directives only exist in recent nginx
# builds, so the flavour is derived from the installed build exactly like
# cloudpanel-fix.sh does it. An existing vhost is rewritten rather than patched:
# CloudPanel's own renewal cron rewrites this very file from its bundled
# template, so nothing but the server_name is ever meant to be hand-edited here.
NGINX_VER="$(nginx -v 2>&1 | sed -n 's/.*nginx\///p' | awk '{print $1}')"
NGINX_BUILD="$(nginx -V 2>&1 || true)"
version_ge() { printf '%s\n%s\n' "$1" "$2" | sort -V -C; }
NGINX_HTTP3=0
NGINX_HTTP2_DIRECTIVE=0
if version_ge "1.25.0" "$NGINX_VER" && grep -q 'http_v3_module' <<< "$NGINX_BUILD"; then
  NGINX_HTTP3=1
fi
if version_ge "1.25.1" "$NGINX_VER"; then
  NGINX_HTTP2_DIRECTIVE=1
fi

# Fills LISTEN_DIRECTIVES / TLS_DIRECTIVES for the requested flavour:
#   quic/http3 - nginx >= 1.25.1 built with --with-http_v3_module
#   quic/http2 - nginx 1.25.0 built with --with-http_v3_module ("http2 on;" is 1.25.1)
#   http2      - nginx >= 1.25.1 without the http3 module
#   legacy     - anything older: "listen 443 ssl http2"
#   plain      - fallback for a build that rejects the selected flavour
vhost_directives() {
  LISTEN_DIRECTIVES=""
  TLS_DIRECTIVES=""
  if [[ "$1" == "plain" ]]; then
    LISTEN_DIRECTIVES="  listen 443 ssl;
  listen [::]:443 ssl;"
  elif [[ "$1" == "legacy" ]]; then
    LISTEN_DIRECTIVES="  listen 443 ssl http2;
  listen [::]:443 ssl http2;"
  elif [[ "$1" == "http2" ]]; then
    LISTEN_DIRECTIVES="  listen 443 ssl;
  listen [::]:443 ssl;"
    TLS_DIRECTIVES="  http2 on;"
  elif [[ "$1" == "quic/http2" ]]; then
    LISTEN_DIRECTIVES="  listen 443 quic;
  listen 443 ssl http2;
  listen [::]:443 quic;
  listen [::]:443 ssl http2;"
    TLS_DIRECTIVES="  http3 on;"
  else
    LISTEN_DIRECTIVES="  listen 443 quic;
  listen 443 ssl;
  listen [::]:443 quic;
  listen [::]:443 ssl;"
    TLS_DIRECTIVES="  http2 on;
  http3 on;"
  fi
}

write_vhost() {
  cat > "$VHOST" <<EOF
server {
${LISTEN_DIRECTIVES}
${TLS_DIRECTIVES}
  ssl_certificate_key ${SSL_DIR}/custom-domain.key;
  ssl_certificate ${SSL_DIR}/custom-domain.crt;
  server_name ${DOMAIN};
  client_max_body_size 5048M;
  root ${WEBROOT};
  #access_log /home/clp/logs/nginx/access.log;
  error_log /home/clp/logs/nginx/error.log;
  add_header Cache-Control no-transform;
  location / {
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_pass https://127.0.0.1:8443/;
    proxy_max_temp_file_size 0;
    proxy_connect_timeout 7200;
    proxy_send_timeout 7200;
    proxy_read_timeout 7200;
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;
    proxy_temp_file_write_size 256k;
  }
}
EOF
}

if [[ "$NGINX_HTTP3" == "1" && "$NGINX_HTTP2_DIRECTIVE" == "1" ]]; then
  VHOST_FLAVOUR="quic/http3"
elif [[ "$NGINX_HTTP3" == "1" ]]; then
  VHOST_FLAVOUR="quic/http2"
elif [[ "$NGINX_HTTP2_DIRECTIVE" == "1" ]]; then
  VHOST_FLAVOUR="http2"
else
  VHOST_FLAVOUR="legacy"
fi
vhost_directives "$VHOST_FLAVOUR"
write_vhost
echo "custom-domain vhost written (nginx ${NGINX_VER:-unknown}: http3=${NGINX_HTTP3}, http2_directive=${NGINX_HTTP2_DIRECTIVE}): ${VHOST}"

# Install the helper tools before nginx is (re)loaded: sqlite3 rewrites the panel
# domain below and openssl creates the temporary placeholder certificate just
# underneath. certbot is deliberately not installed here — it is only pulled in
# when CloudPanel's own clpctl cannot issue the certificate (see below).
missing=()
command -v sqlite3 >/dev/null 2>&1 || missing+=(sqlite3)
command -v openssl >/dev/null 2>&1 || missing+=(openssl)
if (( ${#missing[@]} > 0 )); then
  apt-get update
  apt-get install -y "${missing[@]}"
fi

# --- CloudPanel CLI helpers --------------------------------------------------
# clpctl is always run as the clp user, exactly like CloudPanel's cron entries.
CLPCTL="$(command -v clpctl 2>/dev/null || true)"
if [[ -z "$CLPCTL" && -x /usr/bin/clpctl ]]; then
  CLPCTL="/usr/bin/clpctl"
fi

clpctl_run() {
  [[ -n "$CLPCTL" ]] || return 1
  su -s /bin/bash -c "$(printf '%q ' "$CLPCTL" "$@")" clp
}

CLPCTL_LIST=""
clpctl_has() {
  [[ -n "$CLPCTL" ]] || return 1
  if [[ -z "$CLPCTL_LIST" ]]; then
    CLPCTL_LIST="$(clpctl_run list --raw 2>/dev/null || true)"
    [[ -n "$CLPCTL_LIST" ]] || CLPCTL_LIST="$(clpctl_run list 2>/dev/null || true)"
  fi
  printf '%s\n' "$CLPCTL_LIST" | awk '{print $1}' | grep -qxF "$1"
}

# --- Register the domain with CloudPanel -------------------------------------
# A rewritten vhost alone leaves the panel unaware of the domain: CloudPanel
# keeps it in its own config table (key "custom_domain") and reads it both for
# Settings -> General -> "Domain Name" and for its daily
# `lets-encrypt:renew:custom-domain:certificate` cron, which does nothing while
# that key is empty. Register it before the certificate is requested so
# CloudPanel's own path can take over from here on.
#
# `clpctl app:set:config-value` is the native way (it calls ConfigManager::set);
# the SQLite write mirrors it for CLIs that do not expose the command yet and is
# idempotent — CloudPanel's own installer seeds the table with
# `INSERT INTO config (id, key, value) VALUES (NULL, ...)`.
SQL_DOMAIN="$(printf '%s' "$DOMAIN" | sed "s/'/''/g")"
CONFIG_SQL="
INSERT INTO config (id, key, value)
SELECT NULL, 'custom_domain', '${SQL_DOMAIN}'
WHERE NOT EXISTS (SELECT 1 FROM config WHERE key = 'custom_domain');
UPDATE config SET value = '${SQL_DOMAIN}' WHERE key = 'custom_domain';
"

if clpctl_has 'app:set:config-value' && clpctl_run app:set:config-value custom_domain "$DOMAIN"; then
  echo "CloudPanel custom domain registered (clpctl app:set:config-value)"
elif sqlite3 "$DB" "$CONFIG_SQL"; then
  echo "CloudPanel custom domain registered (config.custom_domain)"
else
  echo "Could not register ${DOMAIN} with CloudPanel; set it in Settings -> General -> Domain Name" >&2
fi

# The SSH login banner (/etc/update-motd.d/10-cloudpanel) reads this file, so keep
# it in sync exactly like the panel's own settings form does.
printf '%s' "$DOMAIN" > /etc/.clp_custom_domain
chown clp:clp /etc/.clp_custom_domain 2>/dev/null || true
chmod 744 /etc/.clp_custom_domain

# The custom-domain vhost points at custom-domain.{crt,key}; when those files do
# not exist yet nginx refuses to load ("BIO_new_file() failed ... No such file
# or directory") and never serves the ACME challenge. Generate a short-lived
# self-signed placeholder so nginx can start; the certificate installed below
# then overwrites it.
if [[ ! -s "${SSL_DIR}/custom-domain.crt" || ! -s "${SSL_DIR}/custom-domain.key" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "${SSL_DIR}/custom-domain.key" \
    -out "${SSL_DIR}/custom-domain.crt" \
    -subj "/CN=${DOMAIN}" >/dev/null 2>&1
  chmod 600 "${SSL_DIR}/custom-domain.key"
  chmod 644 "${SSL_DIR}/custom-domain.crt"
  echo "temporary self-signed certificate created (replaced by Let's Encrypt below)"
fi

# Load the rewritten vhost. A build whose http_v3 module is built as a dynamic
# module but not loaded still advertises it in "nginx -V", so when nginx refuses
# the selected flavour fall back to the plain "listen 443 ssl" form instead of
# leaving a configuration nginx cannot load.
if ! nginx -t; then
  if [[ "$NGINX_HTTP3" == "1" || "$NGINX_HTTP2_DIRECTIVE" == "1" ]]; then
    echo "warning: this nginx build rejected the ${VHOST_FLAVOUR} vhost; rewriting ${VHOST} in the plain 443 form" >&2
    vhost_directives plain
    write_vhost
    nginx -t
  else
    echo "nginx rejected the configuration above; ${VHOST} was left as written" >&2
    exit 1
  fi
fi
systemctl reload nginx

# --- Vhost verification -------------------------------------------------------
# Two listeners are involved and only one of them needs this vhost: CloudPanel
# serves the admin panel itself from its own instance on port 8443, which is a
# catch-all ("server_name _;"), so https://<domain>:8443 answers for any hostname
# even when no vhost exists. The file written above is the panel's port-443
# entry point and only does anything when the nginx that owns that port really
# includes it (/etc/nginx/nginx.conf -> sites-enabled/*.conf): otherwise the
# request lands on the default server and the TLS handshake is rejected
# ("unrecognized name"). Report which of the two is the case instead of leaving
# it to guesswork.
VHOST_ACTIVE="no"
if nginx -T 2>/dev/null | grep -qE "^[[:space:]]*server_name[[:space:]]+[^;]*${DOMAIN}([[:space:];])"; then
  VHOST_ACTIVE="yes"
  echo "custom-domain vhost loaded by nginx: ${VHOST}"
else
  echo "warning: ${VHOST} is not part of the configuration nginx loaded" >&2
  echo "         check that /etc/nginx/nginx.conf includes sites-enabled/*.conf;" >&2
  echo "         https://${DOMAIN}:8443 keeps working, https://${DOMAIN} does not." >&2
fi

# --- Certificate issuance ----------------------------------------------------
# CloudPanel has no stable CLI command for the admin panel's own certificate, so
# probe the installed CLI and use the first supported command; certbot is the
# last resort. The domain is registered above, so CloudPanel's own
# `renew:custom-domain:certificate` can act on it — but that command also exits 0
# without doing anything while the certificate on disk is the self-signed
# placeholder, so its exit code is not trusted: cert_ok() checks the certificate
# itself, which keeps re-runs idempotent too.
cert_ok() {
  local crt="${SSL_DIR}/custom-domain.crt"
  [[ -s "$crt" ]] || return 1
  openssl x509 -in "$crt" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt" || return 1
  openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -qE "DNS:${DOMAIN}(,|;|\$)"
}

ISSUED=""
if cert_ok; then
  echo "a Let's Encrypt certificate for ${DOMAIN} is already installed; keeping it"
  ISSUED="existing certificate"
elif clpctl_has 'lets-encrypt:install:custom-domain:certificate'; then
  echo "issuing the certificate with CloudPanel (clpctl lets-encrypt:install:custom-domain:certificate)"
  if clpctl_run lets-encrypt:install:custom-domain:certificate --domainName="$DOMAIN"; then
    ISSUED="clpctl lets-encrypt:install:custom-domain:certificate"
  fi
elif clpctl_has 'lets-encrypt:renew:custom-domain:certificate'; then
  echo "issuing the certificate with CloudPanel (clpctl lets-encrypt:renew:custom-domain:certificate)"
  if clpctl_run lets-encrypt:renew:custom-domain:certificate; then
    ISSUED="clpctl lets-encrypt:renew:custom-domain:certificate"
  fi
elif clpctl_has 'lets-encrypt:install:certificate' && [[ -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" ]]; then
  echo "issuing the certificate with CloudPanel (clpctl lets-encrypt:install:certificate)"
  if clpctl_run lets-encrypt:install:certificate --domainName="$DOMAIN"; then
    ISSUED="clpctl lets-encrypt:install:certificate"
  fi
fi

# The renew namespace was dropped in CloudPanel CLI 6.0.8, so a command may exist
# in the probe yet do nothing; only trust it once a real certificate is on disk.
if [[ -n "$ISSUED" && "$ISSUED" != "existing certificate" ]] && ! cert_ok; then
  echo "CloudPanel did not install a usable Let's Encrypt certificate for ${DOMAIN}" >&2
  ISSUED=""
fi

if [[ -n "$ISSUED" ]]; then
  echo "certificate ready (${ISSUED})"
  nginx -t
  systemctl reload nginx
else
  # Fallback: issue with certbot's webroot plugin. It writes to /etc/letsencrypt,
  # which CloudPanel's renewal cron never touches, so the two cannot fight over
  # the certificate files. The webroot is CloudPanel's own challenge directory:
  # the panel listener serves it over the port-80 -> https redirect, which is how
  # the panel's own clpctl path validates too. The deploy hook keeps the copies
  # nginx actually reads in sync on every renewal, so a renewed certificate does
  # not sit unused in /etc/letsencrypt while nginx serves the expired one.
  echo "falling back to certbot for the certificate" >&2
  command -v certbot >/dev/null 2>&1 || { apt-get update; apt-get install -y certbot; }
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
    --agree-tos --register-unsafely-without-email --non-interactive \
    --deploy-hook "install -m 600 /etc/letsencrypt/live/${DOMAIN}/privkey.pem ${SSL_DIR}/custom-domain.key && install -m 644 /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${SSL_DIR}/custom-domain.crt && systemctl reload nginx"
  install -m 600 "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${SSL_DIR}/custom-domain.key"
  install -m 644 "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${SSL_DIR}/custom-domain.crt"

  sed -E -i \
    -e "s#^[[:space:]]*ssl_certificate_key[[:space:]]+.*;#  ssl_certificate_key ${SSL_DIR}/custom-domain.key;#" \
    -e "s#^[[:space:]]*ssl_certificate[[:space:]]+.*;#  ssl_certificate ${SSL_DIR}/custom-domain.crt;#" \
    "$VHOST"

  nginx -t
  systemctl reload nginx
fi

# Rewrite any leftover reference to the previous panel domain. The query walks
# every table/column except the "site" table and replaces values exactly equal to
# the previous domain; the identifier regex guards against odd table/column names
# before interpolating. The domain itself is already registered above, so a run
# with no previous domain needs nothing here.
if [[ -n "$OLD_DOMAIN" && "$OLD_DOMAIN" != "$DOMAIN" ]]; then
  SQL_OLD="$(printf '%s' "$OLD_DOMAIN" | sed "s/'/''/g")"
  sqlite3 "$DB" "
    SELECT m.name, p.name
    FROM sqlite_master m
    JOIN pragma_table_info(m.name) p
    WHERE m.type = 'table'
      AND m.name NOT LIKE 'sqlite_%'
      AND m.name != 'site';
  " | while IFS='|' read -r TABLE COLUMN; do
    [[ "$COLUMN" =~ ^[A-Za-z0-9_]+$ && "$TABLE" =~ ^[A-Za-z0-9_]+$ ]] || continue
    sqlite3 "$DB" "UPDATE ${TABLE} SET ${COLUMN} = '${SQL_DOMAIN}' WHERE ${COLUMN} = '${SQL_OLD}';" 2>/dev/null || true
  done
  echo "SQLite values equal to ${OLD_DOMAIN} were changed to ${DOMAIN}, excluding the site table."
else
  echo "No previous domain to replace, so SQLite was not rewritten."
fi

# CloudPanel's own clpctl was already given the chance to issue the certificate
# (see "Certificate issuance" above) and the domain is registered in its config
# table, so Settings -> General -> "Domain Name" and CloudPanel's own renewal
# cron see it too.
if [[ "$VHOST_ACTIVE" == "yes" ]]; then
  echo "Panel URL: https://${DOMAIN}"
else
  echo "Panel URL: https://${DOMAIN}:8443 (the vhost that serves port 443 is not loaded - see the warning above)" >&2
fi
