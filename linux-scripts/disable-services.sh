#!/bin/bash
# Disable unused services
# Disables and stops services that are not needed on a typical web/application
# server, so they neither consume resources nor expose extra attack surface.
# End-of-life PHP-FPM pools are additionally masked so package upgrades and
# presets cannot start them again. Units that are not installed are skipped and
# the run is verified afterwards, so the script is safe to re-run.
# "--status" prints the systemd unit, process list and nginx references of each
# PHP branch without changing anything.
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

########## Directories that may hold PHP-FPM socket files ##########
SOCKET_DIRS=(
    /run/php
    /var/run/php
    /run/php-fpm
)

########## Usage ##########
usage() {
  cat >&2 <<'EOF'
Disable unused services, including the end-of-life PHP-FPM pools.

Usage:
  disable-services.sh            Disable, stop and mask the configured units
  disable-services.sh --status   Report what each end-of-life PHP branch runs
  disable-services.sh --help     Show this help

Environment:
  MASK_PHP=0    disable and stop the PHP pools without masking them
  FORCE_PHP=1   stop a PHP branch even when nginx still references it
EOF
}

MODE="apply"
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --status) MODE="status" ;;
    "") : ;;
    *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
esac

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

########## List the nginx config files that point at a PHP branch ##########
nginx_refs() {
    local version=$1 dir pattern
    for dir in "${NGINX_DIRS[@]}"; do
        for pattern in "php${version}-fpm" "php-fpm${version}"; do
            grep -rlsF "${pattern}" "${dir}" 2>/dev/null || true
        done
    done
}

########## Check whether any nginx config still points at a PHP branch ##########
php_in_use() {
    [[ -n "$(nginx_refs "$1")" ]]
}

########## List the running PHP-FPM processes of a branch, whatever the unit ##########
# pgrep matches the process name (php-fpmX.Y), which catches a master started by
# another unit or by hand and therefore not stopped by systemctl.
php_procs() {
    pgrep -x "php-fpm$1" 2>/dev/null || true
}

########## List the php-fpm binaries installed for a branch ##########
php_binaries() {
    local version=$1 candidate
    for candidate in "/usr/sbin/php-fpm${version}" "/usr/local/sbin/php-fpm${version}" \
        "/usr/bin/php-fpm${version}"; do
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
        fi
    done
    candidate=$(command -v "php-fpm${version}" 2>/dev/null || true)
    if [[ -n "${candidate}" ]]; then
        echo "${candidate}"
    fi
}

########## List the PHP-FPM socket files of a branch, if any ##########
# A leftover socket file does not prove the pool is listening, but audits that
# only look at the socket path keep flagging the branch while it exists.
php_sockets() {
    local version=$1 dir
    for dir in "${SOCKET_DIRS[@]}"; do
        if [[ -e "${dir}/php${version}-fpm.sock" ]]; then
            echo "${dir}/php${version}-fpm.sock"
        fi
        if [[ -e "${dir}/php-fpm${version}.sock" ]]; then
            echo "${dir}/php-fpm${version}.sock"
        fi
    done
}

########## Report what a branch currently runs, without changing anything ##########
php_status() {
    local version=$1 unit active enabled procs refs files binaries sockets
    if unit=$(php_unit "${version}"); then
        active=$(systemctl is-active "${unit}" 2>/dev/null || true)
        enabled=$(systemctl is-enabled "${unit}" 2>/dev/null || true)
    else
        unit="none"
        active="-"
        enabled="-"
    fi
    procs=$(php_procs "${version}" | tr '\n' ' ')
    procs="${procs% }"
    files=$(nginx_refs "${version}" | sort -u)
    refs=$(printf '%s' "${files}" | grep -c . || true)
    binaries=$(php_binaries "${version}" | sort -u | tr '\n' ' ')
    binaries="${binaries% }"
    sockets=$(php_sockets "${version}" | tr '\n' ' ')
    sockets="${sockets% }"
    echo "PHP ${version}: unit=${unit} active=${active} enabled=${enabled}" \
        "procs=${procs:--} nginx_refs=${refs} binary=${binaries:--}"
    if [[ "${refs}" -gt 0 ]]; then
        while IFS= read -r file; do
            echo "  referenced in: ${file}"
        done <<< "${files}"
    fi
    if [[ -n "${sockets}" ]]; then
        echo "  socket file: ${sockets} (may be stale, compare with active/procs)"
    fi
}

if [[ "${MODE}" == "status" ]]; then
    echo "End-of-life PHP-FPM branches (read-only report):"
    for version in "${PHP_VERSIONS[@]}"; do
        php_status "${version}"
    done
    echo "Off means active=inactive, procs empty and enabled=masked or disabled." >&2
    exit 0
fi

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

    ##### Verify the stop actually removed every process of the branch #####
    if [[ -n "$(php_procs "${version}")" ]]; then
        failed+=("php-fpm${version} still running")
        echo "Warning: php-fpm${version} is still running outside ${unit}"
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
