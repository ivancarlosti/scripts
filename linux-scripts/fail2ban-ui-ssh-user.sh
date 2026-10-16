#!/bin/bash
# Fail2Ban UI - dedicated SSH service account
#
# Creates (or updates) the local, password-less, key-only account that Fail2Ban
# UI (https://github.com/swissmakers/fail2ban-ui) uses to manage this host's
# Fail2Ban instance over SSH, then prints the RSA private key to paste into the
# UI's /config/.ssh.
#
# Least privilege - the account gets exactly what the UI's SSH connector runs:
#   * read + write access to /etc/fail2ban through filesystem ACLs. The
#     connector reads the config tree (cat/find) and stages its writes
#     (mkdir, cat > tmp, mv, chmod, rm) as the login user, so the ACLs - not a
#     broad group membership - are what make that work;
#   * password-less sudo restricted to the two commands the upstream security
#     guide requires: `fail2ban-client *` and `systemctl restart fail2ban`;
#   * key-only SSH: the account has no password hash at all ("!"), and the key
#     entry uses OpenSSH's `restrict` option (no pty, no agent, port or X11
#     forwarding).
# The account is never added to sudo/wheel, and this script never touches
# /etc/ssh: per-user sshd hardening is left to whatever the host already runs.
#
# Usage:
#   fail2ban-ui-ssh-user.sh [options]
#
#   --user <name>            Service account name, default "sa_fail2ban"   [SA_USER]
#   --key-bits <n>           RSA key size, default 4096                     [KEY_BITS]
#   --from <addr[,addr]>     Restrict the key to these source addresses      [KEY_FROM]
#   --rotate-key             Generate a new key even when one already exists
#   --output <path>          Also save the private key (mode 600, root)     [OUTPUT_PATH]
#   --reverse-tunnel <port>  Let the key listen on localhost:<port> only, as
#                            required by the UI's "reverse tunnel for events"
#                            (the host's own sshd must also allow TCP
#                            forwarding; this script does not change it)
#   --with-log-read          Add the account to the "adm" group so the UI's
#                            logpath test can read /var/log (Debian/Ubuntu)
#   --log-group <group>      Same as --with-log-read, with an explicit group [LOG_GROUP]
#   --dry-run                Show the planned changes and modify nothing
#   -h, --help               Show this help and exit
#
# Diagnostics - same conventions as the other linux-scripts:
#   * every step is announced, so you can see exactly how far it got;
#   * an ERR trap prints the failing line, the command and the exit code;
#   * run with VERBOSE=1 for a full shell trace of every command;
#   * the terminal is intentionally never cleared: the generated private key
#     must stay visible so it can be copied.
set -euo pipefail
set -E   # let the ERR trap fire inside functions, subshells and $( ) as well

########## Diagnostics helpers ##########
VERBOSE="${VERBOSE:-0}"
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
    printf '                      curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/linux-scripts/fail2ban-ui-ssh-user.sh | sudo VERBOSE=1 bash\n' >&2
    exit "$code"
}
trap on_error ERR

if [ "$VERBOSE" = "1" ]; then
    PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
    set -x
fi

########## Constants ##########
SUDOERS_DIR="/etc/sudoers.d"
FAIL2BAN_ROOT="/etc/fail2ban"
SA_SHELL="/bin/bash"

########## Defaults (overridable via environment, then command line) ##########
SA_USER="${SA_USER:-sa_fail2ban}"
KEY_BITS="${KEY_BITS:-4096}"
KEY_FROM="${KEY_FROM:-}"
OUTPUT_PATH="${OUTPUT_PATH:-}"
LOG_GROUP="${LOG_GROUP:-}"
ROTATE_KEY=0
TUNNEL_PORT=0
DRY_RUN=0

SA_HOME="/home/${SA_USER}"
SSH_DIR="${SA_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SUDOERS_FILE="${SUDOERS_DIR}/fail2ban-ui-${SA_USER}"
KEY_COMMENT="fail2ban-ui@$(hostname -s 2>/dev/null || hostname)"

