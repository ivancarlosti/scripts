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
#   3. rewrite (or create) the custom-domain nginx vhost and its ACME location
#      (an empty "server_name ;" already present is simply filled in; a missing
#      vhost is written as a CloudPanel-style reverse proxy to
#      https://127.0.0.1:8443);
#   4. create a temporary self-signed placeholder when the certificate files are
#      missing, so nginx can load the vhost while the ACME HTTP-01 challenge is
#      served from /var/www/clp-acme;
#   5. obtain the certificate with CloudPanel itself, probing clpctl and using
#      the first command the installed CLI actually provides (see below); only
#      when CloudPanel cannot issue it is certbot installed and used;
#   6. install the certificate as
#      /etc/nginx/ssl-certificates/custom-domain.{crt,key} and reload nginx;
#   7. rewrite every "old domain" value in the CloudPanel database (the site
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
# certificate for <domain> actually landed on disk. certbot (--webroot; it
# writes to /etc/letsencrypt, which CloudPanel's renewal cron never touches) is
# used only when none of those commands works.
#
# Requirements: root, an existing CloudPanel install (nginx + clpctl) and a DNS
# A/AAAA record that already resolves <domain> to this server.
set -euo pipefail

DB="/home/clp/htdocs/app/data/db.sq3"
VHOST="/etc/nginx/sites-enabled/custom-domain.conf"
SSL_DIR="/etc/nginx/ssl-certificates"
WEBROOT="/var/www/clp-acme"

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
install -d -m 755 "$WEBROOT" "$SSL_DIR"

OLD_DOMAIN=""
if [[ -f "$VHOST" ]]; then
  # The custom-domain vhost may already declare server_name but leave it empty
  # ("server_name ;") before a domain is configured — that is not an error, the
  # script simply fills it in. A missing directive altogether is still an error.
  if grep -qE '^[[:space:]]*server_name[[:space:]]+' "$VHOST"; then
    OLD_DOMAIN="$(grep -m1 -E '^[[:space:]]*server_name[[:space:]]+' "$VHOST" \
      | sed -E 's/^[[:space:]]*server_name[[:space:]]+//; s/[[:space:]]*;.*//')"
    sed -E -i "s/^([[:space:]]*server_name[[:space:]]+).*/\1${DOMAIN};/" "$VHOST"
    if [[ -z "$OLD_DOMAIN" ]]; then
      echo "empty server_name set to: ${DOMAIN}"
    elif [[ "$OLD_DOMAIN" == "$DOMAIN" ]]; then
      echo "server_name already set to: ${DOMAIN}"
    else
      echo "server_name changed: ${OLD_DOMAIN} -> ${DOMAIN}"
    fi
  else
    echo "No server_name in $VHOST" >&2
    exit 1
  fi
else
  cat > "$VHOST" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  location ^~ /.well-known/acme-challenge/ {
    root ${WEBROOT};
    default_type "text/plain";
  }
  location / {
    return 301 https://\$host\$request_uri;
  }
}

# Reverse proxy to the panel, mirroring CloudPanel's own custom-domain vhost.
# Only the plain "listen 443 ssl" form is used so this file stays valid on every
# nginx version CloudPanel supports (no http2/http3 directive guessing).
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  ssl_certificate_key ${SSL_DIR}/custom-domain.key;
  ssl_certificate ${SSL_DIR}/custom-domain.crt;
  server_name ${DOMAIN};
  client_max_body_size 5048M;
  root /home/clp/htdocs/app/files/public;
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
fi

# Ensure an HTTP-01 challenge location exists (needed when the vhost already
# existed but had no ACME location yet).
if ! grep -q 'acme-challenge' "$VHOST"; then
  cat >> "$VHOST" <<EOF

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  location ^~ /.well-known/acme-challenge/ {
    root ${WEBROOT};
    default_type "text/plain";
  }
  location / {
    return 301 https://\$host\$request_uri;
  }
}
EOF
fi

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

nginx -t
systemctl reload nginx

# --- Certificate issuance ----------------------------------------------------
# CloudPanel has no stable CLI command for the admin panel's own certificate, so
# probe the installed CLI and use the first supported command; certbot is the
# last resort. cert_ok() makes re-runs idempotent and stops a command that exits
# 0 without actually replacing the placeholder from being treated as a success.
cert_ok() {
  local crt="${SSL_DIR}/custom-domain.crt"
  [[ -s "$crt" ]] || return 1
  openssl x509 -in "$crt" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt" || return 1
  openssl x509 -in "$crt" -noout -text 2>/dev/null | grep -qE "DNS:${DOMAIN}(,|;|\$)"
}

CLPCTL="$(command -v clpctl 2>/dev/null || true)"
if [[ -z "$CLPCTL" && -x /usr/bin/clpctl ]]; then
  CLPCTL="/usr/bin/clpctl"
fi

# clpctl is always run as the clp user, exactly like CloudPanel's cron entries.
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
  # the certificate files.
  echo "falling back to certbot for the certificate" >&2
  command -v certbot >/dev/null 2>&1 || { apt-get update; apt-get install -y certbot; }
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" \
    --agree-tos --register-unsafely-without-email --non-interactive
  install -m 600 "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" "${SSL_DIR}/custom-domain.key"
  install -m 644 "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${SSL_DIR}/custom-domain.crt"

  sed -E -i \
    -e "s#^[[:space:]]*ssl_certificate_key[[:space:]]+.*;#  ssl_certificate_key ${SSL_DIR}/custom-domain.key;#" \
    -e "s#^[[:space:]]*ssl_certificate[[:space:]]+.*;#  ssl_certificate ${SSL_DIR}/custom-domain.crt;#" \
    "$VHOST"

  nginx -t
  systemctl reload nginx
fi

# Rewrite the stored panel domain. The query walks every table/column except the
# "site" table and replaces values exactly equal to the previous domain; the
# identifier regex guards against odd table/column names before interpolating.
SQL_DOMAIN="$(printf '%s' "$DOMAIN" | sed "s/'/''/g")"
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
# (see "Certificate issuance" above), so there is nothing left to sync here.
echo "Panel URL: https://${DOMAIN}"
