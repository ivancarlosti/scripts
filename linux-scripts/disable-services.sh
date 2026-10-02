#!/bin/bash
# Disable unused services
# Disables and stops services that are not needed on a typical web/application
# server, so they neither consume resources nor expose extra attack surface.
# Services that are not installed are skipped, so the script is safe to re-run.
set -euo pipefail

########## Services to disable and stop ##########
SERVICES=(
    php7.1-fpm
    php7.2-fpm
    php7.3-fpm
    memcached
    postfix
    proftpd
    ufw
    varnish
)

########## Disable + stop each service, skipping the ones not installed ##########
for service in "${SERVICES[@]}"; do
    if systemctl cat "${service}.service" > /dev/null 2>&1; then
        echo "Disabling ${service}"
        sudo systemctl disable "${service}" --now
    else
        echo "Skipping ${service} (not installed)"
    fi
done

echo "Unused services disabled."