TMP_DIR=""

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" || true
    fi
    return 0
}
trap cleanup EXIT

usage() {
    sed -n '/^# Usage:/,/^# Diagnostics/p' "${BASH_SOURCE[0]:-$0}" | sed '$d' | sed 's/^# \{0,1\}//'
}

########## Command line ##########
ARGV="$*"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            [ -n "${2:-}" ] || { warn "--user needs an account name"; exit 1; }
            SA_USER="$2"; shift 2 ;;
        --key-bits)
            [ -n "${2:-}" ] || { warn "--key-bits needs a number"; exit 1; }
            KEY_BITS="$2"; shift 2 ;;
        --from)
            [ -n "${2:-}" ] || { warn "--from needs an address list"; exit 1; }
            KEY_FROM="$2"; shift 2 ;;
        --output)
            [ -n "${2:-}" ] || { warn "--output needs a path"; exit 1; }
            OUTPUT_PATH="$2"; shift 2 ;;
        --reverse-tunnel)
            [ -n "${2:-}" ] || { warn "--reverse-tunnel needs a port"; exit 1; }
            TUNNEL_PORT="$2"; shift 2 ;;
        --log-group)
            [ -n "${2:-}" ] || { warn "--log-group needs a group name"; exit 1; }
            LOG_GROUP="$2"; shift 2 ;;
        --with-log-read)
            LOG_GROUP="adm"; shift ;;
        --rotate-key)
            ROTATE_KEY=1; shift ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            warn "unknown argument: $1"
            usage >&2
            exit 1 ;;
    esac
done

# Keep the derived paths in sync with a possibly overridden account name.
SA_HOME="/home/${SA_USER}"
SSH_DIR="${SA_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
SUDOERS_FILE="${SUDOERS_DIR}/fail2ban-ui-${SA_USER}"

case "$KEY_BITS" in
    ''|*[!0-9]*) warn "--key-bits must be a number (got: $KEY_BITS)"; exit 1 ;;
esac
if [ "$KEY_BITS" -lt 2048 ]; then
    warn "refusing to generate a ${KEY_BITS}-bit RSA key; use at least 2048 bits"
    exit 1
fi
if [ "$TUNNEL_PORT" != "0" ]; then
    case "$TUNNEL_PORT" in
        ''|*[!0-9]*) warn "--reverse-tunnel must be a port number (got: $TUNNEL_PORT)"; exit 1 ;;
    esac
    if [ "$TUNNEL_PORT" -lt 1024 ] || [ "$TUNNEL_PORT" -gt 65535 ]; then
        warn "--reverse-tunnel port must be between 1024 and 65535 (got: $TUNNEL_PORT)"
        exit 1
    fi
fi

if [ "$(id -u)" -ne 0 ]; then
    warn "this script must run as root: it creates a system account, a sudoers"
    warn "file and filesystem ACLs, none of which can be done as a normal user"
    if [ -n "$ARGV" ]; then
        warn "run it as: sudo bash ${BASH_SOURCE[0]:-$0} ${ARGV}"
    else
        warn "run it as: sudo bash ${BASH_SOURCE[0]:-$0}"
    fi
    exit 1
fi

########## Preflight ##########
step "Preflight checks"

info "service account : ${SA_USER} (home ${SA_HOME}, shell ${SA_SHELL})"
info "key             : RSA ${KEY_BITS} bits, PEM format, comment \"${KEY_COMMENT}\""
if [ -n "$KEY_FROM" ]; then
    info "key restricted  : from=\"${KEY_FROM}\""
fi
if [ "$TUNNEL_PORT" != "0" ]; then
    info "reverse tunnel  : localhost:${TUNNEL_PORT} only"
fi
if [ -n "$LOG_GROUP" ]; then
    info "log reading     : via group \"${LOG_GROUP}\""
fi
if [ "$DRY_RUN" = "1" ]; then
    info "mode            : dry run (nothing will be modified)"
fi

