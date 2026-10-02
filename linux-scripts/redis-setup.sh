#!/bin/bash
# Redis host tuning
# Applies the kernel settings Redis recommends for stable persistence and
# cluster operation:
#   vm.overcommit_memory      = 1 -> allows the fork() used by BGSAVE /
#                                    BGREWRITEAOF to succeed even when free
#                                    memory is low
#   net.ipv4.ip_nonlocal_bind = 1 -> lets redis-server bind to addresses that
#                                    are not (yet) present on the host
#                                    (required by Redis Cluster)
# Re-running the script is safe: existing values are replaced, missing ones
# are appended.
set -euo pipefail

########## Configuration ##########
SYSCTL_FILE="/etc/sysctl.conf"

########## Replace or append a sysctl setting (idempotent) ##########
apply_sysctl() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}" "$SYSCTL_FILE"; then
        sudo sed -i "s/^${key}.*/${key} = ${value}/" "$SYSCTL_FILE"
    else
        echo "${key} = ${value}" | sudo tee -a "$SYSCTL_FILE" > /dev/null
    fi
    echo "set ${key} = ${value}"
}

########## 1. Handle vm.overcommit_memory ##########
apply_sysctl "vm.overcommit_memory" "1"

########## 2. Handle net.ipv4.ip_nonlocal_bind ##########
apply_sysctl "net.ipv4.ip_nonlocal_bind" "1"

########## 3. Apply the changes immediately ##########
sudo sysctl -p

echo "Redis host tuning applied."
