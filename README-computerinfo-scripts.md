# Computer Info Scripts

Read-only system report scripts for Linux and Windows. Both print the same set of sections — operating system, CPU, memory, disk usage, uptime, load averages and network addressing — so a ticket from either platform can be compared side by side. Nothing is installed, changed or written, and neither script needs administrator rights: the two Windows fields that do require elevation say `Requires administrator` instead of failing.

> These scripts consolidate the standalone [lnxcomputerinfo](https://github.com/ivancarlosti/lnxcomputerinfo) and [wincomputerinfo](https://github.com/ivancarlosti/wincomputerinfo) projects.

---

## 🚀 Remote execution

### 🐧 Linux (bash)

```bash
curl -fsSL https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/linuxcomputeinfo.sh | bash
```

No `sudo` is needed — the script only reads `/proc`, `df`, `free`, `ip` and `/etc/os-release`.

### 🪟 Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/windowscomputeinfo.ps1 | iex
```

### 🪟 Windows (cmd.exe or the Run dialog)

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/windowscomputeinfo.ps1 | iex"
```

> **Note:** `irm … | iex` runs the script in memory and binds no arguments, so a piped run always uses the defaults (antivirus and Secure Boot sections included). Use the local setup below when you want to pass `-SkipAntivirus` or `-SkipSecureBoot`.

---

## 📋 Scripts

### [`linuxcomputeinfo.sh`](computerinfo-scripts/linuxcomputeinfo.sh)

**Purpose:** One-screen summary of a Linux host, printed between two `SYSTEM INFORMATION` rules.

| Section | Field | Source |
|---------|-------|--------|
| System | `OS` | `PRETTY_NAME` from `/etc/os-release` (`/etc/lsb-release`, then `uname -s` as fallback) |
| System | `Kernel` | `uname -r` |
| Processor | `CPU vCores` | `nproc` (`getconf _NPROCESSORS_ONLN`, then `/proc/cpuinfo`) |
| Processor | `CPU Consumption` | `Usage` and `Available` percentages from two `/proc/stat` samples 0.5 s apart (`top -bn1` fallback) |
| Memory | `Total`, `Used`, `Buffers/Cache`, `Free` + percentages | `free -m` (parsed `/proc/meminfo` fallback) |
| Disk | `Total`, `Used`, `Free`, `Usage`, `Available` | `df -h --total` |
| Disk | `<mount> mount:` line per filesystem | `df -h --exclude-type=tmpfs --exclude-type=devtmpfs` |
| Uptime | `Uptime` | `uptime -p`, derived from `/proc/uptime` when `-p` is unsupported |
| Load | `Load Averages` (1, 5, 15 min) | `/proc/loadavg` |
| Network | `Local IPv4` / `Local IPv6` | `ip -o addr show` (`hostname -I` fallback), IPv6 limited to global scope |
| Network | `Public IPv4` / `Public IPv6` | `curl -4/-6 -m 5 https://icanhazip.com` |

**Behaviour notes:**

1. `clear` runs only on an interactive terminal (`-t 1`, `TERM` set), so the script also works when piped, redirected to a file, run from cron or over `ssh host 'bash -s' < script`.
2. CPU usage is sampled from `/proc/stat` instead of scraping `top`, which removes the `top` dependency and works in containers where `top` reports nothing useful.
3. `SKIP_PUBLIC_IP=1` skips both public lookups (offline hosts, CI, air-gapped servers) and prints `skipped`:

   ```bash
   SKIP_PUBLIC_IP=1 bash linuxcomputeinfo.sh
   ```

4. Every probe degrades to `unavailable` instead of aborting the report; the exit status stays `0` for a completed report.

---

### [`windowscomputeinfo.ps1`](computerinfo-scripts/windowscomputeinfo.ps1)

**Purpose:** The Windows counterpart of `linuxcomputeinfo.sh`, plus the two security sections the original `.bat` reported (registered antivirus products and Secure Boot).

| Section | Field | Source |
|---------|-------|--------|
| System | `Host Name` | `Win32_ComputerSystem.Name` |
| System | `OS Name` | `Win32_OperatingSystem.Caption` |
| System | `Windows Version` | `DisplayVersion` (registry) or the build map below, plus `BuildNumber` |
| System | `Manufacturer / Model` | `Win32_ComputerSystem` |
| System | `Logged Username` | `$env:USERNAME` |
| System | `BIOS Serial Number` | `Win32_BIOS.SerialNumber` |
| System | `Installed RAM` | `TotalPhysicalMemory` in GB |
| System | `Uptime` | Now − `Win32_OperatingSystem.LastBootUpTime` |
| System | `CPU Name`, `CPU Core / vCore` | `Win32_Processor` |
| System | `GPU` | `Win32_VideoController` |
| System | `IP Address` | `Get-NetIPAddress -AddressFamily IPv4`, loopback and `169.254.*` excluded |
| System | `Disk <n> Name / Type` | `Get-PhysicalDisk` (Windows 8 / Server 2012+) |
| Disk | `Drive <X> - Total / Used / (%)` | `Win32_LogicalDisk` where `DriveType=3` |
| Antivirus | `Name / State`, `Path` | `root/SecurityCenter2:AntiVirusProduct`, `productState` translated to `Enabled` / `Disabled` |
| Secure Boot | `Secure Boot` | `HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State` (readable as a normal user) |
| Secure Boot | `Secure Boot Mode` | `Get-SecureBootUEFI -Name SetupMode`, `Requires administrator` when not elevated |

**Build → version map** (used when `DisplayVersion` is missing):

| Build | Version | Build | Version |
|-------|---------|-------|---------|
| 19041 | 2004 | 22621 | 22H2 |
| 19042 | 20H2 | 22631 | 23H2 |
| 19043 | 21H1 | 26100 | 24H2 |
| 19044 | 21H2 | 26200 | 25H2 |
| 19045 | 22H2 | | |

**Switches** (only available when the script is run from a file):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windowscomputeinfo.ps1 -SkipAntivirus -SkipSecureBoot
```

**Behaviour notes:**

1. The file is deliberately **ASCII-only**: Windows PowerShell 5.1 decodes `.ps1` files as ANSI unless they carry a UTF-8 BOM, so ASCII keeps the text identical for `-File` and `irm | iex` runs alike. No `chcp 65001` is required.
2. It is self-contained — no `$PSScriptRoot` lookups and no sibling files — because `irm … | iex` executes the script with an empty `$PSScriptRoot`.
3. Windows PowerShell 5.1 compatible: no ternary operator, no null-coalescing, and no `$result = try { … } catch { … }` assignment (replaced by an explicit `if`/`else`), so it also runs unchanged under PowerShell 7+.
4. Each probe is wrapped in `try`/`catch` or `-ErrorAction SilentlyContinue`, so a missing WMI class prints `Unavailable` instead of aborting the report.
5. On a non-Windows host (`pwsh` on Linux/macOS) the script prints a one-line notice and returns without touching anything.

---

### [`windowscomputeinfo.cmd`](computerinfo-scripts/windowscomputeinfo.cmd)

**Purpose:** Double-click launcher, for hosts whose execution policy is `Restricted` (where double-clicking the `.ps1` itself is blocked).

**Workflow:**
1. Verifies `windowscomputeinfo.ps1` sits next to it, and explains what to do when it does not.
2. Runs `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windowscomputeinfo.ps1" %*`, forwarding switches such as `-SkipAntivirus`.
3. Pauses so the window stays readable, unless `NO_PAUSE=1` is set (use that from automation), then exits with the PowerShell script's exit code.

```bat
windowscomputeinfo.cmd
windowscomputeinfo.cmd -SkipSecureBoot
set NO_PAUSE=1 && windowscomputeinfo.cmd
```

---

## 📦 Requirements

| Dependency | Platform | Purpose |
|------------|----------|---------|
| `bash` 3.2+ | Linux | Runs `linuxcomputeinfo.sh` |
| `awk`, `sed`, `df`, `sleep` | Linux | Text processing and the CPU sample; part of every base install |
| `procps` (`free`, `uptime`, `top`) | Linux | Memory, uptime and the CPU fallback; `/proc/meminfo`, `/proc/uptime` and `/proc/stat` are used when missing |
| `iproute2` (`ip`) | Linux | Local addresses; `hostname -I` is used when `ip` is missing |
| `curl` | Linux | Public IPv4/IPv6 lookup only (skip with `SKIP_PUBLIC_IP=1`) |
| Windows PowerShell 5.1+ or PowerShell 7+ | Windows | Runs `windowscomputeinfo.ps1`; ships with Windows 10/11 and Server 2016+ |
| WMI / CIM (`Win32_*` classes) | Windows | Hardware, disk, antivirus and Secure Boot state |
| `Storage` module (`Get-PhysicalDisk`) | Windows 8 / Server 2012+ | Physical disk model and media type; older hosts simply print no disk lines |
| Administrator rights | Optional | Only `Secure Boot Mode` needs elevation; everything else runs as the logged-in user |

---

## 🧰 Local setup

### 🐧 Linux

1. **Clone the repository** (or download the single script):
   ```bash
   git clone https://github.com/ivancarlosti/scripts.git
   cd scripts/computerinfo-scripts
   ```

2. **Run it** — no `sudo`, and no `chmod` needed when invoked through `bash`:
   ```bash
   bash linuxcomputeinfo.sh
   ```

   To run it as `./linuxcomputeinfo.sh`, make it executable first:
   ```bash
   chmod +x linuxcomputeinfo.sh
   ./linuxcomputeinfo.sh
   ```

### 🪟 Windows

1. **Download both files into the same folder** ([`windowscomputeinfo.ps1`](computerinfo-scripts/windowscomputeinfo.ps1) and [`windowscomputeinfo.cmd`](computerinfo-scripts/windowscomputeinfo.cmd)), either from a clone of this repository or from the raw links above.

2. **Double-click `windowscomputeinfo.cmd`**, or run one of:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\windowscomputeinfo.ps1
   ```

   ```bat
   windowscomputeinfo.cmd -SkipAntivirus
   ```

---

<!-- footer -->
---

## 🧑‍💻 Consulting and technical support

- For personal support and queries, please submit a new issue to have it addressed.
- For commercial related questions, please [**contact me**][ivancarlos] for consulting costs.

| 🩷 Project support |
| :---: |
| If you found this project helpful, consider [**buying me a coffee**][buymeacoffee] |
| Thanks for your support, it is much appreciated! |

[ivancarlos]: https://ivancarlos.me
[buymeacoffee]: https://www.buymeacoffee.com/ivancarlos
