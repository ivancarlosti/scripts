#!/bin/bash
# Fail2Ban setup with OPTIONAL Cloudflare firewall integration
#
# Runs standalone, separate from cloudpanel-fix.sh (which now only hardens nginx).
#
# Two modes, chosen automatically from the command line:
#   * Cloudflare credentials provided -> bans/unbans IPs through the Cloudflare
#     Firewall Access Rules API (on top of the jail's own local action).
#   * No credentials                -> LOCAL banning only, using the server's
#     own firewall action (iptables/nftables). No Cloudflare API calls at all.
#
# Usage:
#   fail2ban-setup.sh [options]
#
#   --cf-account <id>          Cloudflare Account ID                        [CF_ACCOUNT]
#   --cf-token <token>         Cloudflare API Token with the Account
#                              "Firewall Access Rules: Edit" permission      [CF_TOKEN]
#   --cf-email <email>         Cloudflare account email  (legacy)           [CF_EMAIL]
#   --cf-key <key>             Cloudflare Global API Key (legacy)           [CF_KEY]
#   --cf-target <ip|hostname>  Rule target type, default "ip"              [CF_TARGET]
#                             (web protection, all sites)
#   --web | --no-web           Install the web jails (default: --web)      [WEB]
#   --badbots | --no-badbots   Scanner/User-Agent jail (default: on)       [WEB_BADBOTS]
#   --ip-source <mode>         remote | xforwarded | auto (default auto)   [WEB_IP_SOURCE]
#   --xff-hop <first|last>     Hop used by --ip-source xforwarded          [WEB_XFF_HOP]
#   --logpath <glob>           Use these access logs (repeatable)          [WEB_LOG_GLOB]
#   --extra-logpath <glob>     Add to the auto-discovered logs             [WEB_EXTRA_LOG_GLOB]
#   --ignoreip <list>          IPs/CIDRs whitelisted in every web jail     [WEB_IGNOREIP]
#   --allow-ua <regex>         Extra "never ban this UA" pattern           [WEB_ALLOW_UA]
#   --no-allowlist             Drop the built-in monitoring UA allow-list  [WEB_ALLOWLIST=0]
#   --aggressive-login         Also match generic /login, /signin, /admin  [WEB_AGGRESSIVE_LOGIN]
#   --aggressive-enum          Also match /wp-json/wp/v2/users/<any id>    [WEB_AGGRESSIVE_ENUM]
#   --web-maxretry <n>         Override maxretry of every web jail         [WEB_MAXRETRY]
#   --web-findtime <time>      Override findtime of every web jail        [WEB_FINDTIME]
#   --web-bantime <time>       Override bantime of every web jail         [WEB_BANTIME]
#   --force-ip-source          Accept a combination the gates refuse      [WEB_FORCE_IP_SOURCE]
#   --no-selftest              Skip the fail2ban-regex self-test          [WEB_SELFTEST=0]
#   --strict-selftest          Treat an inconclusive self-test as an error [WEB_SELFTEST_STRICT]
#   --dry-run                  Print the filters and jail file, write nothing
#   --status                   Show the web jails and their current bans
#   --uninstall-web            Remove filters + web jail file, keep the rest
#   -h, --help                 Show this help and exit
#
# Legacy auth requires BOTH --cf-email and --cf-key; otherwise pass --cf-token.
#
# Web protection is universal (WordPress, Joomla, Drupal, Magento, Laravel,
# n8n, static sites): no generic words are matched, every rule is anchored to a
# known scanner path or a known login endpoint, and only failed statuses count.
# It ABORTS instead of installing a filter that would match legitimate traffic.
#
# Diagnostics - same conventions as cloudpanel-fix.sh:
#   * every step is announced, so you can see exactly how far it got;
#   * an ERR trap prints the failing line, the command and the exit code;
#   * run with VERBOSE=1 for a full shell trace of every command:
#         curl -fsSL <raw-url> | sudo VERBOSE=1 bash -s -- --cf-account ... --cf-token ...
#   * the screen is NOT cleared by default so the log is preserved; set
#     CLEAR_SCREEN=1 to clear the terminal at the end.
set -euo pipefail
set -E   # let the ERR trap fire inside functions, subshells and $( ) as well

########## Diagnostics helpers ##########
VERBOSE="${VERBOSE:-0}"
CLEAR_SCREEN="${CLEAR_SCREEN:-0}"
STEP=0

if [ -t 1 ]; then
    C_B=$'\033[1;34m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
    C_B=''; C_R=''; C_0=''
fi

step() { STEP=$((STEP + 1)); printf '%s==> [step %02d] %s%s\n' "$C_B" "$STEP" "$*" "$C_0"; }
info() { printf '    - %s\n' "$*"; }
warn() { printf '%s    ! %s%s\n' "$C_R" "$*" "$C_0" >&2; }

on_error() {
    local code=$? cmd=$BASH_COMMAND line=${BASH_LINENO[0]}
    trap - ERR   # captured $? first; avoid recursive traps
    printf '\n%s!!! ABORTED at line %s (exit code %s)%s\n' "$C_R" "$line" "$code" "$C_0" >&2
    printf '    failing command : %s\n' "$cmd" >&2
    printf '    script          : %s\n' "${BASH_SOURCE[0]:-$0}" >&2
    printf '    next step       : re-run with a full trace to see the cause:\n' >&2
    printf '                      curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-setup.sh | sudo VERBOSE=1 bash\n' >&2
    exit "$code"
}
trap on_error ERR

if [ "$VERBOSE" = "1" ]; then
    PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

########## Constants ##########
HELPER_PATH="/usr/local/bin/cf-fail2ban.sh"
ACTION_FILE="/etc/fail2ban/action.d/ui-custom-action.conf"
LOCAL_JAIL="/etc/fail2ban/jail.d/zz-fail2ban-setup.conf"
# The web jails live in a ".local" file on purpose: Fail2Ban reads jail.d/*.conf
# BEFORE jail.d/*.local, and CloudPanel ships jail.d/*.local, so anything written
# to a ".conf" here would be silently overridden by CloudPanel's settings.
WEB_JAIL="/etc/fail2ban/jail.d/zz-fail2ban-setup.local"
FILTER_DIR="/etc/fail2ban/filter.d"
WEB_FILTERS=(web-probe web-login web-enum web-badbots)
WEB_STATUS_MARKER="/etc/fail2ban/.zz-fail2ban-setup-web.installed"

########## Defaults (overridable via environment, then command line) ##########
CF_ACCOUNT="${CF_ACCOUNT:-}"
CF_TOKEN="${CF_TOKEN:-}"
CF_EMAIL="${CF_EMAIL:-}"
CF_KEY="${CF_KEY:-}"
CF_TARGET="${CF_TARGET:-ip}"

WEB="${WEB:-1}"
WEB_BADBOTS="${WEB_BADBOTS:-1}"
WEB_IP_SOURCE="${WEB_IP_SOURCE:-auto}"
WEB_XFF_HOP="${WEB_XFF_HOP:-last}"
WEB_ALLOWLIST="${WEB_ALLOWLIST:-1}"
WEB_AGGRESSIVE_LOGIN="${WEB_AGGRESSIVE_LOGIN:-0}"
WEB_AGGRESSIVE_ENUM="${WEB_AGGRESSIVE_ENUM:-0}"
WEB_MAXRETRY="${WEB_MAXRETRY:-}"
WEB_FINDTIME="${WEB_FINDTIME:-}"
WEB_BANTIME="${WEB_BANTIME:-}"
WEB_FORCE_IP_SOURCE="${WEB_FORCE_IP_SOURCE:-0}"
WEB_SELFTEST="${WEB_SELFTEST:-1}"
WEB_SELFTEST_STRICT="${WEB_SELFTEST_STRICT:-0}"
WEB_SAMPLE_LINES="${WEB_SAMPLE_LINES:-200}"
DRY_RUN=0
STATUS_MODE=0
UNINSTALL_WEB=0
WEB_LOG_GLOBS=()
WEB_EXTRA_LOG_GLOBS=()
WEB_IGNOREIP_ARR=()
WEB_ALLOW_UA_ARR=()
# --logpath / --extra-logpath / --ignoreip / --allow-ua are repeatable, so seed
# the arrays from the environment values as well.
if [ -n "${WEB_LOG_GLOB:-}" ]; then WEB_LOG_GLOBS+=("$WEB_LOG_GLOB"); fi
if [ -n "${WEB_EXTRA_LOG_GLOB:-}" ]; then WEB_EXTRA_LOG_GLOBS+=("$WEB_EXTRA_LOG_GLOB"); fi
if [ -n "${WEB_IGNOREIP:-}" ]; then
    read -r -a WEB_IGNOREIP_ARR <<< "${WEB_IGNOREIP//,/ }" || true
fi
if [ -n "${WEB_ALLOW_UA:-}" ]; then WEB_ALLOW_UA_ARR+=("$WEB_ALLOW_UA"); fi

