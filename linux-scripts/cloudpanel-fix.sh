#!/bin/bash
# Cloudflare Fail2Ban + nginx hardening
# Branches config on the installed nginx build so outdated packages do not
# receive directives they reject (quic, http3, http2 on, ssl_reject_handshake,
# ssl_conf_command, brotli).
set -euo pipefail

########## Detect nginx version and optional modules ##########
# quic / http3 on          : nginx >= 1.25.0 built with --with-http_v3_module
# http2 on                 : nginx >= 1.25.1 (older builds use "listen ... http2")
# ssl_reject_handshake     : nginx >= 1.19.4
# ssl_conf_command (KTLS)  : nginx >= 1.19.4
# brotli*                  : only if the ngx_brotli module snippet/object is installed
NGINX_VER=$(nginx -v 2>&1 | sed -n 's/.*nginx\///p' | awk '{print $1}')
NGINX_BUILD=$(nginx -V 2>&1 || true)
version_ge() { printf '%s\n%s\n' "$1" "$2" | sort -V -C; }

NGINX_HTTP3=0
NGINX_HTTP2_DIRECTIVE=0
NGINX_MODERN_SSL=0
NGINX_BROTLI=0

if version_ge "1.25.0" "$NGINX_VER" && grep -q 'http_v3_module' <<< "$NGINX_BUILD"; then
    NGINX_HTTP3=1
fi
if version_ge "1.25.1" "$NGINX_VER"; then
    NGINX_HTTP2_DIRECTIVE=1
fi
if version_ge "1.19.4" "$NGINX_VER"; then
    NGINX_MODERN_SSL=1
fi
if [[ -e /etc/nginx/modules-enabled/50-mod-ngx-brotli.conf ]] \
    || [[ -e /usr/share/nginx/modules-available/ngx_http_brotli_filter_module.so ]] \
    || [[ -e /usr/lib/nginx/modules/ngx_http_brotli_filter_module.so ]] \
    || grep -qi 'brotli' <<< "$NGINX_BUILD"; then
    NGINX_BROTLI=1
fi

echo "nginx ${NGINX_VER}: http3=${NGINX_HTTP3} http2_directive=${NGINX_HTTP2_DIRECTIVE} modern_ssl=${NGINX_MODERN_SSL} brotli=${NGINX_BROTLI}"

########## Write /usr/local/bin/cf-fail2ban.sh file to enable CloudFlare ban/unban calls ##########
sudo tee /usr/local/bin/cf-fail2ban.sh > /dev/null << 'EOF'
#!/bin/bash
ACTION="$1"
NAME="$2"
IP="$3"
CF_ACCOUNT="<<cf account id>>"
CF_TOKEN="<<cf Account.Account Firewall Access Rules token>>"
CF_TARGET="ip"
API_URL="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/firewall/access_rules/rules"
if [ "$ACTION" = "ban" ]; then
    curl -s -o /dev/null -X POST "$API_URL" \
         -H "Authorization: Bearer $CF_TOKEN" \
         -H "Content-Type: application/json" \
         -d "{\"mode\":\"block\",\"configuration\":{\"target\":\"$CF_TARGET\",\"value\":\"$IP\"},\"notes\":\"Fail2Ban $NAME\"}"
elif [ "$ACTION" = "unban" ]; then
    RULE_ID=$(curl -s -X GET "$API_URL?mode=block&configuration.target=$CF_TARGET&configuration.value=$IP&page=1&per_page=1" \
              -H "Authorization: Bearer $CF_TOKEN" \
              -H "Content-Type: application/json" \
              | jq -r '.result[0].id // empty')
    if [ -n "$RULE_ID" ]; then
        curl -s -o /dev/null -X DELETE "$API_URL/$RULE_ID" \
             -H "Authorization: Bearer $CF_TOKEN" \
             -H "Content-Type: application/json"
    fi