MISSING_TOOLS=""
for tool in ssh-keygen visudo useradd usermod setfacl fail2ban-client; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS="${MISSING_TOOLS} ${tool}"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    if printf '%s' "$MISSING_TOOLS" | grep -q ' setfacl' && command -v apt-get >/dev/null 2>&1; then
        step "Installing the ACL tooling (setfacl)"
        if [ "$DRY_RUN" = "1" ]; then
            info "dry run: would run \"apt-get update -qq && apt-get install -y acl\""
        else
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y acl
        fi
        if command -v setfacl >/dev/null 2>&1; then
            MISSING_TOOLS="$(printf '%s' "$MISSING_TOOLS" | sed 's/ setfacl//')"
        fi
    fi
fi

if [ -n "$(printf '%s' "$MISSING_TOOLS" | tr -d ' ')" ]; then
    warn "missing required tools:${MISSING_TOOLS}"
    warn "install them (Debian/Ubuntu: apt-get install -y openssh-client sudo acl passwd) and re-run"
    exit 1
fi

SSH_CLIENT=""
if command -v ssh >/dev/null 2>&1; then
    SSH_CLIENT="$(command -v ssh)"
else
    warn "the ssh client is not installed: the local self-test will be skipped"
fi

if [ ! -d "$FAIL2BAN_ROOT" ]; then
    warn "${FAIL2BAN_ROOT} does not exist: install Fail2Ban first"
    warn "hint: linux-scripts/fail2ban-setup.sh (or server-prep.sh) sets it up"
    exit 1
fi

# The sudoers rules must reference the absolute, canonical paths: sudo does not
# resolve a bare command name the same way the shell does, and a relative or
# symlinked path would silently never match.
FAIL2BAN_CLIENT="$(readlink -f "$(command -v fail2ban-client)")"
info "fail2ban-client: ${FAIL2BAN_CLIENT}"

if fail2ban-client ping >/dev/null 2>&1; then
    info "fail2ban       : running and answering its socket"
else
    warn "fail2ban is not answering its socket yet: the Fail2Ban UI needs a running"
    warn "server, so start it too (\"systemctl start fail2ban\", or fail2ban-server -b)"
fi

SYSTEMCTL=""
if command -v systemctl >/dev/null 2>&1; then
    SYSTEMCTL="$(readlink -f "$(command -v systemctl)")"
    info "systemctl      : ${SYSTEMCTL}"
else
    warn "systemctl is not available: the UI's \"restart Fail2Ban\" action will not work"
    warn "it falls back to \"fail2ban-client reload\", which is covered by the sudo rules"
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    warn "curl and/or jq are missing: the UI's ban-notification callback action needs"
    warn "both on this host (apt-get install -y curl jq). Fail2Ban itself still runs."
fi

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || true)" = "Enforcing" ]; then
    warn "SELinux is enforcing: SSH may refuse to read ${AUTH_KEYS} from a home directory"
    warn "check \"ausearch -m avc -ts recent\" and, if needed, run: restorecon -Rv ${SSH_DIR}"
fi

########## SSH posture (read-only) ##########
# /etc/ssh is deliberately never modified: per-user hardening belongs to the
# host's own sshd policy, and different servers legitimately have different
# configuration. We only report what sshd actually parses (sshd -T, so drop-ins
# and Match blocks are accounted for) and warn about the account's exposure.
step "SSH posture (read-only, this script never edits /etc/ssh)"

SSHD_BIN=""
SSH_PORT="22"
if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
fi

if [ -z "$SSHD_BIN" ]; then
    warn "sshd not found: skipping the SSH posture report and the local self-test"
