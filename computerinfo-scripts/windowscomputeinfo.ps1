<#
.SYNOPSIS
    Prints a read-only summary of the local Windows machine.

.DESCRIPTION
    Reports the operating system, hardware, disk usage, registered antivirus
    products and Secure Boot state. Nothing is installed, changed or written,
    so the script runs as a normal user; the few fields that need elevation
    say "Requires administrator" instead of failing.

    The script is self-contained and ASCII-only on purpose: Windows PowerShell
    5.1 decodes .ps1 files as ANSI unless they carry a UTF-8 BOM, and the same
    file must also work when it is piped into Invoke-Expression by the
    one-liner in the README.

    Optional switches can only be used with -File; a piped run uses the
    defaults.

.PARAMETER SkipAntivirus
    Do not query the Security Center for registered antivirus products.

.PARAMETER SkipSecureBoot
    Do not report the Secure Boot state and mode.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\windowscomputeinfo.ps1

.EXAMPLE
    irm https://raw.githubusercontent.com/ivancarlosti/scripts/main/computerinfo-scripts/windowscomputeinfo.ps1 | iex

.NOTES
    Author: Ivan Carlos
    Requires: Windows PowerShell 5.1 or PowerShell 7+
#>
[CmdletBinding()]
param(
    [switch]$SkipAntivirus,
    [switch]$SkipSecureBoot
)

########## Report layout ##########
# Section rules are 83 columns wide, the same width the original .bat used.
function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    $width = 83
    Write-Host ''
    Write-Host ('=== {0} {1}' -f $Title, ('=' * ($width - 5 - $Title.Length)))
}

########## Print one "Label: value" line ##########
function Write-Field {
    param([string]$Label, [object]$Value)
    Write-Host ('{0,-25} {1}' -f $Label, $Value)
}

########## Return "Unavailable" for an empty or missing value ##########
function Get-ValueOrFallback {
    param([object]$Value, [string]$Fallback = 'Unavailable')
    if ($null -eq $Value) { return $Fallback }
    if (([string]$Value).Trim() -eq '') { return $Fallback }
    return $Value
}

########## Plural aware duration part, e.g. "1 day" / "3 days" ##########
function Format-DurationPart {
    param([int]$Value, [string]$Unit)
    if ($Value -eq 1) { return ('{0} {1}' -f $Value, $Unit) }
    return ('{0} {1}s' -f $Value, $Unit)
}

########## Uptime since the last boot ##########
function Get-UptimeLabel {
    param([object]$OperatingSystem)
    if ($null -eq $OperatingSystem -or $null -eq $OperatingSystem.LastBootUpTime) {
        return 'Unavailable'
    }
    $span = (Get-Date) - $OperatingSystem.LastBootUpTime
    $parts = @()
    if ($span.Days -gt 0) { $parts += (Format-DurationPart $span.Days 'day') }
    if ($span.Days -gt 0 -or $span.Hours -gt 0) { $parts += (Format-DurationPart $span.Hours 'hour') }
    $parts += (Format-DurationPart $span.Minutes 'minute')
    return ('up ' + ($parts -join ', '))
}

########## Marketing name of the running build (2004 ... 25H2) ##########
# DisplayVersion is present on Windows 10 and 11; the build map covers hosts
# where the registry value is missing.
function Get-WindowsVersionLabel {
    param([object]$OperatingSystem)
    if ($null -eq $OperatingSystem) { return 'Unavailable' }
    $build = [string]$OperatingSystem.BuildNumber
    $display = $null
    try {
        $display = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                -Name DisplayVersion -ErrorAction SilentlyContinue).DisplayVersion
    } catch {
        $display = $null
    }
    if (-not $display) {
        $buildMap = @{
            '19041' = '2004'; '19042' = '20H2'; '19043' = '21H1'; '19044' = '21H2'
            '19045' = '22H2'; '22000' = '21H2'; '22621' = '22H2'; '22631' = '23H2'
            '26100' = '24H2'; '26200' = '25H2'
        }
        $display = $buildMap[$build]
    }
    if (-not $display) { $display = 'Unknown' }
    return ('{0} (Build {1})' -f $display, $build)
}

########## Translate the SecurityCenter2 productState bit mask ##########
function Get-AntivirusState {
    param([object]$ProductState)
    switch ([int]$ProductState) {
        397568 { return 'Enabled' }
        393472 { return 'Disabled' }
        262144 { return 'Enabled' }
        262160 { return 'Enabled' }
        266240 { return 'Enabled' }
        266256 { return 'Enabled' }
        393216 { return 'Disabled' }
        397312 { return 'Disabled' }
        default { return ('Unknown State (' + $ProductState + ')') }
    }
}

########## Secure Boot state (readable without elevation) ##########
function Get-SecureBootState {
    $enabled = $null
    try {
        $enabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' `
                -Name UEFISecureBootEnabled -ErrorAction SilentlyContinue).UEFISecureBootEnabled
    } catch {
        $enabled = $null
    }
    if ($enabled -eq 1) { return 'Enabled' }
    if ($enabled -eq 0) { return 'Disabled' }
    return 'Not supported (legacy BIOS) / unknown'
}

