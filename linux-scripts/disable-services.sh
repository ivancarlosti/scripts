#!/bin/bash
# Disable unused services
# Disables and stops services that are not needed on a typical web/application
# server, so they neither consume resources nor expose extra attack surface.
# Services that are not installed are skipped, so the script is safe to re-run.
set -euo pipefail

########## End-of-life PHP branches to disable, stop and mask ##########
# PHP 7.1-8.1 receive no fixes from the PHP project and are all affected by the
# critical core RCEs CVE-2026-109618 (RCE via OOM corruption) and
# CVE-2026-109619 (RCE via stale global state), CVSS 9.2. Upstream only
# backported the fix to 7.4, 8.0 and 8.1 as source patches, so applications
# still served by these branches must move to a supported one (8.3+).
PHP_VERSIONS=(
    7.1
    7.2
    7.3
    7.4
    8.0
    8.1
)

########## Other services to disable and stop ##########
SERVICES=(
    memcached
    postfix
    proftpd
    ufw
    varnish
)

########## Mask the PHP units so upgrades cannot re-enable them ##########
MASK_PHP="${MASK_PHP:-1}"

########## Stop a PHP branch even when nginx still references it ##########
FORCE_PHP="${FORCE_PHP:-0}"

########## Directories scanned for nginx references to a PHP-FPM branch ##########
NGINX_DIRS=(
    /etc/nginx
)
for site_conf in /home/*/conf; do
    if [[ -d "${site_conf}" ]]; then
        NGINX_DIRS+=("${site_conf}")
    fi
done

########## Print the unit providing a PHP branch, if installed ##########
# Debian, Ubuntu and CloudPanel ship phpX.Y-fpm.service; some builds name the
# unit after the binary (php-fpmX.Y.service), so both spellings are probed.
php_unit() {
    local version=$1 candidate
    for candidate in "php${version}-fpm" "php-fpm${version}"; do
        if systemctl cat "${candidate}.service" > /dev/null 2>&1; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

########## Check whether any nginx config still points at a PHP branch ##########
php_in_use() {
    local version=$1 dir pattern
    for dir in "${NGINX_DIRS[@]}"; do
        for pattern in "php${version}-fpm" "php-fpm${version}"; do
            if grep -rqsF "${pattern}" "${dir}" 2>/dev/null; then
                return 0
            fi
        done
    done
    return 1
}

disabled=()
masked=()
skipped=()
in_use=()
failed=()

########## Disable, stop and mask the end-of-life PHP pools ##########
for version in "${PHP_VERSIONS[@]}"; do
    if ! unit=$(php_unit "${version}"); then
        skipped+=("php${version}-fpm")
        echo "Skipping PHP ${version} (not installed)"
        continue
    fi

    if [[ "${FORCE_PHP}" != "1" ]] && php_in_use "${version}"; then
        in_use+=("${unit}")
        echo "Skipping ${unit} (nginx still uses php${version}-fpm, set FORCE_PHP=1 to stop it)"
        continue
    fi

    echo "Disabling ${unit}"
    if ! sudo systemctl disable --now "${unit}"; then
        failed+=("${unit}")
        continue
    fi
    disabled+=("${unit}")

    if [[ "${MASK_PHP}" == "1" ]]; then
        if sudo systemctl mask "${unit}"; then
            masked+=("${unit}")
        else
            failed+=("mask ${unit}")
        fi
    fi
done

########## Other services: disable + stop, skipping the ones not installed ##########
for service in "${SERVICES[@]}"; do
    if systemctl cat "${service}.service" > /dev/null 2>&1; then
        echo "Disabling ${service}"
        if sudo systemctl disable --now "${service}"; then
            disabled+=("${service}")
        else
            failed+=("${service}")
        fi
    else
        skipped+=("${service}")
        echo "Skipping ${service} (not installed)"
    fi
done

########## Summary ##########
echo "Disabled: ${#disabled[@]} (${disabled[*]:-none})"
if [[ ${#masked[@]} -gt 0 ]]; then
    echo "Masked: ${masked[*]}"
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "Skipped: ${skipped[*]}"
fi
if [[ ${#in_use[@]} -gt 0 ]]; then
    echo "In use: ${in_use[*]}"
fi
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed: ${failed[*]}"
fi

if [[ ${#in_use[@]} -gt 0 || ${#failed[@]} -gt 0 ]]; then
    echo "Unused services disabled, but see the warnings above." >&2
    exit 1
fi

echo "Unused services disabled."
