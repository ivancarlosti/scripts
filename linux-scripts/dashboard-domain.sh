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
#      (an empty "server_name ;" already present is simply filled in);
#   4. obtain the certificate with certbot (webroot) and install it as
#      /etc/nginx/ssl-certificates/custom-domain.{crt,key};
#   5. repoint the vhost at the certificate and reload nginx;
#   6. rewrite every "old domain" value in the CloudPanel database (the site
#      table is intentionally left untouched);
#   7. renew the CloudPanel custom-domain certificate via clpctl.
#
# Requirements: root, an existing CloudPanel install (nginx + clpctl + sqlite3)
# and a DNS A/AAAA record that already resolves <domain> to this server.
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

The script rewrites the panel vhost, issues a Let's Encrypt certificate for
<domain> and updates the domain stored in the CloudPanel database.
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
    if [[ -n "$OLD_DOMAIN" ]]; then
      echo "server_name changed: ${OLD_DOMAIN} -> ${DOMAIN}"
    else
      echo "empty server_name set to: ${DOMAIN}"
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

nginx -t
systemctl reload nginx

missing=()
command -v certbot >/dev/null 2>&1 || missing+=(certbot)
command -v sqlite3 >/dev/null 2>&1 || missing+=(sqlite3)
if (( ${#missing[@]} > 0 )); then
  apt-get update
  apt-get install -y "${missing[@]}"
fi

# Request (or reuse) the Let's Encrypt certificate with the webroot plugin.
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

# Let CloudPanel regenerate its own custom-domain certificate metadata.
su -s /bin/bash -c '/usr/bin/clpctl lets-encrypt:renew:custom-domain:certificate' clp || true
echo "Panel URL: https://${DOMAIN}"
