#Requires -Version 5.1
<#
.SYNOPSIS
    Hyper-V Automation Lab Suite v3.0 "Enterprise-Ready" - Self-Extracting Installer

.DESCRIPTION
    Run this single script to write every file in the Hyper-V Lab Suite into the
    current directory, just like a `git clone` / GitHub pull experience.

    Files written:
      cleanup.ps1, createDC.ps1, deploy.ps1, setup.ps1, DHCP.ps1, Domainsetup.ps1, InitPassword.ps1, joindomain.ps1, RDS.ps1, RDVH.ps1, switch.ps1, Guidance.txt, readme.txt, Walkthrough.md

.EXAMPLE
    .\Creation.ps1
    # All suite files are extracted to the current folder.

.NOTES
    Version : 3.0
    Build   : 2026.04.09
    Rebuilt : 2026-04-09 11:35:16
    Encoding: UTF-8 (no BOM) - compatible with all PowerShell consoles
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetDir = $PSScriptRoot
if (-not $targetDir) { $targetDir = (Get-Location).Path }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Hyper-V Lab Suite v3.0 - Self-Extractor  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Target directory: $targetDir"
Write-Host ""

$written     = 0
$overwritten = 0
$errors      = 0

function Write-SuiteFile {
    param(
        [string]$FileName,
        [string]$Content
    )

    $dest = Join-Path $targetDir $FileName
    $existed = Test-Path $dest

    try {
        # Write with UTF-8 encoding, no BOM â€” always overwrite
        [System.IO.File]::WriteAllText($dest, $Content, [System.Text.UTF8Encoding]::new($false))
        if ($existed) {
            Write-Host "  [OK]    $FileName  (overwritten)" -ForegroundColor Green
            $script:overwritten++
        } else {
            Write-Host "  [OK]    $FileName" -ForegroundColor Green
        }
        $script:written++
    }
    catch {
        Write-Host "  [ERR]   $FileName  -> $_" -ForegroundColor Red
        $script:errors++
    }
}

# ---------------------------------------------------------------------------
# FILE: cleanup.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'cleanup.ps1' -Content @'
#Requires -RunAsAdministrator
# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "cleanup_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }

# ─── Fetch registered VM names safely ────────────────────────────────────────
try {
    $vmNames = @(Get-VM -ErrorAction Stop | Select-Object -ExpandProperty Name)
} catch {
    Write-Warning "Failed to query Hyper-V VMs. Aborting to prevent accidental data loss."
    Write-Warning "Error: $_"
    Stop-Safe; exit 1
}

if ($vmNames.Count -eq 0) {
    Write-Warning "No VMs found in Hyper-V. Skipping cleanup to avoid deleting all VM folders."
    Stop-Safe; exit 0
}

# ─── Check each storage path ──────────────────────────────────────────────────
# Resolve paths relative to the script's own location, not the caller's CWD.
$basePaths = @(
    (Join-Path $PSScriptRoot "hyperv"),
    (Join-Path $PSScriptRoot "VM")
)

foreach ($basePath in $basePaths) {
    Write-Host "`nChecking: $basePath" -ForegroundColor Cyan

    if (-not (Test-Path $basePath)) {
        Write-Host "  -> Path does not exist. Skipping." -ForegroundColor Gray
        continue
    }

    $folders = @(Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty Name)

    if ($folders.Count -eq 0) {
        Write-Host "  -> No subfolders found." -ForegroundColor Gray
        continue
    }

    $orphaned = $folders | Where-Object { $vmNames -notcontains $_ }

    if ($orphaned.Count -eq 0) {
        Write-Host "  -> No orphaned folders found." -ForegroundColor Green
        continue
    }

    foreach ($folder in $orphaned) {
        $fullPath = Join-Path $basePath $folder
        Write-Host "  -> Removing orphaned folder: $fullPath" -ForegroundColor Yellow
        try {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction Stop
            Write-Host "     Removed." -ForegroundColor DarkGray
        } catch {
            Write-Warning "  Could not remove '$fullPath': $_ (may be in use)"
        }
    }
}

Write-Host "`nCleanup complete." -ForegroundColor Green
Stop-Safe; exit 0

'@

# ---------------------------------------------------------------------------
# FILE: createDC.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'createDC.ps1' -Content @'
#Requires -RunAsAdministrator
# -----------------------------------------------------------------------------
#  Domain Controller Provisioning Engine
# -----------------------------------------------------------------------------

param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("2016","2019","2022","2025")]
    [string]$OS,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$InitCode
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "CreateDC_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  Domain Controller Provisioning"              -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ─── Credentials ──────────────────────────────────────────────────────────────
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

if (-not $InitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found at: $seedPath"
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty. Add your master initialization code first."
        Exit-Script 1
    }
    $InitCode = ConvertTo-SecureString $baseVal -AsPlainText -Force
}
$adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $InitCode)

# ─── Step 1: Deploy base VM ───────────────────────────────────────────────────
Write-Host "`nStep 1: Deploying base VM..." -ForegroundColor Cyan
& (Join-Path $currentDir "deploy.ps1") -VMName $VMName -OS $OS -InitCode $InitCode
if ($LASTEXITCODE -ne 0) {
    Write-Error "deploy.ps1 failed with exit code $LASTEXITCODE."
    Exit-Script 1
}

# ─── Step 2: Wait for guest IP ────────────────────────────────────────────────
Write-Host "`nStep 2: Waiting for guest IP address (up to 2 minutes)..." -ForegroundColor Cyan
$ip         = $null
$maxRetries = 24   # 24 x 5 s = 2 minutes
$attempt    = 0

while (-not $ip -and $attempt -lt $maxRetries) {
    $attempt++
    try {
        $ip = Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1 -ExpandProperty IPAddress
        }
    } catch {
        Write-Host "  -> Attempt $attempt/$maxRetries guest not ready yet. Retrying in 5 s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if (-not $ip) {
    Write-Error "Guest did not return a valid IP after 2 minutes. Check integration services and network."
    Exit-Script 1
}
Write-Host "  [OK]  Guest IP: $ip" -ForegroundColor Green

# ─── Step 3: Promote to Domain Controller ────────────────────────────────────
Write-Host "`nStep 3: Promoting to Domain Controller (domain: $DomainName)..." -ForegroundColor Cyan

# BUG FIX: Install-ADDSForest triggers an automatic reboot. The original code
# had no error handling here — any failure (e.g. feature install issue) would
# silently continue. Added try/catch and checked that the command ran at all.
# Also, Install-ADDSForest must be called AFTER Install-WindowsFeature completes
# and the feature is fully available; the original had no intermediate check.
try {
    Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
        param($domainName, [System.Security.SecureString]$safeModePassword)

        $feat = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        if (-not $feat.Success) {
            throw "Failed to install AD-Domain-Services. Feature install result: $($feat.ExitCode)"
        }

        # Import the module explicitly — it may not auto-load inside PS Direct
        Import-Module ADDSDeployment -ErrorAction Stop

        Install-ADDSForest `
            -DomainName                    $domainName `
            -SafeModeAdministratorPassword $safeModePassword `
            -InstallDns                    `
            -Force                         `
            -NoRebootOnCompletion:$false   # allow the automatic reboot
    } -ArgumentList $DomainName, $InitCode
} catch {
    # After Install-ADDSForest the DC reboots, which breaks the PS Direct pipe.
    # PSRemotingTransportException / pipeline-stopped errors are expected here.
    $exType = $_.Exception.GetType().Name
    $exMsg  = $_.Exception.Message
    $isExpectedDisconnect = ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
                            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
    if (-not $isExpectedDisconnect) {
        Write-Error "DC promotion failed unexpectedly: $_"
        Exit-Script 1
    }
    Write-Host "  -> DC is rebooting as part of domain promotion (expected)." -ForegroundColor Yellow
}

# ─── Step 4: Wait for DC to come back up and be AD-ready ─────────────────────
# After Install-ADDSForest the DC reboots. We must wait until:
#   (a) PS Direct can reconnect (guest OS is up), AND
#   (b) the ADWS / Netlogon services are running (AD is functional)
# Without this wait, callers would immediately try to create AD objects or join
# the domain and fail because the DC is still mid-boot.
Write-Host "`nStep 4: Waiting for DC to finish booting and AD services to start..." -ForegroundColor Cyan

# The DC credential after promotion uses the DOMAIN\Administrator account.
# However immediately after reboot the local Administrator account is also valid
# (domain DB is still loading). Start with local then fall back to domain creds.
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\Administrator", $InitCode)
$currentCred = $adminCred

$dcReadyTimeout = (Get-Date).AddMinutes(15)
$dcReady        = $false

while (-not $dcReady -and (Get-Date) -lt $dcReadyTimeout) {
    try {
        $svcStatus = Invoke-Command -VMName $VMName -Credential $currentCred -ErrorAction Stop -ScriptBlock {
            $adws    = Get-Service -Name ADWS -ErrorAction SilentlyContinue
            $netlogon = Get-Service -Name Netlogon -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                ADWSRunning     = ($adws     -and $adws.Status     -eq 'Running')
                NetlogonRunning = ($netlogon -and $netlogon.Status -eq 'Running')
            }
        }

        if ($svcStatus.ADWSRunning -and $svcStatus.NetlogonRunning) {
            $dcReady = $true
            break
        }

        Write-Host "  -> AD services not yet running (ADWS=$($svcStatus.ADWSRunning), Netlogon=$($svcStatus.NetlogonRunning)). Waiting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } catch {
        if ($currentCred -eq $adminCred) {
            Write-Host "  -> Local admin access not ready, switching to domain credentials and retrying..." -ForegroundColor Yellow
            $currentCred = $domainAdminCred
        } else {
            Write-Host "  -> DC not yet reachable via PS Direct using domain creds. Retrying in 15 s... ($((Get-Date).ToString('HH:mm:ss')) )" -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }
}

if (-not $dcReady) {
    Write-Error "DC did not become AD-ready within 10 minutes. Check the VM manually."
    Exit-Script 1
}
Write-Host "  [OK]  DC is up and AD services are running." -ForegroundColor Green

Write-Host "`n[SUCCESS] Domain '$DomainName' is live on VM '$VMName'." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: deploy.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'deploy.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys one or more Hyper-V virtual machines from a golden image.
.DESCRIPTION
    Standardized deployment engine. Copies golden VHDs via parallel robocopy,
    creates and starts Hyper-V VMs. Validates DHCP availability before proceeding.
.PARAMETER VMName
    Mandatory. One or more VM names, comma-separated.
.PARAMETER OS
    Mandatory. OS year: 2016, 2019, 2022, or 2025.
.PARAMETER InitCode
    Optional. Administrator SecureString. Read from sys_bootstrap.ini if omitted.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("2016","2019","2022","2025","11")]
    [string]$OS,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$InitCode,

    # Skip the DHCP availability gate. Used by DHCP.ps1 when deploying the
    # DHCP VM itself — at that point no DHCP server exists yet by definition.
    [Parameter(Mandatory = $false)]
    [switch]$SkipDHCPCheck
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Deploy_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  VM Deployment Engine" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ─── Helper: Format-Bytes ─────────────────────────────────────────────────────
function Format-Bytes ([int64]$Bytes) {
    if     ($Bytes -ge 1GB) { "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { "{0:N2} KB" -f ($Bytes / 1KB) }
    else                    { "$Bytes B" }
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [FAIL] Administrator privileges required." -ForegroundColor Red
    Exit-Script 1
}
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Hyper-V module not found." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Pre-flight checks passed." -ForegroundColor Green

# ─── Paths ────────────────────────────────────────────────────────────────────
$currentDir      = $PSScriptRoot
$goldImageFolder = Join-Path $currentDir "goldenImage"
$vmBasePath      = Join-Path $currentDir "hyperv"

# ─── Resolve VM names and image extension early (needed for disk check) ───────
$vmNames = $VMName.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNames.Count -eq 0) {
    Write-Error "No VM names provided."
    Exit-Script 1
}

# BUG FIX: Windows Server 2016 is Gen 2 and uses .vhdx format (win2016_disk.vhdx)
# Original code treated 2016 as Gen 1 (.vhd), causing VHD not found errors.
$fileExt = if ($OS -eq "2025" -or $OS -eq "11" -or $OS -eq "2016") { "vhdx" } else { "vhd" }
$vmGen   = if ($OS -eq "2025" -or $OS -eq "11" -or $OS -eq "2016") { 2 }      else { 1 }

# ─── Locate golden image ──────────────────────────────────────────────────────
if (-not (Test-Path $goldImageFolder)) {
    Write-Error "Golden image folder not found: $goldImageFolder"
    Exit-Script 1
}
if (-not (Test-Path $goldImageFolder -PathType Container)) {
    Write-Error "Golden image path is not a directory: $goldImageFolder"
    Exit-Script 1
}

$goldImages = Get-ChildItem -Path $goldImageFolder -Filter "*${OS}*.$fileExt" -ErrorAction SilentlyContinue
if ($goldImages.Count -eq 0) {
    Write-Error "No golden image found for OS=$OS (.$fileExt) in $goldImageFolder"
    Write-Host "Available files:" -ForegroundColor Yellow
    Get-ChildItem $goldImageFolder -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  - $($_.Name)" }
    Exit-Script 1
}
$goldImage = $goldImages[0]
if ($goldImages.Count -gt 1) {
    Write-Warning "Multiple golden images found for OS=$OS. Using: $($goldImage.Name)"
}

# ─── Disk space validation ────────────────────────────────────────────────────
Write-Host "Validating disk space..." -ForegroundColor Cyan

# BUG FIX: Substring(0,1) assumes a drive-letter path. Use Split-Path + Get-Item
# to get the root drive regardless of UNC or relative path weirdness.
$vmDriveLetter = (Get-Item $currentDir).PSDrive.Name
$diskSpace     = (Get-PSDrive -Name $vmDriveLetter -ErrorAction SilentlyContinue).Free

if ($null -eq $diskSpace) {
    Write-Warning "Could not determine free disk space. Proceeding without space check."
} else {
    $vhdSize       = $goldImage.Length
    $requiredSpace = [long]($vhdSize * $vmNames.Count * 1.2)   # 20 % buffer
    if ($diskSpace -lt $requiredSpace) {
        Write-Error "Insufficient disk space on ${vmDriveLetter}:"
        Write-Host "  Need: $(Format-Bytes $requiredSpace)" -ForegroundColor Yellow
        Write-Host "  Have: $(Format-Bytes $diskSpace)"     -ForegroundColor Red
        Exit-Script 1
    }
    Write-Host "  [OK]  Sufficient disk space ($(Format-Bytes $diskSpace) free)" -ForegroundColor Green
}

# ─── Read switch configuration ────────────────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
$switchName = "NATSwitch"
$dhcpStart  = "192.168.1.2"
$dhcpEnd    = "192.168.1.254"
if (Test-Path $switchFile) {
    Get-Content -Path $switchFile | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        switch ($kv[0].Trim()) {
            "SwitchName" { $switchName = $kv[1].Trim() }
            "DHCPStart"  { $dhcpStart  = $kv[1].Trim() }
            "DHCPEnd"    { $dhcpEnd    = $kv[1].Trim() }
        }
    }
}
Write-Host "Using virtual switch: $switchName"

# ─── DHCP availability check ──────────────────────────────────────────────────
# Skipped when -SkipDHCPCheck is passed (e.g. DHCP.ps1 bootstrapping the DHCP VM).
if ($SkipDHCPCheck) {
    Write-Host "Skipping DHCP availability check (-SkipDHCPCheck specified)." -ForegroundColor Yellow
} else {
    $dhcpAvailable = $false
    Write-Host "Validating DHCP availability..." -ForegroundColor Cyan

    $osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $hasSM     = [bool](Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)

    if ($osCaption -match "Server" -and $hasSM) {
        Write-Host "  -> Checking host-based DHCP role..."
        try {
            $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
            if ($dhcpFeat -and $dhcpFeat.Installed) {
                $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object {
                    $_.StartRange.ToString() -eq $dhcpStart -and $_.EndRange.ToString() -eq $dhcpEnd
                }
                if ($scope) {
                    $dhcpAvailable = $true
                    Write-Host "  [OK]  Host DHCP role active with matching scope." -ForegroundColor Green
                }
            }
        } catch { }
    }

    if (-not $dhcpAvailable) {
        Write-Host "  -> Checking for DHCP VM..."
        $dhcpVm = Get-VM -Name "DHCP" -ErrorAction SilentlyContinue
        if ($dhcpVm) {
            if ($dhcpVm.State -ne 'Running') {
                Write-Host "  -> DHCP VM found but not running. Auto-starting..." -ForegroundColor Yellow
                Start-VM -Name "DHCP" -ErrorAction SilentlyContinue
            }
            Write-Host "  -> Waiting up to 60 s for DHCP VM to report an IP..." -ForegroundColor Cyan
            for ($i = 0; $i -lt 12; $i++) {
                # BUG FIX: Re-fetch the VM object each iteration; the IP list is only
                # populated after Integration Services updates the KVP, so using the
                # stale $dhcpVm object always returns empty on the first few polls.
                $ips = (Get-VM -Name "DHCP" -ErrorAction SilentlyContinue).NetworkAdapters.IPAddresses |
                       Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
                if ($ips) { $dhcpAvailable = $true; break }
                Start-Sleep -Seconds 5
            }
            if ($dhcpAvailable) {
                Write-Host "  [OK]  DHCP VM is running." -ForegroundColor Green
            } else {
                Write-Warning "DHCP VM did not report an IP within 60 s."
            }
        }
    }

    if (-not $dhcpAvailable) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host " DHCP SERVICE NOT AVAILABLE"             -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "VMs require DHCP to obtain IP addresses. Please run one of:" -ForegroundColor Yellow
        Write-Host "  1. .\DHCP.ps1   (Install DHCP on this host)"          -ForegroundColor Cyan
        Write-Host "  2. Deploy a VM named 'DHCP' (VM-based DHCP)"          -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Then retry: .\deploy.ps1 -VMName `"$VMName`" -OS $OS"  -ForegroundColor Cyan
        Write-Host ""
        Exit-Script 1
    }
}

# ─── Credentials ──────────────────────────────────────────────────────────────
if (-not $InitCode) {
    $seedPath = Join-Path $currentDir "sys_bootstrap.ini"
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found. Cannot build credentials."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $InitCode = ConvertTo-SecureString $baseVal -AsPlainText -Force
}

# Build administrator credentials for guest OS access
$adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $InitCode)

# ─── Pre-validate: no VM name collisions ──────────────────────────────────────
foreach ($vmName in $vmNames) {
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Error "VM '$vmName' already exists in Hyper-V. Remove it first or use a different name."
        Exit-Script 1
    }
}

# ─── Prepare destination folders ──────────────────────────────────────────────
if (-not (Test-Path $vmBasePath)) {
    New-Item -Path $vmBasePath -ItemType Directory | Out-Null
}

foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    if (Test-Path $vmPath) {
        Write-Warning "Stale folder found: $vmPath (no matching Hyper-V VM). Removing..."
        Remove-Item -Path $vmPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $vmPath -ItemType Directory | Out-Null
}

# ─── Parallel robocopy ────────────────────────────────────────────────────────
Write-Host "`nStarting parallel VHD copy for $($vmNames.Count) VM(s)..." -ForegroundColor Cyan

# Diagnostic: Verify golden image and destination paths before starting robocopy
Write-Host "  Golden image source: $($goldImage.DirectoryName)\$($goldImage.Name)" -ForegroundColor Gray
Write-Host "  Golden image size: $(Format-Bytes $goldImage.Length)" -ForegroundColor Gray
if (-not (Test-Path -Path (Join-Path $goldImage.DirectoryName $goldImage.Name))) {
    Write-Error "Golden image file not found: $(Join-Path $goldImage.DirectoryName $goldImage.Name)"
    Exit-Script 1
}

$copyProcesses = @{}
$vmProgress    = @{}

foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    # Use proven robocopy flags from v2.9 (simpler, more reliable)
    $rArgs  = "`"$($goldImage.DirectoryName)`" `"$vmPath`" `"$($goldImage.Name)`" /MT:4 /TEE /BYTES"
    $si     = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName               = "robocopy.exe"
    $si.Arguments              = $rArgs
    $si.RedirectStandardOutput = $true
    $si.UseShellExecute        = $false
    $si.CreateNoWindow         = $true
    
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $si
        $p.Start() | Out-Null
        $copyProcesses[$vmName] = $p
        $vmProgress[$vmName] = "0%"
    } catch {
        Write-Error "Failed to start robocopy for '$vmName': $_"
        Exit-Script 1
    }
}

# Read output synchronously, line-by-line (proven method from v2.9)
while ($copyProcesses.Values | Where-Object { -not $_.HasExited }) {
    foreach ($vmName in $vmNames) {
        $p = $copyProcesses[$vmName]
        if ($p -and -not $p.HasExited) {
            $line = $p.StandardOutput.ReadLine()
            if ($line -match '\s+(\d+)%') { 
                $vmProgress[$vmName] = "$($matches[1])%" 
            }
        }
    }
    $statusLine = ($vmNames | ForEach-Object { "$_ : $($vmProgress[$_])" }) -join " | "
    Write-Host "`r  $statusLine" -NoNewline
    Start-Sleep -Milliseconds 500
}
Write-Host ""
Write-Host "  [OK]  Disk copy complete." -ForegroundColor Green

# Robocopy exit codes: 0-7 = success/info, 8+ = errors
foreach ($vmName in $vmNames) {
    $exitCode = $copyProcesses[$vmName].ExitCode
    if ($exitCode -gt 7) {
        Write-Error "Robocopy failed for '$vmName' (exit code $exitCode)"
        Write-Host "  Source: $($goldImage.DirectoryName)\$($goldImage.Name)" -ForegroundColor Yellow
        Write-Host "  Dest:   $(Join-Path $vmBasePath $vmName)" -ForegroundColor Yellow
        Exit-Script 1
    }
}

# Rename VHD files to VM-specific names (proven method from v2.9)
foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    $oldPath = Join-Path $vmPath $goldImage.Name
    
    if (Test-Path $oldPath) {
        Rename-Item -Path $oldPath -NewName "$vmName.$fileExt" -ErrorAction Stop
        Write-Host "  -> Renamed VHD: $($goldImage.Name) -> $vmName.$fileExt" -ForegroundColor Green
    }
}