usage() {
    cat <<'EOF'
Fail2Ban setup with optional Cloudflare integration

Usage: fail2ban-setup.sh [options]

  --cf-account <id>          Cloudflare Account ID                        [CF_ACCOUNT]
  --cf-token <token>         Cloudflare API Token with the Account
                             "Firewall Access Rules: Edit" permission      [CF_TOKEN]
  --cf-email <email>         Cloudflare account email  (legacy)           [CF_EMAIL]
  --cf-key <key>             Cloudflare Global API Key (legacy)           [CF_KEY]
  --cf-target <ip|hostname>  Rule target type, default "ip"              [CF_TARGET]
  -h, --help                 Show this help and exit

Web protection (installed by default, on top of whatever already works):
  --web | --no-web           Install the stack-universal web jails        [WEB]
  --badbots | --no-badbots   Scanner User-Agent jail (default: enabled)   [WEB_BADBOTS]
  --ip-source <mode>         remote | xforwarded | auto (default: auto)   [WEB_IP_SOURCE]
                             auto picks "xforwarded" when Cloudflare edges
                             appear in the logs and real_ip is not restored
  --xff-hop <first|last>     Which X-Forwarded-For hop holds the client,
                             "last" = right-most = the one Cloudflare does
                             not let clients spoof (default: last)        [WEB_XFF_HOP]
  --logpath <glob>           Use these access logs instead of the auto
                             discovery (repeatable)                       [WEB_LOG_GLOB]
  --extra-logpath <glob>     Add to the auto-discovered access logs
                             (repeatable)                                 [WEB_EXTRA_LOG_GLOB]
  --ignoreip <ip|cidr,...>   Extra IPs/CIDRs whitelisted in every web jail
                             (repeatable, added to the existing ignoreip) [WEB_IGNOREIP]
  --allow-ua <regex>         Extra "this User-Agent is never banned" pattern
                             (repeatable)                                 [WEB_ALLOW_UA]
  --no-allowlist             Drop the built-in monitoring User-Agent
                             allow-list (Uptime Kuma, Pingdom, Datadog, ...) [WEB_ALLOWLIST=0]
  --aggressive-login         Also count generic /login, /signin, /admin
                             pages (more coverage, more false positives)  [WEB_AGGRESSIVE_LOGIN]
  --aggressive-enum          Also count /wp-json/wp/v2/users/<any id>      [WEB_AGGRESSIVE_ENUM]
  --web-maxretry <n>         Override maxretry of every web jail          [WEB_MAXRETRY]
  --web-findtime <time>      Override findtime of every web jail (e.g. 10m)[WEB_FINDTIME]
  --web-bantime <time>       Override bantime of every web jail (e.g. 4h) [WEB_BANTIME]
  --force-ip-source          Accept an IP source the safety gates refuse  [WEB_FORCE_IP_SOURCE]
  --no-selftest              Skip the fail2ban-regex self-test            [WEB_SELFTEST=0]
  --strict-selftest          Treat an inconclusive self-test as an error  [WEB_SELFTEST_STRICT]
  --dry-run                  Print the filters and the jail file without
                             writing anything (no CF wiring, no reload)
  --status                   Show the web jails and their current bans, exit
  --uninstall-web            Remove the web filters + jail file (keeps the
                             Cloudflare helper/local jail), exit

With no Cloudflare credentials the script configures LOCAL banning only
(the server's own iptables/nftables action). Legacy auth requires BOTH
--cf-email and --cf-key; otherwise pass --cf-token.

The web jails are always written to jail.d/zz-fail2ban-setup.local, which
Fail2Ban parses AFTER CloudPanel's jail.local, so per-jail settings here win.
EOF
}

########## Parse command-line options ##########
while [ "$#" -gt 0 ]; do
    case "$1" in
        --cf-account)
            [ "$#" -ge 2 ] || { warn "--cf-account requires a value"; exit 2; }
            CF_ACCOUNT="$2"; shift 2 ;;
        --cf-token)
            [ "$#" -ge 2 ] || { warn "--cf-token requires a value"; exit 2; }
            CF_TOKEN="$2"; shift 2 ;;
        --cf-email)
            [ "$#" -ge 2 ] || { warn "--cf-email requires a value"; exit 2; }
            CF_EMAIL="$2"; shift 2 ;;
        --cf-key)
            [ "$#" -ge 2 ] || { warn "--cf-key requires a value"; exit 2; }
            CF_KEY="$2"; shift 2 ;;
        --cf-target)
            [ "$#" -ge 2 ] || { warn "--cf-target requires a value"; exit 2; }
            CF_TARGET="$2"; shift 2 ;;
        --web)
            WEB=1; shift ;;
        --no-web)
            WEB=0; shift ;;
        --badbots)
            WEB_BADBOTS=1; shift ;;
        --no-badbots)
            WEB_BADBOTS=0; shift ;;
        --ip-source)
            [ "$#" -ge 2 ] || { warn "--ip-source requires a value"; exit 2; }
            WEB_IP_SOURCE="$2"; shift 2 ;;
        --xff-hop)
            [ "$#" -ge 2 ] || { warn "--xff-hop requires a value"; exit 2; }
            WEB_XFF_HOP="$2"; shift 2 ;;
        --logpath)
            [ "$#" -ge 2 ] || { warn "--logpath requires a value"; exit 2; }
            WEB_LOG_GLOBS+=("$2"); shift 2 ;;
        --extra-logpath)
            [ "$#" -ge 2 ] || { warn "--extra-logpath requires a value"; exit 2; }
            WEB_EXTRA_LOG_GLOBS+=("$2"); shift 2 ;;
        --ignoreip)
            [ "$#" -ge 2 ] || { warn "--ignoreip requires a value"; exit 2; }
            read -r -a _ip_arr <<< "${2//,/ }" || true
            WEB_IGNOREIP_ARR+=("${_ip_arr[@]}"); shift 2 ;;
        --allow-ua)
            [ "$#" -ge 2 ] || { warn "--allow-ua requires a value"; exit 2; }
            WEB_ALLOW_UA_ARR+=("$2"); shift 2 ;;
        --no-allowlist)
            WEB_ALLOWLIST=0; shift ;;
        --aggressive-login)
            WEB_AGGRESSIVE_LOGIN=1; shift ;;
        --aggressive-enum)
            WEB_AGGRESSIVE_ENUM=1; shift ;;
        --web-maxretry)
            [ "$#" -ge 2 ] || { warn "--web-maxretry requires a value"; exit 2; }
            WEB_MAXRETRY="$2"; shift 2 ;;
        --web-findtime)
            [ "$#" -ge 2 ] || { warn "--web-findtime requires a value"; exit 2; }
            WEB_FINDTIME="$2"; shift 2 ;;
        --web-bantime)
            [ "$#" -ge 2 ] || { warn "--web-bantime requires a value"; exit 2; }
            WEB_BANTIME="$2"; shift 2 ;;
        --force-ip-source)
            WEB_FORCE_IP_SOURCE=1; shift ;;
        --no-selftest)
            WEB_SELFTEST=0; shift ;;
        --strict-selftest)
            WEB_SELFTEST_STRICT=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --status)
            STATUS_MODE=1; shift ;;
        --uninstall-web)
            UNINSTALL_WEB=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            warn "unknown option: $1"
            usage >&2
            exit 2 ;;
    esac
done

########## Decide whether the Cloudflare path is enabled ##########
HAS_CF=0
if [ -n "$CF_TOKEN" ]; then
    HAS_CF=1
elif [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]; then
    HAS_CF=1
elif [ -n "$CF_EMAIL" ] || [ -n "$CF_KEY" ]; then
    warn "--cf-email and --cf-key must be provided together"
    exit 2
fi

if [ "$HAS_CF" = "1" ] && [ -z "$CF_ACCOUNT" ]; then
    warn "--cf-account is required when Cloudflare credentials are provided"
    exit 2
fi

########## Validate the web protection options ##########
case "$WEB_IP_SOURCE" in
    remote|xforwarded|auto) ;;
    *) warn "--ip-source must be remote, xforwarded or auto (got: $WEB_IP_SOURCE)"; exit 2 ;;
esac
case "$WEB_XFF_HOP" in
    first|last) ;;
    *) warn "--xff-hop must be first or last (got: $WEB_XFF_HOP)"; exit 2 ;;
esac
if [ -n "$WEB_MAXRETRY" ] && ! printf '%s' "$WEB_MAXRETRY" | grep -qE '^[0-9]+$'; then
    warn "--web-maxretry must be a number (got: $WEB_MAXRETRY)"
    exit 2
fi
if [ "$DRY_RUN" = "1" ] && [ "$UNINSTALL_WEB" = "1" ]; then
    warn "--dry-run and --uninstall-web cannot be combined"
    exit 2
fi

########## Web protection: log discovery and IP-source safety gates ##########
# Nothing in this section writes anything: it only inspects the nginx config,
# the Cloudflare ranges and the access logs, then decides which field of the log
# line really holds a bannable client address.
WEB_CF_IP_FILE="/etc/nginx/cloudflare/ips"
WEB_REALIP_FILE="/etc/nginx/conf.d/cloudflare_realip.conf"
WEB_NGINX_PREFIX="/etc/nginx"
WEB_IP_SOURCE_USED=""
WEB_REALIP=0
WEB_EDGE_SEEN=0
WEB_LOG_HAS_XFF=0
WEB_LOGPATHS=""
WEB_CF_CIDR_ARR=()
WEB_IGNOREIP_FINAL=()

########## Read a file as root (logs and /etc are not world-readable) ##########
web_tail() { sudo tail -n "$1" -- "$2" 2>/dev/null || true; }

########## Resolve the access logs the jails will watch ##########
web_find_logpaths() {
    local p f
    if [ "${#WEB_LOG_GLOBS[@]}" -gt 0 ]; then
        for p in "${WEB_LOG_GLOBS[@]}"; do
            # shellcheck disable=SC2086  # word splitting + globbing on purpose
            for f in $p; do
                if [ -f "$f" ]; then printf '%s\n' "$f"; fi
            done
        done
    else
        # CloudPanel per-site logs (nginx "main" format: client IP, trailing XFF)
        for p in /home/*/logs/nginx/*access.log; do
            if [ -f "$p" ]; then printf '%s\n' "$p"; fi
        done
        # Fallback: the http-level log (built-in "combined" format)
        for p in /var/log/nginx/*access.log; do
            if [ -f "$p" ]; then printf '%s\n' "$p"; fi
        done
    fi
    for p in "${WEB_EXTRA_LOG_GLOBS[@]}"; do
        # shellcheck disable=SC2086
        for f in $p; do
            if [ -f "$f" ]; then printf '%s\n' "$f"; fi
        done
    done
    return 0
}

########## Do the sampled lines end with a second quoted field (XFF)? ##########
web_log_lines_have_xff() {
    local f="$1" n=0
    n=$(web_tail "$WEB_SAMPLE_LINES" "$f" \
        | grep -cE '"[^"]*"[[:space:]]+"[^"]*"[[:space:]]*$' || true)
    [ "${n:-0}" -gt 0 ]
}

########## Is nginx restoring the real client IP (Cloudflare real_ip)? ##########
web_realip_configured() {
    if sudo test -f "$WEB_REALIP_FILE" \
       && sudo grep -qsE '^[[:space:]]*set_real_ip_from' "$WEB_REALIP_FILE" 2>/dev/null; then
        return 0
    fi
    if sudo test -d "$WEB_NGINX_PREFIX" \
       && sudo grep -rqsE '^[[:space:]]*real_ip_header[[:space:]]+' "$WEB_NGINX_PREFIX" 2>/dev/null; then
        return 0
    fi
    return 1
}

########## Cloudflare edge ranges: CloudPanel file, realip file, built-in ##########
web_cf_cidrs() {
    if sudo test -f "$WEB_CF_IP_FILE"; then
        sudo sed -nE 's/^[[:space:]]*(allow|set_real_ip_from)[[:space:]]+([0-9A-Fa-f.:]+(\/[0-9]+)?).*/\2/p' \
            "$WEB_CF_IP_FILE" 2>/dev/null || true
        return 0
    fi
    if sudo test -f "$WEB_REALIP_FILE"; then
        sudo sed -nE 's/^[[:space:]]*set_real_ip_from[[:space:]]+([0-9A-Fa-f.:]+(\/[0-9]+)?).*/\1/p' \
            "$WEB_REALIP_FILE" 2>/dev/null || true
        return 0
    fi
    # Last resort: the canonical ranges from https://www.cloudflare.com/ips/
    # (CloudPanel normally keeps /etc/nginx/cloudflare/ips up to date).
    printf '%s\n' \
        "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22" \
        "141.101.64.0/18" "108.162.192.0/18" "190.93.240.0/20" "188.114.96.0/20" \
        "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13" \
        "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22" \
        "2400:cb00::/32" "2606:4700::/32" "2803:f800::/32" "2405:b500::/32" \
        "2405:8100::/32" "2a06:98c0::/29" "2c0f:f248::/32"
    return 0
}

########## IPv4/IPv6 membership test, awk-only so that mawk works too ##########
ip_in_cidr() {
    awk -v ip="$1" -v cidr="$2" '
        function v4(a,   p) { split(a, p, "."); return ((p[1] * 256 + p[2]) * 256 + p[3]) * 256 + p[4] }
        BEGIN {
            split(cidr, c, "/")
            net = c[1]; bits = (c[2] == "" ? 32 : c[2] + 0)
            if (ip ~ /:/ || net ~ /:/) {
                # IPv6: whole hex groups only, so a /29 is compared as a /32 and
                # the test can only ever be broader than the real range.
                n = int(bits / 16); if (n < 1) n = 1
                split(tolower(ip), a, ":"); split(tolower(net), b, ":")
                for (i = 1; i <= n; i++) { if (a[i] != b[i]) exit 1 }
                exit 0
            }
            if (bits < 0) bits = 0
            if (bits > 32) bits = 32
            div = 2 ^ (32 - bits)
            exit (int(v4(ip) / div) == int(v4(net) / div)) ? 0 : 1
        }'
}

########## Does the address belong to a Cloudflare range? ##########
web_is_edge_ip() {
    local ip="$1" cidr
    for cidr in "${WEB_CF_CIDR_ARR[@]}"; do
        if ip_in_cidr "$ip" "$cidr"; then return 0; fi
    done
    return 1
}

########## Client addresses seen in the sampled logs (first field) ##########
web_client_ips() {
    local f
    for f in $WEB_LOGPATHS; do
        web_tail 50 "$f"
    done | awk 'NF { print $1 }' | sort -u
    return 0
}