fi
EOF
########## Make /usr/local/bin/cf-fail2ban.sh executable ##########
sudo chmod +x /usr/local/bin/cf-fail2ban.sh
########## Update /etc/fail2ban/action.d/ui-custom-action.conf to trigger CF script by Fail2Ban ##########
sudo grep -q "cf-fail2ban.sh ban" /etc/fail2ban/action.d/ui-custom-action.conf || \
sudo sed -i 's|^actionban = |actionban = /usr/local/bin/cf-fail2ban.sh ban "<name>" "<ip>"\n            |' /etc/fail2ban/action.d/ui-custom-action.conf
sudo grep -q "cf-fail2ban.sh unban" /etc/fail2ban/action.d/ui-custom-action.conf || \
sudo sed -i 's|^actionunban = |actionunban = /usr/local/bin/cf-fail2ban.sh unban "<name>" "<ip>"\n              |' /etc/fail2ban/action.d/ui-custom-action.conf
########## Add crontab to read cloudflare/ips and write conf.d/cloudflare_realip.conf for nginx ##########
# The "|| true" keeps "set -e" from aborting when root has no crontab yet (crontab -l
# exits 1) or when grep -v selects nothing; previously that killed the whole script.
{
    sudo crontab -l 2>/dev/null | grep -v 'cloudflare_realip.conf' || true
    echo "49 7 * * * sed -e 's/allow/set_real_ip_from/' -e '/deny all;/d' /etc/nginx/cloudflare/ips > /etc/nginx/conf.d/cloudflare_realip.conf && systemctl reload nginx"
} | sudo crontab -

