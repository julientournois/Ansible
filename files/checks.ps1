<#
    Collects health information from one Windows server.

    Run by windows_health_check.yml through ansible.windows.win_powershell,
    which binds the param() block below from the task's `parameters:` and
    returns $Ansible.Result to Ansible.

    Read-only: it reads state and reports it, it changes nothing.
#>
param(
    # Drive to report on, for example 'C:'.
    [string]   $Drive = 'C:',

    # Services to check by name, whatever their start mode.
    [string[]] $Services = @(),

    # URLs to call from this server. Each entry has name, url and an
    # optional expect_content.
    [object[]] $Urls = @(),

    [int]      $TimeoutSec = 15,

    [bool]     $IgnoreCertErrors = $true
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Nothing here modifies the server.
$Ansible.Changed = $false

# --- 1. Is a restart pending? ----------------------------------------------
$reasons = @()

if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $reasons += 'Component Based Servicing'
}
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $reasons += 'Windows Update'
}

$sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
if ($sessionManager.PendingFileRenameOperations) {
    $reasons += 'Pending file rename'
}

$activeName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
$pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
if ($activeName -and $pendingName -and $activeName -ne $pendingName) {
    $reasons += 'Computer rename'
}

# --- 2. Automatic services that are not running ----------------------------
$autoStopped = @(
    Get-CimInstance Win32_Service |
        Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } |
        ForEach-Object { $_.Name }
)

# --- 3. The services we were asked to watch --------------------------------
$watched = @(
    foreach ($name in $Services) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service) { "$name=$($service.Status)" } else { "$name=not installed" }
    }
)

# --- 4. Drive --------------------------------------------------------------
# Filtered here rather than with -Filter, so no value is ever pasted into a
# WQL query.
$disk = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $Drive } | Select-Object -First 1

$diskTotalGb = ''
$diskFreeGb = ''
$diskFreePct = ''
if ($disk -and $disk.Size -gt 0) {
    $diskTotalGb = [math]::Round($disk.Size / 1GB, 1)
    $diskFreeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
    $diskFreePct = [math]::Round($disk.FreeSpace / $disk.Size * 100, 1)
}

# --- 5. URLs, called from this server --------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($IgnoreCertErrors) {
    # Internal sites commonly use self-signed certificates.
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$urlResults = @(
    foreach ($u in $Urls) {
        $name = $u.name
        try {
            $response = Invoke-WebRequest -Uri $u.url -UseBasicParsing -TimeoutSec $TimeoutSec
            $code = [int]$response.StatusCode

            if ($u.expect_content) {
                if ($response.Content -like "*$($u.expect_content)*") {
                    "$name=$code content found"
                }
                else {
                    "$name=$code content MISSING"
                }
            }
            else {
                "$name=$code"
            }
        }
        catch {
            "$name=failed: $($_.Exception.Message)"
        }
    }
)

# --- What Ansible gets back ------------------------------------------------
$pendingRestart = if ($reasons.Count -gt 0) { 'yes' } else { 'no' }

$Ansible.Result = @{
    pending_restart    = $pendingRestart
    pending_reasons    = $reasons -join ' | '
    auto_stopped_count = $autoStopped.Count
    auto_stopped       = $autoStopped -join ' | '
    watched_services   = $watched -join ' | '
    disk_total_gb      = $diskTotalGb
    disk_free_gb       = $diskFreeGb
    disk_free_pct      = $diskFreePct
    urls               = $urlResults -join ' | '
}