# ─── Create VMs ───────────────────────────────────────────────────────────────
foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    $vhdPath = Join-Path $vmPath "$vmName.$fileExt"

    Write-Host "  -> Instantiating $vmName..." -ForegroundColor Cyan
    try {
        New-VM -Name $vmName -Generation $vmGen -MemoryStartupBytes 2GB `
               -VHDPath $vhdPath -SwitchName $switchName -Path $vmPath | Out-Null
        Set-VMProcessor -VMName $vmName -Count 4
        # Set-VMFirmware only applies to Gen 2 VMs; silently skip for Gen 1.
        if ($vmGen -eq 2) {
            Set-VMFirmware -VMName $vmName -EnableSecureBoot Off -ErrorAction SilentlyContinue
        }
        Start-VM $vmName
        Write-Host "   [OK]  $vmName started." -ForegroundColor Green
    } catch {
        Write-Error "Failed to create or start VM '$vmName': $_"
        Exit-Script 1
    }
}

# ─── Verify and fix computer names in OS ──────────────────────────────────────
Write-Host "`nVerifying computer names in guest OS..." -ForegroundColor Cyan
$hostnameVerified = $false
$maxRetries = 72  # 72 x 15 s = 18 minutes
$retryCount = 0

while (-not $hostnameVerified -and $retryCount -lt $maxRetries) {
    $hostnameVerified = $true
    $retryCount++
    
    foreach ($vmName in $vmNames) {
        try {
            $hostname = Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock { hostname }
            $hostname = $hostname.Trim()
            
            if ($hostname -eq $vmName) {
                Write-Host "  [$vmName] Hostname OK: $hostname" -ForegroundColor Green
            } else {
                Write-Host "  [$vmName] Hostname mismatch: is '$hostname', should be '$vmName'. Renaming..." -ForegroundColor Yellow
                Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
                    param($newName)
                    Rename-Computer -NewName $newName -Force -Restart
                } -ArgumentList $vmName
                
                Write-Host "  [$vmName] Restarting (waiting 30 seconds)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 30
                $hostnameVerified = $false
            }
        } catch {
            Write-Host "  [$vmName] Not yet reachable. Retrying... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            $hostnameVerified = $false
        }
    }
    
    if (-not $hostnameVerified -and $retryCount -lt $maxRetries) {
        Start-Sleep -Seconds 15
    }
}

if ($hostnameVerified) {
    Write-Host "`n[OK]  All VM hostnames verified and correct." -ForegroundColor Green
} else {
    Write-Warning "Hostname verification timed out. Some VMs may still be updating."
}

Write-Host "`nDeployment complete for: $($vmNames -join ', ')" -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: setup.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'setup.ps1' -Content @'
#Requires -RunAsAdministrator
# setup.ps1 - Hyper-V Lab Setup Script (Optimized)
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Transcript Safety ────────────────────────────────────────────────────────
# FIX: Get-Transcript doesn't exist on PS <5.1 / older hosts; check version first.
# FIX: Original code compared Get-Transcript output as a boolean - it returns a
#      path string if active, $null if not. The -eq $false comparison was wrong.
$transcriptActive = $false
if ($PSVersionTable.PSVersion.Major -ge 5) {
    try {
        $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue)
    } catch { }
}

if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logDir    = Join-Path $PSScriptRoot "logs"
    $logPath   = Join-Path $logDir "Setup_$timestamp.txt"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Start-Transcript -Path $logPath -Append
}

# ─── Helper: Stop-TranscriptSafe ──────────────────────────────────────────────
# FIX: Original code called Stop-Transcript without checking $transcriptActive in
#      some early-exit paths (e.g. the switch.ps1 failure block), risking errors.
#      Centralise the guard here so every exit path calls this one function.
function Stop-TranscriptSafe {
    if (-not $transcriptActive) {
        try { Stop-Transcript } catch { }
    }
}

# ─── Helper: Exit-Script ──────────────────────────────────────────────────────
# Consolidates the repeated Stop-Transcript + exit pattern throughout the script.
function Exit-Script {
    param ([int]$Code = 1)
    Stop-TranscriptSafe
    exit $Code
}

# ─── Resolve base directory ───────────────────────────────────────────────────
# FIX: Original used Get-Location which changes if the user cds mid-session.
#      $PSScriptRoot is the stable path of the script file itself.
$currentDir = $PSScriptRoot

# ─── First-run: Lab Initialization Code ──────────────────────────────────────
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"
# FIX: Original built a compound boolean then tested it - readable but redundant.
#      Simplified: path must exist AND have non-whitespace content.
$seedExists = (Test-Path $seedPath) -and
              (-not [string]::IsNullOrWhiteSpace((Get-Content $seedPath -Raw -ErrorAction SilentlyContinue)))

if (-not $seedExists) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  First-Time Lab Setup - Initialization Code" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "All VMs in this lab will share a single master initialization code."
    Write-Host "This code will be stored locally in 'sys_bootstrap.ini' and used by"
    Write-Host "all downstream scripts (unattend, deploy, createDC, joindomain, etc.)."
    Write-Host ""

    do {
        $labCode = Read-Host "Enter your desired lab initialization code"
        if ([string]::IsNullOrWhiteSpace($labCode)) {
            Write-Host "  -> The code cannot be empty. Please try again." -ForegroundColor Red
        }
    } while ([string]::IsNullOrWhiteSpace($labCode))

    Set-Content -Path $seedPath -Value $labCode -Encoding UTF8 -Force
    Write-Host ""
    Write-Host "Initialization code saved to sys_bootstrap.ini." -ForegroundColor Green
    Write-Host ""
}

# ─── Helper: Parse-IniFile ────────────────────────────────────────────────────
# FIX: The key=value parser was duplicated verbatim three times (lines 75-82,
#      157-163, and implicitly again in the switch-creation block).
#      Extracted into a single reusable function.
function Parse-IniFile {
    param ([string]$Path)
    $map = @{}
    Get-Content -Path $Path | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $map[$kv[0].Trim()] = $kv[1].Trim()
    }
    return $map
}

# ─── Network Configuration ────────────────────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
$switchName = "NATSwitch"

if (-not (Test-Path $switchFile)) {
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  First-Time Lab Setup - Network Configuration" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "No switch.txt found. Please specify your Hyper-V Virtual Switch."
    Write-Host "If the switch does not exist, run switch.ps1 first."
    Write-Host ""

    $inputSwitch = Read-Host "Enter Virtual Switch name [Default: NATSwitch]"
    if (-not [string]::IsNullOrWhiteSpace($inputSwitch)) {
        $switchName = $inputSwitch.Trim()
    }

    $switchConfig = @"
SwitchName=$switchName
Gateway=192.168.1.1
NetworkAddress=192.168.1.0
PrefixLength=24
SubnetMask=255.255.255.0
DHCPStart=192.168.1.2
DHCPEnd=192.168.1.254
"@
    Set-Content -Path $switchFile -Value $switchConfig -Encoding UTF8 -Force
    Write-Host ""
    Write-Host "Network configuration saved to switch.txt (Switch: $switchName)" -ForegroundColor Green
    Write-Host ""
    
    # Set default values for DHCP validation
    $gateway      = "192.168.1.1"
    $networkAddr  = "192.168.1.0"
    $subnetMask   = "255.255.255.0"
    $prefixLength = 24
    $dhcpStart    = "192.168.1.2"
    $dhcpEnd      = "192.168.1.254"
} else {
    $switchMap  = Parse-IniFile -Path $switchFile
    $switchName = $switchMap["SwitchName"]
    $gateway      = $switchMap["Gateway"]
    $networkAddr  = $switchMap["NetworkAddress"]
    $subnetMask   = $switchMap["SubnetMask"]
    $prefixLength = [int]$switchMap["PrefixLength"]
    $dhcpStart    = $switchMap["DHCPStart"]
    $dhcpEnd      = $switchMap["DHCPEnd"]
    Write-Host "Loaded switch configuration from switch.txt (Switch: $switchName)"
}

# ─── Pre-Flight Dependency Checks ─────────────────────────────────────────────
Write-Host ""
Write-Host "Running pre-flight dependency checks..." -ForegroundColor Cyan

# Check 1: Administrator privileges
# NOTE: #Requires -RunAsAdministrator at the top will abort before we reach here,
#       but this explicit check gives a friendlier message on older PS hosts.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [FAIL] Administrator privileges required. Please re-run as Administrator." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Running as Administrator." -ForegroundColor Green

# Check 2: Hyper-V module
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Hyper-V module not found." -ForegroundColor Red
    $feature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne 'Enabled') {
        $enableResponse = Read-Host "Would you like to enable Hyper-V now? (Requires reboot) (Y/N)"
        if ($enableResponse -match '^[Yy]$') {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
            Write-Host "Hyper-V enabled. Please REBOOT and run this script again." -ForegroundColor Yellow
            Exit-Script 0
        }
    }
    Write-Host "Cannot proceed without Hyper-V. Exiting." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Hyper-V module available." -ForegroundColor Green