########## Rewrite nginx.conf file ##########
# Shared body. ssl_conf_command and brotli are appended only when the build accepts them.
sudo tee /etc/nginx/nginx.conf > /dev/null << 'EOF'
user root;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 8192;
include /etc/nginx/modules-enabled/*.conf;
events {
    worker_connections 2000;
    # multi_accept on;
}
http {
    real_ip_recursive on;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    include /etc/nginx/conf.d/cloudflare_realip.conf;
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    log_format cloudflare '$http_cf_connecting_ip - $remote_user [$time_local] "$request" '
                          '$status $body_bytes_sent "$http_referer" '
                          '"$http_user_agent" "$http_x_forwarded_for"';
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    client_max_body_size 64M;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 128;
    server_tokens off;
    port_in_redirect off;
    disable_symlinks if_not_owner from=/home/;
    map $scheme $fastcgi_https { ## Detect when HTTPS is used
      default off;
      https on;
    }
    include /etc/nginx/blocked_ips;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
    ssl_prefer_server_ciphers on;
    include /etc/nginx/conf.d/ssl_ktls.conf;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_dhparam /etc/nginx/ssl/dhparams.pem;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    limit_req_zone $binary_remote_addr zone=limit:10m rate=1r/s;
    limit_req_zone $binary_remote_addr zone=static:5m rate=30r/s;
    gzip on;
    gzip_disable "msie6";
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript image/svg+xml;
    include /etc/nginx/conf.d/brotli.conf;
    include /etc/nginx/sites-enabled/*.conf;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }
}
EOF
########## Write ssl_ktls.conf (nginx >= 1.19.4 only; empty on outdated builds) ##########
if [ "$NGINX_MODERN_SSL" = "1" ]; then
sudo tee /etc/nginx/conf.d/ssl_ktls.conf > /dev/null << 'EOF'
ssl_conf_command Options KTLS;
EOF
else
sudo tee /etc/nginx/conf.d/ssl_ktls.conf > /dev/null << 'EOF'
# ssl_conf_command is not available before nginx 1.19.4; KTLS line omitted
EOF
fi
########## Write brotli.conf (only when ngx_brotli is installed; empty otherwise) ##########
if [ "$NGINX_BROTLI" = "1" ]; then
sudo tee /etc/nginx/conf.d/brotli.conf > /dev/null << 'EOF'
brotli on;
brotli_comp_level 6;
brotli_static on;
brotli_types text/plain text/css application/json application/x-javascript text/xml application/xml application/xml+rss text/javascript application/javascript image/svg+xml;
EOF
else
sudo tee /etc/nginx/conf.d/brotli.conf > /dev/null << 'EOF'
# ngx_brotli is not installed on this build; brotli directives omitted
EOF
fi

########## Rewrite global_settings file ##########
if [ "$NGINX_HTTP3" = "1" ]; then
########## global_settings with Alt-Svc (HTTP/3 capable nginx) ##########
sudo tee /etc/nginx/global_settings > /dev/null << 'EOF'
  ### Include security headers for the server block
  include /etc/nginx/security_headers;
  ### BEGIN Enabling Nostr domain validation and Lightning Address
  location ~ ^/.well-known/(nostr.json|lnurlp/.*) {
    add_header Content-Type application/json always;
    add_header Access-Control-Allow-Origin * always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header alt-svc 'h3=":443"; ma=86400' always;
  }
  ### END Enabling Nostr domain validation and Lightning Address
  ### BEGIN Settings for Traffic Advice
  location = /.well-known/traffic-advice {
    types { }
    default_type "application/trafficadvice+json; charset=utf-8";
    allow all;
  }
  ### END Settings for Traffic Advice
  ### BEGIN Redirect security.txt
  location /.well-known/security.txt {
      if ($host != 'icc.gg') {
          return 301 https://icc.gg/.well-known/security.txt;
      }
  }
  ### END Redirect security.txt
  ### BEGIN Deny access to hidden files and version control
  location ~ /\.(ht|svn|git) {
    deny all;
    access_log off;
    log_not_found off;
  }
  ### END Deny access to hidden files and version control
  ### BEGIN Block for WordPress legacy RPC 
  location = /xmlrpc.php {
    deny all;
  }
  ### END Block for WordPress legacy RPC 
EOF
else
########## global_settings without Alt-Svc (nginx without QUIC/HTTP3) ##########
sudo tee /etc/nginx/global_settings > /dev/null << 'EOF'
  ### Include security headers for the server block
  include /etc/nginx/security_headers;
  ### BEGIN Enabling Nostr domain validation and Lightning Address
  location ~ ^/.well-known/(nostr.json|lnurlp/.*) {
    add_header Content-Type application/json always;
    add_header Access-Control-Allow-Origin * always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
  }
  ### END Enabling Nostr domain validation and Lightning Address
  ### BEGIN Settings for Traffic Advice
  location = /.well-known/traffic-advice {
    types { }
    default_type "application/trafficadvice+json; charset=utf-8";
    allow all;
  }
  ### END Settings for Traffic Advice
  ### BEGIN Redirect security.txt
  location /.well-known/security.txt {
      if ($host != 'icc.gg') {
          return 301 https://icc.gg/.well-known/security.txt;
      }
  }
  ### END Redirect security.txt
  ### BEGIN Deny access to hidden files and version control
  location ~ /\.(ht|svn|git) {
    deny all;
    access_log off;
    log_not_found off;
  }
  ### END Deny access to hidden files and version control
  ### BEGIN Block for WordPress legacy RPC 
  location = /xmlrpc.php {
    deny all;
  }
  ### END Block for WordPress legacy RPC 
EOF
fi

########## Write security_headers file ##########
if [ "$NGINX_HTTP3" = "1" ]; then
########## security_headers with Alt-Svc (HTTP/3 capable nginx) ##########
sudo tee /etc/nginx/security_headers > /dev/null << 'EOF'
  ### BEGIN Header security standards
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
  add_header X-Frame-Options SAMEORIGIN always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;
  add_header Permissions-Policy "geolocation=(), microphone=(), accelerometer=(), camera=(), gyroscope=(), magnetometer=(), payment=(), usb=(), display-capture=(), midi=()" always;
  add_header Content-Security-Policy "img-src https: data: blob:; script-src 'unsafe-inline' 'unsafe-eval'; script-src-elem 'self' 'unsafe-inline' blob: https: data:; style-src 'self' 'unsafe-inline'; style-src-elem 'self' 'unsafe-inline' https:; frame-src 'self' blob: https:; worker-src 'self' blob:; frame-ancestors 'self'; object-src 'self'; base-uri about: https:; upgrade-insecure-requests;" always;
  add_header alt-svc 'h3=":443"; ma=86400' always;
  ### END Header security standards
EOF
else
########## security_headers without Alt-Svc (nginx without QUIC/HTTP3) ##########
sudo tee /etc/nginx/security_headers > /dev/null << 'EOF'
  ### BEGIN Header security standards
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
  add_header X-Frame-Options SAMEORIGIN always;
  add_header X-Content-Type-Options nosniff always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;
  add_header Permissions-Policy "geolocation=(), microphone=(), accelerometer=(), camera=(), gyroscope=(), magnetometer=(), payment=(), usb=(), display-capture=(), midi=()" always;
  add_header Content-Security-Policy "img-src https: data: blob:; script-src 'unsafe-inline' 'unsafe-eval'; script-src-elem 'self' 'unsafe-inline' blob: https: data:; style-src 'self' 'unsafe-inline'; style-src-elem 'self' 'unsafe-inline' https:; frame-src 'self' blob: https:; worker-src 'self' blob:; frame-ancestors 'self'; object-src 'self'; base-uri about: https:; upgrade-insecure-requests;" always;
  ### END Header security standards
EOF
fi

########## Rewrite sites-enabled/default.conf ##########
if [ "$NGINX_HTTP3" = "1" ]; then
########## default.conf with QUIC listeners (HTTP/3 capable nginx) ##########
sudo tee /etc/nginx/sites-enabled/default.conf > /dev/null << 'EOF'
### 1. HTTP (Port 80) Catch-All: Redirects ALL HTTP traffic to HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    # Upgrades all port 80 traffic to HTTPS preserving the requested domain
    return 301 https://$host$request_uri;
}
### 2. HTTPS (Port 443) Catch-All: Drops unmatched SSL/TLS connections
server {
    listen 443 default_server ssl;
    listen [::]:443 default_server ssl;
    listen 443 quic reuseport default_server;
    listen [::]:443 quic reuseport default_server;
    server_name _;
    # Aborts TLS handshake if domain SNI does not match any vhost block
    ssl_reject_handshake on;
    # Fallback to close connection cleanly without response headers
    return 444;
}
EOF
elif [ "$NGINX_MODERN_SSL" = "1" ]; then
########## default.conf without QUIC (nginx >= 1.19.4, no http_v3_module) ##########
sudo tee /etc/nginx/sites-enabled/default.conf > /dev/null << 'EOF'
### 1. HTTP (Port 80) Catch-All: Redirects ALL HTTP traffic to HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    # Upgrades all port 80 traffic to HTTPS preserving the requested domain
    return 301 https://$host$request_uri;
}
### 2. HTTPS (Port 443) Catch-All: Drops unmatched SSL/TLS connections
# QUIC listeners omitted: this build has no http_v3_module
server {
    listen 443 default_server ssl;
    listen [::]:443 default_server ssl;
    server_name _;
    # Aborts TLS handshake if domain SNI does not match any vhost block
    ssl_reject_handshake on;
    # Fallback to close connection cleanly without response headers
    return 444;
}
EOF
else
########## default.conf legacy (nginx < 1.19.4: no quic, no ssl_reject_handshake) ##########
sudo tee /etc/nginx/sites-enabled/default.conf > /dev/null << 'EOF'
### 1. HTTP (Port 80) Catch-All: Redirects ALL HTTP traffic to HTTPS
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    # Upgrades all port 80 traffic to HTTPS preserving the requested domain
    return 301 https://$host$request_uri;
}
### 2. HTTPS (Port 443) Catch-All: Drops unmatched SSL/TLS connections
# QUIC listeners omitted: this build has no http_v3_module
# ssl_reject_handshake omitted: directive added in nginx 1.19.4
server {
    listen 443 default_server ssl;
    listen [::]:443 default_server ssl;
    server_name _;
    # Fallback to close connection cleanly without response headers
    return 444;
}
EOF
fi

########## Remove all legacy GEOIP features ##########
sudo find /etc/nginx -type f -exec sed -i '/GEOIP_/Id' {} +
sudo rm -rf /etc/nginx/geoip
sudo rm -f /etc/nginx/proxy.conf
sudo rm -f /etc/nginx/modules-enabled/50-mod-http-geoip.conf
sudo rm -f /usr/share/nginx/modules-available/mod-http-geoip.conf
########## Rename to disable all extra modules on nginx but brotli ##########
# nullglob avoids a literal "*.conf" rename when modules-enabled is empty
# any *brotli* snippet is kept, not only 50-mod-ngx-brotli.conf
sudo bash -c 'cd /etc/nginx/modules-enabled && shopt -s nullglob && for f in *.conf; do [[ "$f" == *brotli* ]] && continue; mv "$f" "${f%.conf}.disabled"; done'
########## Rewrite custom-domain.conf file ##########
DOMAIN=$(sudo grep -m1 -E '^\s*server_name\s+' /etc/nginx/sites-enabled/custom-domain.conf 2>/dev/null \
    | sed -e 's/^[[:space:]]*server_name[[:space:]]\+//' -e 's/;.*//' || true)