########## Decide and justify the IP source, then gate on it ##########
web_decide_ip_source() {
    local ip fmt
    if web_realip_configured; then WEB_REALIP=1; fi
    if [ "$WEB_REALIP" = "1" ]; then
        info "nginx real_ip  : configured -> \$remote_addr is the real client"
    else
        info "nginx real_ip  : NOT configured -> \$remote_addr may be a CDN edge"
    fi
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if web_is_edge_ip "$ip"; then WEB_EDGE_SEEN=$((WEB_EDGE_SEEN + 1)); fi
    done < <(web_client_ips)
    if [ "$WEB_EDGE_SEEN" -gt 0 ]; then
        info "cloudflare     : ${WEB_EDGE_SEEN} edge address(es) in the sampled logs"
    else
        info "cloudflare     : no edge address in the sampled logs"
    fi
    if [ "$WEB_LOG_HAS_XFF" = "1" ]; then
        fmt='X-Forwarded-For field present (CloudPanel "main" format)'
    else
        fmt='no X-Forwarded-For field (built-in "combined" format)'
    fi
    info "log format     : $fmt"

    case "$WEB_IP_SOURCE" in
        remote)
            if [ "$WEB_FORCE_IP_SOURCE" != "1" ] \
               && { [ "$WEB_EDGE_SEEN" -gt 0 ] \
                    || { [ "$HAS_CF" = "1" ] && [ "$WEB_REALIP" = "0" ]; }; }; then
                warn "refusing --ip-source remote: banning \$remote_addr here would"
                warn "ban the Cloudflare edge itself and take every site offline."
                warn "Fix the root cause (enable real_ip in nginx), or override with"
                warn "--force-ip-source if you know the logs hold real clients."
                exit 2
            fi
            WEB_IP_SOURCE_USED="remote" ;;
        xforwarded)
            if [ "$WEB_LOG_HAS_XFF" != "1" ]; then
                warn "refusing --ip-source xforwarded: no sampled line has an"
                warn "X-Forwarded-For field, so a match would fall back to the CDN"
                warn "edge. Use --ip-source remote, or point --logpath at the site logs."
                exit 2
            fi
            WEB_IP_SOURCE_USED="xforwarded" ;;
        auto)
            if [ "$WEB_EDGE_SEEN" -gt 0 ] && [ "$WEB_REALIP" = "0" ]; then
                if [ "$WEB_LOG_HAS_XFF" != "1" ]; then
                    warn "Cloudflare edges appear in the logs but there is no"
                    warn "X-Forwarded-For field to fall back on: refusing to install"
                    warn "web jails, they would ban the edge. Enable real_ip first."
                    exit 2
                fi
                WEB_IP_SOURCE_USED="xforwarded"
                warn "Cloudflare is in front but nginx does not restore the real"
                warn "client IP: using the X-Forwarded-For hop instead of \$remote_addr"
                warn "and whitelisting the Cloudflare ranges. Enabling"
                warn "cloudflare_realip.conf is the proper long-term fix."
            elif [ "$HAS_CF" = "1" ] && [ "$WEB_REALIP" = "0" ]; then
                if [ "$WEB_LOG_HAS_XFF" != "1" ]; then
                    warn "Cloudflare credentials given but no real_ip config and no"
                    warn "X-Forwarded-For field: refusing to install web jails."
                    exit 2
                fi
                WEB_IP_SOURCE_USED="xforwarded"
                warn "Cloudflare credentials given with no real_ip config: assuming"
                warn "the CDN is in front and using the X-Forwarded-For hop"
            else
                WEB_IP_SOURCE_USED="remote"
            fi ;;
    esac

    if [ "$WEB_IP_SOURCE_USED" = "xforwarded" ]; then
        WEB_IGNOREIP_ARR+=("${WEB_CF_CIDR_ARR[@]}")
        if [ "$WEB_XFF_HOP" = "first" ]; then
            warn "--xff-hop first: a client can prepend a fake X-Forwarded-For value"
            warn "and get somebody else banned. The default (last) cannot be spoofed."
        fi
        if [ "$HAS_CF" != "1" ]; then
            warn "the Cloudflare ranges are whitelisted, but this run has no"
            warn "Cloudflare credential: bans stay local to this server."
        fi
        info "ip source      : xforwarded (X-Forwarded-For, $WEB_XFF_HOP hop)"
    else
        info "ip source      : remote (nginx \$remote_addr)"
    fi
    return 0
}

########## Collect the effective ignoreip list (merge, never replace) ##########
web_collect_ignoreip() {
    local f line ip _ip_arr=() _clean=() eff=""
    # 1) Ask the running Fail2Ban for the effective list of an always-present
    #    jail: it already contains CloudPanel's defaults from jail.local.
    eff=$(sudo fail2ban-client get sshd ignoreip 2>/dev/null | tr -s '[:space:]' ' ' || true)
    case "$eff" in *'%('*|*'is ignored'*|'') eff="" ;; esac
    if [ -n "$eff" ]; then
        read -r -a WEB_IGNOREIP_FINAL <<< "$eff" || true
        info "ignoreip       : taken from the running sshd jail"
    else
        WEB_IGNOREIP_FINAL=()
        # 2) Otherwise parse the static configuration files.
        for f in /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
                 /etc/fail2ban/jail.d/*.conf /etc/fail2ban/jail.d/*.local; do
            if ! sudo test -f "$f"; then continue; fi
            while IFS= read -r line; do
                case "$line" in *'%('*) continue ;; esac
                read -r -a _ip_arr <<< "$line" || true
                WEB_IGNOREIP_FINAL+=("${_ip_arr[@]}")
            done < <(sudo sed -nE 's/^[[:space:]]*ignoreip[[:space:]]*=[[:space:]]*(.*)$/\1/p' \
                        "$f" 2>/dev/null || true)
        done
        info "ignoreip       : merged from jail.conf/jail.local/jail.d"
    fi
    ########## Drop prose, then add the loopback pair and the --ignoreip values
    if [ "${#WEB_IGNOREIP_FINAL[@]}" -gt 0 ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && _clean+=("$ip")
        done < <(web_clean_ignoreip "${WEB_IGNOREIP_FINAL[@]}")
        WEB_IGNOREIP_FINAL=("${_clean[@]}")
    fi
    WEB_IGNOREIP_FINAL+=("127.0.0.1/8" "::1")
    if [ "${#WEB_IGNOREIP_ARR[@]}" -gt 0 ]; then
        WEB_IGNOREIP_FINAL+=("${WEB_IGNOREIP_ARR[@]}")
    fi
    return 0
}

########## Keep only address-looking tokens from an ignoreip answer ##########
# A jail without any ignoreip answers the query with a whole sentence
# ("No IP address/network is ignored") and a hand-written line can carry a
# trailing comment; neither belongs into a generated ignoreip list. Addresses
# (with or without a prefix), localhost and dotted DNS names are kept.
web_clean_ignoreip() {
    local ip
    for ip in "$@"; do
        printf '%s\n' "$ip"
    done | grep -E '^(localhost|([0-9A-Fa-f:.]+(/[0-9]+)?)|([A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+))$' || true
    return 0
}

########## Render the merged ignoreip list as one space-separated value ##########
web_render_ignoreip() {
    local ip seen=""
    for ip in "${WEB_IGNOREIP_FINAL[@]}"; do
        [ -n "$ip" ] || continue
        case " $seen " in *" $ip "*) continue ;; esac
        seen="$seen $ip"
    done
    printf '%s' "${seen# }"
    return 0
}

# Every body below is anchored twice: it starts right after the opening quote of
# $request and it ends with the exact HTTP status the request must have had. No
# generic word ("admin", "login", "page") is ever enough on its own.
W_METHODS='(?:GET|POST|HEAD|PUT|PATCH|OPTIONS|PROPFIND)'
W_ST4='(?:4\d\d|000)(?=[ ]|$)'

########## Human-readable description of the client-IP source ##########
web_ip_source_text() {
    if [ "$WEB_IP_SOURCE_USED" = "xforwarded" ]; then
        printf 'X-Forwarded-For, %s hop ($remote_addr is the CDN edge)' "$WEB_XFF_HOP"
    else
        printf 'nginx $remote_addr'
    fi
}

########## Prefix: everything up to the opening quote of $request ##########
# Fail2Ban cuts the [time] field out of the line before matching, so the log
# line reaches the regex as  '1.2.3.4 - - [] "GET ...'  -> hence \[[^\]]*\].
web_regex_prefix() {
    if [ "$WEB_IP_SOURCE_USED" = "xforwarded" ]; then
        printf '%s' '(?i)^\S+ \S+ \S+ \[[^\]]*\]\s+"'
    else
        printf '%s' '(?i)^(?:[\w.@-]+:\d+ )?<HOST> \S+ \S+ \[[^\]]*\]\s+"'
    fi
}

########## Suffix: only needed when the client address lives in XFF ##########
web_regex_tail() {
    local xff
    if [ "$WEB_IP_SOURCE_USED" != "xforwarded" ]; then return 0; fi
    if [ "$WEB_XFF_HOP" = "first" ]; then
        xff='<HOST>(?:,\s*[^"]*)?'          # left-most hop: spoofable by the client
    else
        xff='(?:[^",]*,\s*)*<HOST>'         # right-most hop: set by the CDN itself
    fi
    if [ "$1" = "end" ]; then
        # the body already consumed the User-Agent, only the XFF field is left
        printf '%s' '\s+"'"$xff"'\s*$'
    else
        # bytes sent, referer, user-agent and then the X-Forwarded-For field
        printf '%s' '\s+[\d-]+\s+"[^"]*"\s+"[^"]*"\s+"'"$xff"'\s*$'
    fi
}

########## Render one filter file: name, tail mode, then the bodies ##########
# WEB_EXTRA_IGNORES may hold extra ignoreregex lines for this filter.
web_render_filter() {
    local name="$1" mode="$2" prefix tail body first=1 line
    shift 2
    prefix=$(web_regex_prefix)
    tail=$(web_regex_tail "$mode")
    printf '# Managed by fail2ban-setup.sh - do not edit by hand.\n'
    printf '# Filter    : %s\n' "$name"
    printf '# Client IP : %s\n' "$(web_ip_source_text)"
    printf '# Generated : %s\n' "$(date -Is)"
    printf '#\n'
    printf '# Fail2Ban cuts the [time] field out before matching, so "[]" in the\n'
    printf '# regexes below is that (now empty) field of a CloudPanel access log.\n'
    printf '[Definition]\n'
    printf 'failregex = '
    for body in "$@"; do
        [ -n "$body" ] || continue
        if [ "$first" = "1" ]; then
            printf '%s%s%s\n' "$prefix" "$body" "$tail"
            first=0
        else
            printf '            %s%s%s\n' "$prefix" "$body" "$tail"
        fi
    done
    if [ "$WEB_ALLOWLIST" = "1" ]; then
        printf 'ignoreregex = %s\n' "$WEB_IGNORE_UA"
    else
        printf 'ignoreregex = %s\n' "$WEB_IGNORE_REFERER"
    fi
    if [ "$WEB_ALLOWLIST" = "1" ]; then
        printf '              %s\n' "$WEB_IGNORE_REFERER"
    fi
    for line in "${WEB_EXTRA_IGNORES[@]}"; do
        printf '              %s\n' "$line"
    done
    return 0
}

########## Rule body building blocks ##########
# A bare "%" cannot appear in a filter value: Fail2Ban's config reader runs
# Python interpolation over failregex, so "%2e" aborts with "InterpolationSyntax-
# Error" (and "%%2e" would only work while that stays true). "\x25" is the
# percent sign for the regex engine and never reaches the config parser.
#
# W_ANY_DIR is the optional directory prefix of every path rule. Sub-directory
# installs are probed just as often as the root one (/blog/wp-config.php,
# /shop/wp-login.php), and requiring every segment to end with "/" keeps ".env"
# from matching an asset such as "green.env.png".
W_ANY_DIR='(?:[^"/]*/)*'
# Paths that must never be fetched by anybody but an attacker.
W_PROBE_FILES='(?:\.|\x252e)(?:env|aws|ssh|htaccess|htpasswd|ds_store|dockerenv|idea|vscode|npmrc|netrc|git-credentials|bash_history|mysql_history|git|svn|hg|bzr)(?![\w])'
# Admin/database tooling and framework debug endpoints, both as a file and as
# the usual /phpmyadmin/index.php directory layout.
W_PROBE_APPS='(?:wp-config\.php(?:\.[a-z0-9]{1,6}|~)?|(?:adminer|phpmyadmin|pma|php-myadmin|myadmin|sqladmin|dbadmin)[a-z0-9_.-]*\.php|(?:phpmyadmin|pma|adminer|php-myadmin)/(?:index|setup|scripts)\.php|(?:phpmyadmin|pma|adminer|php-myadmin)/|(?:admin|mysql|db|database)[a-z0-9]{0,6}\.php|_ignition/execute-solution|telescope/requests|actuator/(?:env|health|heapdump|mappings|beans|configprops)|boaform/admin/formLogin|(?:install|setup|upgrade|configuration|config)\.php)'
# Dumps and editor leftovers are never served to a browser, so any name counts.
W_PROBE_DUMP='[^/"]+\.(?:sql|dump|bak|old|orig|save|swp)'
# Archives, on the other hand, are ordinary traffic below /downloads or /assets,
# so here the name has to look like a site or database export.
W_PROBE_EXPORT='(?:backup|dump|database|db|mysql|sql|site|www|home|public_html|wordpress|wp|prod|production|staging|export|archive|[a-z0-9-]+\.(?:com|net|org|io|co|dev|cloud|shop|store|xyz))'
W_PROBE_ARCHIVE="$W_PROBE_EXPORT"'[^/"]*\.(?:tar|tgz|tar\.gz|gz|zip|rar|7z)'
# Script drops in directories that only ever hold static files.
W_PROBE_CODE='(?:wp-content|wp-includes|uploads|files|storage|cache|media|assets|tmp|var|cgi-bin|vendor|node_modules|\.svn|\.git|\.well-known)/[^"]*\.(?:php|phtml|phar|php[0-9]|cgi|pl|py|sh|env|sql|bak|yml|zip)'
# Login endpoints: a POST here means somebody typed a password.
W_LOGIN_FORMS='(?:wp-login\.php(?![^"]*action=(?:lostpassword|register|resetpass|rp|postpass|logout|confirmaction))|administrator/index\.php|index\.php/login|user/login|customer/account/loginPost|index\.php\?option=com_users)'
W_LOGIN_API='(?:xmlrpc\.php|rest/login|wp-json/jwt-auth/v1/token)'
W_ADMIN_PANELS='(?:wp-admin|wp-login\.php|xmlrpc\.php|administrator|phpmyadmin|pma|adminer|manager)'
W_LOGIN_GENERIC='(?:login|signin|sign-in|admin|admin\.php|admin/login|panel)'
W_ENUM_USERS='wp-json/wp/v2/users'
W_UA_BAD='[^"]*(?:zgrab|masscan|censys|nuclei|sqlmap|wpscan|nikto|gobuster|feroxbuster|dirbuster|dirb|wfuzz|nmap|zap|acunetix|nessus|openvas|hydra|patator|ffuf)[^"]*'
# Status expectations. The trailing lookahead keeps "401" from matching a
# longer number and works with and without trailing log fields.
W_ST4='(?:4\d\d|000)(?=[ ]|$)'
W_ST_L='(?:200|401|403)(?=[ ]|$)'
W_ST_EST='(?:401|403)(?=[ ]|$)'
W_ST_401='401(?=[ ]|$)'
W_ST_200='200(?=[ ]|$)'