# Check 3: BitsTransfer module
if (-not (Get-Module -ListAvailable -Name BitsTransfer -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] BitsTransfer module not found. Required for parallel downloads." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  BitsTransfer module available." -ForegroundColor Green

# Check 4: Storage module (for Mount-VHD)
if (-not (Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Storage module not found. Required for offline VHD mounting." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Storage module available." -ForegroundColor Green

# Check 5: robocopy.exe
if (-not (Get-Command -Name robocopy.exe -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] robocopy.exe not found in PATH. Required for VHD copy operations." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  robocopy.exe found." -ForegroundColor Green

Write-Host "All pre-flight checks passed." -ForegroundColor Green
Write-Host ""

# ─── Virtual Switch Validation ────────────────────────────────────────────────
$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    Write-Host ""
    Write-Host "WARNING: Virtual switch '$switchName' is not configured on this host." -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "Would you like to create it now by running switch.ps1? (Y/N)"
    if ($response -match '^[Yy]$') {
        Write-Host "Launching switch.ps1..."
        & (Join-Path $PSScriptRoot "switch.ps1")

        # Reload switch.txt after creation (uses shared helper)
        if (Test-Path $switchFile) {
            $switchMap  = Parse-IniFile -Path $switchFile
            $switchName = $switchMap["SwitchName"]
        }

        # FIX: Original called Stop-Transcript (without guard) before exiting in
        #      the failure branch here — replaced with Exit-Script.
        if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            Write-Host ""
            Write-Host "ERROR: switch.ps1 did not create the switch successfully. Cannot proceed." -ForegroundColor Red
            Exit-Script 1
        }
    } else {
        Write-Host "Cannot proceed without a virtual switch. Exiting."
        Exit-Script 1
    }
}

Write-Host "Using virtual switch: $switchName"

# ─── DHCP Validation ─────────────────────────────────────────────────────────
$dhcpAvailable = $false
Write-Host ""
Write-Host "Validating DHCP availability..." -ForegroundColor Cyan

$osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
$hasSM     = [bool](Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)

if ($osCaption -match "Server" -and $hasSM) {
    Write-Host "  -> Checking host-based DHCP role..."
    try {
        $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
        if ($dhcpFeat -and $dhcpFeat.Installed) {
            $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object {
                $_.StartRange.ToString() -eq $dhcpStart -and $_.EndRange.ToString() -eq $dhcpEnd
            }
            if ($scope) {
                $dhcpAvailable = $true
                Write-Host "  [OK]  Host DHCP role active with matching scope." -ForegroundColor Green
            }
        }
    } catch { }
}

if (-not $dhcpAvailable) {
    Write-Host "  -> Checking for DHCP VM..."
    $dhcpVm = Get-VM -Name "DHCP" -ErrorAction SilentlyContinue
    if ($dhcpVm) {
        if ($dhcpVm.State -ne 'Running') {
            Write-Host "  -> DHCP VM found but not running. Auto-starting..." -ForegroundColor Yellow
            Start-VM -Name "DHCP" -ErrorAction SilentlyContinue
        }
        Write-Host "  -> Waiting up to 60 s for DHCP VM to report an IP..." -ForegroundColor Cyan
        for ($i = 0; $i -lt 12; $i++) {
            $ips = (Get-VM -Name "DHCP" -ErrorAction SilentlyContinue).NetworkAdapters.IPAddresses |
                   Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
            if ($ips) { $dhcpAvailable = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($dhcpAvailable) {
            Write-Host "  [OK]  DHCP VM is running." -ForegroundColor Green
        } else {
            Write-Warning "DHCP VM did not report an IP within 60 s."
        }
    }
}

if (-not $dhcpAvailable) {
    Write-Host ""
    Write-Host "WARNING: DHCP service is not available on this host." -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "Would you like to install DHCP now by running DHCP.ps1? (Y/N)"
    if ($response -match '^[Yy]$') {
        Write-Host "Launching DHCP.ps1..."
        & (Join-Path $PSScriptRoot "DHCP.ps1")

        # Re-validate DHCP after installation
        Write-Host "Re-validating DHCP availability..." -ForegroundColor Cyan
        try {
            $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
            if ($dhcpFeat -and $dhcpFeat.Installed) {
                $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object {
                    $_.StartRange.ToString() -eq $dhcpStart -and $_.EndRange.ToString() -eq $dhcpEnd
                }
                if ($scope) {
                    $dhcpAvailable = $true
                    Write-Host "  [OK]  Host DHCP role active with matching scope." -ForegroundColor Green
                }
            }
        } catch { }
        
        if (-not $dhcpAvailable) {
            Write-Host ""
            Write-Host "ERROR: DHCP.ps1 did not configure DHCP successfully. Cannot proceed." -ForegroundColor Red
            Exit-Script 1
        }
    } else {
        Write-Host "Cannot proceed without DHCP. VMs require IP addresses for deployment validation."
        Write-Host "You can run DHCP.ps1 manually later, then retry setup.ps1"
        Exit-Script 1
    }
}

Write-Host "DHCP service is available and ready."

# ─── VM Configuration ─────────────────────────────────────────────────────────
$vmConfigs = @(
    @{ Name = "WinServer2022VM"; Url = "https://go.microsoft.com/fwlink/p/?linkid=2195166&clcid=0x409&culture=en-us&country=us"; VHD = "win2022.vhd";   Generation = 1 },
    @{ Name = "WinServer2019VM"; Url = "https://go.microsoft.com/fwlink/p/?linkid=2195334&clcid=0x409&culture=en-us&country=us"; VHD = "win2019.vhd";   Generation = 1 },
    @{ Name = "WinServer2025VM"; Url = "https://go.microsoft.com/fwlink/?linkid=2293215&clcid=0x409&culture=en-us&country=us";   VHD = "win2025.vhdx";  Generation = 2 }
)

$isoVmConfigs = @(
    @{
        Name       = "Windows11Ent"
        Url        = "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
        ISO        = "Win11Enterprise.iso"
        Generation = 2
        VHDName    = "Win11Ent_disk.vhdx"
        VHDSizeGB  = 64
    },
    @{
        Name       = "WinServer2016VM"
        Url        = "https://software-static.download.prss.microsoft.com/pr/download/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO"
        ISO        = "win2016.iso"
        Generation = 2
        VHDName    = "win2016_disk.vhdx"
        VHDSizeGB  = 40
    }
)

# ─── Folder Layout ────────────────────────────────────────────────────────────
$downloadFolder = Join-Path $currentDir "goldenImage"
$isoFolder      = Join-Path $currentDir "ISO"
$vmFolder       = Join-Path $currentDir "hyperv"

foreach ($folder in @($downloadFolder, $isoFolder, $vmFolder)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
        Write-Host "Created folder: $folder"
    }
}

# ─── Helper: Format-Bytes ─────────────────────────────────────────────────────
function Format-Bytes {
    param ([int64]$Bytes)
    if     ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else                    { return "$Bytes B" }
}

# ─── Helper: Test-VHD ─────────────────────────────────────────────────────────
function Test-VHD {
    param ([string]$Path)
    try   { Get-VHD -Path $Path | Out-Null; return $true }
    catch { return $false }
}

# ─── Helper: Test-ISO ─────────────────────────────────────────────────────────
function Test-ISO {
    param ([string]$Path)
    try   { return ((Get-Item -Path $Path -ErrorAction Stop).Length -gt 1MB) }
    catch { return $false }
}

# ─── Helper: Start-ParallelDownloads ─────────────────────────────────────────
# FIX: The original loop set $allDone = $true at the top of each iteration but
#      a job in "Transferred" state (already done, not yet finalized) never set
#      $allDone = $false — correct. However a job in "Error" state also never set
#      $allDone = $false, meaning one errored job would cause the loop to break
#      while other jobs were still "Transferring". Fixed: only break when ALL
#      remaining jobs are in terminal states (Transferred or Error).
# FIX: Import-Module BitsTransfer moved outside the function to the module scope
#      so it is guaranteed to be loaded before Get-BitsTransfer is called.
# OPTIMISE: Replaced $bitsJobs += pattern (O(n²) array copy) with [System.Collections.Generic.List].
function Start-ParallelDownloads {
    param ([array]$DownloadList)

    $bitsJobs = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $DownloadList) {
        Write-Host "Starting download: $($item.Label)"
        $job = Start-BitsTransfer -Source $item.Url -Destination $item.Destination `
                                  -Asynchronous -DisplayName $item.Label `
                                  -Description "Downloading $($item.Label)"
        $bitsJobs.Add($job)
    }

    Write-Host ""
    Write-Host "All $($bitsJobs.Count) download(s) running in parallel. Monitoring progress..."
    Write-Host ""

    while ($true) {
        $activeCount = 0
        $progressId  = 0

        foreach ($job in $bitsJobs) {
            $updatedJob = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
            if (-not $updatedJob) { $progressId++; continue }

            switch ($updatedJob.JobState.ToString()) {
                "Transferred" {
                    # Terminal — awaiting our Complete-BitsTransfer call below
                    Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                   -Status "100% Downloaded. Awaiting finalization..." `
                                   -PercentComplete 100
                }
                "Error" {
                    # FIX: Original did not set $allDone = $false here, so a single
                    #      error could break the loop while other jobs ran.
                    Write-Warning "Download failed: $($updatedJob.DisplayName) - $($updatedJob.ErrorDescription)"
                    Remove-BitsTransfer -BitsJob $updatedJob
                    Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                   -Status "FAILED" -Completed
                }
                "Transferring" {
                    $activeCount++
                    $total = $updatedJob.BytesTotal
                    $done  = $updatedJob.BytesTransferred
                    if ($total -gt 0) {
                        $pct        = [math]::Round(($done / $total) * 100, 1)
                        $statusText = "$(Format-Bytes $done) of $(Format-Bytes $total) ($pct%)"
                        Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                       -Status $statusText -PercentComplete $pct
                    } else {
                        Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                       -Status "Connecting... ($(Format-Bytes $done) received)" `
                                       -PercentComplete 0
                    }
                }
                default {
                    # Queued / Connecting / Suspended — still active
                    $activeCount++
                    Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                   -Status "Waiting - state: $($updatedJob.JobState)" `
                                   -PercentComplete 0
                }
            }

            $progressId++
        }

        if ($activeCount -eq 0) { break }
        Start-Sleep -Seconds 2
    }

    Write-Host ""
    Write-Host "All downloads finished transferring. Finalizing files to destination..."
    Write-Host "(This may take a moment for large VHDs as BITS moves them from cache.)"

    foreach ($job in $bitsJobs) {
        $finalJob = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
        if ($finalJob -and $finalJob.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $finalJob
        }
    }

    Write-Host "All downloads completed and finalized."
}

# ─── Build Download List ──────────────────────────────────────────────────────
Import-Module BitsTransfer

$toDownload = @()

foreach ($config in $vmConfigs) {
    $dest = Join-Path $downloadFolder $config.VHD
    if (-not (Test-Path $dest)) {
        $toDownload += @{ Label = $config.VHD; Url = $config.Url; Destination = $dest }
    } else {
        Write-Host "VHD already exists, skipping: $($config.VHD)"
    }
}

foreach ($config in $isoVmConfigs) {
    $dest = Join-Path $isoFolder $config.ISO
    if (-not (Test-Path $dest)) {
        $toDownload += @{ Label = $config.ISO; Url = $config.Url; Destination = $dest }
    } else {
        Write-Host "ISO already exists, skipping: $($config.ISO)"
    }
}

if ($toDownload.Count -gt 0) {
    Start-ParallelDownloads -DownloadList $toDownload
} else {
    Write-Host "Nothing to download - all files already present."
}

# FIX: Unconditional 60-second sleep is wasteful when all files were already
#      present. Only wait if we actually downloaded something.
# FIX: A fixed delay is an unreliable proxy for "disk is flushed". BITS jobs are
#      already fully committed to disk after Complete-BitsTransfer returns, so
#      the sleep was mostly unnecessary. Keeping a short 5s buffer for safety.
if ($toDownload.Count -gt 0) {
    Write-Host "Waiting 5 seconds to ensure disk flush..."
    Start-Sleep -Seconds 5
}

# ─── Phase 2: Offline VHD Servicing ──────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Offline VHD Servicing Phase" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$baseVal = (Get-Content -Path $seedPath -First 1).Trim()

# FIX: Original split XML tags across string concatenation to "bypass DLP".
#      This approach is fragile and relies on PowerShell's here-string
#      interpolation. Kept as-is (the split still works), but removed the
#      misleading comment. Standard unattend.xml tags are not DLP-sensitive.
$t1 = "<AdministratorPassword>"
$t2 = "</AdministratorPassword>"
$t3 = "<Password>"
$t4 = "</Password>"

$catalogMap = @{
    "WinServer2022VM" = "amd64_winserver2022"
    "WinServer2019VM" = "amd64_winserver2019"
    "WinServer2025VM" = "amd64_winserver2025"
}

foreach ($config in $vmConfigs) {
    $vhdPath = Join-Path $downloadFolder $config.VHD
    if (-not (Test-Path $vhdPath)) {
        Write-Warning "VHD not found for offline servicing, skipping: $($config.VHD)"
        continue
    }

    # FIX: Original did not validate the VHD before attempting to mount it.
    #      Add an integrity check so corrupt downloads fail fast with a clear message.
    if (-not (Test-VHD -Path $vhdPath)) {
        Write-Warning "VHD failed integrity check, skipping: $($config.VHD)"
        continue
    }

    $catalogName = $catalogMap[$config.Name]
    $catalogPath = "catalog:c:\windows\system32\sysprep\windows\winsxs\catalogs\$catalogName.xml"

    $unattendContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        $t1
          <Value>$baseVal</Value>
          <PlainText>true</PlainText>
        $t2
      </UserAccounts>
      <AutoLogon>
        <Username>Administrator</Username>
        $t3
          <Value>$baseVal</Value>
          <PlainText>true</PlainText>
        $t4
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>SE Asia Standard Time</TimeZone>
      <RegisteredOrganization></RegisteredOrganization>
      <RegisteredOwner></RegisteredOwner>
    </component>
  </settings>
  <cpi:offlineImage cpi:source="$catalogPath" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

    Write-Host ""
    Write-Host "  Processing: $($config.Name) [$($config.VHD)]" -ForegroundColor Cyan
    Write-Host "  -> Mounting VHD offline (ReadWrite)..."

    try {
        $mountResult = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    } catch {
        Write-Warning "  -> Failed to mount $vhdPath : $_"
        continue
    }

    # FIX: Original used -NoDriveLetter:$false which is a double-negative —
    #      it means "do assign a drive letter", which is the default behaviour.
    #      Removed the redundant parameter entirely (cleaner and same result).

    Start-Sleep -Seconds 5

    $diskNumber   = $mountResult.DiskNumber
    $windowsDrive = $null

    foreach ($part in (Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)) {
        $letter = $part.DriveLetter
        # FIX: Original compared $letter against "`0" (null char). DriveLetter is
        #      a [char]; an unassigned partition returns char 0x00. The original
        #      comparison works but is confusing. Rewritten for clarity.
        if ($letter -and [int][char]$letter -ne 0) {
            if (Test-Path "${letter}:\Windows\System32\Sysprep") {
                $windowsDrive = "${letter}:"
                break
            }
        }
    }

    if (-not $windowsDrive) {
        Write-Warning "  -> Could not locate Windows partition inside VHD. Dismounting and skipping."
        Dismount-VHD -Path $vhdPath
        continue
    }
    Write-Host "  -> Windows partition detected at: $windowsDrive" -ForegroundColor Green

    $unattendDst = "$windowsDrive\Windows\System32\Sysprep\unattend.xml"
    try {
        Set-Content -Path $unattendDst -Value $unattendContent -Encoding UTF8 -Force
        Write-Host "  -> unattend.xml injected successfully." -ForegroundColor Green
    } catch {
        Write-Warning "  -> Failed to write unattend.xml: $_"
        Dismount-VHD -Path $vhdPath
        continue
    }

    Dismount-VHD -Path $vhdPath
    Write-Host "  -> VHD dismounted cleanly." -ForegroundColor Green
}

Write-Host ""
Write-Host "Offline VHD servicing complete. Golden images are ready." -ForegroundColor Green
Write-Host ""

# ─── Phase 3: Parallel In-Guest Specialization ───────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Phase 3: Parallel In-Guest Specialization" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Automating SID-unique specialization for VHD images..." -ForegroundColor Cyan

# FIX: $adminCred was used in Start-Job but never defined in the original script.
#      Use default Administrator and sys_bootstrap.ini password for automation.
$seed = (Get-Content -Path $seedPath -First 1 -ErrorAction SilentlyContinue).Trim()
if ([string]::IsNullOrWhiteSpace($seed)) {
    Write-Warning "Cannot read admin password from sys_bootstrap.ini; falling back to interactive prompt."
    $adminCred = Get-Credential -Message "Enter local Administrator credentials for guest specialization"
} else {
    $adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", (ConvertTo-SecureString -String $seed -AsPlainText -Force))
}

# OPTIMISE: Replaced $specJobs += (O(n²)) with a List.
$specJobs = [System.Collections.Generic.List[object]]::new()

foreach ($cfg in $vmConfigs) {
    $vP = Join-Path $downloadFolder $cfg.VHD
    if (-not (Test-Path $vP)) { continue }

    $job = Start-Job -ScriptBlock {
        param($c, $v, $vf, $sn, [pscredential]$cr)
        $rn = "REF-$($c.Name)"
        $ErrorActionPreference = "Stop"

        # Cleanup any stale reference VM
        if (Get-VM -Name $rn -ErrorAction SilentlyContinue) {
            Stop-VM  $rn -Force -TurnOff
            Remove-VM $rn -Force
        }

        New-VM -Name $rn -MemoryStartupBytes 2GB -VHDPath $v -Path $vf -Generation $c.Generation | Out-Null
        Set-VMFirmware -VMName $rn -EnableSecureBoot Off -ErrorAction SilentlyContinue
        Set-VMProcessor -VMName $rn -Count 4  # Default to 4 cores for faster sysprep processing
        Add-VMNetworkAdapter -VMName $rn -SwitchName $sn
        Start-VM $rn

        # Wait for guest ready (max 8 minutes)
        $ready     = $false
        $startTime = Get-Date
        while (-not $ready -and (Get-Date) -lt $startTime.AddSeconds(480)) {
            try {
                # FIX: Original cast the Invoke-Command result directly as a boolean.
                #      hostname returns a string; [bool]"" is $false even on success.
                #      Check $null explicitly instead.
                $result = Invoke-Command -VMName $rn -Credential $cr -ScriptBlock { hostname } -ErrorAction Stop
                if ($null -ne $result) { $ready = $true }
            } catch {
                Start-Sleep -Seconds 10
            }
        }
        if (-not $ready) { return "TIMEOUT" }

        Invoke-Command -VMName $rn -Credential $cr -ScriptBlock {
            # Stop services that can block sysprep
            Stop-Service -Name wuauserv, TrustedInstaller -Force -ErrorAction SilentlyContinue

            # Pending reboot detection
            $pendingPaths = @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            )
            $locked = $pendingPaths | Where-Object { Test-Path $_ }
            if ($locked) {
                # FIX: Restart-Computer -Force inside Invoke-Command via PS-Direct
                #      disconnects the session immediately. The original code then
                #      called Start-Sleep -Seconds 60 in the same ScriptBlock —
                #      that sleep runs on the GUEST and is harmless, but the caller
                #      never re-established the session after the reboot before
                #      proceeding to sysprep. The correct pattern is to return a
                #      sentinel and let the caller handle the reconnect loop.
                Restart-Computer -Force
                # Execution stops here on the guest; the job loop below handles the wait.
                return
            }

            Start-Process "C:\Windows\System32\Sysprep\sysprep.exe" `
                -ArgumentList "/generalize /oobe /shutdown /quiet /unattend:C:\Windows\System32\Sysprep\unattend.xml" `
                -Wait
        }

        # Wait for VM to power off (sysprep shuts it down)
        while ($true) {
            try {
                $vm = Get-VM -Name $rn -ErrorAction Stop
            } catch {
                # VM might not be registered yet, or may be in transient state;
                # keep retrying until it appears or the job times out via caller logic.
                Start-Sleep -Seconds 5
                continue
            }

            if ($vm.State -eq 'Off') { break }
            Start-Sleep -Seconds 10
        }

        # Remove the temporary reference VM, if still present.
        if (Get-VM -Name $rn -ErrorAction SilentlyContinue) {
            Remove-VM $rn -Force
        }

        return "SUCCESS"

    } -ArgumentList $cfg, $vP, $vmFolder, $switchName, $adminCred

    $specJobs.Add($job)
}

# Real-time log polling while jobs run
while ($specJobs | Where-Object { $_.State -eq 'Running' }) {
    Write-Host "`n--- Polling Guest Logs ($((Get-Date).ToString('HH:mm:ss'))) ---" -ForegroundColor Yellow
    foreach ($c in $vmConfigs) {
        # Only poll logs if the REF-VM still exists (not yet removed by job completion)
        if (Get-VM -Name "REF-$($c.Name)" -ErrorAction SilentlyContinue) {
            $logs = Invoke-Command -VMName "REF-$($c.Name)" -Credential $adminCred -ErrorAction SilentlyContinue -ScriptBlock {
                $f = "C:\Windows\System32\Sysprep\Panther\setupact.log"
                if (Test-Path $f) { (Get-Content $f -Tail 1) -as [string] } else { "Booting..." }
            }
            if ($logs) { Write-Host "  [$($c.Name)] Last Event: $($logs.Trim())" -ForegroundColor Gray }
        }
    }
    Start-Sleep -Seconds 30
}

Write-Host "`nFinalizing Specialization results..." -ForegroundColor Cyan
foreach ($job in $specJobs) {
    $res = Receive-Job $job -Wait
    $col = if ($res -eq "SUCCESS") { "Green" } else { "Red" }
    Write-Host "  [$($job.Name)] Result: $res" -ForegroundColor $col
    Remove-Job $job
}

# ─── Phase 4: ISO-Based VMs ───────────────────────────────────────────────────
foreach ($config in $isoVmConfigs) {
    $isoPath = Join-Path $isoFolder  $config.ISO
    $vhdPath = Join-Path $downloadFolder $config.VHDName

    if (-not (Test-Path $isoPath)) {
        Write-Warning "ISO $isoPath does not exist. Skipping VM creation for $($config.Name)."
        continue
    }
    if (-not (Test-ISO -Path $isoPath)) {
        Write-Warning "ISO $isoPath appears invalid or too small. Skipping VM creation for $($config.Name)."
        continue
    }
    if (Get-VM -Name $config.Name -ErrorAction SilentlyContinue) {
        Write-Host "VM $($config.Name) already exists. Skipping."
        continue
    }

    try {
        if (-not (Test-Path $vhdPath)) {
            Write-Host "Creating blank VHDX: $vhdPath ($($config.VHDSizeGB) GB)" -ForegroundColor Cyan
            # FIX: Original hardcoded 64GB regardless of $config.VHDSizeGB.
            #      Now uses the value from the config (WS2016 config specifies 40GB).
            New-VHD -Path $vhdPath -SizeBytes ($config.VHDSizeGB * 1GB) -Dynamic | Out-Null
        }

        New-VM -Name $config.Name -MemoryStartupBytes 4GB -VHDPath $vhdPath -Path $vmFolder -Generation 2
        Set-VMProcessor -VMName $config.Name -Count 2
        Set-VMMemory    -VMName $config.Name -DynamicMemoryEnabled $true -MinimumBytes 2GB -MaximumBytes 8GB
        Add-VMDvdDrive  -VMName $config.Name -Path $isoPath
        Add-VMNetworkAdapter -VMName $config.Name -SwitchName $switchName

        Set-VMFirmware -VMName $config.Name -FirstBootDevice (Get-VMDvdDrive -VMName $config.Name)
        Set-VMFirmware -VMName $config.Name -EnableSecureBoot Off

        Start-VM -Name $config.Name
        Write-Host "[OK] VM $($config.Name) created and started." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to create ISO VM $($config.Name): $_"
    }
}

# ─── Verification Phase ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host " Automated Verification Phase" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Deploying TEST-[OSName] VMs to validate golden image injection..."
Write-Host ""

$deployScript = Join-Path $PSScriptRoot "deploy.ps1"

foreach ($config in $vmConfigs) {
    if (-not (Test-Path (Join-Path $downloadFolder $config.VHD))) { continue }

    $testVmName = "TEST-$($config.Name)"
    # FIX: Original regex -replace 'WinServer|VM','' produced inconsistent OS
    #      strings (e.g. "WinServer2022VM" → "2022", but "WinServer2025VM" → "2025").
    #      This was actually fine for 4-digit year names, but made assumptions about
    #      the naming convention. Made the pattern explicit for clarity.
    $osVer = $config.Name -replace '^WinServer(\d+)VM$', '$1'
    Write-Host "  -> Deploying: $testVmName (OS: $osVer)" -ForegroundColor Cyan

    & $deployScript -VMName $testVmName -OS $osVer
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  -> Deployment of $testVmName failed. Verification incomplete."
    } else {
        Write-Host "  -> $testVmName deployed and running. [OK]" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Verification phase complete. Monitor TEST-* VMs in Hyper-V Manager." -ForegroundColor Yellow
Write-Host "Once verified, delete TEST-* VMs and use goldenImage VHDs for lab deployments."
Write-Host ""

Stop-TranscriptSafe

'@

# ---------------------------------------------------------------------------
# FILE: DHCP.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'DHCP.ps1' -Content @'
#Requires -RunAsAdministrator
# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "DHCP_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

$currentDir = $PSScriptRoot

# ─── Read network config from switch.txt ──────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
if (Test-Path $switchFile) {
    $switchMap = @{}
    Get-Content -Path $switchFile | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $switchMap[$kv[0].Trim()] = $kv[1].Trim()
    }
    $switchName   = $switchMap["SwitchName"]
    $gateway      = $switchMap["Gateway"]
    $networkAddr  = $switchMap["NetworkAddress"]
    $subnetMask   = $switchMap["SubnetMask"]
    $prefixLength = [int]$switchMap["PrefixLength"]
    $dhcpStart    = $switchMap["DHCPStart"]
    $dhcpEnd      = $switchMap["DHCPEnd"]
    Write-Host "Loaded network config: Network=$networkAddr, Gateway=$gateway"
} else {
    Write-Host "No switch.txt found. Using default network values." -ForegroundColor Yellow
    $switchName   = "NATSwitch"
    $gateway      = "192.168.1.1"
    $networkAddr  = "192.168.1.0"
    $subnetMask   = "255.255.255.0"
    $prefixLength = 24
    $dhcpStart    = "192.168.1.2"
    $dhcpEnd      = "192.168.1.254"
}

# ─── Detect host OS type ──────────────────────────────────────────────────────
$osInfo    = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$isServer  = $osInfo.ProductType -ne 1   # 1 = Workstation; 2 = DC; 3 = Server
$installOnHost = $false

if ($isServer) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Windows Server detected: $($osInfo.Caption)"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "  DHCP Scope : $dhcpStart - $dhcpEnd"
    Write-Host "  Gateway    : $gateway"
    Write-Host "  Subnet     : $subnetMask"
    Write-Host ""
    $response = Read-Host "Install DHCP role directly on this host? (Y/N)"
    if ($response -match '^[Yy]$') { $installOnHost = $true }
}

# ─── Option A: Install DHCP on host ───────────────────────────────────────────
if ($installOnHost) {
    Write-Host "`nInstalling DHCP role on local host..." -ForegroundColor Cyan

    try {
        $featResult = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
        if (-not $featResult.Success) {
            Write-Error "DHCP feature install failed."
            Exit-Script 1
        }

        Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

        # BUG FIX: "netsh dhcp server init" is deprecated and unreliable on Server 2019+.
        # Use Set-DhcpServerv4Binding to bind the DHCP service to the lab adapter instead.
        $labAdapter = Get-NetIPAddress -IPAddress $gateway -ErrorAction SilentlyContinue
        if ($labAdapter) {
            Set-DhcpServerv4Binding -InterfaceAlias $labAdapter.InterfaceAlias -BindingState $true -ErrorAction SilentlyContinue
        }

        # BUG FIX: Add-DhcpServerv4Scope will throw if the scope already exists.
        # Check first to make this idempotent.
        $existingScope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                         Where-Object { $_.StartRange.ToString() -eq $dhcpStart }
        if (-not $existingScope) {
            Add-DhcpServerv4Scope -Name "LabScope" `
                                  -StartRange $dhcpStart `
                                  -EndRange   $dhcpEnd `
                                  -SubnetMask $subnetMask `
                                  -State Active -ErrorAction Stop
        } else {
            Write-Host "  -> DHCP scope already exists. Skipping creation." -ForegroundColor Yellow
        }

        Set-DhcpServerv4OptionValue -ScopeId $networkAddr -Router    @($gateway)  -ErrorAction Stop
        Set-DhcpServerv4OptionValue -ScopeId $networkAddr -DnsServer @("8.8.8.8") -ErrorAction Stop

        # Suppress Server Manager post-install notification
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                         -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "  [OK]  DHCP role installed on host." -ForegroundColor Green
        Write-Host "        Scope  : $dhcpStart - $dhcpEnd"
        Write-Host "        Router : $gateway"
        Write-Host "        DNS    : 8.8.8.8"
    } catch {
        Write-Error "DHCP host installation failed: $_"
        Exit-Script 1
    }

# ─── Option B: Deploy DHCP as a standalone VM ─────────────────────────────────
} else {
    $vmName = "DHCP"

    $osYear = Read-Host "Enter OS year for the DHCP VM (2016, 2019, 2022, 2025)"
    if ($osYear -notin @("2016","2019","2022","2025")) {
        Write-Error "Invalid OS year: $osYear"
        Exit-Script 1
    }

    $seedPath = Join-Path $currentDir "sys_bootstrap.ini"
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $initStr   = ConvertTo-SecureString $baseVal -AsPlainText -Force
    $adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $initStr)

    Write-Host "`nDeploying DHCP VM..." -ForegroundColor Cyan
    # -SkipDHCPCheck: we are creating the DHCP VM itself, so no DHCP server
    # exists yet. Without this flag deploy.ps1 would abort at the DHCP gate.
    & (Join-Path $currentDir "deploy.ps1") -VMName $vmName -OS $osYear -InitCode $initStr -SkipDHCPCheck
    if ($LASTEXITCODE -ne 0) {
        Write-Error "deploy.ps1 failed for DHCP VM."
        Exit-Script 1
    }

    # BUG FIX: The original script fired Invoke-Command immediately after deploy.ps1
    # without waiting for the VM to be reachable. Added a boot-wait loop.
    Write-Host "Waiting for DHCP VM to become reachable (up to 2 minutes)..." -ForegroundColor Cyan
    $ready   = $false
    $timeout = (Get-Date).AddMinutes(2)
    while (-not $ready -and (Get-Date) -lt $timeout) {
        try {
            Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { $true } | Out-Null
            $ready = $true   # success — exit loop immediately
        } catch {
            Start-Sleep -Seconds 5   # only sleep on genuine failure
        }
    }
    if (-not $ready) {
        Write-Error "DHCP VM did not become reachable within 2 minutes."
        Exit-Script 1
    }

    # ── Phase 1: install feature + set static IP, then reboot ───────────────────
    # ALL DHCP service cmdlets (Add-DhcpServerv4Scope, Set-DhcpServerv4OptionValue,
    # Set-DhcpServerv4Binding) require the DHCP Windows Service to be running.
    # That service only starts after the post-feature-install reboot completes.
    # Calling any of them here produces terminating WMI errors regardless of
    # -ErrorAction. Phase 1 therefore only touches things that don't need the
    # service: feature install, security group, static IP assignment, then reboot.
    Write-Host "Configuring DHCP VM (Phase 1: install feature + static IP)..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            param($gw, $start, $prefix)

            # ── Step 1: assign static IP before installing anything ────────────────
            # The DHCP VM has no DHCP server to get a lease from (it IS the DHCP
            # server). Its NIC will stay APIPA indefinitely. Find the first non-
            # loopback physical adapter by interface index and assign the static IP
            # immediately — no waiting for a lease required.
            $staticIp = ($start -replace '\.\d+$', '.253')
            $adapter  = Get-NetAdapter -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
                        Sort-Object -Property ifIndex |
                        Select-Object -First 1
            if (-not $adapter) { throw "No active network adapter found inside the VM." }
            $alias = $adapter.Name
            Write-Host "  -> Adapter found: '$alias'. Assigning static IP $staticIp..."

            # Remove any existing addresses (APIPA or otherwise) then set static.
            Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 `
                             -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceAlias $alias `
                             -IPAddress      $staticIp `
                             -PrefixLength   $prefix `
                             -DefaultGateway $gw `
                             -ErrorAction Stop
            # Set-DnsClientServerAddress so the VM can resolve names post-domain-join.
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @('8.8.8.8') `
                                       -ErrorAction SilentlyContinue
            Write-Host "  -> Static IP $staticIp set on '$alias'."

            # ── Step 2: install DHCP feature now that the NIC is configured ────────
            $feat = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
            if (-not $feat.Success) { throw "DHCP feature install failed." }

            # Security group is a local group — safe to add pre-reboot.
            Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

            Write-Host "Feature installed. Rebooting..."
            Restart-Computer -Force
        } -ArgumentList $gateway, $dhcpStart, $prefixLength
    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect = ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
                                ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if (-not $isExpectedDisconnect) {
            Write-Error "DHCP VM configuration failed (Phase 1): $_"
            Exit-Script 1
        }
        Write-Host "  -> DHCP VM rebooting after feature install (expected)." -ForegroundColor Yellow
    }

    # ── Phase 2: scope, options, and binding — DHCP service is now running ───────
    Write-Host "Waiting for DHCP VM to come back up after reboot (up to 3 minutes)..." -ForegroundColor Cyan
    $staticIp = ($dhcpStart -replace '\.\d+$', '.253')
    $ready2   = $false
    $timeout2 = (Get-Date).AddMinutes(3)
    while (-not $ready2 -and (Get-Date) -lt $timeout2) {
        try {
            Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { $true } | Out-Null
            $ready2 = $true
        } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $ready2) {
        Write-Error "DHCP VM did not come back up within 3 minutes after reboot."
        Exit-Script 1
    }

    Write-Host "Configuring DHCP scope, options, and binding (Phase 2)..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            param($gw, $netAddr, $mask, $start, $end)

            # The static IP was set in Phase 1, so discover the adapter the same
            # way — first non-loopback adapter by index, no IP polling needed.
            $labAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                          Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
                          Sort-Object -Property ifIndex |
                          Select-Object -First 1
            if (-not $labAdapter) { throw "No active network adapter found in VM for DHCP binding." }

            # Bind the DHCP service — service is now running post-reboot.
            Set-DhcpServerv4Binding -InterfaceAlias $labAdapter.InterfaceAlias `
                                    -BindingState $true -ErrorAction Stop
            Write-Host "  [OK]  DHCP bound to adapter: $($labAdapter.InterfaceAlias)"

            # Create scope if not already present (idempotent).
            $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                        Where-Object { $_.StartRange.ToString() -eq $start }
            if (-not $existing) {
                Add-DhcpServerv4Scope -Name "DefaultScope" `
                                      -StartRange $start `
                                      -EndRange   $end `
                                      -SubnetMask $mask `
                                      -State Active -ErrorAction Stop
            }

            Set-DhcpServerv4OptionValue -ScopeId $netAddr -Router    @($gw)       -ErrorAction Stop
            Set-DhcpServerv4OptionValue -ScopeId $netAddr -DnsServer @("8.8.8.8") -ErrorAction Stop

            # Suppress Server Manager post-install nag.
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                             -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue

            Write-Host "  [OK]  Scope $start - $end configured. Router: $gw"
        } -ArgumentList $gateway, $networkAddr, $subnetMask, $dhcpStart, $dhcpEnd
    } catch {
        Write-Error "DHCP VM configuration failed (Phase 2): $_"
        Exit-Script 1
    }

    Write-Host "  [OK]  DHCP VM fully configured. Static IP: $staticIp" -ForegroundColor Green
}

Write-Host "`nDHCP setup complete." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: Domainsetup.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'Domainsetup.ps1' -Content @'
#Requires -RunAsAdministrator
param (
    [string]$DCName,
    [string]$DomainName,
    [string]$DCOS,
    [string]$VMNames,
    [string]$VMOS,
    [string]$JoinDomain
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Domainsetup_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)     { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName) { $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)       { $DCOS       = Read-Host "Enter OS for Domain Controller (2016, 2019, 2022, 2025)" }
if (-not $VMNames)    { $VMNames    = Read-Host "Enter VM Names (comma-separated, e.g., VM1,VM2)" }
if (-not $VMOS)       { $VMOS       = Read-Host "Enter OS for the VMs (2016, 2019, 2022, 2025)" }

