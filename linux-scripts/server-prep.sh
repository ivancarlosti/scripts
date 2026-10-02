#!/bin/bash
# Base server preparation
# Refreshes the package index, upgrades installed packages and installs a small
# baseline toolset (curl, wget, sudo, cron, nano, fail2ban) used by the other
# scripts in this repository.
set -euo pipefail

########## Packages installed on every prepared host ##########
PACKAGES=(
    curl
    wget
    sudo
    cron
    nano
    fail2ban
)

########## Avoid interactive prompts (e.g. fail2ban, needrestart) ##########
# apt-get is used instead of apt because it has a stable, script-friendly CLI.
export DEBIAN_FRONTEND=noninteractive

########## Refresh the package index ##########
sudo apt-get update

########## Upgrade all installed packages ##########
sudo apt-get -y upgrade

########## Install the baseline packages ##########
sudo apt-get -y install "${PACKAGES[@]}"

echo "Server preparation complete: ${PACKAGES[*]}"