########## Ignore lists ##########
# Requests coming from the panel itself or from a page inside wp-admin are the
# site owner working, never an attack.
W_IGNORE_REFERER='(?i)"https?://[^"]*/wp-admin/'
W_IGNORE_QUERY='(?i)^\S+ \S+ \S+ \[[^\]]*\]\s+"(?:GET|POST|HEAD) [^"]*[?&](?:context|_locale|_fields|who|wp-adm)='
web_build_ignore_ua() {
    local pats='Up-Uptime-Monitor|Uptime-Kuma|Better Uptime Bot|BetterStack|Pingdom|Site24x7|StatusCake|UptimeRobot|Freshping|Datadog|Amazon CloudWatch|GoogleHC|GoogleStackdriverMonitoring|kube-probe|Consul Health Check|NewRelicPinger|GTmetrix|Chrome-Lighthouse|PageSpeed|Googlebot|bingbot|Applebot|YandexBot|DuckDuckBot|Baiduspider|PetalBot|SemrushBot|AhrefsBot|MJ12bot|facebookexternalhit|Twitterbot|LinkedInBot|Slackbot|Discordbot|TelegramBot|WhatsApp|WordPress\.com|Jetpack|WP-CLI' extra
    for extra in "$@"; do
        [ -n "$extra" ] || continue
        pats="$pats|$extra"
    done
    printf '(?i)"[^"]*(?:%s)[^"]*"' "$pats"
    return 0
}
WEB_UA_PAT_PC='zgrab|masscan|censys|nuclei|sqlmap|wpscan|nikto|gobuster|feroxbuster|dirbuster|dirb|wfuzz|nmap|zap|acunetix|nessus|openvas|hydra|patator|ffuf'

########## Access-log globs the rendered jail will watch ##########
# Fail2Ban splits logpath on newlines only, and one glob that matches nothing
# makes the whole jail fail to start - so only offer globs that matched.
web_logpath_globs_final() {
    local g f ok
    local -a globs=()
    if [ "${#WEB_LOG_GLOBS[@]}" -gt 0 ] || [ "${#WEB_EXTRA_LOG_GLOBS[@]}" -gt 0 ]; then
        globs=("${WEB_LOG_GLOBS[@]}" "${WEB_EXTRA_LOG_GLOBS[@]}")
    else
        globs=("/home/*/logs/nginx/*access.log" "/var/log/nginx/*access.log")
    fi
    for g in "${globs[@]}"; do
        [ -n "$g" ] || continue
        ok=0
        # shellcheck disable=SC2086  # word splitting + globbing on purpose
        for f in $g; do
            if [ -f "$f" ]; then ok=1; break; fi
        done
        if [ "$ok" = "1" ]; then printf '%s\n' "$g"; fi
    done
    return 0
}

########## Per-jail timing (command line wins over the built-in default) ##########
web_jail_retry() {
    if [ -n "$WEB_MAXRETRY" ]; then printf '%s' "$WEB_MAXRETRY"; else printf '%s' "$1"; fi
}
web_jail_findtime() {
    if [ -n "$WEB_FINDTIME" ]; then printf '%s' "$WEB_FINDTIME"; else printf '%s' "$1"; fi
}

