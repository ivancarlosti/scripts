#!/bin/bash
# Linux computer info
# Prints a read-only summary of the host: OS, kernel, CPU, memory, disk usage,
# uptime, load averages and network addressing. Nothing is installed, changed
# or written, so it runs as a normal user, either from a clone
# (bash linuxcomputeinfo.sh) or piped straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/linuxcomputeinfo.sh | bash
set -uo pipefail

########## Section rule (same 76-column rule as the original report) ##########
RULE='############################ SYSTEM INFORMATION ############################'

########## Skip the public IP lookups (offline hosts, cron, CI) ##########
SKIP_PUBLIC_IP="${SKIP_PUBLIC_IP:-0}"

########## Clear the screen only on an interactive terminal ##########
# clear fails when TERM is unset (cron, pipes, ssh without a pty); chaining it
# with && used to abort the whole report in those cases.
if [[ -t 1 && -n "${TERM:-}" ]] && command -v clear > /dev/null 2>&1; then
    clear
fi

########## Section rule, printed above and below the report ##########
header() {
    echo "${RULE}"
    echo ""
}

########## One "Label: value" line ##########
field() {
    echo "$1: $2"
}

########## OS pretty name, whatever release file the distribution ships ##########
os_name() {
    local name=""
    if [[ -r /etc/os-release ]]; then
        name=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
    fi
    if [[ -z "${name}" && -r /etc/lsb-release ]]; then
        name=$(awk -F= '/^DISTRIB_DESCRIPTION=/{gsub(/"/, "", $2); print $2; exit}' /etc/lsb-release)
    fi
    if [[ -z "${name}" ]]; then
        name=$(uname -s 2>/dev/null || echo "unavailable")
    fi
    echo "${name}"
}

########## Online CPU count ##########
cpu_cores() {
    if command -v nproc > /dev/null 2>&1; then
        nproc
        return
    fi
    if command -v getconf > /dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN
        return
    fi
    awk '/^processor/{count++} END{print count + 0}' /proc/cpuinfo 2>/dev/null || echo "unavailable"
}

########## CPU consumption from two /proc/stat samples ##########
# Two samples 0.5 s apart give the utilisation of that half second without
# depending on top(1), which is missing on many minimal images and blind to
# the host inside containers.
cpu_consumption() {
    local first="" second=""
    if [[ -r /proc/stat ]]; then
        # Fields of the "cpu" line: user nice system idle iowait irq softirq steal
        first=$(awk '/^cpu /{total=0; for (i = 2; i <= 9; i++) {total += $i}; print total, $5 + $6; exit}' /proc/stat)
        sleep 0.5
        second=$(awk '/^cpu /{total=0; for (i = 2; i <= 9; i++) {total += $i}; print total, $5 + $6; exit}' /proc/stat)
        if [[ -n "${first}" && -n "${second}" ]]; then
            awk -v first="${first}" -v second="${second}" 'BEGIN{
                split(first, start, " ");
                split(second, end, " ");
                total=end[1] - start[1];
                idle=end[2] - start[2];
                if (total <= 0) { print "unavailable"; exit }
                usage=(total - idle) * 100 / total;
                printf "Usage %.1f%%, Available %.1f%%", usage, 100 - usage;
            }'
            return
        fi
    fi
    if command -v top > /dev/null 2>&1; then
        top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" \
            | awk '{print "Usage "100 - $1 "%, Available " $1 "%"}'
        return
    fi
    echo "unavailable"
}

########## Memory consumption (free -m, with a /proc/meminfo fallback) ##########
memory_consumption() {
    echo "Memory Consumption:"
    if command -v free > /dev/null 2>&1; then
        free -m | awk '
        NR==1{next}
        NR==2{
          total=$2; used=$3; free=$4; buff_cache=$6;
          usage_perc=(used/total)*100;
          buffcache_perc=(buff_cache/total)*100;
          available_perc=(free/total)*100;
          printf "Total %dM, Used %dM, Buffers/Cache %dM, Free %dM\nUsage %.1f%%, Buffers/Cache %.1f%%, Available %.1f%%\n",
                 total, used, buff_cache, free, usage_perc, buffcache_perc, available_perc;
        }'
        return
    fi
    awk '
    /^MemTotal:/{total_mb=$2/1024}
    /^MemFree:/{free_mb=$2/1024}
    /^Buffers:/{buffers_mb=$2/1024}
    /^Cached:/{cached_mb=$2/1024}
    END{
        if (total_mb > 0) {
            buff_cache_mb=buffers_mb + cached_mb;
            used_mb=total_mb - free_mb - buff_cache_mb;
            printf "Total %dM, Used %dM, Buffers/Cache %dM, Free %dM\nUsage %.1f%%, Buffers/Cache %.1f%%, Available %.1f%%\n",
                   total_mb, used_mb, buff_cache_mb, free_mb,
                   (used_mb/total_mb)*100, (buff_cache_mb/total_mb)*100, (free_mb/total_mb)*100;
        } else {
            print "unavailable";
        }
    }' /proc/meminfo 2>/dev/null
}