else
    if SSHD_CONF="$("$SSHD_BIN" -T 2>/dev/null)"; then
        SSHD_PORT_CONF="$(printf '%s\n' "$SSHD_CONF" | awk 'tolower($1)=="port"{print $2; exit}')"
        [ -n "$SSHD_PORT_CONF" ] && SSH_PORT="$SSHD_PORT_CONF"

        sshd_value() { printf '%s\n' "$SSHD_CONF" | awk -v k="$1" 'tolower($1)==k{print $2; exit}'; }

        for param in passwordauthentication pubkeyauthentication kbdinteractiveauthentication permitemptypasswords; do
            printf '    - %-30s : %s\n' "$param" "$(sshd_value "$param")"
        done
        info "sshd listens on port ${SSH_PORT}"

        if [ "$(sshd_value pubkeyauthentication)" != "yes" ]; then
            warn "PubkeyAuthentication is not enabled: ${SA_USER} will not be able to log in with its key"
        fi
        if [ "$(sshd_value permitemptypasswords)" = "yes" ]; then
            warn "PermitEmptyPasswords is yes: ${SA_USER} has a locked hash (\"!\"), not an empty one, so it is not affected"
        fi
        if [ "$(sshd_value passwordauthentication)" = "yes" ] || [ "$(sshd_value kbdinteractiveauthentication)" = "yes" ]; then
            info "password authentication is enabled globally, but ${SA_USER} has no password hash, so password logins are refused by PAM"
        fi
    else
        warn "sshd -T failed (missing host keys or a broken config): skipping the SSH posture report"
    fi
fi

########## Authorized key options ##########
# "restrict" is OpenSSH's shorthand for no-pty, no-agent-forwarding,
# no-port-forwarding, no-X11-forwarding and no-user-rc. The UI only runs
# commands, so anything else is turned off explicitly.
if [ "$TUNNEL_PORT" != "0" ]; then
    # permitlisten needs forwarding not to be denied, so spell the options out
    # and allow exactly one loopback port instead of "restrict".
    KEY_OPTIONS="permitlisten=\"localhost:${TUNNEL_PORT}\",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc"
else
    KEY_OPTIONS="restrict"
fi
if [ -n "$KEY_FROM" ]; then
    KEY_OPTIONS="from=\"${KEY_FROM}\",${KEY_OPTIONS}"
fi

render_sudoers() {
    cat <<EOF
# Fail2Ban UI SSH service account - managed by linux-scripts/fail2ban-ui-ssh-user.sh
# Least privilege: only the Fail2Ban client and a Fail2Ban restart, nothing else.
Defaults:${SA_USER} !requiretty
${SA_USER} ALL=(ALL) NOPASSWD: ${FAIL2BAN_CLIENT} *
EOF
    if [ -n "$SYSTEMCTL" ]; then
        printf '%s ALL=(ALL) NOPASSWD: %s restart fail2ban\n' "$SA_USER" "$SYSTEMCTL"
    fi
}

if [ "$DRY_RUN" = "1" ]; then
    step "Planned changes (dry run: nothing was modified)"
    echo
    printf '    account %s\n' "$SA_USER"
    if id -u "$SA_USER" >/dev/null 2>&1; then
        info "exists already (uid $(id -u "$SA_USER")): home/shell would be aligned, password disabled"
    else
        info "would be created with home ${SA_HOME} and shell ${SA_SHELL}, no password hash (\"!\")"
    fi
    info "would be removed from sudo/wheel if it is a member of either"
    echo
    printf '    SSH key\n'
    if [ -f "$AUTH_KEYS" ] && grep -qF "$KEY_COMMENT" "$AUTH_KEYS"; then
        if [ "$ROTATE_KEY" = "1" ]; then
            info "an existing ${KEY_COMMENT} key would be replaced by a new ${KEY_BITS}-bit RSA key"
        else
            info "an existing ${KEY_COMMENT} key would be kept (use --rotate-key to replace it)"
        fi
    else
        info "a new ${KEY_BITS}-bit RSA key would be generated and its private key printed"
    fi
    info "${AUTH_KEYS} would get this entry:"
    info "  ${KEY_OPTIONS} ssh-rsa AAAA... ${KEY_COMMENT}"
    echo
    printf '    sudoers file %s (0440 root:root, validated with visudo)\n' "$SUDOERS_FILE"
    render_sudoers | sed 's/^/      /'
    echo
    printf '    filesystem ACLs\n'
    info "setfacl -R -m u:${SA_USER}:rwX $(readlink -f "$FAIL2BAN_ROOT")"
    info "find $(readlink -f "$FAIL2BAN_ROOT") -type d -exec setfacl -d -m u:${SA_USER}:rwX {} +"
    echo
    if [ -n "$LOG_GROUP" ]; then
        printf '    group membership\n'
        info "usermod --append --groups ${LOG_GROUP} ${SA_USER}   # read-only access to the logs"
        echo
    fi
    info "re-run without --dry-run to apply all of the above"
    exit 0