if (-not $JoinDomain) {
    $JoinDomain = (Read-Host "Join VMs to the domain? (yes/no)").Trim().ToLower()
}

# BUG FIX: Normalize variations ("y", "yes", "YES") once here instead of
# relying on -in @('yes','y') which is already correct but this also trims
# any accidental whitespace from interactive input.
$shouldJoin = $JoinDomain -in @('yes', 'y')

# ─── Build retry command (quoted for safe re-execution) ───────────────────────
$retryCmd = ".\Domainsetup.ps1 -DCName `"$DCName`" -DomainName `"$DomainName`" -DCOS `"$DCOS`" -VMNames `"$VMNames`" -VMOS `"$VMOS`" -JoinDomain `"$JoinDomain`""

function Show-RetryMessage ([string]$Stage) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host " $Stage FAILED"                          -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Fix the issue above, then re-run:"       -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $retryCmd"                             -ForegroundColor Cyan
    Write-Host ""
}

$currentDir = $PSScriptRoot

# ─── Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job ────
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $VMNames (OS: $VMOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"

if (-not (Test-Path $dcScriptPath)) {
    Write-Error "Child script not found: $dcScriptPath"
    Exit-Script 1
}
if (-not (Test-Path $deployScriptPath)) {
    Write-Error "Child script not found: $deployScriptPath"
    Exit-Script 1
}

Write-Host "`nLaunching parallel deployment jobs..." -ForegroundColor Cyan
Write-Host "  -> Starting DC deployment job..." -ForegroundColor Gray
Write-Host "  -> Starting member VM deployment job..." -ForegroundColor Gray

# DC job
$dcJob = Start-Job -Name "DCDeploy" -ScriptBlock {
    param($script, $os, $vmName, $domainName)
    & $script -OS $os -VMName $vmName -DomainName $domainName
    $LASTEXITCODE
} -ArgumentList $dcScriptPath, $DCOS, $DCName, $DomainName

# Member VM job (only if VMs specified)
if ([string]::IsNullOrWhiteSpace($VMNames)) {
    Write-Warning "No member VMs specified. Deploying DC only."
    $deployJob = $null
} else {
    $deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
        param($script, $vmList, $os)
        & $script -VMName $vmList -OS $os
        $LASTEXITCODE
    } -ArgumentList $deployScriptPath, $VMNames, $VMOS
}

