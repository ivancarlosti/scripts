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
#   -h, --help                 Show this help and exit
#
# Legacy auth requires BOTH --cf-email and --cf-key; otherwise pass --cf-token.
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

########## Defaults (overridable via environment, then command line) ##########
CF_ACCOUNT="${CF_ACCOUNT:-}"
CF_TOKEN="${CF_TOKEN:-}"
CF_EMAIL="${CF_EMAIL:-}"
CF_KEY="${CF_KEY:-}"
CF_TARGET="${CF_TARGET:-ip}"

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

With no Cloudflare credentials the script configures LOCAL banning only
(the server's own iptables/nftables action). Legacy auth requires BOTH
--cf-email and --cf-key; otherwise pass --cf-token.
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

########## Preflight: environment and expected files ##########
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
for path in /etc/fail2ban /etc/fail2ban/action.d /etc/fail2ban/jail.d; do
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