fi

########## Account ##########
step "Creating or updating the service account ${SA_USER}"

if id -u "$SA_USER" >/dev/null 2>&1; then
    info "the account already exists (uid $(id -u "$SA_USER")): aligning home, shell and password state"
    # usermod prints "no changes" on stdout when everything already matches.
    usermod --home "$SA_HOME" --shell "$SA_SHELL" "$SA_USER" >/dev/null
else
    info "creating the account together with its home directory"
    useradd --create-home --home-dir "$SA_HOME" --shell "$SA_SHELL" \
        --comment "Fail2Ban UI SSH service account" "$SA_USER"
fi
install -d -m 0755 -o "$SA_USER" -g "$SA_USER" "$SA_HOME"

# No password hash at all: pam_unix refuses password logins for this account even
# when sshd is configured with PasswordAuthentication yes, and "!" is a locked
# hash rather than an empty one, so PermitEmptyPasswords cannot be abused either.
usermod --password '!' "$SA_USER"
info "password login disabled (shadow hash set to \"!\")"

# Membership of sudo/wheel would silently grant unrestricted root, which would
# void every other restriction put in place here.
for grp in sudo wheel; do
    if [ "$(id -gn "$SA_USER" 2>/dev/null || true)" = "$grp" ]; then
        warn "${SA_USER} has \"${grp}\" as its primary group, which grants full root"
        warn "fix that by hand: usermod --gid <new-primary-group> ${SA_USER}"
        continue
    fi
    if getent group "$grp" >/dev/null 2>&1 && id -nG "$SA_USER" | tr ' ' '\n' | grep -qx "$grp"; then
        warn "${SA_USER} is a member of \"${grp}\": removing it, membership grants full root"
        gpasswd --delete "$SA_USER" "$grp"
    fi
done

########## SSH key material ##########
step "SSH key material"

MANAGED_KEY_LINE=""
if [ -f "$AUTH_KEYS" ]; then
    MANAGED_KEY_LINE="$(grep -F "$KEY_COMMENT" "$AUTH_KEYS" | head -n 1 || true)"
fi

GENERATE_KEY=1
if [ -n "$MANAGED_KEY_LINE" ] && [ "$ROTATE_KEY" != "1" ]; then
    GENERATE_KEY=0
fi

KEY_PUB=""
if [ "$GENERATE_KEY" = "1" ]; then
    TMP_DIR="$(mktemp -d)"
    chmod 0700 "$TMP_DIR"
    ssh-keygen -q -t rsa -b "$KEY_BITS" -m PEM -N '' -C "$KEY_COMMENT" -f "${TMP_DIR}/id_rsa"
    if ! head -n 1 "${TMP_DIR}/id_rsa" | grep -qx -- '-----BEGIN RSA PRIVATE KEY-----'; then
        warn "ssh-keygen did not produce a PEM-encoded RSA private key; refusing to continue"
        warn "the file must start with \"-----BEGIN RSA PRIVATE KEY-----\" (Fail2Ban UI and Go's SSH client expect that format)"
        exit 1
    fi
    KEY_PUB="$(cat "${TMP_DIR}/id_rsa.pub")"
    if [ -n "$MANAGED_KEY_LINE" ]; then
        info "rotating the ${KEY_COMMENT} key: generated a new ${KEY_BITS}-bit RSA key"
    else
        info "generated a new ${KEY_BITS}-bit RSA key (${KEY_COMMENT})"
    fi