########## Disk consumption: totals first, then every real mount ##########
disk_consumption() {
    local total_out="" mount_out=""
    echo "Disk Consumption:"
    total_out=$(df -h --total 2>/dev/null || df -h 2>/dev/null)
    printf '%s\n' "${total_out}" | awk '
    NR==1{next}
    $1=="total"{usage=substr($5, 1, length($5) - 1); printf "Total %s, Used %s, Free %s, Usage %s, Available %.1f%%\n", $2, $3, $4, $5, 100 - usage}
    '
    echo ""
    # --exclude-type is GNU-specific; on BusyBox df the tmpfs rows are filtered out.
    if ! mount_out=$(df -h --exclude-type=tmpfs --exclude-type=devtmpfs 2>/dev/null); then
        mount_out=$(df -h 2>/dev/null | awk 'NR==1 || $1 !~ /^(tmpfs|devtmpfs|udev)$/')
    fi
    printf '%s\n' "${mount_out}" | awk '
    NR>1 && $1!="total" && $1!="Filesystem" {
        usage=substr($5, 1, length($5) - 1);
        printf "%s mount: Used %s, Free %s, Usage %s, Available %.1f%%\n", $6, $3, $4, $5, 100 - usage
    }
    '
}

########## Uptime (uptime -p, derived from /proc/uptime when unavailable) ##########
uptime_report() {
    local pretty=""
    if command -v uptime > /dev/null 2>&1; then
        pretty=$(uptime -p 2>/dev/null)
    fi
    if [[ -n "${pretty}" ]]; then
        echo "Uptime: ${pretty}"
        return
    fi
    if [[ -r /proc/uptime ]]; then
        echo "Uptime: $(awk '{seconds=int($1); days=int(seconds/86400); hours=int((seconds%86400)/3600); minutes=int((seconds%3600)/60);
            printf "up ";
            if (days > 0) printf "%d day%s, ", days, (days == 1 ? "" : "s");
            if (days > 0 || hours > 0) printf "%d hour%s, ", hours, (hours == 1 ? "" : "s");
            printf "%d minute%s", minutes, (minutes == 1 ? "" : "s")}' /proc/uptime)"
        return
    fi
    echo "Uptime: unavailable"
}

########## Load averages ##########
load_averages() {
    if [[ -r /proc/loadavg ]]; then
        echo "Load Averages: $(awk '{print $1, $2, $3}' /proc/loadavg)"
        return
    fi
    echo "Load Averages: unavailable"
}

########## Local addresses (iproute2, falling back to hostname -I) ##########
# ip -o prints one address per line, so the prefix length can be stripped
# without grep -oP, which is not available on every build.
local_addresses() {
    local address=""
    if command -v ip > /dev/null 2>&1; then
        while read -r address; do
            [[ -z "${address}" ]] && continue
            echo "Local IPv4: ${address}"
        done <<< "$(ip -o -4 addr show 2>/dev/null | awk '{split($4, parts, "/"); print parts[1]}')"
        while read -r address; do
            [[ -z "${address}" ]] && continue
            echo "Local IPv6: ${address}"
        done <<< "$(ip -o -6 addr show scope global 2>/dev/null | awk '{split($4, parts, "/"); print parts[1]}')"
        return
    fi
    if command -v hostname > /dev/null 2>&1; then
        for address in $(hostname -I 2>/dev/null); do
            if [[ "${address}" == *:* ]]; then
                echo "Local IPv6: ${address}"
            else
                echo "Local IPv4: ${address}"
            fi
        done
        return
    fi
    echo "Local IPv4: unavailable"
}

########## Public address lookup (skipped with SKIP_PUBLIC_IP=1) ##########
public_address() {
    local family="${1:-4}" address=""
    if [[ "${SKIP_PUBLIC_IP}" == "1" ]]; then
        echo "skipped"
        return
    fi
    if ! command -v curl > /dev/null 2>&1; then
        echo "unavailable"
        return
    fi
    address=$(curl -"${family}" -m 5 -s https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    echo "${address:-unavailable}"
}

########## Report ##########
header
field "OS" "$(os_name)"
field "Kernel" "$(uname -r 2>/dev/null || echo "unavailable")"
echo ""
echo "Processor:"
field "CPU vCores" "$(cpu_cores)"
field "CPU Consumption" "$(cpu_consumption)"
echo ""
memory_consumption
echo ""
disk_consumption
echo ""
uptime_report
load_averages
echo ""
local_addresses
field "Public IPv4" "$(public_address 4)"
field "Public IPv6" "$(public_address 6)"
echo ""
header