########## Render every filter into the staging directory ##########
web_render_all_filters() {
    web_staging_dir || return 1
    local b1 b2 b3 b4 b5 l1 l2 l3 l4 e1 e2 e3 bb bad
    WEB_TMP_FILTERS=("$WEB_FILTER_PROBE" "$WEB_FILTER_LOGIN" "$WEB_FILTER_ENUM")
    if [ "$WEB_BADBOTS" = "1" ]; then WEB_TMP_FILTERS+=("$WEB_FILTER_BADBOTS"); fi
    WEB_IGNORE_UA=$(web_build_ignore_ua "${WEB_ALLOW_UA_ARR[@]}")
    WEB_IGNORE_REFERER="$W_IGNORE_REFERER"

    # --- scanning / credential probing: only a 4xx (or an nginx 000) counts
    b1="$W_METHODS"' /'"$W_ANY_DIR$W_PROBE_FILES"'[^\"]*\" '"$W_ST4"
    b2="$W_METHODS"' /'"$W_ANY_DIR$W_PROBE_APPS"'[^\"]*\" '"$W_ST4"
    b3="$W_METHODS"' /'"$W_ANY_DIR$W_PROBE_DUMP"'[^\"]*\" '"$W_ST4"
    b4="$W_METHODS"' /'"$W_ANY_DIR$W_PROBE_ARCHIVE"'[^\"]*\" '"$W_ST4"
    b5="$W_METHODS"' /'"$W_ANY_DIR$W_PROBE_CODE"'[^\"]*\" '"$W_ST4"
    WEB_EXTRA_IGNORES=()
    # shellcheck disable=SC2086  # bodies are single words built above
    web_render_filter "$WEB_FILTER_PROBE" mid "$b1" "$b2" "$b3" "$b4" "$b5" \
        > "$WEB_TMP/$WEB_FILTER_PROBE.conf"

    # --- login endpoints: a POST here means somebody typed a password
    l1='POST /'"$W_ANY_DIR$W_LOGIN_FORMS"'[^\"]*\" '"$W_ST_L"
    l2='POST /'"$W_ANY_DIR$W_LOGIN_API"'[^\"]*\" '"$W_ST_EST"
    l3='(?:GET|POST) /'"$W_ANY_DIR$W_ADMIN_PANELS"'[^\"]*\" '"$W_ST_401"
    if [ "$WEB_AGGRESSIVE_LOGIN" = "1" ]; then
        l4='POST /'"$W_ANY_DIR$W_LOGIN_GENERIC"'[^"]*" '"$W_ST_L"
        web_render_filter "$WEB_FILTER_LOGIN" mid "$l1" "$l2" "$l3" "$l4" \
            > "$WEB_TMP/$WEB_FILTER_LOGIN.conf"
    else
        web_render_filter "$WEB_FILTER_LOGIN" mid "$l1" "$l2" "$l3" \
            > "$WEB_TMP/$WEB_FILTER_LOGIN.conf"
    fi

    # --- user enumeration through the REST API
    e1='GET /'"$W_ANY_DIR$W_ENUM_USERS"'(?:\?[^"\s]*)? \S+\" '"$W_ST_200"
    if [ "$WEB_AGGRESSIVE_ENUM" = "1" ]; then
        e3='GET /'"$W_ANY_DIR$W_ENUM_USERS"'/[1-9]\d*[^\"]*\" '"$W_ST_200"
        WEB_EXTRA_IGNORES=("$W_IGNORE_QUERY")
        web_render_filter "$WEB_FILTER_ENUM" mid "$e1" "$e3" \
            > "$WEB_TMP/$WEB_FILTER_ENUM.conf"
    else
        e2='GET /'"$W_ANY_DIR$W_ENUM_USERS"'/[1-9]\d{2,}[^\"]*\" '"$W_ST_200"
        WEB_EXTRA_IGNORES=("$W_IGNORE_QUERY")
        web_render_filter "$WEB_FILTER_ENUM" mid "$e1" "$e2" \
            > "$WEB_TMP/$WEB_FILTER_ENUM.conf"
    fi

    # --- scanner User-Agents (the only rule that reads the whole line)
    if [ "$WEB_BADBOTS" = "1" ]; then
        WEB_EXTRA_IGNORES=()
        bb="$W_METHODS"' [^"]*" \d{3} [\d-]+ "[^"]*" "'"$W_UA_BAD"'"'
        web_render_filter "$WEB_FILTER_BADBOTS" end "$bb" \
            > "$WEB_TMP/$WEB_FILTER_BADBOTS.conf"
    fi
    WEB_EXTRA_IGNORES=()
    ########## Fail2Ban's config parser rejects a bare % in a value ##########
    if bad=$(grep -l '%' "$WEB_TMP"/*.conf 2>/dev/null) && [ -n "$bad" ]; then
        warn "generated filter(s) contain a bare '%', which Fail2Ban's config"
        warn "parser rejects (use \\x25 instead): $(printf '%s ' $bad)"
        return 1
    fi
    info "filters staged : ${WEB_TMP_FILTERS[*]}"
    return 0
}

########## Web protection: names, staging area and jail file ##########
WEB_FILTER_PROBE="web-probe"
WEB_FILTER_LOGIN="web-login"
WEB_FILTER_ENUM="web-enum"
WEB_FILTER_BADBOTS="web-badbots"
WEB_TMP=""
WEB_IGNORE_UA=""
WEB_TMP_FILTERS=()
WEB_EXTRA_IGNORES=()
WEB_LOGPATH_FINAL=()

########## Private staging directory for the generated files ##########
web_staging_dir() {
    if [ -z "$WEB_TMP" ]; then
        WEB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fail2ban-web.XXXXXX") \
            || { warn "cannot create a temporary directory for the filters"; exit 1; }
    fi
    return 0
}

web_cleanup() {
    if [ -n "$WEB_TMP" ] && [ -d "$WEB_TMP" ]; then
        rm -rf -- "$WEB_TMP"
        WEB_TMP=""
    fi
    return 0
}

########## One jail section (logpath is shared by all web jails) ##########
web_render_jail_section() {
    local p
    printf '[%s]\n' "$1"
    printf 'enabled  = true\n'
    printf 'filter   = %s\n' "$2"
    printf 'port     = http,https\n'
    printf 'maxretry = %s\n' "$3"
    printf 'findtime = %s\n' "$4"
    if [ -n "$WEB_BANTIME" ]; then printf 'bantime  = %s\n' "$WEB_BANTIME"; fi
    printf 'ignoreip = %s\n' "$(web_render_ignoreip)"
    ########## The access logs are files: Debian's defaults-debian.conf sets
    ########## "backend = systemd" globally, which would monitor nothing here.
    printf 'backend  = auto\n'
    printf 'logpath  = %s\n' "${WEB_LOGPATH_FINAL[0]}"
    for p in "${WEB_LOGPATH_FINAL[@]:1}"; do
        printf '           %s\n' "$p"
    done
    ########## CloudPanel bans through its own Cloudflare action; point the jails
    ########## at it only when the action file really exists - "fail2ban-client
    ########## -t" refuses to load a jail that references an unknown action.
    if [ "$HAS_CF" = "1" ] && sudo test -f "$ACTION_FILE"; then
        printf 'action   = ui-custom-action[port="http,https", protocol="tcp"]\n'
    fi
    printf '\n'
    return 0
}

########## The complete jail file ##########
web_render_jail() {
    local p
    WEB_LOGPATH_FINAL=()
    while IFS= read -r p; do
        [ -n "$p" ] && WEB_LOGPATH_FINAL+=("$p")
    done < <(web_logpath_globs_final)
    if [ "${#WEB_LOGPATH_FINAL[@]}" -eq 0 ]; then
        warn "no access log matched, refusing to write a jail without a logpath"
        return 1
    fi
    printf '# Managed by fail2ban-setup.sh - do not edit by hand.\n'
    printf '# Generated : %s\n' "$(date -Is)"
    printf '# Client IP : %s\n' "$(web_ip_source_text)"
    printf '#\n'
    printf '# Fail2Ban reads jail.d/*.local after CloudPanel jail.local, so the\n'
    printf '# values in these sections win over the ones set there. bantime is\n'
    printf '# left alone unless it was given on the command line, so a global\n'
    printf '# bantime/bantime.increment keeps working.\n'
    printf '\n'
    web_render_jail_section "$WEB_FILTER_PROBE" "$WEB_FILTER_PROBE" \
        "$(web_jail_retry 3)" "$(web_jail_findtime 1h)"
    web_render_jail_section "$WEB_FILTER_LOGIN" "$WEB_FILTER_LOGIN" \
        "$(web_jail_retry 8)" "$(web_jail_findtime 10m)"
    web_render_jail_section "$WEB_FILTER_ENUM" "$WEB_FILTER_ENUM" \
        "$(web_jail_retry 4)" "$(web_jail_findtime 1h)"
    if [ "$WEB_BADBOTS" = "1" ]; then
        web_render_jail_section "$WEB_FILTER_BADBOTS" "$WEB_FILTER_BADBOTS" \
            "$(web_jail_retry 2)" "$(web_jail_findtime 1h)"
    fi
    return 0
}

########## Fixtures: reference log lines for the self-test ##########
# Every line is a realistic CloudPanel/nginx "main" line. Legit lines must not
# match, attack lines must all match, and every line carries a unique address so
# the self-test can check *which* IP each filter would have banned.
web_write_fixtures() {
    local dir="$1" mode="$2" d='16/Oct/2026:10:00:00 +0000' entry ip req st by ref ua xff
    local MOZ='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
    local CURLU='curl/8.5.0'
    local KUMA='Uptime-Kuma/1.23.0'
    local UPBK='Up-Uptime-Monitor/1.0'
    local GGL='Googlebot/2.1 (+http://www.google.com/bot.html)'
    local WPC='WordPress.com/1.0; https://shop.example.com'
    local -a legit=(
        "203.0.113.1|GET /wp-admin/ HTTP/1.1|200|5421|https://shop.example.com/wp-admin/|$MOZ|203.0.113.1"
        "203.0.113.1|POST /wp-admin/admin-ajax.php HTTP/1.1|200|321|https://shop.example.com/wp-admin/post.php?post=42|$MOZ|203.0.113.1"
        "203.0.113.1|GET /wp-json/wp/v2/users?context=edit&per_page=10 HTTP/1.1|200|812|https://shop.example.com/wp-admin/post.php|$MOZ|203.0.113.1"
        "203.0.113.1|GET /wp-json/wp/v2/users?who=authors&_locale=user HTTP/1.1|200|642|https://shop.example.com/wp-admin/|$MOZ|203.0.113.1"
        "203.0.113.1|GET /wp-json/wp/v2/users/1 HTTP/1.1|200|540|https://shop.example.com/about-us/|$MOZ|203.0.113.1"
        "203.0.113.1|GET /wp-login.php HTTP/1.1|200|7412|-|$MOZ|203.0.113.1"
        "203.0.113.1|POST /wp-login.php HTTP/1.1|302|0|https://shop.example.com/wp-login.php|$MOZ|203.0.113.1"
        "203.0.113.1|POST /wp-login.php?action=lostpassword HTTP/1.1|200|2154|https://shop.example.com/wp-login.php?action=lostpassword|$MOZ|203.0.113.1"
        "203.0.113.1|POST /wp-login.php?action=postpass HTTP/1.1|302|0|https://shop.example.com/blog/|$MOZ|203.0.113.1"
        "198.51.100.2|POST /wp-login.php?action=register HTTP/1.1|200|3011|https://shop.example.com/wp-login.php?action=register|$MOZ|198.51.100.2"
        "198.51.100.2|GET /wp-content/themes/storefront/style.css HTTP/1.1|200|4231|https://shop.example.com/|$MOZ|-"
        "198.51.100.2|GET /wp-content/uploads/2025/03/product.webp HTTP/1.1|200|92311|-|$MOZ|-"
        "198.51.100.2|GET /wp-json/wp/v2/posts?per_page=6 HTTP/1.1|200|5231|-|$MOZ|-"
        "198.51.100.2|GET /favicon.ico HTTP/1.1|404|153|-|$MOZ|-"
        "203.0.113.3|GET /user/login HTTP/1.1|200|6211|-|$MOZ|203.0.113.3"
        "203.0.113.3|POST /user/login HTTP/1.1|303|0|https://cms.example.com/user/login|$MOZ|203.0.113.3"
        "198.51.100.4|GET /node/42 HTTP/1.1|200|10231|-|$MOZ|-"
        "203.0.113.5|GET /administrator/ HTTP/1.1|200|8112|-|$MOZ|203.0.113.5"
        "203.0.113.5|POST /administrator/index.php HTTP/1.1|303|0|https://www.example.org/administrator/|$MOZ|203.0.113.5"
        "203.0.113.5|POST /index.php?option=com_users&task=user.login HTTP/1.1|303|0|https://www.example.org/|$MOZ|203.0.113.5"
        "198.51.100.6|POST /customer/account/loginPost/ HTTP/1.1|302|0|https://shop.example.net/customer/account/login/|$MOZ|-"
        "198.51.100.6|GET /customer/account/ HTTP/1.1|200|15231|-|$MOZ|-"
        "198.51.100.7|GET /status.php HTTP/1.1|200|141|-|$CURLU|-"
        "198.51.100.7|GET /login HTTP/1.1|200|9121|-|$MOZ|-"
        "198.51.100.7|PROPFIND /remote.php/dav/files/admin/ HTTP/1.1|207|1421|-|davfs2/1.6.1|-"
        "203.0.113.8|GET / HTTP/1.1|200|3211|-|$MOZ|203.0.113.8"
        "203.0.113.8|GET /rest/settings HTTP/1.1|401|32|-|$MOZ|203.0.113.8"
        "203.0.113.8|GET /rest/workflows HTTP/1.1|401|32|-|$MOZ|203.0.113.8"
        "198.51.100.9|POST /webhook/abcd/order HTTP/1.1|200|12|-|$CURLU|198.51.100.9"
        "203.0.113.10|POST /api/v1/webhook/order HTTP/1.1|401|45|-|node-fetch/1.0|203.0.113.10"
        "192.0.2.11|GET /wp-json/wp/v2/users HTTP/1.1|200|612|-|$WPC|192.0.2.11"
        "198.51.100.12|HEAD /wp-admin/ HTTP/1.1|401|0|-|$CURLU|-"
        "198.51.100.12|GET /wp-login.php HTTP/1.1|200|7412|-|$KUMA|-"
        "198.51.100.13|GET /assets/nope-2026.png HTTP/1.1|404|153|-|$UPBK|-"
        "192.0.2.14|POST /webhook/xyz HTTP/1.1|404|153|-|$CURLU|192.0.2.14"
        "198.51.100.15|GET /robots.txt HTTP/1.1|200|211|-|$GGL|198.51.100.15"
        "198.51.100.15|GET /sitemap_index.xml HTTP/1.1|200|512|-|$GGL|198.51.100.15"
        "127.0.0.1|GET /wp-cron.php?doing_wp_cron=1 HTTP/1.1|200|0|-|WordPress/6.6|127.0.0.1"
        "192.0.2.16|GET /adminer.php HTTP/1.1|200|15231|-|$MOZ|192.0.2.16"
        "192.0.2.16|POST /phpmyadmin/index.php HTTP/1.1|302|0|-|$MOZ|192.0.2.16"
        "198.51.100.17|POST /wp-comments-post.php HTTP/1.1|409|211|-|$MOZ|198.51.100.17"
        "203.0.113.18|POST /wp-login.php?action=lostpassword HTTP/1.1|200|211|-|$CURLU|203.0.113.18"
        "172.71.10.10|GET / HTTP/1.1|200|10231|-|Mozilla/5.0 (compatible; Cloudflare-Healthchecks/1.0)|-"
        "172.71.10.10|GET /wp-content/uploads/2025/01/hero.jpg HTTP/1.1|200|52311|-|$MOZ|-"
        "198.51.100.19|POST /panel/save HTTP/1.1|200|211|-|$MOZ|198.51.100.19"
        "198.51.100.20|GET /blog/wp-json/wp/v2/users/2 HTTP/1.1|200|540|-|$MOZ|198.51.100.20"
        "198.51.100.21|GET /downloads/app.zip HTTP/1.1|404|153|-|$MOZ|198.51.100.21"
        "198.51.100.22|GET /blog/wp-content/uploads/2025/03/product.webp HTTP/1.1|200|92311|-|$MOZ|198.51.100.22"
        "198.51.100.23|POST /blog/wp-login.php?action=lostpassword HTTP/1.1|200|2154|-|$MOZ|198.51.100.23"
    )
    : > "$dir/legit.log"
    : > "$dir/legit.ips"
    for entry in "${legit[@]}"; do
        IFS='|' read -r ip req st by ref ua xff <<< "$entry"
        printf '%s - - [%s] "%s" %s %s "%s" "%s" "%s"\n' \
            "$ip" "$d" "$req" "$st" "$by" "$ref" "$ua" "$xff" >> "$dir/legit.log"
        printf '%s\n' "$ip" >> "$dir/legit.ips"
    done
    web_write_fixture_attacks "$dir" "$mode" "$WEB_XFF_HOP" "$d"
    return 0
}

########## Fixture: the attack lines (each one must be caught) ##########
# The third field is the X-Forwarded-For value, which is what the jail bans when
# the client addresses live in XFF; the self-test recomputes the address that
# *should* be banned from the mode and the hop setting.
web_write_fixture_attacks() {
    local dir="$1" mode="$2" hop="$3" d="$4" entry ip req st by ref ua xff host
    local MOZ='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
    local CURLU='curl/8.5.0'
    local PYREQ='python-requests/2.31.0'
    local -a atk=(
        "45.9.9.1|GET /.env HTTP/1.1|404|153|-|zgrab/0.x|45.9.9.1"
        "45.9.9.2|GET /.env.backup HTTP/1.1|404|153|-|$CURLU|45.9.9.2"
        "45.9.9.3|GET /.git/config HTTP/1.1|404|153|-|$CURLU|45.9.9.3"
        "45.9.9.4|PROPFIND /.git/ HTTP/1.1|405|153|-|$CURLU|45.9.9.4"
        "45.9.9.5|GET /.aws/credentials HTTP/1.1|403|153|-|$PYREQ|45.9.9.5"
        "45.9.9.6|GET /.ssh/id_rsa HTTP/1.1|404|153|-|Go-http-client/1.1|45.9.9.6"
        "45.9.9.7|GET /.htpasswd HTTP/1.1|403|153|-|$CURLU|45.9.9.7"
        "45.9.9.8|GET /wp-config.php.bak HTTP/1.1|404|153|-|$CURLU|45.9.9.8"
        "45.9.9.9|GET /wp-config.php~ HTTP/1.1|403|153|-|$CURLU|45.9.9.9"
        "45.9.9.10|GET /blog/wp-config.php.save HTTP/1.1|404|153|-|$CURLU|45.9.9.10"
        "45.9.9.11|POST /adminer.php HTTP/1.1|404|153|-|$PYREQ|45.9.9.11"
        "45.9.9.12|GET /phpmyadmin/index.php HTTP/1.1|403|153|-|$MOZ|45.9.9.12"
        "45.9.9.13|GET /_ignition/execute-solution HTTP/1.1|404|153|-|nuclei|45.9.9.13"
        "45.9.9.14|GET /telescope/requests HTTP/1.1|404|153|-|$CURLU|45.9.9.14"
        "45.9.9.15|GET /actuator/env HTTP/1.1|403|153|-|$CURLU|45.9.9.15"
        "45.9.9.16|GET /boaform/admin/formLogin HTTP/1.1|404|153|-|$MOZ|45.9.9.16"
        "45.9.9.17|GET /install.php HTTP/1.1|404|153|-|$CURLU|45.9.9.17"
        "45.9.9.18|GET /backup.sql HTTP/1.1|403|153|-|wget/1.21.3|45.9.9.18"
        "45.9.9.19|GET /db.zip HTTP/1.1|404|153|-|$CURLU|45.9.9.19"
        "45.9.9.20|GET /site.tar.gz HTTP/1.1|404|153|-|$CURLU|45.9.9.20"
        "45.9.9.21|GET /wp-content/uploads/2025/03/shell.php HTTP/1.1|403|153|-|$MOZ|45.9.9.21"
        "45.9.9.22|GET /wp-content/plugins/revslider/revslider.php HTTP/1.1|403|153|-|$MOZ|45.9.9.22"
        "45.9.9.23|GET /.well-known/exploit.php HTTP/1.1|404|153|-|$CURLU|45.9.9.23"
        "45.9.9.24|POST /wp-login.php HTTP/1.1|200|4121|-|$MOZ|45.9.9.24"
        "45.9.9.25|POST /wp-login.php HTTP/1.1|403|153|-|$PYREQ|45.9.9.25"
        "45.9.9.26|POST /xmlrpc.php HTTP/1.1|403|153|-|$PYREQ|45.9.9.26"
        "45.9.9.27|POST /rest/login HTTP/1.1|401|45|-|$CURLU|45.9.9.27"
        "45.9.9.28|GET /administrator/index.php HTTP/1.1|401|153|-|$MOZ|45.9.9.28"
        "45.9.9.29|GET /wp-json/wp/v2/users HTTP/1.1|200|612|-|$CURLU|45.9.9.29"
        "45.9.9.30|GET /wp-json/wp/v2/users/1234 HTTP/1.1|200|540|-|$CURLU|45.9.9.30"
        "45.9.9.31|GET / HTTP/1.1|200|10231|-|masscan/1.3|45.9.9.31"
        "45.9.9.32|GET /login HTTP/1.1|404|153|-|nuclei/3.1|45.9.9.32"
        "2001:db8:dead:beef::9|GET /.env HTTP/1.1|404|153|-|$CURLU|2001:db8:dead:beef::9"
        "172.71.10.10|GET /.git/HEAD HTTP/1.1|404|153|-|$CURLU|45.9.9.34"
        "172.71.10.10|GET /.env HTTP/1.1|404|153|-|$CURLU|1.1.1.1, 45.9.9.35"
        "172.71.10.10|GET /.env HTTP/1.1|404|153|-|$CURLU|2001:db8::42"
        "45.9.9.37|GET /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php HTTP/1.1|404|153|-|$CURLU|45.9.9.37"
        "45.9.9.38|GET /sitemap.xml.bak HTTP/1.1|404|153|-|$CURLU|45.9.9.38"
        "45.9.9.39|GET /actuator/health HTTP/1.1|403|153|-|$CURLU|45.9.9.39"
        "45.9.9.40|GET /blog/.env HTTP/1.1|404|153|-|$CURLU|45.9.9.40"
        "45.9.9.41|GET /shop/wp-content/uploads/2025/03/drop.php HTTP/1.1|403|153|-|$CURLU|45.9.9.41"
        "45.9.9.42|GET /wordpress/.git/config HTTP/1.1|404|153|-|$CURLU|45.9.9.42"
        "45.9.9.43|GET /blog/phpmyadmin/index.php HTTP/1.1|403|153|-|$MOZ|45.9.9.43"
        "45.9.9.44|GET /blog/wp-json/wp/v2/users HTTP/1.1|200|612|-|$CURLU|45.9.9.44"
        "45.9.9.45|POST /blog/wp-login.php HTTP/1.1|200|4121|-|$PYREQ|45.9.9.45"
        "45.9.9.46|GET /shop/example.com.zip HTTP/1.1|404|153|-|$CURLU|45.9.9.46"
        "45.9.9.47|GET /blog/sitemap.xml.bak HTTP/1.1|404|153|-|$CURLU|45.9.9.47"
    )
    # Lines only the aggressive modes are supposed to catch, one list per switch.
    local -a aggr_login=(
        "46.9.9.1|POST /login HTTP/1.1|200|211|-|$CURLU|46.9.9.1"
        "46.9.9.3|POST /admin/login HTTP/1.1|401|45|-|$CURLU|46.9.9.3"
    )
    local -a aggr_enum=(
        "46.9.9.2|GET /wp-json/wp/v2/users/7 HTTP/1.1|200|540|-|$CURLU|46.9.9.2"
    )
    : > "$dir/attack.log"
    : > "$dir/attack.expected.ips"
    for entry in "${atk[@]}"; do
        IFS='|' read -r ip req st by ref ua xff <<< "$entry"
        printf '%s - - [%s] "%s" %s %s "%s" "%s" "%s"\n' \
            "$ip" "$d" "$req" "$st" "$by" "$ref" "$ua" "$xff" >> "$dir/attack.log"
        web_fixture_expected_host "$mode" "$hop" "$ip" "$xff"
        printf '%s\n' "$host" >> "$dir/attack.expected.ips"
    done
    : > "$dir/attack-aggr.log"
    printf '%s\n' "${aggr_login[@]}" "${aggr_enum[@]}" > "$dir/attack-aggr.entries"
    while IFS='|' read -r ip req st by ref ua xff; do
        [ -n "$ip" ] || continue
        printf '%s - - [%s] "%s" %s %s "%s" "%s" "%s"\n' \
            "$ip" "$d" "$req" "$st" "$by" "$ref" "$ua" "$xff" >> "$dir/attack-aggr.log"
    done < "$dir/attack-aggr.entries"
    web_fixture_expected_list "$dir/attack-aggr-login.expected.ips" "$mode" "$hop" "${aggr_login[@]}"
    web_fixture_expected_list "$dir/attack-aggr-enum.expected.ips" "$mode" "$hop" "${aggr_enum[@]}"
    return 0
}

########## Expected banned addresses for one list of fixture entries ##########
web_fixture_expected_list() {
    local out="$1" mode="$2" hop="$3" entry
    shift 3
    : > "$out"
    for entry in "$@"; do
        IFS='|' read -r _ _ _ _ _ _ xff <<< "$entry"
        web_fixture_expected_host "$mode" "$hop" "${entry%%|*}" "$xff"
        printf '%s\n' "$host" >> "$out"
    done
    return 0
}

########## Which address must be banned for a fixture line? ##########
web_fixture_expected_host() {
    local mode="$1" hop="$2" ip="$3" xff="$4"
    host="$ip"
    if [ "$mode" = "xforwarded" ] && [ -n "$xff" ] && [ "$xff" != "-" ]; then
        if [ "$hop" = "first" ]; then
            host="${xff%%,*}"
        else
            host="${xff##*, }"
        fi
    fi
    return 0
}

WEB_ST_IPTOK=""
WEB_ST_RUNS=0
WEB_ST_FAILS=0

########## Does this fail2ban-regex support "-o ip"? ##########
# With it the self-test can check *which* address each filter would ban, which
# is the only way to prove that a spoofed X-Forwarded-For hop is not used.
web_selftest_probe_iptok() {
    local out
    out=$(LC_ALL=C fail2ban-regex -o ip "$WEB_TMP/attack.log" \
            "$WEB_TMP/$WEB_FILTER_PROBE.conf" 2>/dev/null || true)
    case "$out" in
        ''|None*) WEB_ST_IPTOK=0 ;;
        *) WEB_ST_IPTOK=1 ;;
    esac
    return 0
}

########## One fail2ban-regex run: prints the match count, appends hosts ##########
web_selftest_run() {   # log filter hosts_outfile
    local log="$1" filter="$2" out="$3" hosts=""
    : > "$WEB_TMP/selftest.err"
    if [ "$WEB_ST_IPTOK" = "1" ]; then
        hosts=$(LC_ALL=C fail2ban-regex -o ip "$log" "$filter" \
                    2>>"$WEB_TMP/selftest.err" || true)
        case "$hosts" in
            ''|*None*) ;;
            *) printf '%s\n' "$hosts" >> "$out" ;;
        esac
        printf '%s' "$hosts" | grep -c . || true
    else
        LC_ALL=C fail2ban-regex "$log" "$filter" 2>>"$WEB_TMP/selftest.err" \
            | grep -oE '[0-9]+ matched' | tail -n 1 | grep -oE '^[0-9]+' || true
    fi
    return 0
}

########## Is every expected address present in the collected hosts? ##########
web_selftest_missing() {   # expected_ips_file collected_hosts_file
    local ip
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if ! grep -qxF -- "$ip" "$2"; then printf '%s\n' "$ip"; fi
    done < "$1"
    return 0
}

########## The self-test: no legitimate line banned, every attack caught ##########
web_selftest() {
    local dir="$WEB_TMP" filter count count_all=0 bad miss_file
    local hosts_all legit_hits
    # $dir must be set before the paths below are expanded, so no single local
    # statement can declare both (expansions run before the assignment).
    miss_file="$dir/missing.ips"
    hosts_all="$dir/hosts.all"
    if ! command -v fail2ban-regex > /dev/null 2>&1; then
        warn "self-test      : fail2ban-regex not found, skipping the rule check"
        warn "self-test      : install fail2ban and re-run to validate the rules"
        return 0
    fi
    web_write_fixtures "$dir" "$WEB_IP_SOURCE_USED" "$WEB_XFF_HOP"
    web_selftest_probe_iptok
    : > "$hosts_all"
    step "Self-test: ${#WEB_TMP_FILTERS[@]} filter(s) against reference access-log lines"

    # 1) no legitimate reference line may match. Only the switch the operator
    #    asked for may cost hits, and only inside its own filter.
    for filter in "${WEB_TMP_FILTERS[@]}"; do
        legit_hits="$dir/legit.$filter.hosts"
        : > "$legit_hits"
        count=$(web_selftest_run "$dir/legit.log" "$dir/$filter.conf" "$legit_hits")
        WEB_ST_RUNS=$((WEB_ST_RUNS + 1))
        if [ -z "$count" ]; then
            WEB_ST_FAILS=$((WEB_ST_FAILS + 1))
            warn "self-test FAIL : $filter could not be loaded by fail2ban-regex"
            tail -n 1 "$dir/selftest.err" 2>/dev/null \
                | while IFS= read -r bad; do warn "  $bad"; done
            continue
        fi
        [ "$count" = "0" ] && continue
        if { [ "$WEB_AGGRESSIVE_LOGIN" = "1" ] && [ "$filter" = "$WEB_FILTER_LOGIN" ]; } \
        || { [ "$WEB_AGGRESSIVE_ENUM" = "1" ] && [ "$filter" = "$WEB_FILTER_ENUM" ]; }; then
            warn "self-test      : $filter matched $count reference line(s) (aggressive mode)"
        else
            WEB_ST_FAILS=$((WEB_ST_FAILS + 1))
            warn "self-test FAIL : $filter matched $count legitimate reference line(s)"
        fi
        warn "  $(sort -u "$legit_hits" | tr '\n' ' ')"
    done
    # 2) every attack line must be caught by at least one filter
    for filter in "${WEB_TMP_FILTERS[@]}"; do
        for log in "$dir/attack.log" "$dir/attack-aggr.log"; do
            count_all=$(web_selftest_run "$log" "$dir/$filter.conf" "$hosts_all")
            WEB_ST_RUNS=$((WEB_ST_RUNS + 1))
            if [ -z "$count_all" ]; then
                WEB_ST_FAILS=$((WEB_ST_FAILS + 1))
                warn "self-test FAIL : $filter could not be loaded by fail2ban-regex"
                tail -n 1 "$WEB_TMP/selftest.err" 2>/dev/null \
                    | while IFS= read -r bad; do warn "  $bad"; done
            fi
        done
    done
    if [ "$WEB_ST_IPTOK" = "1" ]; then
        web_selftest_missing "$dir/attack.expected.ips" "$hosts_all" > "$miss_file"
        if [ -s "$miss_file" ]; then
            WEB_ST_FAILS=$((WEB_ST_FAILS + 1))
            warn "self-test FAIL : $(grep -c . "$miss_file") of $(grep -c . "$dir/attack.expected.ips") attack line(s) would NOT be caught:"
            head -n 5 "$miss_file" | while IFS= read -r bad; do warn "  no ban for $bad"; done
        else
            info "self-test      : all $(grep -c . "$dir/attack.expected.ips") reference attacks are caught"
        fi
        if [ "$WEB_AGGRESSIVE_LOGIN" = "1" ]; then
            web_selftest_missing "$dir/attack-aggr-login.expected.ips" "$hosts_all" > "$miss_file"
            if [ -s "$miss_file" ]; then
                WEB_ST_FAILS=$((WEB_ST_FAILS + 1))
                warn "self-test FAIL : aggressive login mode missed $(tr '\n' ' ' < "$miss_file")"
            else
                info "self-test      : aggressive login attacks are caught"
            fi
        fi
        if [ "$WEB_AGGRESSIVE_ENUM" = "1" ]; then
            web_selftest_missing "$dir/attack-aggr-enum.expected.ips" "$hosts_all" > "$miss_file"
            if [ -s "$miss_file" ]; then
                WEB_ST_FAILS=$((WEB_ST_FAILS + 1))
                warn "self-test FAIL : aggressive enum mode missed $(tr '\n' ' ' < "$miss_file")"
            else
                info "self-test      : aggressive user-enumeration attacks are caught"
            fi
        fi
        if [ "$WEB_IP_SOURCE_USED" = "xforwarded" ]; then
            info "self-test      : a spoofed XFF prefix does not choose the banned address"
        fi
    else
        warn "self-test      : this fail2ban-regex has no \"-o ip\", only match counts were checked"
    fi
    if [ "$WEB_ST_FAILS" -gt 0 ]; then
        warn "self-test      : ${WEB_ST_FAILS} check(s) failed in ${WEB_ST_RUNS} fail2ban-regex run(s)"
        if [ "$WEB_SELFTEST_STRICT" = "1" ]; then
            warn "self-test      : --strict-selftest given, aborting before touching /etc/fail2ban"
            return 1
        fi
        warn "self-test      : continuing anyway, review the failures above"
    else
        info "self-test      : ${WEB_ST_RUNS} fail2ban-regex run(s): no legitimate line matched"
    fi
    return 0
}

########## Resolve the logs, the client-IP source and the ignoreip list ##########
# Read-only: it inspects nginx, the Cloudflare ranges and the access logs, then
# decides which field of the log line really holds a bannable client address.
web_discover() {
    local first
    local -a _log_arr=()
    mapfile -t WEB_CF_CIDR_ARR < <(web_cf_cidrs)
    mapfile -t _log_arr < <(web_find_logpaths | sort -u)
    WEB_LOGPATHS="${_log_arr[*]}"
    if [ -z "$WEB_LOGPATHS" ]; then
        warn "no nginx access log found: pass --logpath (CloudPanel keeps them in /home/*/logs/nginx)"
        return 1
    fi
    info "access logs    : $WEB_LOGPATHS"
    first="${_log_arr[0]}"
    WEB_LOG_HAS_XFF=0
    if web_log_lines_have_xff "$first"; then WEB_LOG_HAS_XFF=1; fi
    web_decide_ip_source
    web_collect_ignoreip
    return 0
}