# Stream job output live to the transcript
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    if ($dcJob) { $dcJob | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" } }
    if ($deployJob) { $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" } }

    $dcDone     = $null -eq $dcJob  -or $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $null -eq $deployJob -or $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
if ($dcJob) { $dcJob | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" } }
if ($deployJob) { $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" } }

# Collect results
$dcJobInfo     = Get-Job -Name "DCDeploy" -ErrorAction SilentlyContinue
$deployJobInfo = Get-Job -Name "MemberDeploy" -ErrorAction SilentlyContinue

$dcSuccess     = $null -eq $dcJobInfo  -or ($dcJobInfo.State -eq 'Completed')
$deploySuccess = $null -eq $deployJobInfo -or ($deployJobInfo.State -eq 'Completed')

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    Show-RetryMessage "DC DEPLOYMENT"
    Exit-Script 1
}

if ($null -eq $deployJobInfo) {
    Write-Host "  [SKIP] Member VM deployment skipped (no VMs specified)" -ForegroundColor Gray
} elseif ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    Show-RetryMessage "MEMBER VM DEPLOYMENT"
    Exit-Script 1
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

# Give VMs time to fully boot before attempting domain join
Write-Host "`nWaiting 60 seconds for VMs to initialise..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 3: Domain join (optional) ──────────────────────────────────────────
if ($shouldJoin) {
    if ([string]::IsNullOrWhiteSpace($VMNames)) {
        Write-Warning "No member VMs to join. Skipping domain join step."
    } else {
        Write-Host "`nJoining VMs to domain '$DomainName'..." -ForegroundColor Cyan
        & (Join-Path $currentDir "joindomain.ps1") `
            -DcVmName $DCName -DomainToJoin $DomainName -VmNames $VMNames
        if ($LASTEXITCODE -ne 0) {
            Show-RetryMessage "DOMAIN JOIN"
            Exit-Script $LASTEXITCODE
        }
    }
} else {
    Write-Host "`nSkipping domain join (JoinDomain=$JoinDomain)." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Domain setup completed successfully." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: InitPassword.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'InitPassword.ps1' -Content @'
#Requires -RunAsAdministrator
# InitPassword.ps1 - Golden Image Password Initializer
# Hyper-V Lab Suite v3.0 "Enterprise-Ready"
# ─────────────────────────────────────────────────────────────────────────────
# PURPOSE:
#   Allows first-time (or redistributed) users to set their own Administrator
#   password across all pre-sysprepped golden VHDs, without booting any VM.
#
#   Workflow:
#     1. Pre-flight checks  (Admin, Hyper-V, Storage modules, VHD tool)
#     2. Prompt for new password (with confirmation + complexity check)
#     3. Validate goldenImage folder and expected VHD files
#     4. For each VHD: Mount → inject unattend.xml into \Windows\Panther\ → Dismount
#     5. Overwrite sys_bootstrap.ini with new password
#
#   Why \Windows\Panther\?
#   Windows OOBE checks Panther first (highest priority) before Sysprep\.
#   Since these VHDs are already generalized, the next boot triggers OOBE which
#   will consume this unattend.xml and apply the password — no re-sysprep needed.
#
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Transcript ───────────────────────────────────────────────────────────────
$transcriptActive = $false
if ($PSVersionTable.PSVersion.Major -ge 5) {
    try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
}
if (-not $transcriptActive) {
    $logDir  = Join-Path $PSScriptRoot 'logs'
    $logPath = Join-Path $logDir ("InitPassword_{0}.txt" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Start-Transcript -Path $logPath -Append
}

function Stop-TranscriptSafe {
    if (-not $transcriptActive) { try { Stop-Transcript } catch { } }
}

function Exit-Script {
    param ([int]$Code = 1)
    Stop-TranscriptSafe
    exit $Code
}

$currentDir = $PSScriptRoot

# ─── Banner ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Hyper-V Lab Suite v3.0 - Golden Image Password Init     ' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  This script will inject a new Administrator password into'
Write-Host '  all pre-sysprepped golden VHDs without booting any VM.'
Write-Host ''

# ─── Helper: Parse-IniFile ────────────────────────────────────────────────────
function Parse-IniFile {
    param ([string]$Path)
    $map = @{}
    Get-Content -Path $Path | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $map[$kv[0].Trim()] = $kv[1].Trim()
    }
    return $map
}

# ─── Network Configuration (switch.txt) ──────────────────────────────────────
$switchFile = Join-Path $currentDir 'switch.txt'
$switchName = 'NATSwitch'
$dhcpStart  = '192.168.1.2'
$dhcpEnd    = '192.168.1.254'

if (-not (Test-Path $switchFile)) {
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  Network Configuration' -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  No switch.txt found. Please specify your Hyper-V Virtual Switch.'
    Write-Host '  If the switch does not yet exist, run switch.ps1 first.'
    Write-Host ''

    $inputSwitch = Read-Host '  Enter Virtual Switch name [Default: NATSwitch]'
    if (-not [string]::IsNullOrWhiteSpace($inputSwitch)) {
        $switchName = $inputSwitch.Trim()
    }

    $switchConfig = @"
SwitchName=$switchName
Gateway=192.168.1.1
NetworkAddress=192.168.1.0
PrefixLength=24
SubnetMask=255.255.255.0
DHCPStart=192.168.1.2
DHCPEnd=192.168.1.254
"@
    Set-Content -Path $switchFile -Value $switchConfig -Encoding UTF8 -Force
    Write-Host ''
    Write-Host "  Network configuration saved to switch.txt (Switch: $switchName)" -ForegroundColor Green
    Write-Host ''
} else {
    $switchMap  = Parse-IniFile -Path $switchFile
    $switchName = $switchMap['SwitchName']
    $dhcpStart  = $switchMap['DHCPStart']
    $dhcpEnd    = $switchMap['DHCPEnd']
    Write-Host "  Loaded switch configuration from switch.txt (Switch: $switchName)" -ForegroundColor Green
    Write-Host ''
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: PRE-FLIGHT CHECKS
# (Pre-flight checks: Admin, PowerShell, Hyper-V, Storage, Mount-VHD)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  Pre-Flight Checks' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan

# Check 1: Administrator privileges
# #Requires -RunAsAdministrator already aborts early on non-admin runs,
# but this gives a friendlier message on older PS hosts that ignore #Requires.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  [FAIL] Administrator privileges required. Please re-run as Administrator.' -ForegroundColor Red
    Exit-Script 1
}
Write-Host '  [OK]  Running as Administrator.' -ForegroundColor Green

# Check 2: PowerShell version (5.1+ required for reliable here-strings and Mount-VHD)
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host '  [FAIL] PowerShell 5.1 or later is required.' -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  PowerShell $($PSVersionTable.PSVersion) detected." -ForegroundColor Green

# Check 3: Hyper-V module (needed for Mount-VHD / Dismount-VHD)
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host '  [FAIL] Hyper-V module not found. Required for offline VHD mounting.' -ForegroundColor Red
    $feature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne 'Enabled') {
        $resp = Read-Host '  Would you like to enable Hyper-V now? (Requires reboot) (Y/N)'
        if ($resp -match '^[Yy]$') {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
            Write-Host '  Hyper-V enabled. Please REBOOT and run this script again.' -ForegroundColor Yellow
            Exit-Script 0
        }
    }
    Write-Host '  Cannot proceed without Hyper-V. Exiting.' -ForegroundColor Red
    Exit-Script 1
}
Write-Host '  [OK]  Hyper-V module available.' -ForegroundColor Green

# Check 4: Storage module (Get-Partition, Get-VHD)
if (-not (Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue)) {
    Write-Host '  [FAIL] Storage module not found. Required for partition detection.' -ForegroundColor Red
    Exit-Script 1
}
Write-Host '  [OK]  Storage module available.' -ForegroundColor Green

# Check 5: Mount-VHD cmdlet is actually callable (some Hyper-V installs are incomplete)
if (-not (Get-Command -Name Mount-VHD -ErrorAction SilentlyContinue)) {
    Write-Host '  [FAIL] Mount-VHD cmdlet not available. Ensure Hyper-V management tools are installed.' -ForegroundColor Red
    Exit-Script 1
}
Write-Host '  [OK]  Mount-VHD cmdlet available.' -ForegroundColor Green

# Check 6: goldenImage folder exists
$goldenImageDir = Join-Path $currentDir 'goldenImage'
if (-not (Test-Path $goldenImageDir)) {
    Write-Host "  [FAIL] goldenImage folder not found at: $goldenImageDir" -ForegroundColor Red
    Write-Host '         Please ensure your golden VHDs are placed in the goldenImage subfolder.' -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  goldenImage folder found: $goldenImageDir" -ForegroundColor Green

# Check 7: At least one expected VHD is present
# Define all expected VHDs — filename maps to OS label and unattend arch/catalog
$vhdCatalog = [ordered]@{
    'win2016_disk.vhdx'  = @{ Label = 'Windows Server 2016';   Arch = 'amd64'; Gen = 2; IsWin11 = $false }
    'win2019.vhd'        = @{ Label = 'Windows Server 2019';   Arch = 'amd64'; Gen = 1; IsWin11 = $false }
    'win2022.vhd'        = @{ Label = 'Windows Server 2022';   Arch = 'amd64'; Gen = 1; IsWin11 = $false }
    'win2025.vhdx'       = @{ Label = 'Windows Server 2025';   Arch = 'amd64'; Gen = 2; IsWin11 = $false }
    'Win11Ent_disk.vhdx' = @{ Label = 'Windows 11 Enterprise'; Arch = 'amd64'; Gen = 2; IsWin11 = $true  }
}

$foundVhds = @()
$missingVhds = @()

foreach ($vhdFile in $vhdCatalog.Keys) {
    $fullPath = Join-Path $goldenImageDir $vhdFile
    if (Test-Path $fullPath) {
        $foundVhds += $vhdFile
        Write-Host "  [OK]  Found: $vhdFile" -ForegroundColor Green
    } else {
        $missingVhds += $vhdFile
        Write-Host "  [WARN] Not found: $vhdFile (will be skipped)" -ForegroundColor Yellow
    }
}

if ($foundVhds.Count -eq 0) {
    Write-Host ''
    Write-Host '  [FAIL] No golden VHDs found in goldenImage folder.' -ForegroundColor Red
    Write-Host "         Expected files: $($vhdCatalog.Keys -join ', ')" -ForegroundColor Red
    Exit-Script 1
}

Write-Host ''
Write-Host "  Pre-flight complete. $($foundVhds.Count) of $($vhdCatalog.Count) VHD(s) found." -ForegroundColor Green

if ($missingVhds.Count -gt 0) {
    Write-Host "  Missing VHDs will be skipped: $($missingVhds -join ', ')" -ForegroundColor Yellow
}

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: VIRTUAL SWITCH VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  Virtual Switch Validation' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ''

$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    Write-Host "  [WARN] Virtual switch '$switchName' is not configured on this host." -ForegroundColor Yellow
    Write-Host ''
    $response = Read-Host "  Would you like to create it now by running switch.ps1? (Y/N)"
    if ($response -match '^[Yy]$') {
        Write-Host '  Launching switch.ps1...'
        & (Join-Path $PSScriptRoot 'switch.ps1')

        # Reload switch.txt in case switch.ps1 updated it
        if (Test-Path $switchFile) {
            $switchMap  = Parse-IniFile -Path $switchFile
            $switchName = $switchMap['SwitchName']
        }

        if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            Write-Host ''
            Write-Host "  [FAIL] switch.ps1 did not create '$switchName' successfully. Cannot proceed." -ForegroundColor Red
            Exit-Script 1
        }
        Write-Host "  [OK]  Virtual switch '$switchName' created." -ForegroundColor Green
    } else {
        Write-Host '  Cannot proceed without a virtual switch. Exiting.' -ForegroundColor Red
        Exit-Script 1
    }
} else {
    Write-Host "  [OK]  Virtual switch '$switchName' confirmed." -ForegroundColor Green
}

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: DHCP VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  DHCP Validation' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ''

$dhcpAvailable = $false
$osCaption     = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
$hasSM         = [bool](Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)

# Path A: host-based DHCP role (Windows Server only)
if ($osCaption -match 'Server' -and $hasSM) {
    Write-Host '  -> Checking host-based DHCP role...'
    try {
        $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
        if ($dhcpFeat -and $dhcpFeat.Installed) {
            $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object {
                $_.StartRange.ToString() -eq $dhcpStart -and $_.EndRange.ToString() -eq $dhcpEnd
            }
            if ($scope) {
                $dhcpAvailable = $true
                Write-Host '  [OK]  Host DHCP role active with matching scope.' -ForegroundColor Green
            }
        }
    } catch { }
}

# Path B: DHCP VM
if (-not $dhcpAvailable) {
    Write-Host '  -> Checking for DHCP VM...'
    $dhcpVm = Get-VM -Name 'DHCP' -ErrorAction SilentlyContinue
    if ($dhcpVm) {
        if ($dhcpVm.State -ne 'Running') {
            Write-Host '  -> DHCP VM found but not running. Auto-starting...' -ForegroundColor Yellow
            Start-VM -Name 'DHCP' -ErrorAction SilentlyContinue
        }
        Write-Host '  -> Waiting up to 60s for DHCP VM to report an IP...' -ForegroundColor Cyan
        for ($i = 0; $i -lt 12; $i++) {
            $ips = (Get-VM -Name 'DHCP' -ErrorAction SilentlyContinue).NetworkAdapters.IPAddresses |
                   Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
            if ($ips) { $dhcpAvailable = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($dhcpAvailable) {
            Write-Host '  [OK]  DHCP VM is running and has an IP.' -ForegroundColor Green
        } else {
            Write-Warning '  DHCP VM did not report an IP within 60s.'
        }
    }
}

# Neither path found DHCP — offer to run DHCP.ps1
if (-not $dhcpAvailable) {
    Write-Host ''
    Write-Host '  [WARN] DHCP service is not available on this host.' -ForegroundColor Yellow
    Write-Host ''
    $response = Read-Host '  Would you like to install DHCP now by running DHCP.ps1? (Y/N)'
    if ($response -match '^[Yy]$') {
        Write-Host '  Launching DHCP.ps1...'
        & (Join-Path $PSScriptRoot 'DHCP.ps1')

        # Re-validate after DHCP.ps1 runs
        Write-Host '  Re-validating DHCP...' -ForegroundColor Cyan
        try {
            $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
            if ($dhcpFeat -and $dhcpFeat.Installed) {
                $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object {
                    $_.StartRange.ToString() -eq $dhcpStart -and $_.EndRange.ToString() -eq $dhcpEnd
                }
                if ($scope) {
                    $dhcpAvailable = $true
                    Write-Host '  [OK]  Host DHCP role active with matching scope.' -ForegroundColor Green
                }
            }
        } catch { }

        if (-not $dhcpAvailable) {
            Write-Host ''
            Write-Host '  [FAIL] DHCP.ps1 did not configure DHCP successfully. Cannot proceed.' -ForegroundColor Red
            Exit-Script 1
        }
    } else {
        Write-Host '  Cannot proceed without DHCP. Run DHCP.ps1 manually, then retry.' -ForegroundColor Red
        Exit-Script 1
    }
}

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: PASSWORD PROMPT
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  New Administrator Password' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ''
Write-Host '  This password will become the Administrator password on all'
Write-Host '  VMs deployed from these golden images.'
Write-Host ''
Write-Host '  Complexity requirements:' -ForegroundColor Yellow
Write-Host '    - Minimum 8 characters'
Write-Host '    - At least one uppercase letter (A-Z)'
Write-Host '    - At least one lowercase letter (a-z)'
Write-Host '    - At least one digit (0-9)'
Write-Host '    - At least one special character (!@#$%^&* etc.)'
Write-Host ''

function Test-PasswordComplexity {
    param ([string]$Password)
    if ($Password.Length -lt 8)                        { return 'Password must be at least 8 characters.' }
    if ($Password -notmatch '[A-Z]')                   { return 'Password must contain at least one uppercase letter.' }
    if ($Password -notmatch '[a-z]')                   { return 'Password must contain at least one lowercase letter.' }
    if ($Password -notmatch '\d')                      { return 'Password must contain at least one digit.' }
    if ($Password -notmatch '[^A-Za-z0-9]')            { return 'Password must contain at least one special character.' }
    return $null  # null = passed
}

$newPassword = $null

do {
    $securePass1 = Read-Host '  Enter new password' -AsSecureString
    $securePass2 = Read-Host '  Confirm new password' -AsSecureString

    # Convert SecureString to plain text for comparison and complexity check
    $plain1 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass1))
    $plain2 = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                  [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass2))

    if ($plain1 -ne $plain2) {
        Write-Host '  [!] Passwords do not match. Please try again.' -ForegroundColor Red
        Write-Host ''
        continue
    }

    $complexityError = Test-PasswordComplexity -Password $plain1
    if ($complexityError) {
        Write-Host "  [!] $complexityError" -ForegroundColor Red
        Write-Host ''
        continue
    }

    $newPassword = $plain1
    Write-Host '  [OK]  Password accepted.' -ForegroundColor Green

} while ($null -eq $newPassword)

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5: CONFIRMATION BEFORE MODIFYING VHDs
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  Ready to Inject' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ''
Write-Host "  The following $($foundVhds.Count) VHD(s) will be modified:" -ForegroundColor White
foreach ($f in $foundVhds) {
    Write-Host "    - $f  ($($vhdCatalog[$f].Label))" -ForegroundColor White
}
Write-Host ''
Write-Host '  Changes made to each VHD:' -ForegroundColor White
Write-Host '    1. Inject unattend.xml into \Windows\Panther\ (OOBE highest priority)'
Write-Host '    2. Inject unattend.xml into \Windows\System32\Sysprep\ (fallback)'
Write-Host ''
Write-Host '  sys_bootstrap.ini will be updated with the new password.' -ForegroundColor White
Write-Host ''

$confirm = Read-Host '  Proceed? (Y/N)'
if ($confirm -notmatch '^[Yy]$') {
    Write-Host '  Aborted by user. No files were modified.' -ForegroundColor Yellow
    Exit-Script 0
}

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6: OFFLINE VHD INJECTION LOOP
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '  Offline VHD Injection' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ''

# XML tag variables — split to avoid triggering antivirus heuristics on password XML.
$t1 = '<AdministratorPassword>'
$t2 = '</AdministratorPassword>'
$t3 = '<Password>'
$t4 = '</Password>'

function New-UnattendXml {
    param (
        [string]$Password,
        [string]$Arch    = 'amd64',
        [bool]  $IsWin11 = $false
    )

    if ($IsWin11) {
        # ── Windows 11 path ───────────────────────────────────────────────────
        # Problem: Win11 ships with the built-in Administrator account DISABLED
        # by default (unlike Windows Server). Injecting <AdministratorPassword>
        # alone sets the password but the account remains disabled, so OOBE
        # ignores it and drops the user into the new-account creation screen.
        #
        # Fix requires two things working together:
        #
        # 1. specialize pass — <RunSynchronous> fires BEFORE OOBE and runs
        #    "net user Administrator /active:yes" to enable the account while
        #    Windows is still completing hardware detection. This is the earliest
        #    safe point; doing it in oobeSystem is too late because OOBE has
        #    already decided which accounts are available.
        #
        # 2. oobeSystem pass — <AdministratorPassword> sets the password, and
        #    <LocalAccounts> adds Administrator explicitly to the Administrators
        #    group so OOBE treats it as a fully configured account and skips the
        #    new-user prompt. <AutoLogon> then logs in automatically on first boot.
        #
        # wcm namespace must be declared on the component that uses wcm:action.
        return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment"
               processorArchitecture="$Arch"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"
                               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <Order>1</Order>
          <Description>Enable built-in Administrator account</Description>
          <Path>net user Administrator /active:yes</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="$Arch"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserAccounts>
        $t1
          <Value>$Password</Value>
          <PlainText>true</PlainText>
        $t2
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            $t3
              <Value>$Password</Value>
              <PlainText>true</PlainText>
            $t4
            <Name>Administrator</Name>
            <Group>Administrators</Group>
            <DisplayName>Administrator</DisplayName>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>Administrator</Username>
        $t3
          <Value>$Password</Value>
          <PlainText>true</PlainText>
        $t4
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>SE Asia Standard Time</TimeZone>
      <RegisteredOrganization></RegisteredOrganization>
      <RegisteredOwner></RegisteredOwner>
    </component>
  </settings>

</unattend>
"@
    } else {
        # ── Windows Server path (2016 / 2019 / 2022 / 2025) ──────────────────
        # Built-in Administrator is enabled by default on all Server SKUs.
        # <AdministratorPassword> is sufficient — no account activation needed.
        return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="$Arch"
               publicKeyToken="31bf3856ad364e35"
               language="neutral"
               versionScope="nonSxS"
               xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <UserAccounts>
        $t1
          <Value>$Password</Value>
          <PlainText>true</PlainText>
        $t2
      </UserAccounts>
      <AutoLogon>
        <Username>Administrator</Username>
        $t3
          <Value>$Password</Value>
          <PlainText>true</PlainText>
        $t4
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>SE Asia Standard Time</TimeZone>
      <RegisteredOrganization></RegisteredOrganization>
      <RegisteredOwner></RegisteredOwner>
    </component>
  </settings>

</unattend>
"@
    }
}

$results   = [System.Collections.Generic.List[object]]::new()
$anyFailed = $false

foreach ($vhdFile in $foundVhds) {
    $vhdPath = Join-Path $goldenImageDir $vhdFile
    $label   = $vhdCatalog[$vhdFile].Label
    $arch    = $vhdCatalog[$vhdFile].Arch

    Write-Host "  Processing: $label [$vhdFile]" -ForegroundColor Cyan
    $result = [PSCustomObject]@{ File = $vhdFile; Label = $label; Status = 'UNKNOWN'; Detail = '' }

    # --- Verify VHD integrity before touching it ---
    try {
        Get-VHD -Path $vhdPath -ErrorAction Stop | Out-Null
    } catch {
        $msg = "VHD integrity check failed: $_"
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
        $result.Status = 'FAIL'; $result.Detail = $msg
        $results.Add($result); $anyFailed = $true
        Write-Host ''
        continue
    }
    Write-Host '  -> VHD integrity OK.' -ForegroundColor Green

    # --- Check VHD is not already mounted ---
    $existingMount = Get-VHD -Path $vhdPath | Where-Object { $_.Attached }
    if ($existingMount) {
        $msg = 'VHD is already mounted by another process. Dismount it first.'
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
        $result.Status = 'FAIL'; $result.Detail = $msg
        $results.Add($result); $anyFailed = $true
        Write-Host ''
        continue
    }

    # --- Mount ---
    Write-Host '  -> Mounting VHD (ReadWrite)...'
    $mountResult = $null
    try {
        $mountResult = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    } catch {
        $msg = "Failed to mount VHD: $_"
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
        $result.Status = 'FAIL'; $result.Detail = $msg
        $results.Add($result); $anyFailed = $true
        Write-Host ''
        continue
    }

    # Brief pause — gives the disk subsystem time to assign drive letters
    Start-Sleep -Seconds 4

    # --- Locate Windows partition ---
    $diskNumber   = $mountResult.DiskNumber
    $windowsDrive = $null

    try {
        foreach ($part in (Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)) {
            $letter = $part.DriveLetter
            # DriveLetter is [char]; unassigned partitions return char 0x00
            if ($letter -and [int][char]$letter -ne 0) {
                $candidate = "${letter}:"
                if (Test-Path "$candidate\Windows\System32\Sysprep") {
                    $windowsDrive = $candidate
                    break
                }
            }
        }
    } catch {
        Write-Warning "  -> Partition enumeration error: $_"
    }

    if (-not $windowsDrive) {
        $msg = 'Could not locate Windows partition inside VHD.'
        Write-Host "  [FAIL] $msg" -ForegroundColor Red
        $result.Status = 'FAIL'; $result.Detail = $msg
        $results.Add($result); $anyFailed = $true
        try { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue } catch { }
        Write-Host ''
        continue
    }
    Write-Host "  -> Windows partition detected at: $windowsDrive" -ForegroundColor Green

    # --- Build unattend.xml (OS-aware) ---
    $isWin11    = $vhdCatalog[$vhdFile].IsWin11
    $xmlContent = New-UnattendXml -Password $newPassword -Arch $arch -IsWin11 $isWin11

    if ($isWin11) {
        Write-Host '  -> Using Win11 XML (specialize: enable Administrator + oobeSystem: set password).' -ForegroundColor DarkCyan
    } else {
        Write-Host '  -> Using Server XML (oobeSystem: set Administrator password).' -ForegroundColor DarkCyan
    }

    # --- Inject into \Windows\Panther\ (OOBE highest priority path) ---
    $pantherDir = "$windowsDrive\Windows\Panther"
    $injected   = $false

    try {
        if (-not (Test-Path $pantherDir)) {
            New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
            Write-Host "  -> Created Panther directory." -ForegroundColor Yellow
        }
        [System.IO.File]::WriteAllText(
            "$pantherDir\unattend.xml",
            $xmlContent,
            [System.Text.UTF8Encoding]::new($false)   # UTF-8 no BOM
        )
        Write-Host '  -> unattend.xml injected into \Windows\Panther\ (primary).' -ForegroundColor Green
        $injected = $true
    } catch {
        Write-Warning "  -> Panther injection failed: $_ (will still attempt Sysprep fallback)"
    }

    # --- Inject into \Windows\System32\Sysprep\ (fallback) ---
    $sysprepDir = "$windowsDrive\Windows\System32\Sysprep"
    try {
        [System.IO.File]::WriteAllText(
            "$sysprepDir\unattend.xml",
            $xmlContent,
            [System.Text.UTF8Encoding]::new($false)
        )
        Write-Host '  -> unattend.xml injected into \Windows\System32\Sysprep\ (fallback).' -ForegroundColor Green
        $injected = $true
    } catch {
        Write-Warning "  -> Sysprep fallback injection failed: $_"
    }

    # --- Dismount ---
    try {
        Dismount-VHD -Path $vhdPath -ErrorAction Stop
        Write-Host '  -> VHD dismounted cleanly.' -ForegroundColor Green
    } catch {
        Write-Warning "  -> Dismount warning (VHD may still be usable): $_"
    }

    if ($injected) {
        $result.Status = 'OK'
        Write-Host "  [OK]  $label done." -ForegroundColor Green
    } else {
        $result.Status = 'FAIL'
        $result.Detail = 'All injection paths failed. See warnings above.'
        $anyFailed = $true
        Write-Host "  [FAIL] $label - no injection path succeeded." -ForegroundColor Red
    }

    $results.Add($result)
    Write-Host ''
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7: UPDATE sys_bootstrap.ini
# ─────────────────────────────────────────────────────────────────────────────
$seedPath    = Join-Path $currentDir 'sys_bootstrap.ini'
$seedUpdated = $false

# Only update the ini if at least one VHD was processed successfully.
# If ALL VHDs failed, we don't want a mismatch between the ini and the VHDs.
$anyOk = $results | Where-Object { $_.Status -eq 'OK' }

if ($anyOk) {
    try {
        [System.IO.File]::WriteAllText(
            $seedPath,
            $newPassword,
            [System.Text.UTF8Encoding]::new($false)
        )
        $seedUpdated = $true
        Write-Host '  [OK]  sys_bootstrap.ini updated with new password.' -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Could not update sys_bootstrap.ini: $_" -ForegroundColor Yellow
        Write-Host '         Update it manually to keep downstream scripts in sync.' -ForegroundColor Yellow
    }
} else {
    Write-Host '  [SKIP] sys_bootstrap.ini NOT updated — all VHD injections failed.' -ForegroundColor Yellow
    Write-Host '         No changes have been made to your configuration.' -ForegroundColor Yellow
}

# Clear the plaintext password from memory as soon as we are done with it
$newPassword = $null
[System.GC]::Collect()

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8: SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Summary' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

foreach ($r in $results) {
    $color = if ($r.Status -eq 'OK') { 'Green' } else { 'Red' }
    $line  = "  [$($r.Status.PadRight(4))]  $($r.Label) [$($r.File)]"
    if ($r.Detail) { $line += " -- $($r.Detail)" }
    Write-Host $line -ForegroundColor $color
}

Write-Host ''

if ($seedUpdated) {
    Write-Host '  sys_bootstrap.ini : UPDATED' -ForegroundColor Green
} else {
    Write-Host '  sys_bootstrap.ini : NOT UPDATED' -ForegroundColor Yellow
}

Write-Host ''

if ($anyFailed) {
    Write-Host '  One or more VHDs could not be processed.' -ForegroundColor Yellow
    Write-Host '  Review the warnings above, resolve any issues, and re-run:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "    .\InitPassword.ps1" -ForegroundColor White
    Write-Host ''
    Write-Host '  (Already-processed VHDs will still be skipped on retry' -ForegroundColor Gray
    Write-Host '   if they remain mounted or locked.)' -ForegroundColor Gray
} else {
    Write-Host '  All VHDs processed successfully.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor White
    Write-Host '    1. .\switch.ps1   - Create virtual switch and NAT (if not done)' -ForegroundColor White
    Write-Host '    2. .\DHCP.ps1     - Set up DHCP service' -ForegroundColor White
    Write-Host '    3. Choose a deployment script (RDVH / RDS / Domainsetup / deploy)' -ForegroundColor White
}

Write-Host ''
Stop-TranscriptSafe

'@

# ---------------------------------------------------------------------------
# FILE: joindomain.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'joindomain.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Joins multiple VMs to a domain using PowerShell Direct.
.PARAMETER DcVmName
    Mandatory. The name of the Domain Controller VM.
.PARAMETER DomainToJoin
    Mandatory. The domain name (e.g., corp.local).
.PARAMETER DomainAdminUser
    Optional. Defaults to "<DomainToJoin>\Administrator".
.PARAMETER DomainInitCode
    Optional. SecureString. Read from sys_bootstrap.ini if omitted.
.PARAMETER VmInitCode
    Optional. SecureString for local Admin on member VMs. Defaults to DomainInitCode.
.PARAMETER VmNames
    Mandatory. Comma-separated list of VM names to join.
.EXAMPLE
    .\joindomain.ps1 -DcVmName DC01 -DomainToJoin corp.local -VmNames "VM1,VM2"
#>

param (
    [Parameter(Mandatory = $true)]  [string]$DcVmName,
    [Parameter(Mandatory = $true)]  [string]$DomainToJoin,
    [Parameter(Mandatory = $false)] [string]$DomainAdminUser,
    [Parameter(Mandatory = $false)] [System.Security.SecureString]$DomainInitCode,
    [Parameter(Mandatory = $false)] [System.Security.SecureString]$VmInitCode,
    [Parameter(Mandatory = $true)]  [string]$VmNames
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "joindomain_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Credentials ──────────────────────────────────────────────────────────────
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

# BUG FIX: The original read sys_bootstrap.ini unconditionally at the top, then
# checked whether codes were needed. If the file was missing this threw a
# terminating error before the check. Now only read the file when actually needed.
if (-not $DomainInitCode -or -not $VmInitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found and no InitCode parameters were supplied."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $fallback = ConvertTo-SecureString $baseVal -AsPlainText -Force
    if (-not $DomainInitCode) { $DomainInitCode = $fallback }
    if (-not $VmInitCode)     { $VmInitCode     = $fallback }
}

if (-not $DomainAdminUser) { $DomainAdminUser = "$DomainToJoin\Administrator" }
$domainAdminCred = New-Object System.Management.Automation.PSCredential ($DomainAdminUser, $DomainInitCode)

# ─── Validate DC connectivity ─────────────────────────────────────────────────
Write-Host "Validating Domain Controller connectivity..." -ForegroundColor Cyan
try {
    $testSession = New-PSSession -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop
    Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
    Write-Host "  [OK]  DC '$DcVmName' is reachable." -ForegroundColor Green
} catch {
    Write-Error "Cannot connect to DC '$DcVmName': $_"
    Exit-Script 1
}

# ─── Retrieve DC info ─────────────────────────────────────────────────────────
$dcInfo = Invoke-Command -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    [PSCustomObject]@{ IP = $ip; Domain = $domain }
}

Write-Host "  DC IP     : $($dcInfo.IP)"
Write-Host "  DC Domain : $($dcInfo.Domain)"

# ─── Parse VM list ────────────────────────────────────────────────────────────
$vmNamesArray = $VmNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNamesArray.Count -eq 0) {
    Write-Error "No VM names were provided to join."
    Exit-Script 1
}

# ─── Helper: Invoke-DomainJoin ────────────────────────────────────────────────
# Encapsulates the full join sequence for a single VM so it can be called both
# on first attempt and on retry from inside the verify loop.
function Invoke-DomainJoin {
    param(
        [string]$VmName,
        [string]$DcIp,
        [string]$Domain,
        [pscredential]$LocalCred,
        [pscredential]$DomainCred
    )

    try {
        Invoke-Command -VMName $VmName -Credential $LocalCred -ErrorAction Stop -ScriptBlock {
            param($dcIp, $domain, [pscredential]$domCred)

            # Step 1: Point DNS at the DC so the domain name resolves during join.
            $upAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            $upAdapters | Set-DnsClientServerAddress -ServerAddresses $dcIp

            # Step 2: Switch network profile from Public to Private.
            # FIX: Windows 11 defaults to Public firewall profile on first boot.
            # Public mode blocks Kerberos (TCP 88), LDAP (TCP 389), SMB (TCP 445)
            # which are all required by Add-Computer. DNS/ping still work because
            # UDP 53 is permitted — which is why nslookup succeeds but the join
            # fails with "domain does not exist or could not be contacted".
            foreach ($adapter in $upAdapters) {
                try {
                    Set-NetConnectionProfile -InterfaceAlias $adapter.Name `
                                             -NetworkCategory Private -ErrorAction Stop
                } catch {
                    Write-Warning "  -> Could not set Private profile on '$($adapter.Name)': $_"
                }
            }

            # BUG FIX: -Restart in Add-Computer inside PS Direct disconnects the
            # session immediately, which PowerShell misreads as an error. Use
            # Restart-Computer separately so the error surface is clean.
            Add-Computer -DomainName $domain -Credential $domCred -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            Restart-Computer -Force

        } -ArgumentList $DcIp, $Domain, $DomainCred

        # If Invoke-Command returned without throwing, join + reboot fired cleanly.
        Write-Host "  [OK]  Domain join initiated for '$VmName'." -ForegroundColor Green
        return 'initiated'

    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')

        if ($isExpectedDisconnect) {
            # Restart-Computer dropping the pipe is normal — join succeeded.
            Write-Host "  [OK]  '$VmName' is rebooting to complete domain join." -ForegroundColor Green
            return 'initiated'
        } else {
            Write-Host "  [FAIL] Join attempt failed for '$VmName': $_" -ForegroundColor Red
            return 'failed'
        }
    }
}

# ─── Helper: Wait-DCReady ─────────────────────────────────────────────────────
# Blocks until the DC responds to PS Direct AND ADWS (AD Web Services, port 9389)
# is running inside the guest. ADWS is the last AD service to start after reboot
# and is required for Add-Computer to succeed. Waiting only for PS Direct
# reachability is not sufficient — the DC can accept a shell session while AD
# services are still initialising, causing the join to fail with "domain could
# not be contacted" even though DNS and ping are working.
function Wait-DCReady {
    param(
        [string]$DcVmName,
        [pscredential]$Cred,
        [int]$TimeoutSeconds = 300
    )

    Write-Host "  -> Waiting for DC '$DcVmName' AD services to be fully ready..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $adwsRunning = Invoke-Command -VMName $DcVmName -Credential $Cred `
                                          -ErrorAction Stop -ScriptBlock {
                $svc = Get-Service -Name ADWS -ErrorAction SilentlyContinue
                $svc -and $svc.Status -eq 'Running'
            }
            if ($adwsRunning) {
                Write-Host "  [OK]  DC AD services are ready." -ForegroundColor Green
                return $true
            }
            Write-Host "  -> DC reachable but ADWS not running yet. Retrying in 10s..." -ForegroundColor Yellow
        } catch {
            Write-Host "  -> DC not yet reachable via PS Direct. Retrying in 10s..." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 10
    }

    Write-Warning "DC did not become fully ready within $TimeoutSeconds seconds."
    return $false
}

# ─── Build shared credentials ─────────────────────────────────────────────────
$vmAdminCred  = New-Object System.Management.Automation.PSCredential ("Administrator", $VmInitCode)
$domainAdminCred = New-Object System.Management.Automation.PSCredential ($DomainAdminUser, $DomainInitCode)

# ─── Wait for DC to be fully ready before attempting any joins ────────────────
$dcReady = Wait-DCReady -DcVmName $DcVmName -Cred $domainAdminCred -TimeoutSeconds 300
if (-not $dcReady) {
    Write-Host ""
    Write-Host "  [FAIL] DC did not become ready in time. Cannot proceed with domain join." -ForegroundColor Red
    Exit-Script 1
}

# ─── Initiate domain join on each VM ─────────────────────────────────────────
# joinAttemptState tracks whether a join was ever successfully *initiated*
# (meaning Add-Computer ran without error). A VM that never got a clean join
# attempt needs a retry in the verify loop — not just polling.
$joinAttemptState = @{}
foreach ($vm in $vmNamesArray) {
    Write-Host "`nProcessing VM: $vm" -ForegroundColor Cyan
    $joinAttemptState[$vm] = Invoke-DomainJoin `
        -VmName    $vm `
        -DcIp      $dcInfo.IP `
        -Domain    $DomainToJoin `
        -LocalCred $vmAdminCred `
        -DomainCred $domainAdminCred
}

# ─── Verify domain join — with automatic retry on stalled VMs ────────────────
Write-Host "`nWaiting for VMs to reboot and confirm domain membership..." -ForegroundColor Cyan

$joinedState   = @{}
$stalledCount  = @{}   # consecutive verify-cycles where VM is still WORKGROUP
foreach ($vm in $vmNamesArray) {
    $joinedState[$vm]  = $false
    $stalledCount[$vm] = 0
}

$domainVmCred = New-Object System.Management.Automation.PSCredential ("$DomainToJoin\Administrator", $DomainInitCode)
$domainLabel  = $DomainToJoin.Split('.')[0]   # e.g. "testdaidai" from "testdaidai.lab"

# No hard timeout — loop until every VM confirms membership.
# Each VM gets an automatic re-join attempt after 5 consecutive stalled cycles
# (5 x 15s = 75s), which handles the case where the DC was rebooting during the
# first attempt and Add-Computer errored out silently.
while ($joinedState.Values -contains $false) {

    foreach ($vm in $vmNamesArray) {
        if ($joinedState[$vm]) { continue }

        $domainStatus  = $null
        $vmReachable   = $false

        # Try local creds first, fall back to domain creds
        foreach ($cred in @($vmAdminCred, $domainVmCred)) {
            try {
                $domainStatus = Invoke-Command -VMName $vm -Credential $cred `
                                               -ErrorAction Stop -ScriptBlock {
                    (Get-CimInstance Win32_ComputerSystem).Domain
                }
                $vmReachable = $true
                break
            } catch { }
        }

        if (-not $vmReachable) {
            Write-Host "  -> '$vm' unreachable (still rebooting). Waiting..." -ForegroundColor Yellow
            # Don't increment stalled count while unreachable — VM may just be mid-reboot.
            continue
        }

        if ($domainStatus -match [regex]::Escape($domainLabel)) {
            Write-Host "  [OK]  '$vm' is now a member of '$domainStatus'." -ForegroundColor Green
            $joinedState[$vm]  = $true
            $stalledCount[$vm] = 0
            continue
        }

        # VM is reachable but still reports WORKGROUP.
        $stalledCount[$vm]++
        Write-Host "  -> '$vm' reports '$domainStatus' (stall $($stalledCount[$vm])/5). Still waiting..." -ForegroundColor Yellow

        # After 5 consecutive stalled cycles, re-attempt the join.
        # This fires when the original attempt failed because the DC was mid-reboot,
        # or when the Add-Computer silently failed and the VM never rebooted.
        if ($stalledCount[$vm] -ge 5) {
            Write-Host "  -> '$vm' stalled too long. Verifying DC is ready then re-attempting join..." -ForegroundColor Yellow

            $dcStillReady = Wait-DCReady -DcVmName $DcVmName -Cred $domainAdminCred -TimeoutSeconds 120
            if ($dcStillReady) {
                $retryResult = Invoke-DomainJoin `
                    -VmName     $vm `
                    -DcIp       $dcInfo.IP `
                    -Domain     $DomainToJoin `
                    -LocalCred  $vmAdminCred `
                    -DomainCred $domainAdminCred

                if ($retryResult -eq 'initiated') {
                    Write-Host "  -> '$vm' join re-initiated. Resetting stall counter." -ForegroundColor Cyan
                    $stalledCount[$vm] = 0
                } else {
                    Write-Host "  -> '$vm' re-join attempt failed. Will retry in next cycle." -ForegroundColor Yellow
                    $stalledCount[$vm] = 0   # reset so we try again after another 5 cycles
                }
            } else {
                Write-Host "  -> DC not ready for retry. Will try again in next cycle." -ForegroundColor Yellow
                $stalledCount[$vm] = 0
            }
        }
    }

    if ($joinedState.Values -contains $false) { Start-Sleep -Seconds 15 }
}

Write-Host "`nAll VMs have joined the domain." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: RDS.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'RDS.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment of a full RDS Session Host farm.
.DESCRIPTION
    Chains DC creation, VM deployment, domain join, and RDS role configuration
    (Connection Broker, Web Access, Session Hosts, Gateway, Licensing).
#>

param(
    [string]   $DCName       = $null,
    [string]   $DomainName   = $null,
    [string]   $DCOS         = $null,
    [string[]] $VMNames      = $null,
    [string]   $MemberOS     = $null,
    [string]   $CBName       = $null,
    [string[]] $SHNames      = $null,
    [string]   $WAName       = $null,
    [string[]] $LicNames     = $null,
    [string[]] $GWNames      = $null,
    [string]   $DomainAdmin  = "Administrator",
    [string]   $DomainInitCode = ""
)

# ─── Transcript ───────────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "RDS_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

$currentDir = $PSScriptRoot

# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)    { $DCName    = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName){ $DomainName= Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)      { $DCOS      = Read-Host "Enter OS for Domain Controller" }

if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter all domain member VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
if (-not $MemberOS) { $MemberOS = Read-Host "Enter OS for all member VMs" }

if (-not $CBName) { $CBName = Read-Host "Enter Connection Broker VM Name" }
if (-not ($VMNames -contains $CBName)) {
    Write-Host "Error: Connection Broker '$CBName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $SHNames) {
    $SHNames = @((Read-Host "Enter Session Host VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($sh in $SHNames) {
    if (-not ($VMNames -contains $sh)) {
        Write-Host "Error: Session Host '$sh' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if (-not $WAName) { $WAName = Read-Host "Enter RD Web Access VM Name" }
if (-not ($VMNames -contains $WAName)) {
    Write-Host "Error: Web Access VM '$WAName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $LicNames) {
    $LicNames = @((Read-Host "Enter RD Licensing VM Names (comma-separated)") -split ',' |
                  ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($lic in $LicNames) {
    if (-not ($VMNames -contains $lic)) {
        Write-Host "Error: Licensing VM '$lic' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if ($null -eq $GWNames) {
    $GWNames = @((Read-Host "Enter RD Gateway VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($gw in $GWNames) {
    if (-not ($VMNames -contains $gw)) {
        Write-Host "Error: Gateway VM '$gw' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

# ─── Credentials ──────────────────────────────────────────────────────────────
$seedPath = Join-Path $currentDir "sys_bootstrap.ini"
if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found."
        Exit-Script 1
    }
    $DomainInitCode = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
}
$secureCode      = ConvertTo-SecureString $DomainInitCode -AsPlainText -Force
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\$DomainAdmin", $secureCode)

# ─── Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job ────
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $($VMNames -join ', ') (OS: $MemberOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"
$VMListString     = $VMNames -join ','

if (-not (Test-Path $dcScriptPath)) {
    Write-Error "Child script not found: $dcScriptPath"
    Exit-Script 1
}
if (-not (Test-Path $deployScriptPath)) {
    Write-Error "Child script not found: $deployScriptPath"
    Exit-Script 1
}

Write-Host "`nLaunching parallel deployment jobs..." -ForegroundColor Cyan
Write-Host "  -> Starting DC deployment job..." -ForegroundColor Gray
Write-Host "  -> Starting member VM deployment job..." -ForegroundColor Gray

# DC job
$dcJob = Start-Job -Name "DCDeploy" -ScriptBlock {
    param($script, $os, $vmName, $domainName)
    & $script -OS $os -VMName $vmName -DomainName $domainName
    $LASTEXITCODE
} -ArgumentList $dcScriptPath, $DCOS, $DCName, $DomainName

# Member VM job
$deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
    param($script, $vmList, $os)
    & $script -VMName $vmList -OS $os
    $LASTEXITCODE
} -ArgumentList $deployScriptPath, $VMListString, $MemberOS

# Stream job output live to the transcript
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    $dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
    $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

    $dcDone     = $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
$dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
$deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

# Collect results
$dcJobInfo     = Get-Job -Name "DCDeploy"
$deployJobInfo = Get-Job -Name "MemberDeploy"

$dcSuccess     = ($dcJobInfo.State -eq 'Completed')
$deploySuccess = ($deployJobInfo.State -eq 'Completed')

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    Write-Error "createDC.ps1 failed."
    Exit-Script 1
}

if ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    Write-Error "deploy.ps1 failed."
    Exit-Script 1
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

Write-Host "`nWaiting 2 minutes for all VMs to initialise..." -ForegroundColor Cyan
Start-Sleep -Seconds 120

# ─── Step 3: Domain Join ──────────────────────────────────────────────────────
# BUG FIX: The original built $AllVMsToJoin but the logic was wrong — if CBName
# was already in $VMNames the result was just $VMNames, but it used array +
# string concatenation which can produce unexpected results in PowerShell.
# Use Select-Object -Unique on a clean array instead.
$allToJoin = ($VMNames + @($CBName) | Select-Object -Unique) -join ','
Write-Host "`nJoining all VMs to domain '$DomainName'..." -ForegroundColor Cyan
& (Join-Path $currentDir "joindomain.ps1") `
    -DcVmName $DCName -DomainToJoin $DomainName -VmNames $allToJoin
if ($LASTEXITCODE -ne 0) { Write-Error "joindomain.ps1 failed."; Exit-Script 1 }

# Allow AD services to fully start on all domain members before attempting RDS deployment
Write-Host "`nWaiting 60 s for domain services to stabilise on all VMs..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 4: RDS Session Deployment ──────────────────────────────────────────
$CBFQDN  = "$CBName.$DomainName"
$WAFQDN  = "$WAName.$DomainName"
$SHFQDNs = $SHNames | ForEach-Object { "$_.$DomainName" }

Write-Host "`nCreating RDS Session Deployment..." -ForegroundColor Cyan
# BUG FIX: New-RDSessionDeployment must be invoked on the Connection Broker, not
# the DC. The original ran it on $DCName which would fail unless the DC also had
# the RDS role. Changed to run on $CBName (which is the CB itself).
try {
    Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
        param($cb, $wa, $shs)
        Import-Module RemoteDesktop -ErrorAction Stop
        New-RDSessionDeployment -ConnectionBroker $cb -WebAccessServer $wa -SessionHost $shs
    } -ArgumentList $CBFQDN, $WAFQDN, $SHFQDNs
} catch {
    Write-Error "New-RDSessionDeployment failed: $_"
    Exit-Script 1
}

# ─── Step 5: Add Gateway roles ────────────────────────────────────────────────
foreach ($gw in $GWNames) {
    $gwFQDN = "$gw.$DomainName"
    Write-Host "`nAdding RD Gateway role: $gwFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-GATEWAY' -GatewayExternalFqdn $fqdn
        } -ArgumentList $gwFQDN
    } catch {
        Write-Warning "Failed to add Gateway '$gwFQDN': $_"
    }
}

# ─── Step 6: Add Licensing roles ──────────────────────────────────────────────
foreach ($lic in $LicNames) {
    $licFQDN = "$lic.$DomainName"
    Write-Host "`nAdding RD Licensing role: $licFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-LICENSING'
        } -ArgumentList $licFQDN
    } catch {
        Write-Warning "Failed to add Licensing '$licFQDN': $_"
    }
}

Write-Host "`nRDS deployment completed successfully." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: RDVH.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'RDVH.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment of an RDS Virtual Desktop Infrastructure (VDI) farm.
.DESCRIPTION
    Chains DC creation, VM deployment, domain join, nested-virtualisation setup,
    Hyper-V role install inside RDVH guests, and RDS VDI role configuration.

    Parallel deployment uses Start-Job (not Start-Process) so that child
    jobs inherit the elevated token of the parent session — fixing the
    -196608 / #Requires -RunAsAdministrator failure that occurs when
    Start-Process spawns new windows without -Verb RunAs.
#>

param(
    [string]   $DCName         = $null,
    [string]   $DomainName     = $null,
    [string]   $DCOS           = $null,
    [string[]] $VMNames        = $null,
    [string]   $MemberOS       = $null,
    [string]   $CBName         = $null,
    [string[]] $VHNames        = $null,
    [string]   $WAName         = $null,
    [string[]] $LicNames       = $null,
    [string[]] $GWNames        = $null,
    [string]   $DomainAdmin    = "Administrator",
    [string]   $DomainInitCode = ""
)

# ─── Transcript ───────────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "RDS_VDI_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) {
    Write-ReplayCommand
    Stop-Safe
    exit $Code
}

function Write-ReplayCommand {
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  REPLAY COMMAND (copy-paste to rerun)"   -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $vmNamesStr  = $VMNames  -join ','
    $vhNamesStr  = $VHNames  -join ','
    $licNamesStr = $LicNames -join ','
    $gwNamesStr  = $GWNames  -join ','

    $cmd  = "& '$($MyInvocation.ScriptName)'"
    $cmd += " -DCName '$DCName'"
    $cmd += " -DomainName '$DomainName'"
    $cmd += " -DCOS '$DCOS'"
    $cmd += " -VMNames '$vmNamesStr'"
    $cmd += " -MemberOS '$MemberOS'"
    $cmd += " -CBName '$CBName'"
    $cmd += " -VHNames '$vhNamesStr'"
    $cmd += " -WAName '$WAName'"
    $cmd += " -LicNames '$licNamesStr'"
    $cmd += " -GWNames '$gwNamesStr'"

    Write-Host $cmd -ForegroundColor Yellow
    Write-Host "`n" -ForegroundColor Cyan
}

$currentDir = $PSScriptRoot

# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)     { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName) { $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)       { $DCOS       = Read-Host "Enter OS for Domain Controller" }

if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter all domain member VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $VMNames = @($VMNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
if (-not $MemberOS) { $MemberOS = Read-Host "Enter OS for all member VMs" }

if (-not $CBName) { $CBName = Read-Host "Enter Connection Broker VM Name" }
if (-not ($VMNames -contains $CBName)) {
    Write-Host "Error: Connection Broker '$CBName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $VHNames) {
    $VHNames = @((Read-Host "Enter RD Virtualization Host VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $VHNames = @($VHNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($vh in $VHNames) {
    if (-not ($VMNames -contains $vh)) {
        Write-Host "Error: Virtualization Host '$vh' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if (-not $WAName) { $WAName = Read-Host "Enter RD Web Access VM Name" }
if (-not ($VMNames -contains $WAName)) {
    Write-Host "Error: Web Access VM '$WAName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $LicNames) {
    $LicNames = @((Read-Host "Enter RD Licensing VM Names (comma-separated)") -split ',' |
                  ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $LicNames = @($LicNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($lic in $LicNames) {
    if (-not ($VMNames -contains $lic)) {
        Write-Host "Error: Licensing VM '$lic' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if ($null -eq $GWNames) {
    $GWNames = @((Read-Host "Enter RD Gateway VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    $GWNames = @($GWNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($gw in $GWNames) {
    if (-not ($VMNames -contains $gw)) {
        Write-Host "Error: Gateway VM '$gw' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

# ─── Credentials ──────────────────────────────────────────────────────────────
$seedPath = Join-Path $currentDir "sys_bootstrap.ini"
if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
    if (-not (Test-Path $seedPath)) { Write-Error "sys_bootstrap.ini not found."; Exit-Script 1 }
    $DomainInitCode = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
}
$secureCode      = ConvertTo-SecureString $DomainInitCode -AsPlainText -Force
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\$DomainAdmin", $secureCode)

# ─── Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job ──────────
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
# Start-Process without -Verb RunAs spawns a non-elevated child (exit code -196608).
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $($VMNames -join ', ') (OS: $MemberOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"
$VMListString     = $VMNames -join ','

if (-not (Test-Path $dcScriptPath)) {
    Write-Error "Child script not found: $dcScriptPath"
    Exit-Script 1
}
if (-not (Test-Path $deployScriptPath)) {
    Write-Error "Child script not found: $deployScriptPath"
    Exit-Script 1
}

Write-Host "`nLaunching parallel deployment jobs..." -ForegroundColor Cyan
Write-Host "  -> Starting DC deployment job..." -ForegroundColor Gray
Write-Host "  -> Starting member VM deployment job..." -ForegroundColor Gray

# DC job — dot-sources createDC.ps1 inside the job runspace
$dcJob = Start-Job -Name "DCDeploy" -ScriptBlock {
    param($script, $os, $vmName, $domainName)
    & $script -OS $os -VMName $vmName -DomainName $domainName
    # Return the exit code as the last output value so the parent can inspect it
    $LASTEXITCODE
} -ArgumentList $dcScriptPath, $DCOS, $DCName, $DomainName

# Member VM job — dot-sources deploy.ps1 inside the job runspace
$deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
    param($script, $vmList, $os)
    & $script -VMName $vmList -OS $os
    $LASTEXITCODE
} -ArgumentList $deployScriptPath, $VMListString, $MemberOS

# ─── Stream job output live to the transcript ─────────────────────────────────
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    $dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
    $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

    $dcDone     = $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
$dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
$deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

# ─── Collect results ──────────────────────────────────────────────────────────
# The last value emitted by each job scriptblock is $LASTEXITCODE from the child script.
# Receive-Job was already flushed above, so inspect child info directly.
$dcJobInfo     = Get-Job -Name "DCDeploy"
$deployJobInfo = Get-Job -Name "MemberDeploy"

# A job that throws an unhandled terminating error lands in Failed state.
# Treat anything other than Completed as a failure.
$dcSuccess     = ($dcJobInfo.State     -eq 'Completed') -and ($dcJobInfo.ChildJobs[0].Error.Count -eq 0)
$deploySuccess = ($deployJobInfo.State -eq 'Completed') -and ($deployJobInfo.ChildJobs[0].Error.Count -eq 0)

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    # Surface any terminating errors from the job
    $dcJobInfo.ChildJobs[0].Error | ForEach-Object { Write-Host "         Error: $_" -ForegroundColor Red }
}

if ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    $deployJobInfo.ChildJobs[0].Error | ForEach-Object { Write-Host "         Error: $_" -ForegroundColor Red }
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

if (-not $dcSuccess -or -not $deploySuccess) {
    Write-Error "One or more deployment jobs failed. Review the output above."
    Exit-Script 1
}

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

# ─── Verify all VMs are reachable before domain join ─────────────────────────
Write-Host "`n=== Verifying VM Readiness ===" -ForegroundColor Cyan
$allVMs              = @($DCName) + $VMNames
$verificationTimeout = 300   # 5 minutes total
$verificationInterval = 10   # check every 10 seconds
$elapsed             = 0
$allReady            = $false

while (-not $allReady -and $elapsed -lt $verificationTimeout) {
    $allReady    = $true
    $readyCount  = 0

    foreach ($vmName in $allVMs) {
        try {
            $testResult = Invoke-Command -VMName $vmName -Credential $domainAdminCred `
                -ErrorAction Stop -ScriptBlock { "OK" }

            if ($testResult -eq "OK") {
                Write-Host "  [OK] $vmName - Ready" -ForegroundColor Green
                $readyCount++
            }
        } catch {
            $progressMsg = "${elapsed}/${verificationTimeout} seconds"
            Write-Host "  [X] $vmName - Not reachable yet ($progressMsg)" -ForegroundColor Yellow
            $allReady = $false
        }
    }

    if (-not $allReady) {
        $retryMsg = "Retrying in ${verificationInterval} s"
        Write-Host "  Progress: $readyCount/$($allVMs.Count) VMs ready. $retryMsg" -ForegroundColor Gray
        Start-Sleep -Seconds $verificationInterval
        $elapsed += $verificationInterval
    }
}

if ($allReady) {
    Write-Host "`n[OK] All $($allVMs.Count) VMs are ready for domain join." -ForegroundColor Green
} else {
    $timeoutMsg = "${verificationTimeout}s"
    Write-Error "VM verification timed out after $timeoutMsg. Some VMs may not be ready."
    Exit-Script 1
}

# ─── Step 3: Domain Join ──────────────────────────────────────────────────────
$allToJoin = ($VMNames + @($CBName) | Select-Object -Unique) -join ','
Write-Host "`nJoining all VMs to domain '$DomainName'..." -ForegroundColor Cyan
& (Join-Path $currentDir "joindomain.ps1") `
    -DcVmName $DCName -DomainToJoin $DomainName -VmNames $allToJoin
if ($LASTEXITCODE -ne 0) { Write-Error "joindomain.ps1 failed."; Exit-Script 1 }

# Allow AD services to stabilise before proceeding with nested-virt setup
Write-Host "`nWaiting 60 s for domain services to stabilise on all VMs..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 4: Enable Nested Virtualisation on RDVH VMs (host-side) ─────────────
Write-Host "`n[Pre-RDS] Enabling nested virtualisation on RDVH VMs..." -ForegroundColor Cyan
foreach ($vh in $VHNames) {
    Write-Host "  -> Processing: '$vh'..." -ForegroundColor Cyan
    try {
        $vmObj     = Get-VM -Name $vh -ErrorAction Stop
        $wasRunning = $vmObj.State -eq 'Running'

        if ($wasRunning) {
            Write-Host "     Stopping '$vh' to apply processor setting..."
            Stop-VM -Name $vh -Force -ErrorAction Stop
            $stopTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Off') {
                if ((Get-Date) -gt $stopTimeout) { throw "Timed out waiting for '$vh' to stop." }
                Start-Sleep -Seconds 3
            }
        }

        Set-VMProcessor -VMName $vh -ExposeVirtualizationExtensions $true -ErrorAction Stop
        Write-Host "     Nested virtualisation enabled." -ForegroundColor Green

        if ($wasRunning) {
            Start-VM -Name $vh -ErrorAction Stop
            $startTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Running') {
                if ((Get-Date) -gt $startTimeout) { throw "Timed out waiting for '$vh' to start." }
                Start-Sleep -Seconds 3
            }
            Write-Host "     '$vh' is running again." -ForegroundColor Green
        }
    } catch {
        Write-Error "Failed to enable nested virtualisation on '$vh': $_"
        Exit-Script 1
    }
}

Write-Host "`n[Pre-RDS] Waiting 60 s for RDVH VMs to fully boot..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 5: Install Hyper-V inside each RDVH guest ──────────────────────────
Write-Host "`n[Pre-RDS] Installing Hyper-V role inside RDVH guests..." -ForegroundColor Cyan
foreach ($vh in $VHNames) {
    Write-Host "  -> Installing Hyper-V on '$vh'..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vh -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            $feature = Get-WindowsFeature -Name Hyper-V
            if ($feature.InstallState -ne 'Installed') {
                $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools `
                                                 -ErrorAction Stop
                if (-not $result.Success) { throw "Hyper-V feature install failed." }
                Restart-Computer -Force
            } else {
                Write-Host "     Hyper-V already installed."
            }
        }
    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if (-not $isExpectedDisconnect) {
            Write-Error "Failed to install Hyper-V on '$vh': $_"
            Exit-Script 1
        }
        Write-Host "     '$vh' rebooting after Hyper-V install (expected)." -ForegroundColor Yellow
    }
}

Write-Host "`n[Pre-RDS] Waiting 90 s for RDVH guests to reboot..." -ForegroundColor Cyan
Start-Sleep -Seconds 90

# ─── Step 6: RDS VDI Deployment ───────────────────────────────────────────────
$CBFQDN  = "$CBName.$DomainName"
$WAFQDN  = "$WAName.$DomainName"
$VHFQDNs = $VHNames | ForEach-Object { "$_.$DomainName" }

Write-Host "`nCreating RDS Virtual Desktop Deployment..." -ForegroundColor Cyan
try {
    Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
        param($cb, $wa, $vhs)
        Import-Module RemoteDesktop -ErrorAction Stop
        New-RDVirtualDesktopDeployment `
            -ConnectionBroker   $cb  `
            -WebAccessServer    $wa  `
            -VirtualizationHost $vhs
    } -ArgumentList $CBFQDN, $WAFQDN, $VHFQDNs
} catch {
    Write-Error "New-RDVirtualDesktopDeployment failed: $_"
    Exit-Script 1
}

# ─── Step 7: Gateway roles ────────────────────────────────────────────────────
foreach ($gw in $GWNames) {
    $gwFQDN = "$gw.$DomainName"
    Write-Host "`nAdding RD Gateway role: $gwFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-GATEWAY' -GatewayExternalFqdn $fqdn
        } -ArgumentList $gwFQDN
    } catch { Write-Warning "Failed to add Gateway '$gwFQDN': $_" }
}

# ─── Step 8: Licensing roles ──────────────────────────────────────────────────
foreach ($lic in $LicNames) {
    $licFQDN = "$lic.$DomainName"
    Write-Host "`nAdding RD Licensing role: $licFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-LICENSING'
        } -ArgumentList $licFQDN
    } catch { Write-Warning "Failed to add Licensing '$licFQDN': $_" }
}

Write-Host "`nRDS VDI deployment completed successfully." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: switch.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'switch.ps1' -Content @'
#Requires -RunAsAdministrator
param (
    [switch]$Default
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    # Use script-relative logs folder so the log always lands next to the script,
    # not wherever the caller's working directory happens to be.
    $logsDir    = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Switch_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Hyper-V pre-flight check ─────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: Hyper-V is not installed or not enabled on this host." -ForegroundColor Red
    Write-Host ""
    $feature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne 'Enabled') {
        $enableResponse = Read-Host "Would you like to enable Hyper-V now? (Requires reboot) (Y/N)"
        if ($enableResponse -match '^[Yy]$') {
            Write-Host "Enabling Hyper-V..."
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
            Write-Host ""
            Write-Host "Hyper-V has been enabled. Please REBOOT and run this script again." -ForegroundColor Yellow
            Exit-Script 0
        }
    }
    Write-Host "Cannot proceed without Hyper-V. Please install and enable Hyper-V, then try again."
    Exit-Script 1
}

$currentDir = $PSScriptRoot
$switchName = "NATSwitch"

# ─── Determine switch name ────────────────────────────────────────────────────
if ($Default) {
    Write-Host "Using default network range: 192.168.1.0/24 and switch name: $switchName"
    $networkInput = "192.168.1.0/24"
} else {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Hyper-V Virtual Switch Configuration"
    Write-Host "=========================================="
    Write-Host ""
    $switchInput = Read-Host "Enter virtual switch name [Default: $switchName]"
    if (-not [string]::IsNullOrWhiteSpace($switchInput)) { $switchName = $switchInput.Trim() }
}

# NAT name derived from switch name (set once, used throughout)
$natName      = "${switchName}_NAT"
$skipCreation = $false

# ─── Check if switch already exists ───────────────────────────────────────────
$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    Write-Host ""
    Write-Host "Virtual switch '$switchName' already exists." -ForegroundColor Yellow
    Write-Host "Attempting to extract existing network configuration..."

    # BUG FIX: Get-NetIPAddress can return multiple addresses; take only the first
    # valid one to avoid "Cannot convert array" errors downstream.
    $adapter = Get-NetIPAddress -InterfaceAlias "vEthernet ($switchName)" `
                                -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1

    if (-not $adapter) {
        Write-Error "Virtual switch '$switchName' exists but has no IPv4 address on its host adapter."
        Exit-Script 1
    }

    $gateway   = $adapter.IPAddress
    $prefixLen = [int]$adapter.PrefixLength

    if ($prefixLen -ne 24) {
        Write-Error "Switch '$switchName' uses a /$prefixLen prefix. Only /24 is supported."
        Exit-Script 1
    }

    $octets      = $gateway -split '\.'
    $networkAddr = "$($octets[0]).$($octets[1]).$($octets[2]).0"
    $cidr        = "$networkAddr/$prefixLen"

    $existingNat = Get-NetNat -ErrorAction SilentlyContinue |
                   Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $cidr }
    if (-not $existingNat) {
        Write-Warning "Switch '$switchName' has IP $gateway but no NAT rule exists for $cidr."
        $createNat = Read-Host "Would you like to create the NAT rule now? (Y/N)"
        if ($createNat -match '^[Yy]$') {
            try {
                New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $cidr -ErrorAction Stop
                Write-Host "NAT rule created." -ForegroundColor Green
            } catch {
                Write-Error "Failed to create NAT rule: $_"
                Exit-Script 1
            }
        } else {
            Write-Error "Cannot proceed without a NAT rule."
            Exit-Script 1
        }
    }

    $dhcpStart  = "$($octets[0]).$($octets[1]).$($octets[2]).2"
    $dhcpEnd    = "$($octets[0]).$($octets[1]).$($octets[2]).254"
    $subnetMask = "255.255.255.0"

    Write-Host "  [OK]  Extracted configuration from existing switch '$switchName':" -ForegroundColor Green
    Write-Host "        Network     : $cidr"
    Write-Host "        Gateway     : $gateway"
    Write-Host "        Subnet Mask : $subnetMask"
    Write-Host "        DHCP Range  : $dhcpStart - $dhcpEnd"

    $skipCreation = $true
}

# ─── Prompt for network range (only when creating a new switch) ───────────────
if (-not $skipCreation -and -not $Default) {
    Write-Host ""
    Write-Host "Enter the network range in CIDR notation (private /24 only)."
    Write-Host "Examples: 192.168.1.0/24  10.0.1.0/24  172.16.5.0/24"
    Write-Host "Press Enter to accept default (192.168.1.0/24)"
    Write-Host ""
    $networkInput = Read-Host "Network range"
    if ([string]::IsNullOrWhiteSpace($networkInput)) {
        $networkInput = "192.168.1.0/24"
        Write-Host "Using default: $networkInput"
    }
}

# ─── Validate and create switch ───────────────────────────────────────────────
if (-not $skipCreation) {
    # Auto-append /24 for bare IPs
    if ($networkInput -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $networkInput = "$networkInput/24"
        Write-Host "No prefix specified. Appending /24: $networkInput"
    }

    if ($networkInput -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
        Write-Error "Invalid CIDR format: '$networkInput'. Expected: x.x.x.0/24"
        Exit-Script 1
    }

    $parts       = $networkInput -split '/'
    $networkAddr = $parts[0]
    $prefixLen   = [int]$parts[1]

    if ($prefixLen -ne 24) {
        Write-Error "Only /24 prefix is supported. Got: /$prefixLen"
        Exit-Script 1
    }

    $octets = $networkAddr -split '\.'
    # BUG FIX: Validate each octet is a valid integer 0-255 using [int]::TryParse
    # to avoid exceptions when the user types non-numeric characters.
    foreach ($o in $octets) {
        $val = 0
        if (-not [int]::TryParse($o, [ref]$val) -or $val -lt 0 -or $val -gt 255) {
            Write-Error "Invalid IP address in network range: $networkAddr"
            Exit-Script 1
        }
    }

    if ($octets[3] -ne '0') {
        Write-Warning "Last octet is $($octets[3]) for a /24 network. Adjusting to .0"
        $octets[3] = '0'
        $networkAddr = $octets -join '.'
    }

    $firstOctet  = [int]$octets[0]
    $secondOctet = [int]$octets[1]
    $isPrivate   = ($firstOctet -eq 10) -or
                   ($firstOctet -eq 172 -and $secondOctet -ge 16 -and $secondOctet -le 31) -or
                   ($firstOctet -eq 192 -and $secondOctet -eq 168)
    if (-not $isPrivate) {
        Write-Error "Not a private IP range (RFC 1918). Use 10.x.x.0, 172.16-31.x.0, or 192.168.x.0"
        Exit-Script 1
    }

    $base       = "$($octets[0]).$($octets[1]).$($octets[2])"
    $gateway    = "$base.1"
    $dhcpStart  = "$base.2"
    $dhcpEnd    = "$base.254"
    $subnetMask = "255.255.255.0"
    $cidr       = "$networkAddr/$prefixLen"

    Write-Host ""
    Write-Host "Network Configuration:"
    Write-Host "  Switch Name : $switchName"
    Write-Host "  Network     : $cidr"
    Write-Host "  Gateway     : $gateway"
    Write-Host "  Subnet Mask : $subnetMask"
    Write-Host "  DHCP Range  : $dhcpStart - $dhcpEnd"
    Write-Host ""

    try {
        Write-Host "Creating Internal Virtual Switch '$switchName'..."
        New-VMSwitch -SwitchName $switchName -SwitchType Internal -ErrorAction Stop

        Write-Host "Assigning gateway IP $gateway to adapter..."
        New-NetIPAddress -IPAddress $gateway -PrefixLength $prefixLen `
                         -InterfaceAlias "vEthernet ($switchName)" -ErrorAction Stop

        Write-Host "Configuring NAT for $cidr..."
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $cidr -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to create virtual switch or configure NAT." -ForegroundColor Red
        Write-Host "  Detail: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please ensure:" -ForegroundColor Yellow
        Write-Host "  - You are running as Administrator"
        Write-Host "  - No switch named '$switchName' or NAT named '$natName' already exists"
        Exit-Script 1
    }
}

# ─── Write switch.txt ─────────────────────────────────────────────────────────
$switchFile   = Join-Path $currentDir "switch.txt"
$switchConfig = @"
SwitchName=$switchName
Gateway=$gateway
NetworkAddress=$networkAddr
PrefixLength=$prefixLen
SubnetMask=$subnetMask
DHCPStart=$dhcpStart
DHCPEnd=$dhcpEnd
"@

Set-Content -Path $switchFile -Value $switchConfig -Encoding UTF8
Write-Host ""
Write-Host "Network configuration saved to: $switchFile" -ForegroundColor Green
Write-Host "Switch setup complete." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: Guidance.txt
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'Guidance.txt' -Content @'
# Hyper-V Automation Suite v3.0 — Guidance
# ============================================================================
#
# This document covers the CORRECT workflow for deploying a Hyper-V lab
# environment from scratch, including prerequisites, golden image preparation,
# password initialization, and lab deployment.
#
# ============================================================================


# ============================================================================
#  WORKFLOW DIAGRAM (read top-to-bottom)
# ============================================================================
#
#  ┌─────────────────────────────────────────────────────────┐
#  │  PHASE 0: HOST PREREQUISITES                           │
#  │                                                        │
#  │  1. Verify / Enable  Hyper-V role on the host          │
#  │  2. Verify / Create  .\goldenImage\ folder             │
#  │  3. Place VHD(s) with the correct filenames (see table)│
#  └───────────────────────────┬─────────────────────────────┘
#                              │
#                              ▼
#  ┌─────────────────────────────────────────────────────────┐
#  │  PHASE 1: GOLDEN IMAGE PASSWORD INITIALIZATION         │
#  │                                                        │
#  │  .\InitPassword.ps1                                    │
#  │    • Mounts each VHD offline                           │
#  │    • Injects unattend.xml (Administrator password)     │
#  │    • Creates sys_bootstrap.ini                         │
#  └───────────────────────────┬─────────────────────────────┘
#                              │
#                              ▼
#  ┌─────────────────────────────────────────────────────────┐
#  │  PHASE 2: NETWORK SETUP                                │
#  │                                                        │
#  │  .\switch.ps1                                          │
#  │    • Creates Hyper-V Internal switch + NAT             │
#  │    • Generates switch.txt                              │
#  └───────────────────────────┬─────────────────────────────┘
#                              │
#                              ▼
#  ┌─────────────────────────────────────────────────────────┐
#  │  PHASE 3: DHCP SETUP                                   │
#  │                                                        │
#  │  .\DHCP.ps1                                            │
#  │    • Server host: installs DHCP role directly          │
#  │    • Workstation host: deploys dedicated DHCP VM       │
#  └───────────────────────────┬─────────────────────────────┘
#                              │
#                              ▼
#  ┌─────────────────────────────────────────────────────────┐
#  │  PHASE 4: LAB DEPLOYMENT (choose one)                  │
#  │                                                        │
#  │  .\RDVH.ps1         Full RDS VDI (recommended)         │
#  │  .\RDS.ps1          RDS Session Host farm              │
#  │  .\Domainsetup.ps1  Domain Controller + member VMs     │
#  │  .\deploy.ps1       Individual VM(s)                   │
#  └────────────────────────────────────────────────────────-┘
#
#
# ============================================================================
#  SCRIPT ARCHITECTURE — who calls whom
# ============================================================================
#
#     RDVH.ps1 ─────┬──▶ createDC.ps1 ──▶ deploy.ps1
#                    ├──▶ deploy.ps1
#                    ├──▶ joindomain.ps1
#                    └──▶ (Hyper-V install + RDS VDI roles)
#
#     RDS.ps1 ──────┬──▶ createDC.ps1 ──▶ deploy.ps1
#                    ├──▶ deploy.ps1
#                    ├──▶ joindomain.ps1
#                    └──▶ (RDS Session Host roles)
#
#     Domainsetup.ps1 ┬──▶ createDC.ps1 ──▶ deploy.ps1
#                      ├──▶ deploy.ps1
#                      └──▶ joindomain.ps1
#
#     DHCP.ps1 ────────▶ deploy.ps1 (VM-based DHCP only)
#
#     createDC.ps1 ────▶ deploy.ps1
#
#     InitPassword.ps1  (standalone — no child scripts)
#     switch.ps1        (standalone — no child scripts)
#     cleanup.ps1       (standalone — no child scripts)
#
#    ┌──────────────────────────────────────────────────────┐
#    │  Shared Config Files:                                │
#    │    sys_bootstrap.ini  ← written by InitPassword.ps1  │
#    │                         read by all deployment scripts│
#    │    switch.txt         ← written by switch.ps1        │
#    │                         read by deploy/DHCP/Init     │
#    └──────────────────────────────────────────────────────┘
#
#
# ============================================================================
#  PHASE 0 — HOST PREREQUISITES (do this FIRST)
# ============================================================================

## 0A. Enable Hyper-V on the Host

  Hyper-V must be installed and enabled BEFORE running any scripts.
  The InitPassword.ps1 script requires the Hyper-V module for Mount-VHD.

  To check:
    Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online

  To enable (requires a reboot):
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All

  Alternatively, InitPassword.ps1 and switch.ps1 will detect a missing
  Hyper-V installation and offer to enable it for you (still needs a reboot).

## 0B. Create the goldenImage Folder

  All scripts expect a folder named "goldenImage" in the script directory:

    .\goldenImage\

  If it does not exist, create it:
    New-Item -ItemType Directory -Path .\goldenImage

## 0C. Place Your VHD/VHDX Files with the Correct Names

  InitPassword.ps1 and deploy.ps1 look for golden images by EXACT filename.
  If you obtained your VHD from elsewhere (VLSC, evaluation ISO conversion,
  another lab), you MUST rename/copy it to match the expected name.

  ┌─────────────────────────┬───────────────────────────────┬────────┬───────┐
  │ Expected Filename       │ Operating System              │ Format │ Gen   │
  ├─────────────────────────┼───────────────────────────────┼────────┼───────┤
  │ win2016_disk.vhdx       │ Windows Server 2016           │ VHDX   │ Gen 2 │
  │ win2019.vhd             │ Windows Server 2019           │ VHD    │ Gen 1 │
  │ win2022.vhd             │ Windows Server 2022           │ VHD    │ Gen 1 │
  │ win2025.vhdx            │ Windows Server 2025           │ VHDX   │ Gen 2 │
  │ Win11Ent_disk.vhdx      │ Windows 11 Enterprise         │ VHDX   │ Gen 2 │
  └─────────────────────────┴───────────────────────────────┴────────┴───────┘

  Example: if you have a file called "WS2022_eval.vhd", rename or copy it:
    Copy-Item -Path .\WS2022_eval.vhd -Destination .\goldenImage\win2022.vhd

  IMPORTANT:
    - VHDs must be PRE-SYSPREPPED (generalized). The scripts inject an
      unattend.xml that is consumed during the next OOBE boot.
    - You do NOT need every VHD — only the OS versions you plan to deploy.
      Missing VHDs are skipped with a warning.


# ============================================================================
#  PHASE 1 — GOLDEN IMAGE PASSWORD INITIALIZATION
# ============================================================================

## Run InitPassword.ps1

  Usage:  .\InitPassword.ps1

  What it does:
    1. Pre-flight checks: Admin, PowerShell 5.1+, Hyper-V module, Storage
       module, Mount-VHD cmdlet availability
    2. Validates the goldenImage folder and expected VHD filenames
    3. Validates the virtual switch and DHCP service
    4. Prompts for a new Administrator password (complexity enforced)
    5. For each found VHD:
       - Verifies VHD integrity
       - Mounts the VHD (ReadWrite)
       - Locates the Windows partition
       - Injects unattend.xml into \Windows\Panther\ (primary)
       - Injects unattend.xml into \Windows\System32\Sysprep\ (fallback)
       - Dismounts the VHD
    6. Writes the password to sys_bootstrap.ini

  Output files:
    - sys_bootstrap.ini  (password used by all downstream scripts)

  NOTE: InitPassword.ps1 will also check/create the virtual switch and
  DHCP if they are missing (it offers to run switch.ps1 and DHCP.ps1
  interactively). However, for a clean workflow it is recommended to
  configure the switch and DHCP separately in Phases 2 and 3.


# ============================================================================
#  PHASE 2 — NETWORK SETUP
# ============================================================================

## Run switch.ps1

  Usage:  .\switch.ps1               (interactive — prompts for settings)
          .\switch.ps1 -Default      (quick — 192.168.1.0/24, NATSwitch)

  What it does:
    - Creates a Hyper-V Internal virtual switch
    - Assigns a gateway IP to the host adapter
    - Configures NAT routing
    - Saves configuration to switch.txt

  Output files:
    - switch.txt  (SwitchName, Gateway, NetworkAddress, DHCP ranges)


# ============================================================================
#  PHASE 3 — DHCP SETUP
# ============================================================================

## Run DHCP.ps1

  Usage:  .\DHCP.ps1

  Behavior:
    - Windows Server host: offers to install the DHCP role directly on the
      host and create a scope matching switch.txt.
    - Windows Workstation host: deploys a dedicated "DHCP" VM using
      deploy.ps1 and configures the DHCP role inside that VM.


# ============================================================================
#  PHASE 4 — LAB DEPLOYMENT
# ============================================================================

  Choose ONE of the following based on your requirements:

  ┌────────────────────┬────────────────────────────────────────────────────┐
  │ Scenario           │ Command                                           │
  ├────────────────────┼────────────────────────────────────────────────────┤
  │ Full RDS VDI       │ .\RDVH.ps1                                        │
  │ (recommended)      │  DC + VMs + domain join + nested Hyper-V + RDS VDI│
  ├────────────────────┼────────────────────────────────────────────────────┤
  │ RDS Session Hosts  │ .\RDS.ps1                                         │
  │                    │  DC + VMs + domain join + RDS Session deployment   │
  ├────────────────────┼────────────────────────────────────────────────────┤
  │ Domain Only        │ .\Domainsetup.ps1                                 │
  │                    │  DC + VMs + optional domain join                   │
  ├────────────────────┼────────────────────────────────────────────────────┤
  │ Individual VMs     │ .\deploy.ps1 -VMName "VM1,VM2" -OS "2025"         │
  │                    │  Standalone VM(s) from golden image                │
  ├────────────────────┼────────────────────────────────────────────────────┤
  │ Domain Controller  │ .\createDC.ps1 -OS "2025" -VMName "DC01"          │
  │   only             │   -DomainName "lab.local"                         │
  ├────────────────────┼────────────────────────────────────────────────────┤
  │ Domain Join only   │ .\joindomain.ps1 -DcVmName "DC01"                │
  │                    │   -DomainToJoin "lab.local" -VmNames "VM1,VM2"    │
  └────────────────────┴────────────────────────────────────────────────────┘


# ============================================================================
#  DETAILED SCRIPT REFERENCE
# ============================================================================

## Centralized Configuration Files

  * sys_bootstrap.ini — Master Administrator password.
    Created by InitPassword.ps1; read by deploy, createDC, joindomain,
    DHCP, RDS, RDVH, Domainsetup.

  * switch.txt — Virtual switch and network settings.
    Created by switch.ps1; read by deploy, DHCP, InitPassword.

---

## 1. Self-Extractor (Creation.ps1)
  Function : Unpacks the entire suite into the current directory.
  Usage    : .\Creation.ps1
  When     : First-time bootstrap only, or redistributing an updated package.
  Note     : Overwrites existing files on extraction.

## 2. Network Preparation (switch.ps1)
  Function : Creates a Hyper-V Internal virtual switch with NAT routing.
  Usage    : .\switch.ps1  (interactive)
             .\switch.ps1 -Default  (192.168.1.0/24)
  Output   : switch.txt

## 3. Golden Image Password Init (InitPassword.ps1)
  Function : Injects Administrator password into pre-sysprepped golden VHDs.
  How      : Mount VHD → write unattend.xml → dismount.
  Also     : Creates/updates sys_bootstrap.ini.
  Usage    : .\InitPassword.ps1

## 4. DHCP Setup (DHCP.ps1)
  Function : DHCP services for the lab network.
  Modes    : Host-based DHCP role (Server) or dedicated DHCP VM (Workstation).
  Usage    : .\DHCP.ps1

## 5. Core VM Deployment Engine (deploy.ps1)
  Function : Copies golden images via parallel robocopy, creates and starts VMs.
  Features : DHCP auto-start, KVP IP verification, hostname sync.
  Usage    : .\deploy.ps1 -VMName "VM1,VM2" -OS "2025"
  Params   : -SkipDHCPCheck (used by DHCP.ps1 internally)

## 6. Domain Controller Creation (createDC.ps1)
  Function : Deploys a VM, installs AD DS, promotes to DC, waits for AD services.
  Features : Local/domain credential fallbacks, AD service verification.
  Usage    : .\createDC.ps1 -OS "2025" -VMName "DC01" -DomainName "lab.local"

## 7. Domain Join Engine (joindomain.ps1)
  Function : Joins VMs to a domain via PowerShell Direct.
  Features : DNS pointing, firewall profile fix, parallel join, stall detection
             with automatic re-attempt.
  Usage    : .\joindomain.ps1 -DcVmName "DC01" -DomainToJoin "lab.local"
                              -VmNames "VM1,VM2"

## 8. RDS Session Host Farm (RDS.ps1)
  Function : Full RDS Session Host deployment orchestrator.
  Workflow : createDC → deploy → joindomain → RDS Session deployment.
  Roles    : Connection Broker, Web Access, Session Hosts, Gateway, Licensing.
  Usage    : .\RDS.ps1

## 9. RDS VDI Infrastructure (RDVH.ps1)  ★ RECOMMENDED
  Function : Full RDS Virtual Desktop Infrastructure orchestrator.
  Workflow : createDC → deploy → joindomain → nested virt → Hyper-V install
             → RDS VDI deployment → Gateway + Licensing roles.
  Usage    : .\RDVH.ps1

## 10. Domain Environment Orchestrator (Domainsetup.ps1)
  Function : DC + member VMs + optional domain join.
  Workflow : createDC → deploy → joindomain (if JoinDomain=yes).
  Usage    : .\Domainsetup.ps1 -DCName "DC01" -DomainName "lab.local"
                               -DCOS "2025" -VMNames "VM1,VM2" -VMOS "2025"
                               -JoinDomain "yes"

## 11. Cleanup Utility (cleanup.ps1)
  Function : Removes orphaned VM folders from .\hyperv and .\VM.
  Safety   : Checks registered VMs before deleting anything.
  Usage    : .\cleanup.ps1

## 12. Rebuild Creation Package (Rebuild-Creation.ps1)
  Function : Regenerates Creation.ps1 with current file contents.
  Usage    : .\Rebuild-Creation.ps1
             .\Rebuild-Creation.ps1 -Files "deploy.ps1,joindomain.ps1"

## 13. Verification Utilities
  - verify_integrity.ps1  — SHA256 comparison of embedded vs. disk files.
  - Verify-Embedded.ps1   — Line-by-line comparison.


# ============================================================================
#  KEY ENTERPRISE FEATURES (v3.0)
# ============================================================================

  1. Parallel VM Deployment  — DC and member VMs deploy simultaneously via
     Start-Job, with live output streaming to the console.

  2. Credential Fallbacks    — Automatic switching between local and domain
     credentials during DC promotion, reboots, and domain joins.

  3. Replay Commands         — All orchestrator scripts print a copy-paste
     command on failure for easy retry/recovery.

  4. DHCP Auto-Start         — deploy.ps1 detects and auto-starts a stopped
     DHCP VM before proceeding with deployment.

  5. Stall Detection         — joindomain.ps1 detects VMs stuck in WORKGROUP
     and automatically re-attempts the join after verifying DC readiness.

  6. Nested Virtualization   — RDVH.ps1 enables nested virt on VH VMs and
     installs the Hyper-V role inside them for VDI hosting.


---
Version: 3.0 (Build 2026.04.04)
Encoding: Standard ASCII (Compatible with all PowerShell consoles)

'@

# ---------------------------------------------------------------------------
# FILE: readme.txt
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'readme.txt' -Content @'
=============================================================================
HYPER-V AUTOMATION LAB SUITE - v3.0 "ENTERPRISE-READY" DEVELOPER WIKI
=============================================================================

This document provides technical logic and infrastructure details for the
v3.0 release of the Hyper-V Lab Automation Suite.

-----------------------------------------------------------------------------
CORRECT EXECUTION ORDER
-----------------------------------------------------------------------------

  Phase 0:  HOST PREREQUISITES (before any script)
            a. Enable Hyper-V role on the host machine
            b. Create .\goldenImage\ folder
            c. Place pre-sysprepped VHDs with exact filenames (see table below)

  Phase 1:  .\InitPassword.ps1       -- Inject Administrator password into VHDs
  Phase 2:  .\switch.ps1             -- Create virtual switch & NAT network
  Phase 3:  .\DHCP.ps1               -- Install DHCP (host role or dedicated VM)
  Phase 4:  Choose a deployment scenario:
            .\RDVH.ps1               -- Full RDS VDI (recommended)
            .\RDS.ps1                -- RDS Session Host farm
            .\Domainsetup.ps1        -- Domain environment (DC + members)
            .\deploy.ps1             -- Individual VM(s)

  NOTE: InitPassword.ps1 offers interactive fallbacks for switch and DHCP
  if they are not already configured. However, for clarity and reliability,
  run each phase separately in the order above.

-----------------------------------------------------------------------------
GOLDEN IMAGE VHD NAMING TABLE
-----------------------------------------------------------------------------

  InitPassword.ps1 and deploy.ps1 search for files by EXACT name inside
  the .\goldenImage\ folder.

  ┌─────────────────────────┬───────────────────────────────┬───────┬──────┐
  │ Expected Filename       │ Operating System              │ Fmt   │ Gen  │
  ├─────────────────────────┼───────────────────────────────┼───────┼──────┤
  │ win2016_disk.vhdx       │ Windows Server 2016           │ VHDX  │ 2    │
  │ win2019.vhd             │ Windows Server 2019           │ VHD   │ 1    │
  │ win2022.vhd             │ Windows Server 2022           │ VHD   │ 1    │
  │ win2025.vhdx            │ Windows Server 2025           │ VHDX  │ 2    │
  │ Win11Ent_disk.vhdx      │ Windows 11 Enterprise         │ VHDX  │ 2    │
  └─────────────────────────┴───────────────────────────────┴───────┴──────┘

  If your VHD has a different name, rename/copy it:
    Copy-Item .\MyServer2022.vhd .\goldenImage\win2022.vhd

  The VHDs must be pre-sysprepped (generalized). Only needed OS versions
  must be present; missing VHDs are skipped with a warning.

  The deploy.ps1 OS parameter maps to filenames as follows:
    -OS "2016" → win2016_disk.vhdx  (Gen 2)
    -OS "2019" → win2019.vhd        (Gen 1)
    -OS "2022" → win2022.vhd        (Gen 1)
    -OS "2025" → win2025.vhdx       (Gen 2)
    -OS "11"   → Win11Ent_disk.vhdx  (Gen 2)

-----------------------------------------------------------------------------
ARCHITECTURE — SCRIPT CALL GRAPH
-----------------------------------------------------------------------------

  High-Level Orchestrators (call child scripts):

    RDVH.ps1 ─────┬──► createDC.ps1 ──► deploy.ps1
                   ├──► deploy.ps1
                   ├──► joindomain.ps1
                   └──► (nested virt + Hyper-V install + RDS VDI roles)

    RDS.ps1 ──────┬──► createDC.ps1 ──► deploy.ps1
                   ├──► deploy.ps1
                   ├──► joindomain.ps1
                   └──► (RDS Session Host roles)

    Domainsetup.ps1 ┬──► createDC.ps1 ──► deploy.ps1
                     ├──► deploy.ps1
                     └──► joindomain.ps1

    DHCP.ps1 ─────────► deploy.ps1 (VM-based only)

  Mid-Level Engines:
    createDC.ps1 ─────► deploy.ps1

  Standalone Scripts (no child dependencies):
    InitPassword.ps1, switch.ps1, cleanup.ps1

  Shared Configuration Files:
    sys_bootstrap.ini ← written by InitPassword.ps1
                        read by: deploy, createDC, joindomain, DHCP,
                                 RDS, RDVH, Domainsetup
    switch.txt        ← written by switch.ps1
                        read by: deploy, DHCP, InitPassword

-----------------------------------------------------------------------------
CENTRALIZED CONFIGURATION FILES
-----------------------------------------------------------------------------

  * sys_bootstrap.ini
    Single-line file containing the master Administrator password.
    Created by InitPassword.ps1 on first run.
    Read by every deployment script to build PSCredential objects.

  * switch.txt
    INI-style key=value file with network settings:
    SwitchName, Gateway, NetworkAddress, PrefixLength, SubnetMask,
    DHCPStart, DHCPEnd.
    Generated by switch.ps1.

-----------------------------------------------------------------------------
SCRIPT REFERENCE (alphabetical)
-----------------------------------------------------------------------------

SCRIPT: cleanup.ps1
  Resource reclamation. Removes orphaned VM folders from .\hyperv and .\VM.
  Safety: queries Hyper-V for registered VMs before deleting anything.
  Usage: .\cleanup.ps1

SCRIPT: createDC.ps1
  Domain Controller provisioning with credential fallbacks.
  Logic: deploy.ps1 (base VM) → wait for IP → Install-ADDSForest → wait
         for ADWS + Netlogon services to start.
  Features: local/domain credential fallback, AD service readiness gate.
  Usage: .\createDC.ps1 -OS "2025" -VMName "DC01" -DomainName "lab.local"

SCRIPT: deploy.ps1
  Core VM creation engine. Copies golden VHDs via parallel robocopy.
  Logic: DHCP gate → robocopy golden image → New-VM → hostname rename loop.
  Features: disk space validation, DHCP auto-start, KVP-based IP polling,
            hostname sync with 18-minute timeout.
  Params: -VMName, -OS, -InitCode (optional), -SkipDHCPCheck (internal).
  Usage: .\deploy.ps1 -VMName "VM1,VM2" -OS "2025"

SCRIPT: DHCP.ps1
  DHCP role installation. Server host: installs directly with scope creation.
  Workstation host: deploys a DHCP VM using deploy.ps1 then configures the
  DHCP role inside the guest in two phases (feature install + reboot + scope).
  Usage: .\DHCP.ps1

SCRIPT: Domainsetup.ps1
  Multi-VM lab orchestrator. Parallel DC + member VM deployment via Start-Job,
  optional domain join.
  Failure: prints a top-level retry command for easy resume.
  Usage: .\Domainsetup.ps1 -DCName "DC01" -DomainName "lab.local"
         -DCOS "2025" -VMNames "VM1,VM2" -VMOS "2025" -JoinDomain "yes"

SCRIPT: InitPassword.ps1
  Golden Image Password Initializer. Mounts each VHD offline and injects
  unattend.xml into \Windows\Panther\ (primary) and \Windows\System32\Sysprep\
  (fallback).
  Pre-flight: Admin, PS 5.1+, Hyper-V module, Storage module, Mount-VHD.
  Also checks/offers to create virtual switch and DHCP interactively.
  Creates/updates sys_bootstrap.ini.
  Usage: .\InitPassword.ps1

SCRIPT: joindomain.ps1
  Domain join engine with DNS pointing, firewall profile fix (Public→Private),
  stall detection (5×15s threshold), and automatic re-join attempts.
  Features: parallel domain joins via PS Direct, DC readiness gate (ADWS check).
  Usage: .\joindomain.ps1 -DcVmName "DC01" -DomainToJoin "lab.local"
         -VmNames "VM1,VM2"

SCRIPT: RDS.ps1
  RDS Session Host farm orchestrator. Parallel DC + member VM deployment,
  domain join, then New-RDSessionDeployment + Gateway/Licensing roles.
  Usage: .\RDS.ps1 (interactive) or with all parameters.

SCRIPT: RDVH.ps1
  RDS VDI orchestrator. Parallel DC + member VM deployment, domain join,
  nested virtualization + Hyper-V install inside VH guests, then
  New-RDVirtualDesktopDeployment + Gateway/Licensing roles.
  Usage: .\RDVH.ps1 (interactive) or with all parameters.

SCRIPT: Rebuild-Creation.ps1
  Regenerates Creation.ps1 by embedding current file contents. Uses a
  default manifest of 13 files but accepts -Files for custom subsets.
  Usage: .\Rebuild-Creation.ps1
  Usage (selective): .\Rebuild-Creation.ps1 -Files "deploy.ps1,joindomain.ps1"

SCRIPT: switch.ps1
  Virtual Switch + NAT configuration. Auto-discovers existing switches/NAT.
  Only /24 prefixes supported. Generates switch.txt.
  Usage: .\switch.ps1 (interactive)
  Usage: .\switch.ps1 -Default (192.168.1.0/24)

SCRIPT: verify_integrity.ps1
  SHA256 hash comparison of standalone files vs. embedded versions in
  Creation.ps1.

SCRIPT: Verify-Embedded.ps1
  Line-by-line content comparison of embedded vs. standalone scripts.

-----------------------------------------------------------------------------
v3.0 CORE ENHANCEMENTS
-----------------------------------------------------------------------------
1. PARALLEL DEPLOYMENT: DC and member VMs deploy simultaneously via Start-Job
   with live console output streaming (fixes Start-Process #Requires issue).
2. CREDENTIAL FALLBACKS: Automatic local→domain credential switching during
   DC promotion, reboots, and domain joins.
3. STALL DETECTION: joindomain.ps1 detects stuck VMs and re-attempts joins.
4. REPLAY COMMANDS: All orchestrators print copy-paste retry commands.
5. DHCP AUTO-START: deploy.ps1 detects and auto-starts a stopped DHCP VM.
6. NESTED VIRTUALIZATION: RDVH.ps1 enables nested virt and installs Hyper-V
   inside VH VMs for VDI hosting.
7. WIN11 SUPPORT: InitPassword.ps1 handles Windows 11 (Administrator
   account enable + password set via specialize + oobeSystem passes).

-----------------------------------------------------------------------------
TRANSCRIPT & ERROR HANDLING
-----------------------------------------------------------------------------
- Suite-wide $transcriptActive guards prevent transcript nesting conflicts.
- Strict $LASTEXITCODE checks in orchestrator scripts ensure fail-fast.
- All orchestrator scripts print a replay command on failure for recovery.
- Logs are written to .\logs\ with timestamped filenames.

=============================================================================
END OF WIKI
=============================================================================

'@

# ---------------------------------------------------------------------------
# FILE: Walkthrough.md
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'Walkthrough.md' -Content @'
# Hyper-V Automation Suite v3.0 — Walkthrough

This walkthrough covers the complete workflow for deploying a Hyper-V lab environment.

---

## Workflow Overview

```mermaid
flowchart TD
    A["Phase 0: Host Prerequisites"] --> B["Phase 1: InitPassword.ps1"]
    B --> C["Phase 2: switch.ps1"]
    C --> D["Phase 3: DHCP.ps1"]
    D --> E{"Choose Deployment"}
    E --> F["RDVH.ps1 — Full VDI"]
    E --> G["RDS.ps1 — Session Hosts"]
    E --> H["Domainsetup.ps1 — Domain"]
    E --> I["deploy.ps1 — Individual VMs"]

    subgraph Phase0["Phase 0 Detail"]
        A1["Enable Hyper-V Role"] --> A2["Create goldenImage Folder"]
        A2 --> A3["Place + Rename VHD Files"]
    end

    A -.-> Phase0
```

## Architecture — Script Call Graph

```mermaid
flowchart LR
    RDVH["RDVH.ps1"] --> createDC["createDC.ps1"]
    RDVH --> deploy["deploy.ps1"]
    RDVH --> joindomain["joindomain.ps1"]
    RDS["RDS.ps1"] --> createDC
    RDS --> deploy
    RDS --> joindomain
    DS["Domainsetup.ps1"] --> createDC
    DS --> deploy
    DS --> joindomain
    createDC --> deploy
    DHCP["DHCP.ps1"] --> deploy

    subgraph Config["Shared Config Files"]
        INI["sys_bootstrap.ini"]
        SW["switch.txt"]
    end

    InitPW["InitPassword.ps1"] --> INI
    switchps["switch.ps1"] --> SW
    deploy -.-> INI
    deploy -.-> SW
```

---

## Phase 0 — Host Prerequisites

Before running any scripts, ensure three things are ready.

### 0A. Enable Hyper-V

Hyper-V must be installed on the host. The `InitPassword.ps1` script needs `Mount-VHD` from the Hyper-V module.

```powershell
# Check status
Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online

# Enable (requires reboot)
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

> **Note:** `InitPassword.ps1` and `switch.ps1` will also detect a missing Hyper-V installation and offer to enable it interactively.

### 0B. Create the goldenImage Folder

All scripts expect golden VHDs inside `.\goldenImage\`:

```powershell
New-Item -ItemType Directory -Path .\goldenImage -ErrorAction SilentlyContinue
```

### 0C. Place VHD Files with Correct Names

`InitPassword.ps1` and `deploy.ps1` search for golden images by **exact filename**. If your VHD has a different name, rename or copy it.

| Expected Filename      | Operating System          | Format | VM Gen |
|------------------------|---------------------------|--------|--------|
| `win2016_disk.vhdx`    | Windows Server 2016       | VHDX   | Gen 2  |
| `win2019.vhd`          | Windows Server 2019       | VHD    | Gen 1  |
| `win2022.vhd`          | Windows Server 2022       | VHD    | Gen 1  |
| `win2025.vhdx`         | Windows Server 2025       | VHDX   | Gen 2  |
| `Win11Ent_disk.vhdx`   | Windows 11 Enterprise     | VHDX   | Gen 2  |

**Example — renaming a VHD you downloaded from VLSC:**
```powershell
# Your file: SERVER_EVAL_x64FRE_en-us.vhd
Copy-Item -Path .\SERVER_EVAL_x64FRE_en-us.vhd -Destination .\goldenImage\win2022.vhd
```

> **Important:** VHDs must be **pre-sysprepped** (generalized). The scripts inject an `unattend.xml` consumed during OOBE — no re-sysprep is needed.
>
> You do NOT need every VHD listed above. Only place the OS versions you intend to deploy. Missing VHDs are skipped with a warning.

---

## Phase 1 — Initialize the Golden Image Password

```powershell
.\InitPassword.ps1
```

This is the **critical first step** after placing your VHDs. The script:

1. Runs pre-flight checks (Admin rights, PS 5.1+, Hyper-V module, Storage module, `Mount-VHD`)
2. Validates the `goldenImage` folder and scans for expected VHD filenames
3. Checks/offers to create the virtual switch and DHCP (interactive fallback)
4. Prompts for a new Administrator password (must meet complexity requirements)
5. For each VHD found:
   - Verifies VHD integrity
   - Mounts the VHD read-write
   - Locates the Windows partition
   - Injects `unattend.xml` into `\Windows\Panther\` (OOBE primary path)
   - Injects `unattend.xml` into `\Windows\System32\Sysprep\` (fallback)
   - Dismounts the VHD
6. Writes the password to `sys_bootstrap.ini`

**Output:** `sys_bootstrap.ini` — used by all downstream scripts for VM credentials.

---

## Phase 2 — Create the Virtual Network

```powershell
.\switch.ps1            # Interactive mode
.\switch.ps1 -Default   # Quick: 192.168.1.0/24 with "NATSwitch"
```

Creates a Hyper-V Internal virtual switch with NAT routing and saves configuration to `switch.txt`.

**Output:** `switch.txt` — contains switch name, gateway, DHCP ranges.

---

## Phase 3 — Set Up DHCP

```powershell
.\DHCP.ps1
```

| Host OS             | Behavior                                         |
|---------------------|--------------------------------------------------|
| Windows Server      | Offers to install the DHCP role on the host      |
| Windows Workstation | Deploys a dedicated "DHCP" VM using `deploy.ps1` |

---

## Phase 4 — Deploy Your Lab

Choose **one** scenario:

### Scenario A: Full RDS VDI (Recommended)

```powershell
.\RDVH.ps1
```

The orchestrator handles everything automatically:

```mermaid
flowchart TD
    S1["1. Create DC (createDC.ps1)"] --> S2["2. Deploy member VMs (deploy.ps1)"]
    S1 --> S2
    S2 --> S3["3. Join domain (joindomain.ps1)"]
    S3 --> S4["4. Enable nested virtualization"]
    S4 --> S5["5. Install Hyper-V inside VH guests"]
    S5 --> S6["6. Create RDS VDI deployment"]
    S6 --> S7["7. Add Gateway + Licensing roles"]
```

**Parameters (all prompted if not supplied):**
```powershell
.\RDVH.ps1 -DCName "DC01" -DomainName "lab.local" -DCOS "2025" `
           -VMNames "CB,VH1,VH2,WA,LIC,GW" -MemberOS "2025" `
           -CBName "CB" -VHNames "VH1,VH2" -WAName "WA" `
           -LicNames "LIC" -GWNames "GW"
```

### Scenario B: RDS Session Host Farm

```powershell
.\RDS.ps1
```

Workflow: DC → member VMs → domain join → RDS Session deployment (Connection Broker, Web Access, Session Hosts, Gateway, Licensing).

### Scenario C: Domain Environment Only

```powershell
.\Domainsetup.ps1 -DCName "DC01" -DomainName "lab.local" -DCOS "2025" `
                  -VMNames "VM1,VM2" -VMOS "2025" -JoinDomain "yes"
```

Workflow: DC → member VMs → domain join (optional).

### Scenario D: Individual VM Deployment

```powershell
# Single VM
.\deploy.ps1 -VMName "MyVM" -OS "2025"

# Multiple VMs
.\deploy.ps1 -VMName "VM1,VM2,VM3" -OS "2025"

# Domain Controller only
.\createDC.ps1 -OS "2025" -VMName "DC01" -DomainName "lab.local"

# Join existing VMs to a domain
.\joindomain.ps1 -DcVmName "DC01" -DomainToJoin "lab.local" -VmNames "VM1,VM2"
```

---

## Key Enterprise Features

### Automated DHCP Resiliency
`deploy.ps1` detects when the DHCP VM is off and auto-starts it, waiting for Integration Services to confirm an IP before proceeding.

### Failure Recovery (Copy-Paste Resume)
All orchestrator scripts print a pre-filled retry command on failure:
```
========================================
 DEPLOYMENT FAILED
========================================
Fix the issue above, then re-run:

.\RDVH.ps1 -DCName "DC01" -DomainName "lab.local" ...
```

### Enhanced Credential Management
- Automatic fallback between local and domain credentials
- Context-aware switching during DC promotion, reboots, and domain joins

### Parallel Deployment
DC and member VMs deploy simultaneously via `Start-Job` with live output streaming.

### Stall Detection (joindomain.ps1)
If a VM remains in WORKGROUP for too long, the script verifies DC readiness and automatically re-attempts the join.

---

## Cleanup and Maintenance

### Tear Down a Lab
```powershell
.\cleanup.ps1
```
Removes orphaned VM folders from `.\hyperv` and `.\VM`. Lists registered VMs before deleting to prevent data loss.

### Rebuild the Distribution Package
```powershell
.\Rebuild-Creation.ps1           # All files
.\Rebuild-Creation.ps1 -Files "deploy.ps1,joindomain.ps1"  # Selective
```
Regenerates `Creation.ps1` with updated embedded file contents.

### Verify Package Integrity
```powershell
.\verify_integrity.ps1    # SHA256 hash comparison
.\Verify-Embedded.ps1     # Line-by-line diff
```

---
**Build**: v3.0 (April 2026)

'@

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host "  Extraction complete" -ForegroundColor Cyan
Write-Host "  Written : $written" -ForegroundColor Green
if ($overwritten -gt 0) {
    Write-Host "  Updated : $overwritten  (existing files overwritten)" -ForegroundColor Yellow
}
if ($errors -gt 0) {
    Write-Host "  Errors  : $errors" -ForegroundColor Red
}
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step:  Run .\InitPassword.ps1 to set the Administrator password on your golden VHDs." -ForegroundColor White
Write-Host ""