else
    # Keep the existing key so an already configured Fail2Ban UI keeps working,
    # but refresh the authorized_keys options (--from, --reverse-tunnel, ...).
    KEY_PUB="$(printf '%s\n' "$MANAGED_KEY_LINE" | sed -E 's/^.*((ssh|ecdsa)-[A-Za-z0-9-]+) /\1 /')"
    if ! printf '%s\n' "$KEY_PUB" | grep -qE '^(ssh-|ecdsa-)'; then
        warn "the existing authorized_keys entry for ${KEY_COMMENT} could not be parsed:"
        warn "  ${MANAGED_KEY_LINE}"
        warn "re-run with --rotate-key to replace it with a freshly generated key"
        exit 1
    fi
    info "reusing the existing ${KEY_COMMENT} key; no new private key will be printed"
fi

install -d -m 0700 -o "$SA_USER" -g "$SA_USER" "$SSH_DIR"

TMP_AUTH="$(mktemp)"
chmod 0600 "$TMP_AUTH"
if [ -f "$AUTH_KEYS" ]; then
    # Drop only the entry this script manages; any other key of the account stays.
    grep -vF "$KEY_COMMENT" "$AUTH_KEYS" > "$TMP_AUTH" || true
fi
printf '%s %s\n' "$KEY_OPTIONS" "$KEY_PUB" >> "$TMP_AUTH"
install -m 0600 -o "$SA_USER" -g "$SA_USER" "$TMP_AUTH" "$AUTH_KEYS"
rm -f "$TMP_AUTH"
info "${AUTH_KEYS} now contains:"
info "  ${KEY_OPTIONS} <public key> ${KEY_COMMENT}"

########## Private key ##########
if [ "$GENERATE_KEY" = "1" ]; then
    step "Private key - copy it into the Fail2Ban UI now"
    echo
    printf '%s\n' "======================= COPY FROM HERE ======================="
    cat "${TMP_DIR}/id_rsa"
    printf '%s\n' "======================== COPY TO HERE ========================"
    echo
    info "this is the only time the private key is shown; it is shredded once the"
    info "self-test below has confirmed that it works, so copy it now"
    info "in the Fail2Ban UI container it belongs at /config/.ssh/id_rsa with mode 600, e.g.:"
    info "  docker exec -i fail2ban-ui sh -c 'umask 077; cat > /config/.ssh/id_rsa' < privatekey.pem"
    info "  podman exec -i fail2ban-ui sh -c 'umask 077; cat > /config/.ssh/id_rsa' < privatekey.pem"
    info "then set \"SSH key path\" to /config/.ssh/id_rsa in the UI's server form"

    if [ -n "$OUTPUT_PATH" ]; then
        if [ -e "$OUTPUT_PATH" ]; then
            KEY_BACKUP="${OUTPUT_PATH}.$(date +%Y%m%d-%H%M%S).bak"
            warn "${OUTPUT_PATH} already exists: keeping a copy at ${KEY_BACKUP}"
            cp -p "$OUTPUT_PATH" "$KEY_BACKUP"
            chmod 0600 "$KEY_BACKUP"
        fi
        install -m 0600 -o root -g root "${TMP_DIR}/id_rsa" "$OUTPUT_PATH"
        info "private key also written to ${OUTPUT_PATH} (mode 600, root): move it and delete it"
    fi
fi

########## Sudo rules ##########
step "Installing the sudo rules (${SUDOERS_FILE})"

TMP_SUDOERS="$(mktemp)"
chmod 0440 "$TMP_SUDOERS"
render_sudoers > "$TMP_SUDOERS"

if visudo --check --file "$TMP_SUDOERS" >/dev/null; then
    info "visudo validated the generated rules"
else
    warn "the generated sudoers file does not parse: nothing was changed in ${SUDOERS_DIR}"
    exit 1
fi

SUDOERS_BACKUP=""
if [ -f "$SUDOERS_FILE" ]; then
    SUDOERS_BACKUP="/root/sudoers.d-fail2ban-ui-${SA_USER}.$(date +%Y%m%d-%H%M%S).bak"
    warn "replacing the existing ${SUDOERS_FILE} (backup: ${SUDOERS_BACKUP})"
    cp -p "$SUDOERS_FILE" "$SUDOERS_BACKUP"
fi

install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
rm -f "$TMP_SUDOERS"