########## Print the filters and the jail file (--dry-run) ##########
web_dry_run() {
    local f
    if ! web_render_all_filters; then
        warn "could not render the web filters"
        return 1
    fi
    for f in "${WEB_TMP_FILTERS[@]}"; do
        printf '\n# ---------- %s/%s.conf ----------\n' "$FILTER_DIR" "$f"
        cat -- "$WEB_TMP/$f.conf"
    done
    printf '\n# ---------- %s ----------\n' "$WEB_JAIL"
    if ! web_render_jail; then
        warn "could not render the jail file"
        return 1
    fi
    printf '\n# dry run: nothing was written\n'
    return 0
}

########## Copy the validated filters into /etc/fail2ban/filter.d ##########
web_install_filters() {
    local f
    sudo mkdir -p "$FILTER_DIR" || return 1
    for f in "${WEB_TMP_FILTERS[@]}"; do
        if [ ! -f "$WEB_TMP/$f.conf" ]; then
            warn "missing generated filter: $WEB_TMP/$f.conf"
            return 1
        fi
        if ! sudo install -m 0644 "$WEB_TMP/$f.conf" "$FILTER_DIR/$f.conf"; then
            warn "cannot install $FILTER_DIR/$f.conf"
            return 1
        fi
        info "installed       : $FILTER_DIR/$f.conf"
    done
    return 0
}