########## Secure Boot mode: Setup mode means no Platform Key is enrolled ##########
function Get-SecureBootMode {
    $elevated = $false
    try {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $elevated = $false
    }
    if (-not $elevated) { return 'Requires administrator' }
    try {
        $setupMode = (Get-SecureBootUEFI -Name SetupMode -ErrorAction Stop).Bytes
        if ($setupMode[0] -eq 1) { return 'Setup mode (no Platform Key)' }
        return 'User mode (Platform Key provisioned)'
    } catch {
        return 'Unavailable'
    }
}

########## Refuse to run on a non-Windows host (pwsh on Linux/macOS) ##########
$onWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $onWindows = $false }
if (-not $onWindows) {
    Write-Host 'windowscomputeinfo.ps1 reports on Windows hosts, and this session is not Windows.'
    return
}

########## Collect once, print once ##########
Write-Host '### Please wait, collecting system information... ###'

Write-Section 'SYSTEM INFORMATION'

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
$processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
$graphicsCards = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue)
$logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)

# Get-PhysicalDisk only exists on Windows 8 / Server 2012 and later.
$physicalDisks = @()
if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    $physicalDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
}

# Link-local (169.254.*) and loopback addresses are noise in a support report.
$ipAddresses = @()
try {
    $ipAddresses = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop) |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -ExpandProperty IPAddress)
} catch {
    $ipAddresses = @()
}

$ramLabel = 'Unavailable'
if ($null -ne $computerSystem -and $computerSystem.TotalPhysicalMemory) {
    $ramLabel = ('{0} GB' -f [Math]::Round($computerSystem.TotalPhysicalMemory / 1GB))
}

$manufacturer = Get-ValueOrFallback $computerSystem.Manufacturer
$model = Get-ValueOrFallback $computerSystem.Model

Write-Field 'Host Name:' (Get-ValueOrFallback $computerSystem.Name)
Write-Field 'OS Name:' (Get-ValueOrFallback $operatingSystem.Caption)
Write-Field 'Windows Version:' (Get-WindowsVersionLabel $operatingSystem)
Write-Field 'Manufacturer / Model:' ('{0} / {1}' -f $manufacturer, $model)
Write-Field 'Logged Username:' (Get-ValueOrFallback $env:USERNAME)
Write-Field 'BIOS Serial Number:' (Get-ValueOrFallback $bios.SerialNumber)
Write-Field 'Installed RAM:' $ramLabel
Write-Field 'Uptime:' (Get-UptimeLabel $operatingSystem)
foreach ($processor in $processors) {
    $processorName = Get-ValueOrFallback (($processor.Name -replace '\s+', ' ').Trim())
    Write-Field 'CPU Name:' $processorName
    Write-Field 'CPU Core / vCore:' ('{0} Cores / {1} Virtual Cores' -f $processor.NumberOfCores, $processor.NumberOfLogicalProcessors)
}
foreach ($graphicsCard in $graphicsCards) {
    Write-Field 'GPU:' (Get-ValueOrFallback $graphicsCard.Name)
}
Write-Field 'IP Address:' (Get-ValueOrFallback ($ipAddresses -join ', '))
$diskIndex = 0
foreach ($disk in $physicalDisks) {
    $diskIndex++
    Write-Field ('Disk {0} Name / Type:' -f $diskIndex) ('{0} / {1}' -f (Get-ValueOrFallback $disk.FriendlyName), (Get-ValueOrFallback $disk.MediaType))
}

Write-Section 'DISK USAGE'
if ($logicalDisks.Count -eq 0) {
    Write-Host 'No fixed logical disk reported.'
}
foreach ($logicalDisk in $logicalDisks) {
    $totalGb = [Math]::Round($logicalDisk.Size / 1GB, 2)
    $freeGb = [Math]::Round($logicalDisk.FreeSpace / 1GB, 2)
    $usedGb = $totalGb - $freeGb
    $usedPercent = 0
    if ($totalGb -ne 0) { $usedPercent = [Math]::Round(($usedGb / $totalGb) * 100, 2) }
    Write-Host ('Drive {0} - Total: {1} GB, Used: {2} GB ({3}%)' -f $logicalDisk.DeviceID, $totalGb, $usedGb, $usedPercent)
}

if (-not $SkipAntivirus) {
    Write-Section 'ANTIVIRUS SOFTWARE'
    $antivirusProducts = @()
    try {
        $antivirusProducts = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    } catch {
        $antivirusProducts = @()
    }
    if ($antivirusProducts.Count -eq 0) {
        Write-Host 'No antivirus product registered in the Security Center.'
    }
    foreach ($product in $antivirusProducts) {
        Write-Field 'Name / State:' ('{0} / {1}' -f (Get-ValueOrFallback $product.displayName), (Get-AntivirusState $product.productState))
        Write-Field 'Path:' (Get-ValueOrFallback $product.pathToSignedProductExe)
        Write-Host ''
    }
}

if (-not $SkipSecureBoot) {
    Write-Section 'SECURE BOOT'
    Write-Field 'Secure Boot:' (Get-SecureBootState)
    Write-Field 'Secure Boot Mode:' (Get-SecureBootMode)
}

Write-Host ''
Write-Host '### Data collection completed. Please print or save the above ###'