if [ "$NGINX_HTTP3" = "1" ] && [ "$NGINX_HTTP2_DIRECTIVE" = "1" ]; then
########## custom-domain.conf with QUIC + http2/http3 directives (nginx >= 1.25.1 with http_v3) ##########
cat << 'EOF' | sed "s/{{DOMAIN}}/$DOMAIN/g" | sudo tee /etc/nginx/sites-enabled/custom-domain.conf > /dev/null
server {
  listen 443 quic;
  listen 443 ssl;
  listen [::]:443 quic;
  listen [::]:443 ssl;
  http2 on;
  http3 on;
  ssl_certificate_key /etc/nginx/ssl-certificates/custom-domain.key;
  ssl_certificate /etc/nginx/ssl-certificates/custom-domain.crt;
  server_name {{DOMAIN}};
  client_max_body_size 5048M;
  root /home/clp/htdocs/app/files/public;
  #access_log /home/clp/logs/nginx/access.log;
  error_log /home/clp/logs/nginx/error.log;
  add_header Cache-Control no-transform;
  location / {
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Host $http_host;
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
elif [ "$NGINX_HTTP3" = "1" ]; then
########## custom-domain.conf with QUIC and legacy listen http2 (nginx 1.25.0 with http_v3) ##########
cat << 'EOF' | sed "s/{{DOMAIN}}/$DOMAIN/g" | sudo tee /etc/nginx/sites-enabled/custom-domain.conf > /dev/null
server {
  listen 443 quic;
  listen 443 ssl http2;
  listen [::]:443 quic;
  listen [::]:443 ssl http2;
  http3 on;
  ssl_certificate_key /etc/nginx/ssl-certificates/custom-domain.key;
  ssl_certificate /etc/nginx/ssl-certificates/custom-domain.crt;
  server_name {{DOMAIN}};
  client_max_body_size 5048M;
  root /home/clp/htdocs/app/files/public;
  #access_log /home/clp/logs/nginx/access.log;
  error_log /home/clp/logs/nginx/error.log;
  add_header Cache-Control no-transform;
  location / {
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Host $http_host;
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
elif [ "$NGINX_HTTP2_DIRECTIVE" = "1" ]; then
########## custom-domain.conf without QUIC, http2 directive (nginx >= 1.25.1, no http_v3) ##########
cat << 'EOF' | sed "s/{{DOMAIN}}/$DOMAIN/g" | sudo tee /etc/nginx/sites-enabled/custom-domain.conf > /dev/null
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  http2 on;
  ssl_certificate_key /etc/nginx/ssl-certificates/custom-domain.key;
  ssl_certificate /etc/nginx/ssl-certificates/custom-domain.crt;
  server_name {{DOMAIN}};
  client_max_body_size 5048M;
  root /home/clp/htdocs/app/files/public;
  #access_log /home/clp/logs/nginx/access.log;
  error_log /home/clp/logs/nginx/error.log;
  add_header Cache-Control no-transform;
  location / {
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Host $http_host;
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
else
########## custom-domain.conf legacy listen http2 (nginx < 1.25.1, no quic) ##########
cat << 'EOF' | sed "s/{{DOMAIN}}/$DOMAIN/g" | sudo tee /etc/nginx/sites-enabled/custom-domain.conf > /dev/null
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  ssl_certificate_key /etc/nginx/ssl-certificates/custom-domain.key;
  ssl_certificate /etc/nginx/ssl-certificates/custom-domain.crt;
  server_name {{DOMAIN}};
  client_max_body_size 5048M;
  root /home/clp/htdocs/app/files/public;
  #access_log /home/clp/logs/nginx/access.log;
  error_log /home/clp/logs/nginx/error.log;
  add_header Cache-Control no-transform;
  location / {
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Host $http_host;
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
clear || true
########## Execute crontab line, test and restart fail2ban & nginx ##########
sudo sed -e 's/allow/set_real_ip_from/' -e '/deny all;/d' /etc/nginx/cloudflare/ips | sudo tee /etc/nginx/conf.d/cloudflare_realip.conf > /dev/null
sudo fail2ban-client -t && sudo fail2ban-client reload
sudo nginx -t && sudo systemctl reload nginx
echo "Applied nginx ${NGINX_VER} profile: http3=${NGINX_HTTP3} http2_directive=${NGINX_HTTP2_DIRECTIVE} modern_ssl=${NGINX_MODERN_SSL} brotli=${NGINX_BROTLI}"