########## Write the jail file into /etc/fail2ban/jail.d ##########
web_install_jail() {
    local stamp
    if ! web_render_jail > "$WEB_TMP/jail.local"; then
        warn "refusing to install a jail file without a logpath"
        return 1
    fi
    sudo mkdir -p "$(dirname "$WEB_JAIL")" || return 1
    ########## A file we did not write (no marker) is somebody else's: keep it ##########
    if sudo test -f "$WEB_JAIL" && ! sudo test -f "$WEB_STATUS_MARKER"; then
        stamp=$(date +%Y%m%d%H%M%S)
        if sudo cp -a "$WEB_JAIL" "${WEB_JAIL}.bak.${stamp}"; then
            info "backup          : ${WEB_JAIL}.bak.${stamp}"
        else
            warn "cannot back up $WEB_JAIL"
            return 1
        fi
    fi
    if ! sudo install -m 0644 "$WEB_TMP/jail.local" "$WEB_JAIL"; then
        warn "cannot install $WEB_JAIL"
        return 1
    fi
    printf 'installed by fail2ban-setup.sh at %s\n' "$(date -Is)" \
        | sudo tee "$WEB_STATUS_MARKER" > /dev/null
    info "installed       : $WEB_JAIL"
    return 0
}
########## Render, self-test and install everything (--web) ##########
web_install() {
    step "Rendering the web filters"
    if ! web_render_all_filters; then
        return 1
    fi
    if [ "$WEB_SELFTEST" = "1" ]; then
        step "Self-test: fail2ban-regex against the reference access-log lines"
        if ! web_selftest; then
            return 1
        fi
    else
        info "self-test      : skipped (--no-selftest)"
    fi
    step "Installing the web filters"
    web_install_filters || return 1
    step "Installing the web jail"
    web_install_jail || return 1
    return 0
}

########## Remove the filters, the jail file and the marker (--uninstall-web) ##########
web_uninstall() {
    local f removed=0
    for f in "${WEB_FILTERS[@]}"; do
        if sudo test -f "$FILTER_DIR/$f.conf"; then
            if sudo rm -f "$FILTER_DIR/$f.conf"; then
                info "removed         : $FILTER_DIR/$f.conf"
                removed=$((removed + 1))
            else
                warn "cannot remove $FILTER_DIR/$f.conf"
            fi
        fi
    done
    if sudo test -f "$WEB_JAIL"; then
        if sudo rm -f "$WEB_JAIL"; then
            info "removed         : $WEB_JAIL"
            removed=$((removed + 1))
        else
            warn "cannot remove $WEB_JAIL"
        fi
    fi
    if sudo test -f "$WEB_STATUS_MARKER"; then
        sudo rm -f "$WEB_STATUS_MARKER" || true
    fi
    ########## The first draft of this script used the name web-api-enum ##########
    if sudo test -f "$FILTER_DIR/web-api-enum.conf"; then
        sudo rm -f "$FILTER_DIR/web-api-enum.conf" || true
        info "removed         : $FILTER_DIR/web-api-enum.conf (legacy name)"
        removed=$((removed + 1))
    fi
    if [ "$removed" -eq 0 ]; then
        info "nothing to remove: no web filter or jail file was installed"
        return 0
    fi
    if command -v fail2ban-client > /dev/null 2>&1; then
        if sudo fail2ban-client reload > /dev/null 2>&1; then
            info "fail2ban reloaded without the web jails"
        else
            warn "fail2ban-client reload failed (is the service running?)"
        fi
    fi
    return 0
}