# visudo -c parses the whole configuration, so a bad drop-in anywhere is caught
# here rather than by the next sudo call.
if ! visudo --check >/dev/null; then
    warn "the sudo configuration does not parse with ${SUDOERS_FILE} in place: rolling back"
    if [ -n "$SUDOERS_BACKUP" ] && [ -f "$SUDOERS_BACKUP" ]; then
        install -m 0440 -o root -g root "$SUDOERS_BACKUP" "$SUDOERS_FILE"
        warn "restored the previous ${SUDOERS_FILE} from ${SUDOERS_BACKUP}"
    else
        rm -f "$SUDOERS_FILE"
        warn "removed ${SUDOERS_FILE} again"
    fi
    exit 1
fi

info "installed ${SUDOERS_FILE} (0440 root:root):"
render_sudoers | sed 's/^/      /'

OTHER_GRANTS="$(grep -rlF -- "$SA_USER" "$SUDOERS_DIR" 2>/dev/null | grep -vF "$SUDOERS_FILE" || true)"
if [ -n "$OTHER_GRANTS" ]; then
    warn "other sudoers files also mention ${SA_USER}: review them to keep least privilege"
    printf '%s\n' "$OTHER_GRANTS" | sed 's/^/      /'
fi

########## Filesystem ACLs ##########
step "Granting read and write access to ${FAIL2BAN_ROOT} through filesystem ACLs"

# The Fail2Ban UI connector reads the config tree and stages its writes as the
# login user, so it needs the ACLs below rather than a broad directory mode.
FAIL2BAN_REAL="$(readlink -f "$FAIL2BAN_ROOT")"
if [ "$FAIL2BAN_REAL" != "$FAIL2BAN_ROOT" ]; then
    info "${FAIL2BAN_ROOT} resolves to ${FAIL2BAN_REAL}: the ACLs go on the real path"
fi

setfacl --recursive --modify "u:${SA_USER}:rwX" "$FAIL2BAN_REAL"
find "$FAIL2BAN_REAL" -type d -exec setfacl --default --modify "u:${SA_USER}:rwX" {} +

info "read/write granted on ${FAIL2BAN_REAL} (directories inherit it for new files)"
getfacl --absolute-names --omit-header "$FAIL2BAN_REAL" 2>/dev/null \
    | grep -E '^(user|default:user):' | sed 's/^/      /' || true

########## Optional log reading ##########
if [ -n "$LOG_GROUP" ]; then
    step "Allowing the account to read the logs (group ${LOG_GROUP})"
    if getent group "$LOG_GROUP" >/dev/null 2>&1; then
        usermod --append --groups "$LOG_GROUP" "$SA_USER"
        info "${SA_USER} is now in \"${LOG_GROUP}\" (read-only access to /var/log)"
        info "without this, the UI's logpath test reports the logs as unreadable and"
        info "Features > Logpath Test stays disabled - Fail2Ban itself keeps working"
    else
        warn "group \"${LOG_GROUP}\" does not exist: skipping the log-reading setup"
    fi
fi

########## Local self-test ##########
step "Local self-test (key login + sudo rules over 127.0.0.1)"

if [ "$GENERATE_KEY" != "1" ]; then
    info "skipped: this run reused the existing key, so there is no private key to test with"
elif [ ! -r "${TMP_DIR}/id_rsa" ]; then
    warn "skipped: the generated private key is no longer readable, nothing to test with"
    warn "re-run the script if you want the end-to-end self-test"
elif [ -z "$SSHD_BIN" ] || [ -z "$SSH_CLIENT" ]; then
    info "skipped: sshd and/or the ssh client are not installed on this host"