########## Report the installed web jails and their current bans (--status) ##########
web_status() {
    local f line
    if sudo test -f "$WEB_JAIL"; then
        info "jail file      : $WEB_JAIL"
    else
        warn "jail file      : $WEB_JAIL (MISSING - run without --status to install)"
    fi
    for f in "${WEB_FILTERS[@]}"; do
        if sudo test -f "$FILTER_DIR/$f.conf"; then
            info "filter         : $FILTER_DIR/$f.conf"
        else
            info "filter         : $FILTER_DIR/$f.conf (absent)"
        fi
    done
    if ! command -v fail2ban-client > /dev/null 2>&1; then
        warn "fail2ban-client not installed: cannot show the current bans"
        return 0
    fi
    for f in "${WEB_FILTERS[@]}"; do
        if ! sudo fail2ban-client status "$f" > /dev/null 2>&1; then
            info "jail $f: not active"
            continue
        fi
        info "jail $f:"
        while IFS= read -r line; do
            info "    $line"
        done < <(sudo fail2ban-client status "$f" 2> /dev/null \
                 | grep -E 'Currently banned|Total banned|Banned IP list' \
                 | sed -e 's/^[^A-Za-z]*//' || true)
    done
    return 0
}

########## Web protection: install, dry-run, status and uninstall ##########

########## --status / --uninstall-web: report or remove, then stop ##########
if [ "$STATUS_MODE" = "1" ]; then
    step "Web protection status"
    web_status
    exit 0
fi
if [ "$UNINSTALL_WEB" = "1" ]; then
    step "Removing the web protection filters and the jail file"
    web_uninstall || exit 1
    exit 0
fi

step "Preflight: environment and expected files"
info "running as      : $(id -un) (uid $(id -u))"
if [ "$HAS_CF" = "1" ]; then
    info "cloudflare      : ENABLED (account ${CF_ACCOUNT}, target ${CF_TARGET})"
    if [ -n "$CF_TOKEN" ]; then
        info "auth method     : API token (Bearer)"
    else
        info "auth method     : legacy Global API key (email + key)"
    fi
else
    info "cloudflare      : DISABLED (no credentials -> local banning only)"
fi
for tool in sudo fail2ban-client; do
    if command -v "$tool" > /dev/null 2>&1; then
        info "tool present    : $tool"
    else
        warn "tool MISSING    : $tool (the step that needs it will fail)"
    fi
done
if [ "$HAS_CF" = "1" ]; then
    for tool in curl jq; do
        if command -v "$tool" > /dev/null 2>&1; then
            info "tool present    : $tool"
        else
            warn "tool MISSING    : $tool (required for the Cloudflare ban/unban helper)"
        fi
    done
fi
for path in /etc/fail2ban /etc/fail2ban/action.d /etc/fail2ban/jail.d "$FILTER_DIR"; do
    if sudo test -e "$path"; then
        info "path present    : $path"
    else
        warn "path MISSING    : $path"
    fi
done
if [ "$HAS_CF" = "1" ]; then
    if sudo test -e "$ACTION_FILE"; then
        info "path present    : $ACTION_FILE"
    else
        warn "path MISSING    : $ACTION_FILE (the Cloudflare action will NOT be wired)"
    fi
fi

########## Web protection: discovery, then --dry-run returns here ##########
WEB_ENABLED=1
if [ "$WEB" != "1" ] && [ "$DRY_RUN" != "1" ]; then
    WEB_ENABLED=0
    step "Web protection disabled (--no-web)"
    if sudo test -f "$WEB_JAIL" || sudo test -f "$FILTER_DIR/${WEB_FILTER_PROBE}.conf"; then
        warn "a web jail from an earlier run is still installed:"
        warn "  $WEB_JAIL"
        warn "remove it by re-running with --uninstall-web"
    else
        info "no web jail installed, nothing to do"
    fi
fi

if [ "$WEB_ENABLED" = "1" ] || [ "$DRY_RUN" = "1" ]; then
    web_staging_dir
    trap web_cleanup EXIT
    step "Web protection: access logs and client address"
    if ! web_discover; then
        exit 1
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    step "Dry run: rendering the filters and the jail file (nothing is written)"
    if ! web_dry_run; then
        exit 1
    fi
    info "dry run complete: no file written, Cloudflare untouched, no reload"
    exit 0
fi

########## Escape a value for safe use as a sed replacement ##########
sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

if [ "$HAS_CF" = "1" ]; then
    ########## Cloudflare mode: install the ban/unban helper ##########
    step "Installing ${HELPER_PATH} (Cloudflare ban/unban helper)"
    ########## Write the helper with the credentials baked in ##########
    # A quoted heredoc keeps the helper's own $VAR references literal; the
    # placeholders are then substituted with escaped values so a token that
    # contains $, & or | cannot break generation.
    {
        cat << 'EOF'
#!/bin/bash
# Cloudflare Firewall Access Rules helper invoked by Fail2Ban.
# Generated by fail2ban-setup.sh - do not edit by hand.
ACTION="$1"
NAME="$2"
IP="$3"
CF_ACCOUNT="__CF_ACCOUNT__"
CF_TARGET="__CF_TARGET__"
CF_TOKEN="__CF_TOKEN__"
CF_EMAIL="__CF_EMAIL__"
CF_KEY="__CF_KEY__"
API_URL="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/firewall/access_rules/rules"
########## Build the auth headers (Bearer token or legacy email + key) ##########
AUTH_HEADERS=()
if [ -n "$CF_TOKEN" ]; then
    AUTH_HEADERS=(-H "Authorization: Bearer $CF_TOKEN")
elif [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]; then
    AUTH_HEADERS=(-H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY")
else
    exit 0
fi
if [ "$ACTION" = "ban" ]; then
    curl -s -o /dev/null -X POST "$API_URL" \
         "${AUTH_HEADERS[@]}" \
         -H "Content-Type: application/json" \
         -d "{\"mode\":\"block\",\"configuration\":{\"target\":\"$CF_TARGET\",\"value\":\"$IP\"},\"notes\":\"Fail2Ban $NAME\"}"
elif [ "$ACTION" = "unban" ]; then
    RULE_ID=$(curl -s -X GET "$API_URL?mode=block&configuration.target=$CF_TARGET&configuration.value=$IP&page=1&per_page=1" \
              "${AUTH_HEADERS[@]}" \
              -H "Content-Type: application/json" \
              | jq -r '.result[0].id // empty')
    if [ -n "$RULE_ID" ]; then
        curl -s -o /dev/null -X DELETE "$API_URL/$RULE_ID" \
             "${AUTH_HEADERS[@]}" \
             -H "Content-Type: application/json"
    fi
fi
EOF
    } | sed \
        -e "s|__CF_ACCOUNT__|$(sed_replacement "$CF_ACCOUNT")|g" \
        -e "s|__CF_TARGET__|$(sed_replacement "$CF_TARGET")|g" \
        -e "s|__CF_TOKEN__|$(sed_replacement "$CF_TOKEN")|g" \
        -e "s|__CF_EMAIL__|$(sed_replacement "$CF_EMAIL")|g" \
        -e "s|__CF_KEY__|$(sed_replacement "$CF_KEY")|g" \
        | sudo tee "$HELPER_PATH" > /dev/null
    ########## Root-only: the file contains the Cloudflare credential ##########
    sudo chmod 700 "$HELPER_PATH"
    info "helper installed (mode 700)"


    step "Wiring the Cloudflare action into Fail2Ban (ui-custom-action.conf)"
    if sudo test -f "$ACTION_FILE"; then
        ########## Prepend the CF call to actionban/actionunban, idempotently ##########
        sudo grep -q "cf-fail2ban.sh ban" "$ACTION_FILE" || \
        sudo sed -i "s|^actionban = |actionban = ${HELPER_PATH} ban \"<name>\" \"<ip>\"\\n            |" "$ACTION_FILE"
        sudo grep -q "cf-fail2ban.sh unban" "$ACTION_FILE" || \
        sudo sed -i "s|^actionunban = |actionunban = ${HELPER_PATH} unban \"<name>\" \"<ip>\"\\n              |" "$ACTION_FILE"
        info "ui-custom-action.conf now triggers the Cloudflare helper on ban/unban"
    else
        warn "$ACTION_FILE not found; skipping Cloudflare action wiring"
    fi
else
    ########## Local mode: no Cloudflare, ban with the server's own firewall ##########
    step "No Cloudflare credentials - configuring LOCAL banning only"
    ########## Remove any helper left over from a previous Cloudflare run ##########
    if sudo test -e "$HELPER_PATH"; then
        sudo rm -f "$HELPER_PATH"
        info "removed stale $HELPER_PATH"
    else
        info "no Cloudflare helper present"
    fi
    ########## Revert a Cloudflare wiring previously injected into the action ##########
    if sudo test -f "$ACTION_FILE" && sudo grep -q 'cf-fail2ban.sh' "$ACTION_FILE"; then
        sudo cp -a "$ACTION_FILE" "${ACTION_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        sudo sed -i -e 's|^actionban = .*cf-fail2ban.sh ban .*$|actionban = |' \
                    -e 's|^actionunban = .*cf-fail2ban.sh unban .*$|actionunban = |' "$ACTION_FILE"
        info "reverted Cloudflare wiring in $(basename "$ACTION_FILE") (backup kept)"
    fi
    ########## Pick the available local firewall action (nftables > iptables) ##########
    BAN_ACTION=""
    if command -v nft > /dev/null 2>&1 \
        && sudo test -f /etc/fail2ban/action.d/nftables-multiport.conf \
        && sudo nft list ruleset > /dev/null 2>&1; then
        BAN_ACTION="nftables-multiport"
    elif sudo test -f /etc/fail2ban/action.d/iptables-multiport.conf; then
        BAN_ACTION="iptables-multiport"
    fi
    ########## Write an additive jail override (CloudPanel's jail.local still wins) ##########
    step "Writing the local jail override (jail.d)"
    sudo mkdir -p /etc/fail2ban/jail.d
    {
        cat << 'EOF'
# Managed by fail2ban-setup.sh - local banning (no Cloudflare).
# NOTE: CloudPanel values in /etc/fail2ban/jail.local take precedence over
# this file. It only adds a baseline sshd jail and sane default timings.
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
EOF
        if [ -n "$BAN_ACTION" ]; then
            printf 'banaction = %s\n' "$BAN_ACTION"
        fi
        cat << 'EOF'

[sshd]
enabled  = true
EOF
    } | sudo tee "$LOCAL_JAIL" > /dev/null
    if [ -n "$BAN_ACTION" ]; then
        info "local ban action: ${BAN_ACTION}"
    else
        info "local ban action: Fail2Ban distro default (iptables)"
    fi
    info "wrote $LOCAL_JAIL"
fi

########## Web protection: install the filters and the jail (unless --no-web) ##########
if [ "$WEB_ENABLED" = "1" ]; then
    if ! web_install; then
        warn "refusing to install a web filter that did not pass its self-test"
        exit 1
    fi
else
    info "web jails not installed (--no-web)"
fi

########## Common: enable, validate and reload Fail2Ban ##########
step "Enabling, validating and reloading Fail2Ban"
if ! command -v fail2ban-client > /dev/null 2>&1; then
    warn "fail2ban-client not installed; install Fail2Ban first (e.g. server-prep.sh) and re-run"
    exit 1
fi
if systemctl cat fail2ban.service > /dev/null 2>&1; then
    sudo systemctl enable --now fail2ban
    info "fail2ban service enabled and running"
else
    warn "fail2ban.service not found; continuing with fail2ban-client only"
fi
sudo fail2ban-client -t && sudo fail2ban-client reload
info "fail2ban validated and reloaded"

step "All done"
if [ "$HAS_CF" = "1" ]; then
    echo "Fail2Ban configured with the Cloudflare firewall integration (account ${CF_ACCOUNT})."
else
    echo "Fail2Ban configured for local banning only (no Cloudflare)."
fi
if [ "$CLEAR_SCREEN" = "1" ]; then clear || true; fi