else
    TEST_OUTPUT="$("$SSH_CLIENT" -i "${TMP_DIR}/id_rsa" -p "$SSH_PORT" \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes -o PreferredAuthentications=publickey \
        -o ConnectTimeout=8 -o LogLevel=ERROR \
        "${SA_USER}@127.0.0.1" 'sudo -n fail2ban-client ping' 2>&1 || true)"

    if printf '%s' "$TEST_OUTPUT" | grep -qi 'pong'; then
        info "success: the key logs in and ${SA_USER} reaches fail2ban-client through sudo"
        printf '%s\n' "$TEST_OUTPUT" | sed 's/^/      /'
    elif printf '%s' "$TEST_OUTPUT" | grep -q 'Failed to access socket path'; then
        info "the key login and the sudo rules work (fail2ban-client really ran as root),"
        info "but Fail2Ban is not running, so there was nothing to answer the ping:"
        info "start it with \"systemctl start fail2ban\" (or fail2ban-server -b) and re-run"
        printf '%s\n' "$TEST_OUTPUT" | sed 's/^/      /'
    else
        warn "the self-test did not confirm a working connection (not fatal, check the output):"
        printf '%s\n' "$TEST_OUTPUT" | sed 's/^/      /'
        warn "common causes: Fail2Ban is not running, sshd does not accept the key yet,"
        warn "or this host refuses loopback SSH logins (AllowUsers/DenyUsers/Match rules)"
    fi

    info "sudo rules as sudo itself reports them (sudo -l -U ${SA_USER}):"
    sudo --list --other-user="$SA_USER" 2>&1 | sed 's/^/      /' || true
fi

########## Remove the private key from this host ##########
# Do not leave a usable private key behind: it is the credential for this
# account and belongs only to the Fail2Ban UI. This runs after the self-test so
# that the key can still be verified end to end first.
if [ "$GENERATE_KEY" = "1" ] && [ -f "${TMP_DIR}/id_rsa" ]; then
    if command -v shred >/dev/null 2>&1; then
        shred -u "${TMP_DIR}/id_rsa"
    else
        rm -f "${TMP_DIR}/id_rsa"
    fi
    info "the private key was removed from this host's disk (copy it from the screen above)"
fi

########## Summary ##########
step "Done - use these values in the Fail2Ban UI"

if [ -n "$SYSTEMCTL" ]; then
    SUDO_RULES="${FAIL2BAN_CLIENT} *
          ${SYSTEMCTL} restart fail2ban"
else
    SUDO_RULES="${FAIL2BAN_CLIENT} *
          (systemctl is not installed on this host, so the UI's restart action
           falls back to \"fail2ban-client reload\")"
fi

cat <<EOF

    Add this host under the UI's "Manage Servers":

      Connection type : SSH (remote)
      Host            : <this host's address or DNS name>
      SSH port        : ${SSH_PORT}
      SSH user        : ${SA_USER}
      SSH key path    : /config/.ssh/id_rsa     (path inside the Fail2Ban UI container)

    What ${SA_USER} is allowed to do:

      * read and write ${FAIL2BAN_REAL:-$FAIL2BAN_ROOT} through filesystem ACLs
        (configuration reads and the UI's staged configuration writes)
      * sudo, without a password, restricted to exactly:
          ${SUDO_RULES}
      * log in with a key only: no password hash at all, and the key entry uses
          ${KEY_OPTIONS}
      * NOT a member of sudo/wheel${LOG_GROUP:+ (only added to "${LOG_GROUP}" for log reading)}

    This script never modifies /etc/ssh: the host's own sshd policy decides
    everything else, and ${SA_USER} is protected by having no password hash.

    To revoke the access again:

      userdel -r ${SA_USER}
      rm -f ${SUDOERS_FILE}
      setfacl --recursive --remove "u:${SA_USER}" ${FAIL2BAN_REAL:-$FAIL2BAN_ROOT}
      find ${FAIL2BAN_REAL:-$FAIL2BAN_ROOT} -type d -exec setfacl --default --remove "u:${SA_USER}" {} +

EOF

if [ "$GENERATE_KEY" = "1" ]; then
    info "the private key above is the only credential for this account: keep it secret,"
    info "store it with mode 600 inside the Fail2Ban UI, and never commit it to a repository"
else
    info "the existing key was kept, so no private key was printed: use the one already"
    info "loaded in the Fail2Ban UI, or re-run with --rotate-key and update the UI afterwards"
fi
