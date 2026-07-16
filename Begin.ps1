#Requires -Version 5.1
<#
.SYNOPSIS
    One-script bootstrap for a Hyper-V Active Directory lab: virtual switch +
    NAT, one or more domain controllers, DHCP, DNS, and any number of
    additional domain-joined VMs (servers or workstations), with Windows
    media pulled and converted automatically.

.DESCRIPTION
    Run this single file. On first run it:
      1. Checks prerequisites (admin, Hyper-V).
      2. Writes out its own child scripts/module under -LabRoot (Scripts\,
         Modules\), each doing one job (switch, media, VM creation, DC
         promotion, domain join, DHCP, DNS). If a child file already exists
         and differs from what this version would generate, the old copy is
         renamed to *.bak and replaced - so re-running a newer copy of this
         master script transparently upgrades an existing lab's tooling.
      3. Walks you through an interactive configuration wizard (domain name,
         how many DCs, how many other VMs and what they should run, network
         settings, etc.) and saves your answers to Config\LabConfig.json.
      4. Builds the switch, then the DC(s), then DHCP, then (optionally) a
         separate DNS server, then every other VM, joining each to the
         domain as it comes up.
      5. Prints a summary of what was created.

    Re-running the script reuses Config\LabConfig.json and skips any step
    already marked complete, so an interrupted run can simply be resumed.
    Use -Reset to throw away saved progress and start over.

.PARAMETER LabRoot
    Root folder for everything this toolkit creates: generated scripts,
    config, downloaded media, VM files, and logs. Needs plenty of free space
    (each cached Windows edition is tens of GB; VMs are on top of that).

.PARAMETER ForceRegenerateScripts
    Re-writes every generated child file even if its content hasn't changed
    (normally you'd never need this - content-based change detection already
    handles picking up a newer master script automatically).

.PARAMETER Reset
    Ignores any saved Config\LabConfig.json and re-runs the configuration
    wizard from scratch. Does NOT delete already-created VMs.

.PARAMETER TearDown
    Destroys the existing lab's VMs and clears saved build progress, then
    exits WITHOUT rebuilding. Every VM named in Config\LabConfig.json is
    stopped (if running) and removed along with its per-VM VHDX folder under
    VMs\<name>\, and the CompletedSteps array is emptied - so the next run
    rebuilds everything. Topology, network settings, and per-VM MediaSource
    choices are PRESERVED, so cached ISO/VHDX media is reused and nothing is
    re-downloaded. Combine with -RemoveSwitch to also tear down the vSwitch
    and NAT. The intended fast-fresh flow is:
        .\Begin.ps1 -TearDown      # destroy VMs, clear progress, keep media
        .\Begin.ps1 -SkipValidation # rebuild all VMs from cached media
    No Administrator password is needed (tearing a VM down needs no guest
    credentials).

.PARAMETER RemoveSwitch
    Only meaningful with -TearDown. Also removes the Hyper-V virtual switch
    and its NetNat object after the VMs are gone. Off by default for
    host-networking safety (removing a switch/NAT that other things depend on
    is surprising if you didn't ask for it).

.PARAMETER BootForValidation
    By default the ground-truth validation pass does NOT power on VMs that are
    off: an off VM is treated as "Unverifiable" and its saved progress is
    trusted, so validating a shut-down lab is instant. Supply this switch to
    restore the older deep-check behaviour of starting every stopped VM so its
    roles can be probed live via PowerShell Direct. Slower, but useful when you
    suspect the saved progress file is lying and want a full read.

.NOTES
    Requires an elevated PowerShell session on a Windows host with the
    Hyper-V role/feature already enabled, and a working internet connection
    for the first run of any given OS edition (downloads are cached after
    that). All Windows editions require a one-time manual registration at
    Microsoft Evaluation Center - see Config\MediaSources.psd1 after first run.
#>

[CmdletBinding()]
param(
    [string] $LabRoot = 'C:\HyperV-Lab',
    [switch] $ForceRegenerateScripts,
    [switch] $Reset,

    # Run the media scan AND the lab-state validation, print both reports, then
    # exit WITHOUT building anything. Handy for "what do I already have here?"
    [switch] $ScanOnly,

    # Skip the ground-truth validation pass and revert to the legacy behaviour of
    # trusting only the persisted CompletedSteps file. Use only if PowerShell
    # Direct probing of the guests is undesirable (e.g. all VMs intentionally off).
    [switch] $SkipValidation,

    # Destroy the existing lab's VMs and clear saved progress, then exit WITHOUT
    # rebuilding. Preserves topology + per-VM MediaSource (so cached media is
    # reused) and the lab config. No password required. See comment-based help.
    [switch] $TearDown,

    # With -TearDown, also remove the Hyper-V virtual switch and its NetNat.
    # Off by default for host-networking safety.
    [switch] $RemoveSwitch,

    # Power on stopped VMs during validation so their roles can be probed live.
    # Off by default: off VMs are treated as "Unverifiable" (progress trusted),
    # which makes validating a shut-down lab instant.
    [switch] $BootForValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'  # Changed to Continue so we can catch errors and provide detailed reporting

# Global error handler function for detailed error reporting
function Get-DetailedErrorMessage {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = ''
    )
    
    $errorOutput = @()
    $errorOutput += "=" * 80
    $errorOutput += "ERROR DETAILS"
    $errorOutput += "=" * 80
    $errorOutput += ""
    
    # Add context if provided
    if ($Context) {
        $errorOutput += "Context: $Context"
        $errorOutput += ""
    }
    
    # Error record information
    $errorOutput += "Error Message:"
    $errorOutput += $ErrorRecord.Exception.Message
    $errorOutput += ""
    
    # Exception type
    $errorOutput += "Exception Type: $($ErrorRecord.Exception.GetType().FullName)"
    $errorOutput += ""
    
    # Error category
    $errorOutput += "Category: $($ErrorRecord.CategoryInfo.Category)"
    $errorOutput += "Activity: $($ErrorRecord.CategoryInfo.Activity)"
    $errorOutput += "Reason: $($ErrorRecord.CategoryInfo.Reason)"
    $errorOutput += "Target Name: $($ErrorRecord.CategoryInfo.TargetName)"
    $errorOutput += ""
    
    # Error position (line and char)
    if ($ErrorRecord.InvocationInfo) {
        $errorOutput += "Error Position:"
        $errorOutput += "  Script Name: $(if ($ErrorRecord.InvocationInfo.ScriptName) { $ErrorRecord.InvocationInfo.ScriptName } else { 'N/A' })"
        $errorOutput += "  Line Number: $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        $errorOutput += "  Column Number: $($ErrorRecord.InvocationInfo.OffsetInLine)"
        $errorOutput += "  Command: $(if ($ErrorRecord.InvocationInfo.Line) { $ErrorRecord.InvocationInfo.Line } else { 'N/A' })"
        $errorOutput += ""
    }
    
    # Stack trace
    if ($ErrorRecord.ScriptStackTrace) {
        $errorOutput += "Call Stack:"
        $errorOutput += $ErrorRecord.ScriptStackTrace
        $errorOutput += ""
    } else {
        $errorOutput += "Call Stack: (not available)"
        $errorOutput += ""
    }
    
    # Target object
    if ($ErrorRecord.TargetObject) {
        $errorOutput += "Target Object:"
        $errorOutput += ($ErrorRecord.TargetObject | Format-List * | Out-String).Trim()
        $errorOutput += ""
    }
    
    # Error details
    if ($ErrorRecord.ErrorDetails) {
        $errorOutput += "Error Details:"
        $errorOutput += $ErrorRecord.ErrorDetails.Message
        $errorOutput += ""
    }
    
    # Recommended action
    $errorOutput += "=" * 80
    $errorOutput += "RECOMMENDED ACTION"
    $errorOutput += "=" * 80
    $errorOutput += ""
    $errorOutput += "1. Note the line number and script name above"
    $errorOutput += "2. Open the script in a code editor"
    $errorOutput += "3. Navigate to the indicated line number"
    $errorOutput += "4. Review the command that failed"
    $errorOutput += "5. Check if required parameters are correct"
    $errorOutput += "6. Share this error report when asking for help"
    $errorOutput += ""
    
    return $errorOutput -join "`r`n"
}

# Set up global error action preference handler
$Script:ErrorActionPreferenceHandler = {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    # Only process non-terminating errors that we want to handle
    if ($ErrorRecord.Exception -and $ErrorRecord.CategoryInfo.Category -ne 'NotSpecified') {
        Write-Host "`n" -NoNewline
        Write-Host "!!! ERROR DETECTED !!!" -ForegroundColor Red -BackgroundColor Black
        Write-Host "`n"
        Write-Host (Get-DetailedErrorMessage -ErrorRecord $ErrorRecord) -ForegroundColor Yellow
        Write-Host "`n"
    }
}

# ===================================================================================
# PATHS
# ===================================================================================
$Paths = [ordered]@{
    Root    = $LabRoot
    Modules = Join-Path $LabRoot 'Modules'
    Scripts = Join-Path $LabRoot 'Scripts'
    Config  = Join-Path $LabRoot 'Config'
    Media   = Join-Path $LabRoot 'Media'
    VMs     = Join-Path $LabRoot 'VMs'
    Logs    = Join-Path $LabRoot 'Logs'
}
foreach ($p in $Paths.Values) {
    if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
}

# Plain console output until the logging module exists/loads - keep this tiny on purpose.
function Write-Bootstrap([string]$Message) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

# ===================================================================================
# PREREQUISITE CHECK (before we touch anything else)
# ===================================================================================
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this from an elevated (Run as Administrator) PowerShell session."
}
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "The Hyper-V PowerShell module isn't available on this machine. Enable the Hyper-V role/feature, reboot if prompted, then re-run this script."
}

# ===================================================================================
# CHILD FILE GENERATION ENGINE
# ===================================================================================
# Every child script/module lives below as a verbatim (single-quoted) here-string so
# what you see is exactly what gets written to disk - nothing encoded, nothing built
# up at runtime. $Script:ChildFiles maps "relative path under -LabRoot" -> content.

function Write-LabGeneratedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [string] $Content,
        [Parameter(Mandatory)] [string] $Root,
        [switch] $Force
    )
    $fullPath = Join-Path $Root $RelativePath
    $dir = Split-Path -Path $fullPath -Parent
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    # Normalize line endings so the hash comparison isn't thrown off by CRLF/LF differences.
    $normalizedNew = $Content -replace "`r`n", "`n"

    if (Test-Path $fullPath) {
        $existing = Get-Content -Path $fullPath -Raw
        $normalizedExisting = $existing -replace "`r`n", "`n"
        if (-not $Force -and $normalizedExisting -eq $normalizedNew) {
            return $false # unchanged - nothing to do
        }
        $backupPath = "$fullPath.bak"
        Copy-Item -Path $fullPath -Destination $backupPath -Force
        Write-Bootstrap "Updating $RelativePath (previous version backed up to $(Split-Path $backupPath -Leaf))"
    } else {
        Write-Bootstrap "Creating $RelativePath"
    }

    Set-Content -Path $fullPath -Value $Content -Encoding UTF8
    return $true
}

$Script:ChildFiles = [ordered]@{
    'Modules\LabDeploy.Common.psm1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helper functions for the Hyper-V Lab Deploy toolkit.
.DESCRIPTION
    Every generated child script dot-sources / imports this module. It is regenerated
    by Deploy-HyperVLab.ps1 along with everything else, so do not hand-edit it unless
    you also intend to edit the source copy embedded in the master script.
#>

Set-StrictMode -Version Latest

# Enhanced error handling setup
$ErrorActionPreference = 'Stop'

# Store script start time for duration reporting
$Script:StartTime = Get-Date

# Store the current script path for error context
$Script:MainScriptPath = $MyInvocation.MyCommand.Path

# Custom error handler that provides detailed context
function Handle-ScriptError {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$ContextMessage = '',
        [switch]$Terminate
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $scriptName = Split-Path $Script:MainScriptPath -Leaf
    
    # Get line number and context from error position if available
    $lineInfo = ''
    if ($ErrorRecord.InvocationInfo) {
        $lineNum = $ErrorRecord.InvocationInfo.ScriptLineNumber
        $lineContent = $ErrorRecord.InvocationInfo.Line.Trim()
        $scriptName = if ($ErrorRecord.InvocationInfo.ScriptName) { Split-Path $ErrorRecord.InvocationInfo.ScriptName -Leaf } else { $scriptName }
        $lineInfo = " at line ${lineNum}: `"$lineContent`""
    }
    
    # Build detailed error message
    $errorMsg = "[$timestamp] [ERROR]$lineInfo"
    if ($ContextMessage) { $errorMsg += " | $ContextMessage" }
    $errorMsg += "`n    Exception: $($ErrorRecord.Exception.Message)"
    
    # Add stack trace if available
    if ($ErrorRecord.ScriptStackTrace) {
        $stackTrace = $ErrorRecord.ScriptStackTrace -join "`n"
        $errorMsg += "`n    StackTrace:`n$stackTrace"
    }
    
    # Write to log and console
    Write-LabLog $errorMsg -Level Error
    
    if ($Terminate) {
        throw $errorMsg
    }
}

# Populated by Invoke-LabStateValidation (10-Validate-LabState.ps1) and consumed
# by Test-LabStepNeeded below. Maps a step ID -> a state tag reported by ground
# truth (Hyper-V / live guest), independent of what CompletedSteps says:
#   'Present'       guest confirms the step is done
#   'Missing'       guest confirms the step is NOT done
#   'Unverifiable'  VM is off / unreachable, ground truth could not be read
# Empty map = no validation has run, so Test-LabStepNeeded falls back to the
# CompletedSteps-only behaviour (legacy -SkipValidation path).
$Script:StepOverrides = @{}

function Register-LabStepOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StepId,
        [Parameter(Mandatory)] [ValidateSet('Present','Missing','Unverifiable')] [string] $State
    )
    $Script:StepOverrides[$StepId] = $State
}

function Clear-LabStepOverrides {
    [CmdletBinding()]
    param()
    $Script:StepOverrides = @{}
}

function Get-LabStepState {
    <#
        Reconciles the persisted CompletedSteps array against the live ground-truth
        override map (if any) and returns one of:
          'Complete'      tracked in CompletedSteps and ground truth does not contradict
          'Missing'       not tracked and/or ground truth says Missing
          'Conflict'      tracked in CompletedSteps but ground truth says Missing
                          (ground truth wins -> caller should re-run)
          'Unverifiable'  tracked, but VM off so ground truth could not be checked
                          (trust the persisted file)
        Returns 'Unknown' if nothing is known either way (treated as Missing by callers).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $StepId
    )

    $tracked = $false
    if ($Config.PSObject.Properties['CompletedSteps']) {
        $tracked = ($Config.CompletedSteps -contains $StepId)
    }

    $override = $null
    if ($Script:StepOverrides.ContainsKey($StepId)) {
        $override = $Script:StepOverrides[$StepId]
    }

    switch ($override) {
        'Present'      { return 'Complete' }       # ground truth confirms -> done
        'Missing'      { return 'Missing' }        # ground truth says not done -> run (overrides tracked)
        'Unverifiable' { return $(if ($tracked) { 'Unverifiable' } else { 'Missing' }) }
        default {
            # No override available (no validation run, or -SkipValidation): trust the file.
            return $(if ($tracked) { 'Complete' } else { 'Missing' })
        }
    }
}

function Test-LabStepNeeded {
    <#
        The new orchestration gate. Returns $true when the step still needs to run,
        $false when it can be skipped. Logic:

          Complete / Unverifiable -> skip (file is trusted, or ground truth confirms)
          Missing / Conflict       -> run

        Per the "trust ground truth, never auto-fix" rule: a Conflict (file says done,
        guest says missing) causes a RE-RUN; a step the file missed but the guest has is
        reported as Complete and SKIPPED (we do NOT call Set-LabStepComplete for it, so
        manual setup outside the toolkit is never silently absorbed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $StepId
    )
    $state = Get-LabStepState -Config $Config -StepId $StepId
    switch ($state) {
        'Complete'      { return $false }
        'Unverifiable'  { return $false }
        'Missing'       { return $true }
        default         { return $true }   # Unknown / Conflict -> run
    }
}

function Initialize-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $Script:LabLogPath = $Path
}

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('Info', 'Warn', 'Error', 'Success', 'Step')] [string] $Level = 'Info'
    )
    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'Warn'    { Write-Host $line -ForegroundColor Yellow }
        'Error'   { Write-Host $line -ForegroundColor Red }
        'Success' { Write-Host $line -ForegroundColor Green }
        'Step'    { Write-Host $line -ForegroundColor Cyan }
        default   { Write-Host $line }
    }

    if ($Script:LabLogPath) {
        try { Add-Content -Path $Script:LabLogPath -Value $line -ErrorAction Stop } catch { }
    }
}

# Wrapper function to execute script blocks with enhanced error reporting
function Invoke-WithErrorContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock]$ScriptBlock,
        [string]$StepName = 'Operation',
        [switch]$ContinueOnError
    )
    
    try {
        & $ScriptBlock
    }
    catch {
        # Get the line number and context from the error
        $lineNum = $_.InvocationInfo.ScriptLineNumber
        $lineContent = $_.InvocationInfo.Line.Trim()
        
        Write-LabLog "=== ERROR in $StepName at line $lineNum ===" -Level Error
        Write-LabLog "Line: $lineContent" -Level Error
        Write-LabLog "Exception: $($_.Exception.Message)" -Level Error
        
        if ($_.ScriptStackTrace) {
            Write-LabLog "Stack Trace:" -Level Error
            $_.ScriptStackTrace | ForEach-Object { Write-LabLog "  $_" -Level Error }
        }
        
        # Log to file with full details
        $errorDetails = @{
            Step = $StepName
            LineNumber = $lineNum
            LineContent = $lineContent
            Message = $_.Exception.Message
            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        }
        
        if ($Script:LabLogPath) {
            $errorDetails | ConvertTo-Json | Add-Content -Path "$Script:LabLogPath.error.json" -ErrorAction SilentlyContinue
        }
        
        if (-not $ContinueOnError) {
            throw $_
        }
    }
}

function Test-IsAdministrator {
    [CmdletBinding()]
    param()
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LabPrerequisite {
    <#
        Validates the host can actually run this toolkit. Throws a single,
        clear, actionable error per failed check rather than letting cmdlets
        fail later with confusing messages.
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-IsAdministrator)) {
        throw "This must be run from an elevated (Run as Administrator) PowerShell session."
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "PowerShell 5.1 or later is required. Found $($PSVersionTable.PSVersion)."
    }

    $hyperVFeature = $null
    try {
        $hyperVFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
    } catch {
        # Server SKUs expose Hyper-V as a role, not an optional feature - fall back to checking the module/service.
    }

    $hyperVModule = Get-Module -ListAvailable -Name Hyper-V
    if (-not $hyperVModule) {
        throw "The Hyper-V PowerShell module isn't available. Enable the Hyper-V role/feature (and reboot if prompted), then re-run this script."
    }

    if ($hyperVFeature -and $hyperVFeature.State -ne 'Enabled') {
        throw "The Hyper-V feature is installed but not enabled. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All, reboot, then re-run."
    }

    try {
        Get-VMHost -ErrorAction Stop | Out-Null
    } catch {
        throw "Could not query the Hyper-V host (Get-VMHost failed). Confirm the Hyper-V Virtual Machine Management service is running. Underlying error: $($_.Exception.Message)"
    }
}

function Get-LabConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path
    )
    if (-not (Test-Path -Path $Path)) {
        return $null
    }
    try {
        $config = Get-Content -Path $Path -Raw | ConvertFrom-Json
        
        # Ensure DomainControllers is always an array (single item from JSON becomes object)
        if ($config.PSObject.Properties['DomainControllers']) {
            if ($config.DomainControllers -isnot [array]) {
                $config.DomainControllers = @($config.DomainControllers)
            }
        }
        
        # Ensure AdditionalVMs is always an array (single item from JSON becomes object)
        if ($config.PSObject.Properties['AdditionalVMs']) {
            if ($config.AdditionalVMs -isnot [array]) {
                $config.AdditionalVMs = @($config.AdditionalVMs)
            }
        }
        
        # Ensure CompletedSteps is always an array (single item from JSON becomes object)
        if ($config.PSObject.Properties['CompletedSteps']) {
            if ($config.CompletedSteps -isnot [array]) {
                $config.CompletedSteps = @($config.CompletedSteps)
            }
        }
        
        return $config
    } catch {
        Write-LabLog "Could not parse existing config at $Path - $($_.Exception.Message)" -Level Warn
        return $null
    }
}

function Save-LabConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $Path
    )
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $Config | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8
}

function Test-LabStepComplete {
    <#
        Idempotency helper. $Config.CompletedSteps is a simple array of step IDs
        (e.g. "VM:DC1:Created", "DC:DC1:ForestPromoted"). Re-running the
        orchestrator skips anything already marked complete unless -Reset was used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $StepId
    )
    if (-not $Config.PSObject.Properties['CompletedSteps']) { return $false }
    return ($Config.CompletedSteps -contains $StepId)
}

function Set-LabStepComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $StepId,
        [Parameter(Mandatory)] [string] $ConfigPath
    )
    if (-not $Config.PSObject.Properties['CompletedSteps']) {
        $Config | Add-Member -MemberType NoteProperty -Name CompletedSteps -Value @()
    }
    $Config.CompletedSteps = @($Config.CompletedSteps) + $StepId
    Save-LabConfig -Config $Config -Path $ConfigPath
}

function Wait-LabVMHeartbeat {
    <#
        Waits for Hyper-V integration services to report the VM as running with
        a healthy heartbeat - this just means the guest OS has booted enough to
        respond, not that OOBE/setup has finished.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [int] $TimeoutSeconds = 600
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running' -and $vm.Heartbeat -match 'OkApplicationsHealthy|OkApplicationsUnknown') {
            return      # void - callers only need the throw-on-failure contract
        }
        Start-Sleep -Seconds 5
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for '$VMName' to report a healthy heartbeat."
}

function Wait-LabVMPowerShellDirect {
    <#
        Waits until Invoke-Command -VMName succeeds against the guest using the
        supplied credential. This works over the VMBus, not the network, so it
        is reliable even before any virtual switch/NAT/DHCP path is functional -
        which is exactly why it's used as the primary automation transport
        throughout this toolkit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [int] $TimeoutSeconds = 900,
        [int] $RetryDelaySeconds = 10
    )
    Wait-LabVMHeartbeat -VMName $VMName -TimeoutSeconds $TimeoutSeconds

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $result = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { 'ready' } -ErrorAction Stop
            if ($result -eq 'ready') {
                return      # void
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $RetryDelaySeconds
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for PowerShell Direct against '$VMName'. Last error: $lastError"
}

function Wait-LabVMRestart {
    <#
        Use after triggering a guest reboot (domain join, DC promotion, etc.).
        Waits for the heartbeat to drop (VM actually restarting) and then come
        back, then re-validates PowerShell Direct with the *new* credential
        (e.g. domain credential after a domain join).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [int] $TimeoutSeconds = 1200
    )
    Write-LabLog "Waiting for '$VMName' to restart..." -Level Info
    Start-Sleep -Seconds 20 # give it a moment to actually start going down before we poll
    Wait-LabVMPowerShellDirect -VMName $VMName -Credential $Credential -TimeoutSeconds $TimeoutSeconds
}

function Wait-LabDomainResolvable {
    <#
        Gen1.0.0: Polls a guest until it can resolve the lab domain via DNS, or
        times out. Speed-tuned: default 60s timeout, 3s polling. Throws with
        full DNS-client + IP-config diagnostics on timeout so you know exactly
        why resolution failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $DomainName,
        [int] $TimeoutSeconds = 60,
        [int] $RetryIntervalSeconds = 3
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $ok = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
                param($d) [bool](Resolve-DnsName -Name $d -Type A -ErrorAction SilentlyContinue)
            } -ArgumentList $DomainName -ErrorAction Stop
            if ($ok) { return }
        } catch { }
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    # Timed out - collect diagnostics for the throw message.
    $diag = $null
    try {
        $diag = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            $dns = Get-DnsClientServerAddress -AddressFamily IPv4 |
                Where-Object { $_.ServerAddresses.Count -gt 0 } |
                ForEach-Object { "$($_.InterfaceAlias)=$($_.ServerAddresses -join ',')" }
            $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -in @('Dhcp','Manual') } |
                ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)($($_.PrefixOrigin))" }
            [pscustomobject]@{ DnsClients = ($dns -join '; '); IPs = ($ips -join '; ') }
        } -ErrorAction Stop
    } catch { }

    $dnsInfo = if ($diag) { $diag.DnsClients } else { '<unreadable>' }
    $ipInfo  = if ($diag) { $diag.IPs }        else { '<unreadable>' }
    throw "Timed out after $TimeoutSeconds seconds waiting for '$VMName' to resolve '$DomainName'.`n  Guest IP : $ipInfo`n  Guest DNS: $dnsInfo"
}

function ConvertTo-LabSecureFile {
    <#
        Encrypts a SecureString to disk using Windows DPAPI (ConvertFrom-SecureString
        with no -Key), meaning it is only decryptable by the same Windows user
        account on the same machine. Used only for short-lived, in-run handoff
        between the orchestrator process and helper processes if ever needed -
        the default flow keeps credentials in memory only and never touches disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [securestring] $SecureString,
        [Parameter(Mandatory)] [string] $Path
    )
    $SecureString | ConvertFrom-SecureString | Set-Content -Path $Path -Encoding UTF8
}

Export-ModuleMember -Function *
'@

    'Scripts\01-New-LabSwitch.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Creates (idempotently) the Hyper-V virtual switch the lab will use.
#>

Set-StrictMode -Version Latest

function New-LabSwitch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SwitchName,

        [Parameter(Mandatory)] [ValidateSet('InternalNAT', 'External', 'Private')]
        [string] $NetworkMode,

        # Only used for InternalNAT
        [string] $NatSubnetCidr = '192.168.50.0/24',
        [string] $GatewayIPAddress = '192.168.50.1',

        # Only used for External
        [string] $ExternalAdapterName
    )

    $existing = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabLog "Virtual switch '$SwitchName' already exists (Type: $($existing.SwitchType)) - skipping creation." -Level Info
    } else {
        switch ($NetworkMode) {
            'InternalNAT' {
                Write-LabLog "Creating Internal switch '$SwitchName'..." -Level Step
                New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
            }
            'External' {
                if (-not $ExternalAdapterName) {
                    throw "NetworkMode 'External' requires -ExternalAdapterName."
                }
                Write-LabLog "Creating External switch '$SwitchName' bound to adapter '$ExternalAdapterName'..." -Level Step
                New-VMSwitch -Name $SwitchName -NetAdapterName $ExternalAdapterName -AllowManagementOS $true | Out-Null
            }
            'Private' {
                Write-LabLog "Creating Private switch '$SwitchName'..." -Level Step
                New-VMSwitch -Name $SwitchName -SwitchType Private | Out-Null
            }
        }
    }

    if ($NetworkMode -eq 'InternalNAT') {
        # The Internal switch creates a host vNIC named "vEthernet ($SwitchName)".
        # Give that vNIC the gateway address, then bind a NetNat object to the subnet.
        $prefixLength = ($NatSubnetCidr -split '/')[1]
        $hostAdapterName = "vEthernet ($SwitchName)"

        $hostAdapter = Get-NetAdapter -Name $hostAdapterName -ErrorAction SilentlyContinue
        if (-not $hostAdapter) {
            throw "Expected host vNIC '$hostAdapterName' was not found after creating the Internal switch. Check Get-NetAdapter manually."
        }

        $existingIp = Get-NetIPAddress -InterfaceAlias $hostAdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $GatewayIPAddress }
        if (-not $existingIp) {
            Write-LabLog "Assigning gateway address $GatewayIPAddress/$prefixLength to '$hostAdapterName'..." -Level Step
            New-NetIPAddress -InterfaceAlias $hostAdapterName -IPAddress $GatewayIPAddress -PrefixLength $prefixLength -ErrorAction Stop | Out-Null
        } else {
            Write-LabLog "Host adapter already has gateway address $GatewayIPAddress - skipping." -Level Info
        }

        $natName = "$SwitchName-NAT"
        $existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
        if (-not $existingNat) {
            $conflicting = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $NatSubnetCidr }
            if ($conflicting) {
                Write-LabLog "A NetNat object already covers $NatSubnetCidr ('$($conflicting.Name)') - skipping creation." -Level Info
            } else {
                Write-LabLog "Creating NAT '$natName' for $NatSubnetCidr..." -Level Step
                New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $NatSubnetCidr -ErrorAction Stop | Out-Null
            }
        } else {
            Write-LabLog "NAT object '$natName' already exists - skipping." -Level Info
        }
    }

    Write-LabLog "Virtual switch '$SwitchName' ready (Mode: $NetworkMode)." -Level Success
    return Get-VMSwitch -Name $SwitchName
}
'@

    'Scripts\02-Get-WindowsMedia.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Resolves, downloads, and converts Windows installation media into a cached,
    reusable "golden" VHDX per OS edition.
.DESCRIPTION
    All Windows editions (including Home, Pro, Enterprise, and Server) require a
    one-time registration at Microsoft Evaluation Center. The resulting fwlink URL
    must be supplied in Config\MediaSources.psd1. See that file for exact instructions.
    Golden VHDX files are cached and reused across every VM that requests the same
    OS - only the first VM of a given edition pays the download/convert cost.
#>

Set-StrictMode -Version Latest







function Resolve-LabIsoEdition {
    <#
        Inspects an ISO's install.wim/install.esd and returns the exact ImageName
        to hand to Convert-WindowsImage, instead of guessing a wildcard pattern
        blind (edition naming has changed across Windows Server releases).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IsoPath,
        [Parameter(Mandatory)] [ValidateSet('Win10Pro', 'Win11Pro', 'Win10Enterprise', 'Win11Enterprise', 'Server2016', 'Server2019', 'Server2022', 'Server2025')]
        [string] $OSKey,
        [switch] $PreferServerCore
    )

    $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    try {
        $vol = $mount | Get-Volume
        $driveLetter = $vol.DriveLetter
        $sourcesPath = "${driveLetter}:\sources"
        $wimPath = Join-Path $sourcesPath 'install.wim'
        if (-not (Test-Path $wimPath)) {
            $wimPath = Join-Path $sourcesPath 'install.esd'
        }
        if (-not (Test-Path $wimPath)) {
            throw "Could not find install.wim or install.esd inside $IsoPath."
        }

        $images = Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop

        $selected = switch -Regex ($OSKey) {
            'Pro$' {
                $images | Where-Object { $_.ImageName -eq 'Professional' -or $_.ImageName -match '^Windows (10|11) Pro$' } | Select-Object -First 1
            }
            'Enterprise$' {
                $images | Where-Object { $_.ImageName -eq 'Enterprise' -or $_.ImageName -match '^Windows (10|11) Enterprise$' } | Select-Object -First 1
            }
            '^Server' {
                $candidates = $images | Where-Object { $_.ImageName -match 'Standard' }
                if ($PreferServerCore) {
                    $core = $candidates | Where-Object { $_.ImageName -notmatch 'Desktop Experience' }
                    if ($core) { $core | Select-Object -First 1 } else { $candidates | Select-Object -First 1 }
                } else {
                    $desktop = $candidates | Where-Object { $_.ImageName -match 'Desktop Experience' }
                    if ($desktop) { $desktop | Select-Object -First 1 } else { $candidates | Select-Object -First 1 }
                }
            }
        }

        if (-not $selected) {
            $available = ($images | Select-Object -ExpandProperty ImageName) -join ', '
            throw "Could not find a matching edition for '$OSKey' inside $IsoPath. Editions found in this ISO: $available"
        }

        return $selected.ImageName
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
}

function Get-WindowsMedia {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Win10Pro', 'Win11Pro', 'Win10Enterprise', 'Win11Enterprise', 'Server2016', 'Server2019', 'Server2022', 'Server2025')]
        [string] $OSKey,

        [Parameter(Mandatory)] [string] $MediaRoot,
        [Parameter(Mandatory)] [string] $MediaSourcesPath,

        [ValidateSet('x64')] [string] $Architecture = 'x64',
        [switch] $PreferServerCore,
        [uint64] $VhdSizeBytes = 0,  # 0 = use the per-OSKey default below
        [switch] $Force,
        [int] $Generation = 2,  # Default to Gen 2 (VHDX), set to 1 for VHD

        # Media-reuse hooks (populated by Invoke-LabMediaSelection in the master
        # script after a scan). Either one short-circuits the download step:
        #   -LocalVhdxPath : a ready-to-use golden VHDX -> skip download AND convert,
        #                    just register/copy it as the cached golden for this OSKey.
        #   -LocalIsoPath  : a local ISO -> skip download, but still run Convert-WindowsImage.
        # Both are validated to exist before use; if the file is missing we fall
        # through to the normal download path with a warning.
        [string] $LocalVhdxPath,
        [string] $LocalIsoPath
    )

    $toolsRoot = Join-Path $MediaRoot 'Tools'
    $isoRoot = Join-Path $MediaRoot 'ISO'
    $vhdxRoot = Join-Path $MediaRoot 'VHDX'
    
    # Determine disk layout based on OS version
    # Older Windows Server versions (2016/2019/2022) use BIOS layout to avoid bcdboot.exe error 193
    # Newer versions (2025+) use UEFI layout
    # NOTE: This mapping is based on testing with specific ISOs on this host configuration.
    # Future ISO updates or different hosts may not need this distinction.
    $useBIOSLayout = @('Server2016', 'Server2019', 'Server2022') -contains $OSKey
    
    # Build output path dynamically based on chosen layout
    if ($LocalIsoPath -and (Test-Path $LocalIsoPath)) {
        $isoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($LocalIsoPath)
        $outputExt = if ($useBIOSLayout) { '.vhd' } else { '.vhdx' }
        $vhdxPath = Join-Path $vhdxRoot "$isoBaseName$outputExt"
    } else {
        $outputExt = if ($useBIOSLayout) { '.vhd' } else { '.vhdx' }
        $vhdxPath = Join-Path $vhdxRoot "$OSKey$outputExt"
    }
    foreach ($p in @($toolsRoot, $isoRoot, $vhdxRoot)) {
        if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
    }

    # Ensure Convert-WindowsImage is available
    $convertToolPath = Join-Path $toolsRoot 'Convert-WindowsImage.ps1'
    if (-not (Get-Command Convert-WindowsImage -ErrorAction SilentlyContinue)) {
        if (Test-Path $convertToolPath) {
            . $convertToolPath
        } else {
            # Try to download it automatically
            Write-LabLog "Downloading Convert-WindowsImage.ps1..." -Level Info
            try {
                $webClient = New-Object System.Net.WebClient
                $webClient.DownloadFile('https://raw.githubusercontent.com/MicrosoftDocs/Virtualization-Documentation/main/hyperv-tools/Convert-WindowsImage/Convert-WindowsImage.ps1', $convertToolPath)
                . $convertToolPath
            } catch {
                Write-LabLog "Failed to download Convert-WindowsImage.ps1: $_" -Level Warn
            }
        }
    }

    $mediaSources = Import-PowerShellDataFile -Path $MediaSourcesPath

    # ---- Reuse an explicitly-supplied local golden VHDX/VHD (highest priority) ----
    if ($LocalVhdxPath -and (Test-Path $LocalVhdxPath)) {
        Write-LabLog "Reusing selected local media for $OSKey - $LocalVhdxPath (skipping download + convert)" -Level Step
        
        # Check if source is VHD format
        $sourceExt = [System.IO.Path]::GetExtension($LocalVhdxPath).ToLower()
        
        if ($Generation -eq 1 -and $sourceExt -eq '.vhd') {
            # Gen 1 VMs can use VHD directly, no conversion needed
            Write-LabLog "Gen 1 VM using VHD file directly: $LocalVhdxPath" -Level Info
            return [pscustomobject]@{ OSKey = $OSKey; VhdPath = $LocalVhdxPath; MediaSource = 'LocalVhd' }
        } elseif ($sourceExt -eq '.vhd') {
            # Gen 2 VMs need VHDX, convert if source is VHD
            Write-LabLog "Gen 2 VM converting VHD to VHDX..." -Level Info
            
            try {
                Convert-Vhd -Path $LocalVhdxPath -DestinationPath $vhdxPath -ErrorAction Stop
                
                Write-LabLog "Golden image ready for $OSKey - $vhdxPath (converted from VHD)" -Level Success
            } catch {
                throw "Failed to convert VHD to VHDX: $_"
            }
        } else {
            # Already VHDX or other format, just copy it
            Copy-Item -Path $LocalVhdxPath -Destination $vhdxPath -Force
            Write-LabLog "Golden image ready for $OSKey - $vhdxPath" -Level Success
        }
        return [pscustomobject]@{ OSKey = $OSKey; VhdxPath = $vhdxPath; MediaSource = 'LocalVhdx' }
    }

    # Check for any cached VHDX file (for non-standard naming like win2025.vhdx)
    # Try to match by OSKey first, then fall back to any VHDX file
    $cachedVhdx = $null
    if (Test-Path $vhdxRoot) {
        Write-LabLog "Checking for VHDX/VHD files in $vhdxRoot..." -Level Info
        $allVhdx = @() + (Get-ChildItem -Path $vhdxRoot -Filter "*.vhdx" -File -ErrorAction SilentlyContinue)
        $allVhd = @() + (Get-ChildItem -Path $vhdxRoot -Filter "*.vhd" -File -ErrorAction SilentlyContinue)
        $allMedia = $allVhdx + $allVhd
        
        # Deduplicate by full path
        $seenPaths = @{}
        $uniqueMedia = @()
        foreach ($media in $allMedia) {
            if (-not $seenPaths.ContainsKey($media.FullName)) {
                $seenPaths[$media.FullName] = $true
                $uniqueMedia += $media
            }
        }
        
        Write-LabLog "Found $($uniqueMedia.Count) VHDX/VHD file(s) in $vhdxRoot" -Level Info
        foreach ($media in $uniqueMedia) {
            Write-LabLog "  - $($media.Name) (BaseName: $($media.BaseName))" -Level Info
        }
        
        # Map OSKey to VHDX naming convention:
        # Win2016, Win2019, Win2022, Win2025, Win11E, Win10E, W11E, W11P
        $vhdxNamePatterns = @()
        switch ($OSKey) {
            'Win2016' { $vhdxNamePatterns = @('Win2016', 'Win2016.vhdx') }
            'Win2019' { $vhdxNamePatterns = @('Win2019', 'Win2019.vhdx') }
            'Win2022' { $vhdxNamePatterns = @('Win2022', 'Win2022.vhdx') }
            'Win2025' { $vhdxNamePatterns = @('Win2025', 'Win2025.vhdx') }
            'Win11Enterprise' { $vhdxNamePatterns = @('Win11E', 'Win11Enterprise', 'W11E', 'Win11E.vhdx') }
            'Win10Enterprise' { $vhdxNamePatterns = @('Win10E', 'Win10Enterprise', 'Win10E.vhdx') }
            'Win11Pro' { $vhdxNamePatterns = @('W11P', 'Win11Pro', 'W11P.vhdx') }
            'Win10Pro' { $vhdxNamePatterns = @('Win10Pro', 'Win10Pro.vhdx') }
            'Server2016' { $vhdxNamePatterns = @('Win2016', 'Server2016', 'Win2016.vhdx') }
            'Server2022' { $vhdxNamePatterns = @('Win2022', 'Server2022', 'Win2022.vhdx') }
            'Server2025' { $vhdxNamePatterns = @('Win2025', 'Server2025', 'Win2025.vhdx') }
            default { $vhdxNamePatterns = @($OSKey) }
        }
        
        # Try to match by OSKey (case-insensitive) using the naming convention
        $matchedVhdx = @(@($allMedia | Where-Object { 
            $vhdxBase = $_.BaseName
            $vhdxExt = $_.Extension.ToLower()
            foreach ($pattern in $vhdxNamePatterns) {
                # Match exact name or pattern with either .vhdx or .vhd extension
                if ($vhdxBase -ieq $pattern -or $vhdxBase -like "*$pattern*") {
                    return $true
                }
                # Also check for pattern with extension variations
                if ($vhdxBase -like "*$pattern.vhdx" -or $vhdxBase -like "*$pattern.vhd") {
                    return $true
                }
            }
            return $false
        }) | Where-Object { $_ -ne $null })
        
        # If multiple matches or ambiguous, prompt user to select
        if (@($matchedVhdx).Count -gt 1) {
            Write-LabLog "Multiple VHDX/VHD files match OSKey '$OSKey'. Please select:" -Level Info
            $i = 1
            foreach ($media in $matchedVhdx) {
                Write-LabLog "  [$i] $($media.Name)" -Level Info
                $i++
            }
            $selection = Read-Host "Enter selection (1-$(@($matchedVhdx).Count))"
            if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le @($matchedVhdx).Count) {
                $cachedVhdx = $matchedVhdx[[int]$selection - 1]
            } else {
                $cachedVhdx = @($matchedVhdx)[0]  # Default to first if invalid input
            }
        } elseif (@($matchedVhdx).Count -eq 1) {
            $cachedVhdx = @($matchedVhdx)[0]
        } else {
            # No match found, check if we have any VHDX/VHD files or ISO files
            $isoRoot = Join-Path $MediaRoot 'ISO'
            $allIso = @()
            if (Test-Path $isoRoot) {
                $allIso = @() + (Get-ChildItem -Path $isoRoot -Filter "*.iso" -File -ErrorAction SilentlyContinue)
            }
            
            # Combine VHDX/VHD and ISO files for selection
            $allAvailableMedia = $allMedia + $allIso
            
            if ($allAvailableMedia.Count -gt 0) {
                # If a specific file was pre-selected via MediaSource, use it directly without prompting
                if ($LocalVhdxPath) {
                    $fileName = Split-Path $LocalVhdxPath -Leaf
                    Write-LabLog "Using pre-selected file for ${OSKey}: ${fileName}" -Level Info
                    $cachedVhdx = Get-Item $LocalVhdxPath
                } else {
                    # No pre-selection, prompt user to select from all available files (VHDX/VHD/ISO)
                    if ($allAvailableMedia.Count -gt 1) {
                        Write-LabLog "WARNING: No VHDX/VHD matched OSKey '$OSKey'. Available files:" -Level Info
                        $i = 1
                        foreach ($media in $allAvailableMedia) {
                            $kind = if ($media.Extension -eq '.iso') { 'ISO' } else { "$($media.Extension.TrimStart('.').ToUpper())" }
                            Write-LabLog "  [$i] ${kind}: $($media.Name)" -Level Info
                            $i++
                        }
                        $selection = Read-Host "Select file for $OSKey (1-$(@($allAvailableMedia).Count))"
                        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le @($allAvailableMedia).Count) {
                            $selected = @($allAvailableMedia)[[int]$selection - 1]
                            # If ISO, we'll use it directly; if VHDX/VHD, continue with existing logic
                            if ($selected.Extension -eq '.iso') {
                                Write-LabLog "Selected ISO file: $($selected.FullName)" -Level Info
                                $cachedIso = $selected
                            } else {
                                $cachedVhdx = $selected
                            }
                        } else {
                            # Default to first available file
                            $selected = @($allAvailableMedia)[0]
                            if ($selected.Extension -eq '.iso') {
                                Write-LabLog "Selected ISO file: $($selected.FullName)" -Level Info
                                $cachedIso = $selected
                            } else {
                                $cachedVhdx = $selected
                            }
                        }
                    } else {
                        # Only one file, use it with warning
                        $media = @($allAvailableMedia)[0]
                        $kind = if ($media.Extension -eq '.iso') { 'ISO' } else { "$($media.Extension.TrimStart('.').ToUpper())" }
                        Write-LabLog "WARNING: No VHDX/VHD matched OSKey '$OSKey'. Using available file: ${kind} - $($media.Name)" -Level Info
                        if ($media.Extension -eq '.iso') {
                            $cachedIso = $media
                        } else {
                            $cachedVhdx = $media
                        }
                    }
                }
            }
        }
    }
    
    if ($cachedVhdx) {
        Write-LabLog "Using cached golden image for $OSKey - $($cachedVhdx.FullName)" -Level Info
        # Check if this is a VHD file and we're using Gen 1
        $ext = [System.IO.Path]::GetExtension($cachedVhdx.FullName).ToLower()
        
        # Determine the correct destination path based on generation requirement
        if ($Generation -eq 1) {
            $destPath = Join-Path $vhdxRoot "$($cachedVhdx.BaseName).vhd"
        } else {
            $destPath = Join-Path $vhdxRoot "$($cachedVhdx.BaseName).vhdx"
        }
        
        # Check if conversion is needed
        if ($Generation -eq 1 -and $ext -eq '.vhd') {
            # Gen1 + VHD: use as-is
            return [pscustomobject]@{ OSKey = $OSKey; VhdPath = $cachedVhdx.FullName; MediaSource = 'CachedVhd' }
        } elseif ($Generation -eq 2 -and $ext -eq '.vhdx') {
            # Gen2 + VHDX: use as-is
            return [pscustomobject]@{ OSKey = $OSKey; VhdxPath = $cachedVhdx.FullName; MediaSource = 'CachedVhdx' }
        } else {
            # Conversion needed: VHD->VHDX (Gen2) or VHDX->VHD (Gen1)
            Write-LabLog "Converting $($ext.ToUpper()) to $([System.IO.Path]::GetExtension($destPath).ToUpper()) for Generation $Generation..." -Level Step
            
            # Only copy if source and destination are different
            if ($cachedVhdx.FullName -ne $destPath) {
                Convert-Vhd -Path $cachedVhdx.FullName -DestinationPath $destPath -Force -ErrorAction Stop
            } else {
                # Same file but need to rename extension (same format, just wrong extension)
                Copy-Item -Path $cachedVhdx.FullName -Destination $destPath -Force
            }
            
            # Return correct property based on generation
            if ($Generation -eq 1) {
                return [pscustomobject]@{ OSKey = $OSKey; VhdPath = $destPath; MediaSource = 'CachedVhd' }
            } else {
                return [pscustomobject]@{ OSKey = $OSKey; VhdxPath = $destPath; MediaSource = 'CachedVhdx' }
            }
        }
    }
    
    # Handle cached ISO if selected
    if ($cachedIso) {
        Write-LabLog "Using cached ISO for $OSKey - $($cachedIso.FullName)" -Level Info
        $isoPath = $cachedIso.FullName
        $mediaSourceLabel = 'CachedIso'
        
        # Check if Convert-WindowsImage is available (it should have been auto-downloaded above)
        if (-not (Get-Command Convert-WindowsImage -ErrorAction SilentlyContinue)) {
            Write-LabLog "WARNING: Convert-WindowsImage cmdlet not found. ISO files require this tool to convert to VHDX." -Level Warn
            Write-LabLog "To use ISO files, you need to install the Windows ADK or download Convert-WindowsImage.ps1:" -Level Info
            Write-LabLog "  - Windows ADK: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -Level Info
            Write-LabLog "  - Or run this script again to attempt automatic download" -Level Info
            throw "Convert-WindowsImage cmdlet is required to use ISO files as media source."
        }
        
        Write-LabLog "Inspecting $isoPath to select the right edition..." -Level Step
        $editionName = Resolve-LabIsoEdition -IsoPath $isoPath -OSKey $OSKey -PreferServerCore:$PreferServerCore
        Write-LabLog "Selected edition: $editionName" -Level Info

        if ($VhdSizeBytes -eq 0) {
            $VhdSizeBytes = if ($OSKey -like 'Server*') { 100GB } else { 80GB }
        }

        if (Test-Path $vhdxPath) { Remove-Item -Path $vhdxPath -Force }

        # Determine disk layout and format based on OS version
        $diskLayout = if ($useBIOSLayout) { 'BIOS' } else { 'UEFI' }
        $vhdFormat = if ($useBIOSLayout) { 'VHD' } else { 'VHDX' }
        
        Write-LabLog "Converting ISO to a $($VhdSizeBytes / 1GB)GB dynamic $vhdFormat (golden image, will be copied per-VM)..." -Level Step
        
        # Use BIOS layout for older Windows Server versions (2016/2019/2022) to avoid bcdboot.exe error 193
        # Newer versions (2025+) use UEFI layout
        Convert-WindowsImage -SourcePath $isoPath -Edition $editionName -VHDPath $vhdxPath -VHDFormat $vhdFormat -SizeBytes $VhdSizeBytes -DiskLayout $diskLayout -ErrorAction Stop | Out-Null
        
        # Check if the conversion actually succeeded by verifying the output file exists
        if (-not (Test-Path $vhdxPath)) {
            # Try to detect bcdboot.exe error 193 specifically
            $tempLogs = Join-Path $env:TEMP 'Convert-WindowsImage'
            if (Test-Path $tempLogs) {
                $latestLog = Get-ChildItem -Path $tempLogs -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latestLog) {
                    $logContent = Get-Content -Path (Join-Path $latestLog 'Convert-WindowsImage.log') -ErrorAction SilentlyContinue | Out-String
                    if ($logContent -match 'bcdboot.*failed|ERROR.*193') {
                        Write-LabLog "bcdboot.exe failed with error 193 (known issue on Windows 11 24H2+ with Secure Boot)" -Level Warn
                        Write-LabLog "This happens when converting older ISOs on hosts with Secure Boot enabled" -Level Info
                        Write-LabLog "Workaround: Temporarily disable Secure Boot in host UEFI firmware before running conversion, then re-enable." -Level Info
                    }
                }
            }
            throw "Convert-WindowsImage reported success but $vhdxPath was not created. Check the Convert-WindowsImage transcript in %TEMP% for details."
        }
        
        # Return correct property based on file format (VHD vs VHDX)
        Write-LabLog "Golden image ready for $OSKey - $vhdxPath" -Level Success
        if ($useBIOSLayout) {
            return [pscustomobject]@{ OSKey = $OSKey; VhdPath = $vhdxPath; MediaSource = $mediaSourceLabel }
        } else {
            return [pscustomobject]@{ OSKey = $OSKey; VhdxPath = $vhdxPath; MediaSource = $mediaSourceLabel }
        }
    }
    
    Write-LabLog "No cached VHDX found for $OSKey" -Level Info
    
    # Check for local ISO as fallback (no download - only use pre-downloaded files)
    if ($LocalIsoPath -and (Test-Path $LocalIsoPath)) {
        Write-LabLog "Using provided local ISO: $LocalIsoPath" -Level Step
        $isoPath = $LocalIsoPath
        $mediaSourceLabel = 'LocalIso'
        
        # Use ISO filename (without extension) as VHDX name when converting from ISO
        $isoBaseName = [System.IO.Path]::GetFileNameWithoutExtension($isoPath)
        $vhdxPath = Join-Path $vhdxRoot "$isoBaseName.vhdx"
    } else {
        throw "No cached VHDX found for $OSKey. Please place a cached VHDX/VHD file in the Media folder, or install Convert-WindowsImage to use ISO files."
    }

    Write-LabLog "Inspecting $isoPath to select the right edition..." -Level Step
    $editionName = Resolve-LabIsoEdition -IsoPath $isoPath -OSKey $OSKey -PreferServerCore:$PreferServerCore
    Write-LabLog "Selected edition: $editionName" -Level Info

    # Convert-WindowsImage must be available (from previous runs or manually installed)

    if ($VhdSizeBytes -eq 0) {
        $VhdSizeBytes = if ($OSKey -like 'Server*') { 100GB } else { 80GB }
    }

    if (Test-Path $vhdxPath) { Remove-Item -Path $vhdxPath -Force }

    # Determine disk layout and format based on OS version
    $diskLayout = if ($useBIOSLayout) { 'BIOS' } else { 'UEFI' }
    $vhdFormat = if ($useBIOSLayout) { 'VHD' } else { 'VHDX' }
    
    Write-LabLog "Converting ISO to a $($VhdSizeBytes / 1GB)GB dynamic $vhdFormat (golden image, will be copied per-VM)..." -Level Step
    
    # Use BIOS layout for older Windows Server versions (2016/2019/2022) to avoid bcdboot.exe error 193
    # Newer versions (2025+) use UEFI layout
    Convert-WindowsImage -SourcePath $isoPath -Edition $editionName -VHDPath $vhdxPath -VHDFormat $vhdFormat -SizeBytes $VhdSizeBytes -DiskLayout $diskLayout -ErrorAction Stop | Out-Null
    
    # Check if the conversion actually succeeded by verifying the output file exists
    if (-not (Test-Path $vhdxPath)) {
        # Try to detect bcdboot.exe error 193 specifically
        $tempLogs = Join-Path $env:TEMP 'Convert-WindowsImage'
        if (Test-Path $tempLogs) {
            $latestLog = Get-ChildItem -Path $tempLogs -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestLog) {
                $logContent = Get-Content -Path (Join-Path $latestLog 'Convert-WindowsImage.log') -ErrorAction SilentlyContinue | Out-String
                if ($logContent -match 'bcdboot.*failed|ERROR.*193') {
                    Write-LabLog "bcdboot.exe failed with error 193 (known issue on Windows 11 24H2+ with Secure Boot)" -Level Warn
                    Write-LabLog "This happens when converting older ISOs on hosts with Secure Boot enabled" -Level Info
                    Write-LabLog "Workaround: Temporarily disable Secure Boot in host UEFI firmware before running conversion, then re-enable." -Level Info
                }
            }
        }
        throw "Convert-WindowsImage reported success but $vhdxPath was not created. Check the Convert-WindowsImage transcript in %TEMP% for details."
    }

    # Return correct property based on file format (VHD vs VHDX)
    Write-LabLog "Golden image ready for $OSKey - $vhdxPath" -Level Success
    if ($useBIOSLayout) {
        return [pscustomobject]@{ OSKey = $OSKey; VhdPath = $vhdxPath; MediaSource = $mediaSourceLabel }
    } else {
        return [pscustomobject]@{ OSKey = $OSKey; VhdxPath = $vhdxPath; MediaSource = $mediaSourceLabel }
    }
}
'@

    'Scripts\03-New-LabVM.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a lab VM from a cached golden VHDX, with an injected unattend.xml so
    it boots straight past OOBE with no human interaction required.
.NOTES
    The golden VHDX produced by Get-WindowsMedia has NOT been sysprepped - it's
    simply an applied WIM image, exactly like what Setup leaves on disk right
    before the specialize pass. Booting it directly triggers the normal
    specialize + oobeSystem unattend passes on first boot, which is what the
    injected unattend.xml drives. This is the standard "thin VHD boot"
    deployment technique and avoids ever running the interactive Setup UI.
#>

Set-StrictMode -Version Latest

function New-LabUnattendXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [string] $AdminPlainTextPassword,
        [string] $TimeZone = 'UTC',
        [string] $Locale = 'en-US',
        [string] $CustomAdminName = '',
        [string] $CustomAdminPassword = ''
    )

    # NOTE ON THE PASSWORD: Windows unattend.xml only supports a reversible
    # obfuscation (Base64 of the password + a fixed suffix string) for
    # PlainText=false, which is NOT real encryption - anyone with the file can
    # recover it. We use PlainText=true here for clarity/simplicity and instead
    # treat the *file* as the secret: it is injected directly into the VHDX
    # (never transits the network) and a FirstLogonCommand deletes it from the
    # guest within seconds of first boot. Don't reuse these unattend.xml files
    # for anything beyond this one-time provisioning step.
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>$TimeZone</TimeZone>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>$Locale</InputLocale>
      <SystemLocale>$Locale</SystemLocale>
      <UILanguage>$Locale</UILanguage>
      <UserLocale>$Locale</UserLocale>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$AdminPlainTextPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
        <Password>
          <Value>$AdminPlainTextPassword</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c del /f /q C:\Windows\Panther\unattend.xml</CommandLine>
          <Description>Remove unattend.xml (contains the provisioning password)</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
}

function Set-LabDiskUnattend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DiskPath,
        [Parameter(Mandatory)] [string] $UnattendXmlContent
    )
    Write-LabLog "Mounting $DiskPath to inject unattend.xml..." -Level Info
    # Mount-VHD works for both .vhd and .vhdx files
    $disk = Mount-VHD -Path $DiskPath -Passthru -ErrorAction Stop | Get-Disk
    try {
        $osPartition = $disk | Get-Partition | Where-Object { $_.DriveLetter -and $_.Size -gt 5GB } | Select-Object -First 1
        if (-not $osPartition) {
            throw "Could not locate the Windows OS partition inside $DiskPath after mounting."
        }
        $pantherDir = "$($osPartition.DriveLetter):\Windows\Panther"
        if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
        $unattendPath = Join-Path $pantherDir 'unattend.xml'
        Set-Content -Path $unattendPath -Value $UnattendXmlContent -Encoding UTF8
        Write-LabLog "unattend.xml injected at $unattendPath" -Level Info
    } finally {
        Dismount-VHD -Path $DiskPath
    }
}

function New-LabVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $GoldenVhdxPath,
        [Parameter(Mandatory)] [string] $VMRoot,
        [Parameter(Mandatory)] [string] $SwitchName,
        [Parameter(Mandatory)] [securestring] $LocalAdminPassword,

        [switch] $Force,

        [int] $VCpuCount = 2,
        [uint64] $MemoryStartupBytes = 4GB,
        [uint64] $MemoryMinimumBytes = 1GB,
        [uint64] $MemoryMaximumBytes = 8GB,
        [switch] $IsWindows11,
        [string] $TimeZone = 'UTC',
        [string] $Locale = 'en-US',

        # VM Generation: 1 (BIOS/MBR, supports VHD/VHDX) or 2 (UEFI/GPT, VHDX only)
        # If not specified, auto-detect based on file extension (.vhd = Gen1, .vhdx = Gen2)
        [ValidateSet(1, 2)] [int] $Generation,
        [string] $CustomAdminName = '',
        [string] $CustomAdminPassword = '',

        # Leave these null/empty to let the VM pick up an address via DHCP instead.
        [string] $StaticIPAddress,
        [int] $StaticPrefixLength = 24,
        [string] $StaticGateway,
        [string[]] $StaticDnsServers
    )

    # Auto-detect VM generation based on file extension if not specified
    # VHD files = Generation 1 (BIOS/MBR), VHDX files = Generation 2 (UEFI/GPT)
    $sourceExt = [System.IO.Path]::GetExtension($GoldenVhdxPath).ToLower()
    if (-not $Generation) {
        $Generation = if ($sourceExt -eq '.vhd') { 1 } else { 2 }
        Write-LabLog "Auto-detected VM Generation $Generation from file extension '$sourceExt'" -Level Info
    }
    
    $vmDir = Join-Path $VMRoot $VMName
    $vhdDir = Join-Path $vmDir 'Virtual Hard Disks'
    New-Item -Path $vhdDir -ItemType Directory -Force | Out-Null
    
    # Use correct extension based on VM generation: Gen1=VHD, Gen2=VHDX
    $ext = if ($Generation -eq 1) { '.vhd' } else { '.vhdx' }
    $vmVhdxPath = Join-Path $vhdDir "$VMName$ext"
    
    if (Test-Path $vmVhdxPath) {
        if ($Force) {
            Write-LabLog "Removing existing file at $vmVhdxPath (-Force specified)..." -Level Info
            Remove-Item -Path $vmVhdxPath -Force | Out-Null
            
            # Also remove the VM if it exists
            $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if ($existingVM) {
                Write-LabLog "Removing existing VM '$VMName' (-Force specified)..." -Level Info
                Remove-VM -Name $VMName -Force | Out-Null
            }
        } else {
            throw "A file already exists at $vmVhdxPath - refusing to overwrite. Remove the existing VM/files first if you intend to recreate it."
        }
    }

    Write-LabLog "Copying golden image for '$VMName'..." -Level Step
    Copy-Item -Path $GoldenVhdxPath -Destination $vmVhdxPath -Force

    $plainPassword = (New-Object PSCredential('placeholder', $LocalAdminPassword)).GetNetworkCredential().Password
    $unattendXml = New-LabUnattendXml -ComputerName $VMName -AdminPlainTextPassword $plainPassword -TimeZone $TimeZone -Locale $Locale `
        -CustomAdminName $CustomAdminName -CustomAdminPassword $CustomAdminPassword
    Set-LabDiskUnattend -DiskPath $vmVhdxPath -UnattendXmlContent $unattendXml

    Write-LabLog "Creating VM '$VMName' (vCPU: $VCpuCount, Startup RAM: $($MemoryStartupBytes/1GB)GB, Generation: $Generation)..." -Level Step
    $vm = New-VM -Name $VMName -Generation $Generation -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vmVhdxPath -SwitchName $SwitchName -Path $VMRoot -ErrorAction Stop

    Set-VMProcessor -VMName $VMName -Count $VCpuCount -ErrorAction Stop
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $true -StartupBytes $MemoryStartupBytes -MinimumBytes $MemoryMinimumBytes -MaximumBytes $MemoryMaximumBytes -ErrorAction Stop
    # Generation 2 VMs use UEFI with Secure Boot; Generation 1 use BIOS
    if ($Generation -eq 2) {
        Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
    }
    Set-VM -Name $VMName -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -CheckpointType Disabled

    if ($IsWindows11) {
        Write-LabLog "Enabling vTPM for '$VMName' (required by Windows 11)..." -Level Info
        Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
        Enable-VMTPM -VMName $VMName
    }

    Write-LabLog "Starting '$VMName'..." -Level Step
    Start-VM -Name $VMName

    $localCred = New-Object PSCredential(".\Administrator", $LocalAdminPassword)
    Write-LabLog "Waiting for '$VMName' to finish unattended setup and become reachable via PowerShell Direct (this can take several minutes on first boot)..." -Level Info
    Wait-LabVMPowerShellDirect -VMName $VMName -Credential $localCred -TimeoutSeconds 1200

    # --- Gen1.0.0: Disable IPv6 on the lab adapter (faster DNS, simpler lab network) ---
    Write-LabLog "Disabling IPv6 on lab adapter inside '$VMName'..." -Level Info
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($adapter) {
            try {
                Disable-NetAdapterBinding -Name $adapter.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop
            } catch {
                Write-Warning "Could not disable IPv6 on '$($adapter.Name)': $($_.Exception.Message)"
            }
        }
    }

    if ($StaticIPAddress) {
        Write-LabLog "Configuring static IP $StaticIPAddress on '$VMName' via PowerShell Direct..." -Level Step
        Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
            param($ip, $prefix, $gw, $dns)
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
            if (-not $adapter) { throw 'No active network adapter found inside the guest.' }
            # Clear any DHCP-assigned address first so we don't end up with two.
            Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            if ($gw) {
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw -ErrorAction Stop | Out-Null
            } else {
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -ErrorAction Stop | Out-Null
            }
            if ($dns -and $dns.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns
            }
        } -ArgumentList $StaticIPAddress, $StaticPrefixLength, $StaticGateway, $StaticDnsServers
    }

    Write-LabLog "'$VMName' is up and reachable." -Level Success
    
    # --- Time synchronization configuration ---
    Write-LabLog "Configuring time synchronization for '$VMName'..." -Level Info
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        # Configure W32Time service to sync from DC
        & w32tm /config /syncfromflags:DOMHIER /update | Out-Null
        Restart-Service -Name W32Time -ErrorAction SilentlyContinue
        & w32tm /resync | Out-Null
    }
    
    return [pscustomobject]@{
        Name        = $VMName
        IPAddress   = $StaticIPAddress
        VhdxPath    = $vmVhdxPath
    }
}
'@

    'Scripts\04-Install-PrimaryDC.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Promotes a freshly-created VM into the forest root domain controller.
.NOTES
    The new forest's own DC always runs DNS (-InstallDns), regardless of whether
    you also chose to stand up a separate dedicated DNS server elsewhere - a new
    AD forest needs its own authoritative DNS zone for SRV records, full stop.
    "Separate DNS" in this toolkit means an *additional* DNS server (see
    08-Install-DnsServer.ps1) that holds a secondary copy of the zone for
    redundancy/offload, not a replacement for the DC's own DNS.
#>

Set-StrictMode -Version Latest

function Confirm-LabDCDnsRegistration {
    <#
        Gen1.0.0: Verifies and repairs DNS registration on a freshly-promoted DC.
        Fixes the "ping lab.local fails on a fresh DC" bug where Netlogon
        occasionally fails to register the zone apex A record. Total worst
        case ~35s in-guest + up to 60s for the final resolvable poll.
        Also creates reverse lookup zones for proper DNS functionality.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $DomainCredential,
        [Parameter(Mandatory)] [string] $DomainName,
        [Parameter(Mandatory)] [string] $DCIPAddress
    )

    Write-LabLog "Verifying '$VMName' DNS registration for '$DomainName' (apex A + SRV records)..." -Level Step

    $report = Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        param($domain, $dcIp)

        $r = [ordered]@{ ApexBefore = $null; ApexAfter = $null; ApexCreated = $false; NetlogonOk = $false; ReverseZoneCreated = $false; ZoneCreated = $false }

        # 1. Pin DNS client to self first (Netlogon races DNS Server otherwise).
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($adapter) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('127.0.0.1', $dcIp)
        }

        # 2. Wait for DNS Server service to be ready
        Write-Host "Waiting for DNS Server service..." -ForegroundColor Cyan
        $maxRetries = 30
        $retryCount = 0
        while ($retryCount -lt $maxRetries) {
            try {
                $dnsService = Get-Service -Name DNS -ErrorAction Stop
                if ($dnsService.Status -eq 'Running') {
                    Write-Host "DNS Server service is running." -ForegroundColor Green
                    break
                }
            } catch {
                # Service not ready yet
            }
            Start-Sleep -Seconds 5
            $retryCount++
        }

        # 3. Wait for AD DS sync to complete (DNS Server service is waiting for this)
        Write-Host "Waiting for AD DS initial synchronization..." -ForegroundColor Cyan
        $maxSyncRetries = 30
        $syncCount = 0
        while ($syncCount -lt $maxSyncRetries) {
            try {
                # Check if AD DS is synchronized by looking for the NTDS settings
                $ntdsSettings = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -ErrorAction Stop
                if ($ntdsSettings) {
                    # Additional check: verify DNS Server can actually query zones
                    # This ensures the AD DS database is fully loaded
                    $testZone = Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue
                    if ($testZone -or (Get-DnsServerZone -Name "$domain" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
                        Write-Host "AD DS synchronization complete." -ForegroundColor Green
                        break
                    } else {
                        Write-Host "AD DS still loading DNS database..." -ForegroundColor Cyan
                    }
                }
            } catch {
                # AD DS not ready yet
            }
            Start-Sleep -Seconds 10
            $syncCount++
        }
        
        # 4. Check if zone exists, create if not (retry if DNS is still syncing)
        $zone = Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue
        if (-not $zone) {
            Write-Host "Zone '$domain' not found, creating..." -ForegroundColor Cyan
            $maxZoneRetries = 30
            $zoneRetry = 0
            while ($zoneRetry -lt $maxZoneRetries) {
                try {
                    Add-DnsServerPrimaryZone -Name $domain -ReplicationScope "Forest" -ErrorAction Stop
                    $r.ZoneCreated = $true
                    Write-Host "Created DNS zone: $domain" -ForegroundColor Green
                    break
                } catch {
                    $errorMessage = $_.Exception.Message
                    # Check if the error is due to AD DS still syncing (common on first boot)
                    if ($errorMessage -match "AD DS is still initializing" -or 
                        $errorMessage -match "directory service is not ready" -or
                        $errorMessage -match "The directory service is unavailable") {
                        $zoneRetry++
                        if ($zoneRetry -lt $maxZoneRetries) {
                            Write-Host "AD DS still initializing, retrying zone creation... ($zoneRetry/$maxZoneRetries)" -ForegroundColor Yellow
                            Start-Sleep -Seconds 20
                        } else {
                            Write-Host "WARNING: Could not create zone '$domain': $errorMessage" -ForegroundColor Yellow
                        }
                    } else {
                        # Different error, don't retry
                        Write-Host "WARNING: Could not create zone '$domain': $errorMessage" -ForegroundColor Yellow
                        break
                    }
                }
            }
        }

        # 4. Snapshot apex record state BEFORE repair.
        $r.ApexBefore = (Get-DnsServerResourceRecord -ZoneName $domain -Name '@' -RRType A -ErrorAction SilentlyContinue |
            ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString }) -join ','

        # 5. Force Netlogon to re-register SRV/glue records.
        try {
            Restart-Service -Name Netlogon -Force -ErrorAction Stop
            $r.NetlogonOk = $true
        } catch { }
        Start-Sleep -Seconds 10
        & ipconfig /registerdns | Out-Null
        Start-Sleep -Seconds 20

        # 6. Re-check apex. If still missing, create explicitly.
        $apex = Get-DnsServerResourceRecord -ZoneName $domain -Name '@' -RRType A -ErrorAction SilentlyContinue
        if (-not $apex) {
            Add-DnsServerResourceRecordA -ZoneName $domain -Name '@' -IPv4Address $dcIp -ErrorAction Stop
            $r.ApexCreated = $true
        }

        $r.ApexAfter = (Get-DnsServerResourceRecord -ZoneName $domain -Name '@' -RRType A -ErrorAction SilentlyContinue |
            ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString }) -join ','

        # 7. Create reverse lookup zone if it doesn't exist (retry if DNS is still syncing)
        $ipParts = $dcIp.Split('.')
        if ($ipParts.Count -eq 4) {
            # Create reverse zone for the /24 subnet (most common lab setup)
            $reverseZoneName = "$($ipParts[2]).$($ipParts[1]).$($ipParts[0]).in-addr.arpa"
            $existingReverse = Get-DnsServerZone -Name $reverseZoneName -ErrorAction SilentlyContinue
            if (-not $existingReverse) {
                $maxZoneRetries = 30
                $zoneRetry = 0
                while ($zoneRetry -lt $maxZoneRetries) {
                    try {
                        Add-DnsServerPrimaryZone -Name $reverseZoneName -ReplicationScope "Forest" -ErrorAction Stop
                        $r.ReverseZoneCreated = $true
                        Write-Host "Created reverse lookup zone: $reverseZoneName" -ForegroundColor Green
                        break
                    } catch {
                        $errorMessage = $_.Exception.Message
                        # Check if the error is due to AD DS still syncing
                        if ($errorMessage -match "AD DS is still initializing" -or 
                            $errorMessage -match "directory service is not ready" -or
                            $errorMessage -match "The directory service is unavailable") {
                            $zoneRetry++
                            if ($zoneRetry -lt $maxZoneRetries) {
                                Write-Host "AD DS still initializing, retrying reverse zone creation... ($zoneRetry/$maxZoneRetries)" -ForegroundColor Yellow
                                Start-Sleep -Seconds 20
                            } else {
                                Write-Host "WARNING: Could not create reverse zone '$reverseZoneName': $errorMessage" -ForegroundColor Yellow
                            }
                        } else {
                            # Different error, don't retry
                            Write-Host "WARNING: Could not create reverse zone '$reverseZoneName': $errorMessage" -ForegroundColor Yellow
                            break
                        }
                    }
                }
            }
        }

        return [pscustomobject]$r
    } -ArgumentList $DomainName, $DCIPAddress

    # 6. Final gate: actually verify resolution works (60s short poll).
    Wait-LabDomainResolvable -VMName $VMName -Credential $DomainCredential -DomainName $DomainName -TimeoutSeconds 60

    Write-LabLog "DNS registration confirmed on '$VMName': apex A = $($report.ApexAfter) (manual create: $($report.ApexCreated), Netlogon ok: $($report.NetlogonOk), reverse zone: $($report.ReverseZoneCreated))" -Level Success
    return $report
}

function Install-PrimaryDomainController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [securestring] $LocalAdminPassword,
        [Parameter(Mandatory)] [string] $DomainName,
        [Parameter(Mandatory)] [string] $NetBIOSName,
        [Parameter(Mandatory)] [securestring] $SafeModeAdministratorPassword,
        [Parameter(Mandatory)] [ValidateSet('Win2016', 'Win2019', 'Win2022', 'Win2025')] [string] $ForestMode,
        [Parameter(Mandatory)] [string] $DCIPAddress
    )
    
    # Map internal OSKey to valid ForestMode values for Install-ADDSForest
    # Valid enum values: Win2008, Win2008R2, Win2012, Win2012R2, WinThreshold, Win2025, Default
    $forestModeMap = @{
        'Win2016' = 'WinThreshold'
        'Win2019' = 'WinThreshold'
        'Win2022' = 'WinThreshold'
        'Win2025' = 'Win2025'
    }
    $validForestMode = $forestModeMap[$ForestMode]

    $localCred = New-Object PSCredential(".\Administrator", $LocalAdminPassword)

    Write-LabLog "Waiting for '$VMName' to be ready before promoting to DC..." -Level Info
    Wait-LabVMPowerShellDirect -VMName $VMName -Credential $localCred -TimeoutSeconds 600

    # --- Check if already promoted to avoid re-installing AD DS ---
    Write-LabLog "Checking if '$VMName' is already promoted to domain controller..." -Level Info
    $isDC = Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        return ($cs.DomainRole -ge 4)
    }
    if ($isDC) {
        Write-LabLog "'$VMName' is already a domain controller (DomainRole: $isDC) - skipping promotion." -Level Info
        return $null
    }

    Write-LabLog "Installing AD DS binaries on '$VMName'..." -Level Step
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        Install-WindowsFeature -Name AD-Domain-Services, RSAT-ADDS-Tools -IncludeManagementTools -ErrorAction Stop | Out-Null
    }

    Write-LabLog "Promoting '$VMName' to forest root DC for '$DomainName' (NetBIOS: $NetBIOSName, mode: $ForestMode). This formats SYSVOL/NTDS and will take several minutes..." -Level Step
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        param($domainName, $netbiosName, $safeModePw, $forestMode, $validForestMode)
        Import-Module ADDSDeployment -ErrorAction Stop
        
        # Install AD DS with DNS - DNS zone will be created after AD DS sync completes
        Install-ADDSForest `
            -DomainName $domainName `
            -DomainNetbiosName $netbiosName `
            -SafeModeAdministratorPassword $safeModePw `
            -InstallDns:$true `
            -ForestMode $validForestMode `
            -DomainMode $validForestMode `
            -NoRebootOnCompletion:$true `
            -Force:$true `
            -ErrorAction Stop | Out-Null
    } -ArgumentList $DomainName, $NetBIOSName, $SafeModeAdministratorPassword, $ForestMode, $validForestMode

    Write-LabLog "Promotion command completed without error - restarting '$VMName' to finish becoming a domain controller..." -Level Info
    Restart-VM -Name $VMName -Force -Confirm:$false

    # After this reboot the local Administrator account IS the Domain
    # Administrator account (same SID, same password) - so the credential
    # we use to validate readiness changes from a local to a domain identity.
    $domainCred = New-Object PSCredential("$NetBIOSName\Administrator", $LocalAdminPassword)
    Wait-LabVMRestart -VMName $VMName -Credential $domainCred -TimeoutSeconds 1200

    # --- Gen1.0.0: Verify (and repair if needed) DNS registration before declaring DC ready ---
    # Retry DNS verification with delays to allow DNS zone creation to complete
    $maxDnsRetries = 3
    $dnsRetryCount = 0
    $dnsSuccess = $false
    while ($dnsRetryCount -lt $maxDnsRetries -and -not $dnsSuccess) {
        try {
            $dnsResult = Confirm-LabDCDnsRegistration -VMName $VMName -DomainCredential $domainCred -DomainName $DomainName -DCIPAddress $DCIPAddress -ErrorAction Stop
            $dnsSuccess = $true
        } catch {
            $dnsRetryCount++
            if ($dnsRetryCount -lt $maxDnsRetries) {
                Write-LabLog "DNS verification failed (attempt $dnsRetryCount/$maxDnsRetries), retrying in 30 seconds..." -Level Warn
                Start-Sleep -Seconds 30
            } else {
                Write-LabLog "DNS verification failed after $maxDnsRetries attempts: $($_.Exception.Message)" -Level Error
                throw $_
            }
        }
    }

    Write-LabLog "'$VMName' is now the forest root domain controller for $DomainName." -Level Success
    return [pscustomobject]@{
        VMName        = $VMName
        DomainName    = $DomainName
        NetBIOSName   = $NetBIOSName
        DomainCredential = $domainCred
    }
}
'@

    'Scripts\05-Install-AdditionalDC.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Joins an existing forest as an additional domain controller.
.NOTES
    Install-ADDSDomainController requires the target computer to already be
    domain-joined - unlike Install-ADDSForest, it does not join and promote in
    one step. So this script does it in the textbook two-step order:
    Add-Computer (join) -> reboot -> Install-ADDSDomainController (promote).

    Precondition: the VM was created with its DNS client already pointed at an
    existing, working DC (New-LabVM -StaticDnsServers), so domain name
    resolution works before the join is attempted.
#>

Set-StrictMode -Version Latest

function Install-AdditionalDomainController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [securestring] $LocalAdminPassword,
        [Parameter(Mandatory)] [string] $DomainName,
        [Parameter(Mandatory)] [pscredential] $DomainCredential,
        [Parameter(Mandatory)] [securestring] $SafeModeAdministratorPassword,
        [Parameter(Mandatory)] [string] $DCIPAddress
    )

    $localCred = New-Object PSCredential(".\Administrator", $LocalAdminPassword)

    Write-LabLog "Waiting for '$VMName' to be ready..." -Level Info
    Wait-LabVMPowerShellDirect -VMName $VMName -Credential $localCred -TimeoutSeconds 600

    Write-LabLog "Verifying '$VMName' can resolve '$DomainName' before attempting to join..." -Level Info
    $canResolve = Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        param($domainName)
        [bool](Resolve-DnsName -Name $domainName -ErrorAction SilentlyContinue)
    } -ArgumentList $DomainName
    if (-not $canResolve) {
        throw "'$VMName' cannot resolve '$DomainName'. Check that its DNS client is pointed at an existing, working domain controller before promoting it."
    }

    Write-LabLog "Installing AD DS binaries on '$VMName'..." -Level Step
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        Install-WindowsFeature -Name AD-Domain-Services, RSAT-ADDS-Tools -IncludeManagementTools -ErrorAction Stop | Out-Null
    }

    Write-LabLog "Joining '$VMName' to '$DomainName'..." -Level Step
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        param($domainName, $domainCred)
        Add-Computer -DomainName $domainName -Credential $domainCred -Restart:$false -Force -ErrorAction Stop
    } -ArgumentList $DomainName, $DomainCredential

    Write-LabLog "Restarting '$VMName' to complete the domain join..." -Level Info
    Restart-VM -Name $VMName -Force -Confirm:$false
    Wait-LabVMRestart -VMName $VMName -Credential $DomainCredential -TimeoutSeconds 900

    Write-LabLog "Promoting '$VMName' to an additional domain controller for '$DomainName'. This replicates AD/SYSVOL and will take several minutes..." -Level Step
    Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        param($domainName, $safeModePw)
        Import-Module ADDSDeployment -ErrorAction Stop
        
        # Install ADDSDomainController with DNS
        # DNS zone will be created after AD DS sync completes (on first reboot)
        Install-ADDSDomainController `
            -DomainName $domainName `
            -SafeModeAdministratorPassword $safeModePw `
            -InstallDns:$true `
            -NoRebootOnCompletion:$true `
            -Force:$true `
            -ErrorAction Stop | Out-Null
    } -ArgumentList $DomainName, $SafeModeAdministratorPassword

    Write-LabLog "Promotion command completed without error - restarting '$VMName' to finish becoming a domain controller..." -Level Info
    Restart-VM -Name $VMName -Force -Confirm:$false
    Wait-LabVMRestart -VMName $VMName -Credential $DomainCredential -TimeoutSeconds 1200

    # --- Verify DNS registration for additional DC ---
    Write-LabLog "Verifying '$VMName' DNS registration for '$DomainName'..." -Level Step
    $dnsResult = Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        param($domain, $dcIp)
        
        # Wait for DNS Server service
        Write-Host "Waiting for DNS Server service..." -ForegroundColor Cyan
        $maxRetries = 20
        $retryCount = 0
        while ($retryCount -lt $maxRetries) {
            try {
                $dnsService = Get-Service -Name DNS -ErrorAction Stop
                if ($dnsService.Status -eq 'Running') {
                    Write-Host "DNS Server service is running." -ForegroundColor Green
                    break
                }
            } catch { }
            Start-Sleep -Seconds 3
            $retryCount++
        }
        
        # Wait for AD DS sync to complete
        Write-Host "Waiting for AD DS initial synchronization..." -ForegroundColor Cyan
        $maxSyncRetries = 30
        $syncCount = 0
        while ($syncCount -lt $maxSyncRetries) {
            try {
                $ntdsSettings = Get-Item "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -ErrorAction Stop
                if ($ntdsSettings) {
                    # Additional check: verify DNS Server can actually query zones
                    $testZone = Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue
                    if ($testZone -or (Get-DnsServerZone -Name "$domain" -ErrorAction SilentlyContinue -WarningAction SilentlyContinue)) {
                        Write-Host "AD DS synchronization complete." -ForegroundColor Green
                        break
                    } else {
                        Write-Host "AD DS still loading DNS database..." -ForegroundColor Cyan
                    }
                }
            } catch {
                # AD DS not ready yet
            }
            Start-Sleep -Seconds 10
            $syncCount++
        }
        
        # Check if zone exists, create if not (retry if DNS is still syncing)
        $zone = Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue
        if (-not $zone) {
            Write-Host "Zone '$domain' not found, creating..." -ForegroundColor Cyan
            $maxZoneRetries = 30
            $zoneRetry = 0
            while ($zoneRetry -lt $maxZoneRetries) {
                try {
                    Add-DnsServerPrimaryZone -Name $domain -ReplicationScope "Forest" -ErrorAction Stop
                    Write-Host "Created DNS zone: $domain" -ForegroundColor Green
                    
                    # Create apex A record
                    Start-Sleep -Seconds 5
                    Add-DnsServerResourceRecordA -Name '@' -ZoneName $domain -IPv4Address $dcIp -CreatePtr:$true -ErrorAction Stop
                    Write-Host "Apex A record created for $domain -> $dcIp" -ForegroundColor Green
                    break
                } catch {
                    $errorMessage = $_.Exception.Message
                    # Check if the error is due to AD DS still syncing
                    if ($errorMessage -match "AD DS is still initializing" -or 
                        $errorMessage -match "directory service is not ready" -or
                        $errorMessage -match "The directory service is unavailable") {
                        $zoneRetry++
                        if ($zoneRetry -lt $maxZoneRetries) {
                            Write-Host "AD DS still initializing, retrying zone creation... ($zoneRetry/$maxZoneRetries)" -ForegroundColor Yellow
                            Start-Sleep -Seconds 20
                        } else {
                            Write-Host "WARNING: Could not create zone: $errorMessage" -ForegroundColor Yellow
                        }
                    } else {
                        # Different error, don't retry
                        Write-Host "WARNING: Could not create zone: $errorMessage" -ForegroundColor Yellow
                        break
                    }
                }
            }
        } else {
            Write-Host "DNS zone '$domain' already exists." -ForegroundColor Green
        }
        
        # Return whether zone exists now
        return [bool](Get-DnsServerZone -Name $domain -ErrorAction SilentlyContinue)
    } -ArgumentList $DomainName, $DCIPAddress
    
    if (-not $dnsResult) {
        Write-LabLog "WARNING: DNS zone '$DomainName' not found on '$VMName' after verification." -Level Info
    } else {
        Write-LabLog "DNS zone '$DomainName' verified on '$VMName'." -Level Success
    }

    Write-LabLog "'$VMName' is now an additional domain controller for $DomainName." -Level Success
    return [pscustomobject]@{ VMName = $VMName; DomainName = $DomainName }
}
'@

    'Scripts\06-Join-Domain.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Joins a non-DC VM (member server or workstation) to the lab domain.
.NOTES
    These VMs get their IP/DNS from the lab's DHCP server (Option 006 points
    them at the DC), so by the time this runs they should already be able to
    resolve the domain - this just verifies that before joining.
#>

Set-StrictMode -Version Latest

function Add-LabComputerToDomain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [securestring] $LocalAdminPassword,
        [Parameter(Mandatory)] [string] $DomainName,
        [Parameter(Mandatory)] [pscredential] $DomainCredential,
        [string] $TargetOUDistinguishedName
    )

    $localCred = New-Object PSCredential(".\Administrator", $LocalAdminPassword)

    Write-LabLog "Verifying '$VMName' can resolve '$DomainName' (polls up to 60s)..." -Level Info
    Wait-LabDomainResolvable -VMName $VMName -Credential $localCred -DomainName $DomainName -TimeoutSeconds 60

    Write-LabLog "Joining '$VMName' to '$DomainName'..." -Level Step
    Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
        param($domainName, $domainCred, $ouPath)
        $params = @{
            DomainName  = $domainName
            Credential  = $domainCred
            Restart     = $false
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($ouPath) { $params['OUPath'] = $ouPath }
        Add-Computer @params
    } -ArgumentList $DomainName, $DomainCredential, $TargetOUDistinguishedName

    Write-LabLog "Restarting '$VMName' to complete the domain join..." -Level Info
    Restart-VM -Name $VMName -Force -Confirm:$false
    Wait-LabVMRestart -VMName $VMName -Credential $DomainCredential -TimeoutSeconds 600

    Write-LabLog "'$VMName' has joined $DomainName." -Level Success
    return [pscustomobject]@{ VMName = $VMName; DomainName = $DomainName }
}
'@

    'Scripts\07-Install-DhcpServer.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the DHCP Server role on a domain-joined VM and configures a scope.
#>

Set-StrictMode -Version Latest

function Install-LabDhcpServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $DomainCredential,
        [Parameter(Mandatory)] [string] $ServerIPAddress,   # this DHCP server's own IP, used for AD authorization

        [Parameter(Mandatory)] [string] $ScopeId,            # network address, e.g. 192.168.50.0
        [Parameter(Mandatory)] [string] $ScopeName,
        [Parameter(Mandatory)] [string] $ScopeStartRange,
        [Parameter(Mandatory)] [string] $ScopeEndRange,
        [Parameter(Mandatory)] [string] $ScopeSubnetMask,
        [Parameter(Mandatory)] [string] $ScopeRouter,
        [Parameter(Mandatory)] [string[]] $DnsServers,
        [string] $DnsDomainName = "",
        [int] $LeaseDurationDays = 8,
        [switch] $SkipADAuthorization
    )

    Write-LabLog "Waiting for '$VMName' to be ready..." -Level Info
    Wait-LabVMPowerShellDirect -VMName $VMName -Credential $DomainCredential -TimeoutSeconds 600

    Write-LabLog "Installing DHCP Server role on '$VMName'..." -Level Step
    Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        if (-not (Get-WindowsFeature -Name DHCP).Installed) {
            Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop | Out-Null
        }
        # Creates the local DHCP Administrators / DHCP Users groups the service expects.
        try { Add-DhcpServerSecurityGroup -ErrorAction Stop } catch { }
        Restart-Service -Name DHCPServer -Force -ErrorAction SilentlyContinue
        
        # Wait for DHCP service to be fully initialized
        $maxRetries = 20
        $retryCount = 0
        while ($retryCount -lt $maxRetries) {
            try {
                $dhcpService = Get-Service -Name DHCPServer -ErrorAction Stop
                if ($dhcpService.Status -eq 'Running') {
                    # Verify DHCP service is responding
                    $scope = Get-DhcpServerV4Scope -ErrorAction SilentlyContinue
                    if ($scope -ne $null -or (Get-Command Get-DhcpServerV4Scope -ErrorAction SilentlyContinue)) {
                        break
                    }
                }
            } catch { }
            Start-Sleep -Seconds 3
            $retryCount++
        }
    }

    if (-not $SkipADAuthorization) {
        Write-LabLog "Authorizing '$VMName' as a DHCP server in Active Directory..." -Level Step
        Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
            param($ip)
            $fqdn = "$($env:COMPUTERNAME).$((Get-CimInstance -ClassName Win32_ComputerSystem).Domain)"
            
            # Retry authorization with AD DS initialization detection
            $maxRetries = 10
            $retryCount = 0
        while ($retryCount -lt $maxRetries) {
            try {
                $already = Get-DhcpServerInDC -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $ip }
                if (-not $already) {
                    Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ip -ErrorAction Stop
                }
                break
            } catch {
                $errorMessage = $_.Exception.Message
                # Check if error is due to AD DS still initializing
                if ($errorMessage -match "directory service is not ready" -or 
                    $errorMessage -match "The directory service is unavailable" -or
                    $errorMessage -match "DHCP 20070" -or
                    $errorMessage -match "Failed to initialize directory service resources") {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Host "AD DS still initializing, retrying DHCP authorization... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        Start-Sleep -Seconds 15
                    } else {
                        Write-Host "WARNING: Could not authorize DHCP server: $errorMessage" -ForegroundColor Yellow
                        throw $_
                    }
                } else {
                    # Different error, don't retry
                    Write-Host "WARNING: Could not authorize DHCP server: $errorMessage" -ForegroundColor Yellow
                    throw $_
                }
            }
        }
    } -ArgumentList $ServerIPAddress
    }

    Write-LabLog "Creating/updating DHCP scope '$ScopeName' ($ScopeStartRange - $ScopeEndRange)..." -Level Step
    Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        param($scopeId, $scopeName, $start, $end, $mask, $router, $dnsServers, $dnsDomain, $leaseDays)

        # Retry scope creation with AD DS initialization detection
        $maxRetries = 10
        $retryCount = 0
        while ($retryCount -lt $maxRetries) {
            try {
                $existingScope = Get-DhcpServerV4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
                if (-not $existingScope) {
                    Add-DhcpServerV4Scope -Name $scopeName -StartRange $start -EndRange $end -SubnetMask $mask -State Active -ErrorAction Stop
                } else {
                    Set-DhcpServerV4Scope -ScopeId $scopeId -Name $scopeName -State Active -ErrorAction Stop
                }

                # In workgroup mode, DnsDomain is empty (no domain)
                if ([string]::IsNullOrEmpty($dnsDomain)) {
                    Set-DhcpServerV4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dnsServers -ErrorAction Stop
                } else {
                    Set-DhcpServerV4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dnsServers -DnsDomain $dnsDomain -ErrorAction Stop
                }
                Set-DhcpServerV4Scope -ScopeId $scopeId -LeaseDuration ([TimeSpan]::FromDays($leaseDays)) -ErrorAction Stop
                break
            } catch {
                $errorMessage = $_.Exception.Message
                # Check if error is due to AD DS still initializing
                if ($errorMessage -match "directory service is not ready" -or 
                    $errorMessage -match "The directory service is unavailable" -or
                    $errorMessage -match "DHCP 20070" -or
                    $errorMessage -match "Failed to initialize directory service resources") {
                    $retryCount++
                    if ($retryCount -lt $maxRetries) {
                        Write-Host "AD DS still initializing, retrying DHCP scope configuration... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        Start-Sleep -Seconds 15
                    } else {
                        Write-Host "WARNING: Could not configure DHCP scope: $errorMessage" -ForegroundColor Yellow
                        throw $_
                    }
                } else {
                    # Different error, don't retry
                    Write-Host "WARNING: Could not configure DHCP scope: $errorMessage" -ForegroundColor Yellow
                    throw $_
                }
            }
        }
    } -ArgumentList $ScopeId, $ScopeName, $ScopeStartRange, $ScopeEndRange, $ScopeSubnetMask, $ScopeRouter, $DnsServers, $DnsDomainName, $LeaseDurationDays

    Write-LabLog "DHCP scope ready on '$VMName' ($ScopeStartRange - $ScopeEndRange, gateway $ScopeRouter, DNS $($DnsServers -join ', '))." -Level Success
    return [pscustomobject]@{ VMName = $VMName; ScopeId = $ScopeId }
}
'@

    'Scripts\08-Install-DnsServer.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Configures a non-DC VM as a dedicated DNS server holding a secondary copy
    of the AD zone, for labs that want DNS split out from the domain
    controller rather than purely AD-integrated.
.NOTES
    A new forest's own DC always hosts the authoritative, AD-integrated copy
    of the zone (see 04-Install-PrimaryDC.ps1) - that isn't optional, AD needs
    it. What this script adds is a secondary, file-based copy on a separate
    server via standard DNS zone transfer, which is the closest faithful
    equivalent to "DNS on its own box" that still keeps AD fully functional.
    Zone transfer here uses -SecureSecondaries TransferAnyServer for
    simplicity, which is fine for an isolated lab but not something to carry
    into production without tightening to specific secondary IPs.
#>

Set-StrictMode -Version Latest

function Install-LabDnsServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $DomainCredential,
        [Parameter(Mandatory)] [string] $PrimaryDCVMName,
        [Parameter(Mandatory)] [string] $PrimaryDCIPAddress,
        [Parameter(Mandatory)] [string] $ZoneName,
        [string[]] $ForwarderIPAddresses = @('1.1.1.1', '8.8.8.8')
    )

    Write-LabLog "Waiting for '$VMName' to be ready..." -Level Info
    Wait-LabVMPowerShellDirect -VMName $VMName -Credential $DomainCredential -TimeoutSeconds 600

    Write-LabLog "Allowing zone transfer of '$ZoneName' from '$PrimaryDCVMName'..." -Level Step
    Invoke-Command -VMName $PrimaryDCVMName -Credential $DomainCredential -ScriptBlock {
        param($zoneName)
        Set-DnsServerPrimaryZone -Name $zoneName -SecureSecondaries TransferAnyServer -Notify Notify -ErrorAction Stop
    } -ArgumentList $ZoneName

    Write-LabLog "Installing DNS Server role on '$VMName'..." -Level Step
    Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        if (-not (Get-WindowsFeature -Name DNS).Installed) {
            Install-WindowsFeature -Name DNS -IncludeManagementTools -ErrorAction Stop | Out-Null
        }
    }

    Write-LabLog "Configuring '$VMName' as a secondary for '$ZoneName' (master: $PrimaryDCIPAddress) and setting forwarders..." -Level Step
    Invoke-Command -VMName $VMName -Credential $DomainCredential -ScriptBlock {
        param($zoneName, $masterIp, $forwarders)

        $existingZone = Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue
        if (-not $existingZone) {
            Add-DnsServerSecondaryZone -Name $zoneName -MasterServers $masterIp -ZoneFile "$zoneName.dns" -ErrorAction Stop
        }

        Set-DnsServerForwarder -IPAddress $forwarders -ErrorAction Stop
    } -ArgumentList $ZoneName, $PrimaryDCIPAddress, $ForwarderIPAddresses

    Write-LabLog "'$VMName' is now serving a secondary copy of '$ZoneName'." -Level Success
    return [pscustomobject]@{ VMName = $VMName; ZoneName = $ZoneName }
}
'@

    'Scripts\09-Scan-LabMedia.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Discovers existing Windows media (ISO and VHDX) inside the lab so a re-run
    can reuse it instead of re-downloading / re-converting.
.DESCRIPTION
    Two kinds of media are scanned:
      - ISOs  under Media\ISO\      -> editions read via Mount-DiskImage + Get-WindowsImage
      - VHDXs under Media\VHDX\ and VMs\<name>\ -> edition read by mounting read-only and
        querying the offline SOFTWARE registry hive via reg.exe (the PowerShell registry
        provider leaks a handle that prevents reg unload, so we deliberately shell out).

    Each discovered item is mapped back to the toolkit's OSKey vocabulary
    (Win11Pro, Server2022, ...) so Invoke-LabMediaSelection can auto-match VMs to
    the best cached item by edition.

    IMPORTANT: every mount / load is wrapped in try/finally so a VHDX is never
    left attached (which would block the next VM creation) if anything throws.
#>

Set-StrictMode -Version Latest

# Raw registry/string value -> toolkit OSKey. Centralized so both ISO and VHDX
# detection funnel through the same mapping. Returns $null if the edition can't
# be confidently classified (caller then offers it as an "unknown" pick).
function ConvertTo-LabOSKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $EditionID,      # e.g. 'Professional', 'ServerDatacenter'
        [Parameter(Mandatory)] [string] $ProductName,    # e.g. 'Windows 11 Pro' / 'Windows Server 2022 Datacenter'
        [Parameter(Mandatory)] [string] $InstallationType # 'Client' | 'Server' | 'Server Core'
    )

    $isServer = $InstallationType -match 'Server'

    if (-not $isServer) {
        # Client SKU: figure out 10 vs 11 from ProductName, then Pro/Enterprise from edition.
        $isWin11 = $ProductName -match 'Windows 11|Windows11'
        $isPro        = $EditionID -match 'Pro'        -or $ProductName -match '\bPro\b'
        $isEnterprise = $EditionID -match 'Enterprise' -or $ProductName -match 'Enterprise'
        if     ($isWin11 -and $isPro)        { return 'Win11Pro' }
        elseif ($isWin11 -and $isEnterprise) { return 'Win11Enterprise' }
        elseif ($isPro)                       { return 'Win10Pro' }
        elseif ($isEnterprise)                { return 'Win10Enterprise' }
        return $null
    }

    # Server SKU: distill 2016/2019/2022/2025 from ProductName (build numbers would also
    # work but naming is the most stable signal across the versions).
    switch -Regex ($ProductName) {
        '2025' { return 'Server2025' }
        '2022' { return 'Server2022' }
        '2019' { return 'Server2019' }
        '2016' { return 'Server2016' }
    }
    return $null
}

function Find-LabMedia {
    <#
        Enumerates ISO and VHDX files in the lab's Media\ tree (plus per-VM VHDX
        files under VMs\<name>\). Returns objects with Kind/Path/SizeBytes but
        WITHOUT edition info - call Read-LabIsoEditionInfo / Read-LabVhdxEditionInfo
        to populate the OSKey/Edition fields. This split keeps discovery cheap and
        lets the caller decide how deep to inspect each hit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MediaRoot,
        [Parameter(Mandatory)] [string] $VMsRoot
    )

    $items = @()

    $isoRoot  = Join-Path $MediaRoot 'ISO'
    $vhdxRoot = Join-Path $MediaRoot 'VHDX'

    Write-LabLog "Scanning media folders:" -Level Info
    Write-LabLog "  ISO folder: $isoRoot" -Level Info
    Write-LabLog "  VHDX folder: $vhdxRoot" -Level Info

    foreach ($root in @($isoRoot, $vhdxRoot)) {
        if (Test-Path $root) {
            # Scan for ISO files in ISO folder
            if ($root -eq $isoRoot) {
                Write-LabLog "  Scanning for ISO files..." -Level Info
                $isoFiles = Get-ChildItem -Path $root -Filter "*.iso" -File -ErrorAction SilentlyContinue
                foreach ($file in $isoFiles) {
                    Write-LabLog "    Found ISO: $($file.Name) ($([math]::Round($file.Length / 1GB, 2)) GB)" -Level Info
                    $items += [pscustomobject]@{
                        Kind       = 'Iso'
                        Path       = $file.FullName
                        SizeBytes  = $file.Length
                        Source     = 'MediaCache'
                        OSKey      = $null
                        EditionID  = $null
                        ProductName = $null
                        InstallationType = $null
                        Editions   = @()
                    }
                }
            }
            
            # Scan for VHDX/VHD files in VHDX folder
            if ($root -eq $vhdxRoot) {
                Write-LabLog "  Scanning for VHDX/VHD files..." -Level Info
                $vhdFiles = @()
                $vhdFiles += Get-ChildItem -Path $root -Filter "*.vhdx" -File -ErrorAction SilentlyContinue
                $vhdFiles += Get-ChildItem -Path $root -Filter "*.vhd" -File -ErrorAction SilentlyContinue
                foreach ($file in $vhdFiles) {
                    # Determine Kind based on file extension
                    $ext = [System.IO.Path]::GetExtension($file.FullName).ToLower()
                    $kind = if ($ext -eq '.vhdx') { 'Vhdx' } else { 'Vhd' }
                    
                    Write-LabLog "    Found ${kind}: $($file.Name) ($([math]::Round($file.Length / 1GB, 2)) GB)" -Level Info
                    $items += [pscustomobject]@{
                        Kind       = $kind
                        Path       = $file.FullName
                        SizeBytes  = $file.Length
                        Source     = 'MediaCache'
                        OSKey      = $null
                        EditionID  = $null
                        ProductName = $null
                        InstallationType = $null
                        Editions   = @()
                    }
                }
            }
        }
    }

    # NOTE: Per-VM disk files under VMs\ are intentionally NOT scanned.
    # They are locked when the VM is running and are not reusable as golden images.
    # All reusable media lives under Media\VHDX\ and Media\ISO\ above.

    Write-LabLog "Found $($items.Count) total media file(s) before deduplication" -Level Info

    # Deduplicate by path (in case same file appears in multiple scans)
    $uniqueItems = @()
    $seenPaths = @{}
    foreach ($item in $items) {
        if (-not $seenPaths.ContainsKey($item.Path)) {
            $seenPaths[$item.Path] = $true
            $uniqueItems += $item
        }
    }

    Write-LabLog "Found $($uniqueItems.Count) unique media file(s)" -Level Info

    return ,$uniqueItems
}

function Read-LabIsoEditionInfo {
    <#
        Mounts an ISO read-only and reads the edition(s) from its install.wim/esd.
        Returns an array of @{ ImageIndex; ImageName } for every edition inside.
        Reuses the exact Mount-DiskImage technique already proven in
        02-Get-WindowsMedia.ps1's Resolve-LabIsoEdition.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $IsoPath)

    $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    try {
        $driveLetter = ($mount | Get-Volume).DriveLetter
        $sourcesPath = "${driveLetter}:\sources"
        $wimPath = Join-Path $sourcesPath 'install.wim'
        if (-not (Test-Path $wimPath)) { $wimPath = Join-Path $sourcesPath 'install.esd' }
        if (-not (Test-Path $wimPath)) {
            throw "Could not find install.wim or install.esd inside $IsoPath."
        }
        $images = Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop
        $result = $images | ForEach-Object {
            [pscustomobject]@{ ImageIndex = $_.ImageIndex; ImageName = $_.ImageName }
        }
        # Ensure we always return an array (even for single item)
        if (-not $result) { return @() }
        return ,$result
    } finally {
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    }
}

function Read-LabVhdxEditionInfo {
    <#
        Attaches the VHDX/VHD read-only and reads the installed Windows edition out
        of the offline SOFTWARE hive. We shell out to reg.exe (NOT the PowerShell
        HKLM: provider) deliberately: the PS provider opens a handle on the hive
        that it does not reliably release, which makes the subsequent `reg unload`
        fail and leaves the hive orphaned. reg.exe query has no such leak.

        Returns $null if this disk doesn't contain a recognizable Windows install
        (e.g. a blank differencing disk, or a non-Windows image) so the caller can
        present it as "unknown".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $VhdxPath)

    $mounted = $false
    $alreadyMounted = $false
    $hiveKey = 'HKLM\LabOfflineSW'
    try {
        # Check if VHDX is already mounted by checking for attached disks with this path
        $attachedDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'File Backed Virtual' })
        $alreadyMountedDisk = $null
        foreach ($disk in $attachedDisks) {
            try {
                # Try to get the VHD path for this disk
                $vhdPath = (Get-VHD -DiskNumber $disk.DiskNumber -ErrorAction SilentlyContinue).Path
                if ($vhdPath -and (Resolve-Path $vhdPath -ErrorAction SilentlyContinue).Path -eq (Resolve-Path $VhdxPath -ErrorAction SilentlyContinue).Path) {
                    $alreadyMountedDisk = $disk
                    break
                }
            } catch { }
        }
        
        if ($alreadyMountedDisk) {
            # Already mounted, check if it has a drive letter
            $osVolume = $alreadyMountedDisk | Get-Partition -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter } |
                Sort-Object Size -Descending |
                Select-Object -First 1
            if (-not $osVolume) {
                # Mount it to get a drive letter (shouldn't happen if already mounted, but just in case)
                Mount-VHD -Path $VhdxPath -ReadOnly -ErrorAction Stop | Out-Null
                $mounted = $true
            } else {
                $alreadyMounted = $true
            }
        } else {
            # Not mounted, mount it
            Mount-VHD -Path $VhdxPath -ReadOnly -ErrorAction Stop | Out-Null
            $mounted = $true
        }

        # Find the OS partition: the largest partition that got assigned a drive
        # letter (Windows install partition is typically >> any boot/EFI/recovery
        # partition and always gets a letter when mounted).
        $osVolume = Get-Disk | Where-Object { $_.BusType -eq 'File Backed Virtual' } |
            Get-Partition -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } |
            Sort-Object Size -Descending |
            Select-Object -First 1
        if (-not $osVolume) { return $null }

        $swFile = "$($osVolume.DriveLetter):\Windows\System32\config\SOFTWARE"
        if (-not (Test-Path $swFile)) { return $null }

        # Load the offline hive, then query each value we need with a single
        # reg.exe call. Output is plain text; we parse the "VALUE    TYPE    DATA"
        # triple via regex rather than trusting column positions.
        $loadResult = & reg.exe load $hiveKey $swFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "reg load of offline SOFTWARE hive failed: $loadResult"
        }
        try {
            $cvPath = "$hiveKey\Microsoft\Windows NT\CurrentVersion"
            $query = & reg.exe query $cvPath 2>&1

            $getValue = {
                param($name)
                $line = @($query | Where-Object { $_ -match "^\s+$name\s+" } | Select-Object -First 1)
                if (-not $line) { return $null }
                # Trailing field after the type is the value; split on whitespace runs.
                $parts = @(($line -split '\s+') | Where-Object { $_ })
                if ($parts.Count -ge 3) { return ($parts[2..($parts.Count - 1)] -join ' ') }
                return $null
            }

            $editionID  = & $getValue 'EditionID'
            $productName = & $getValue 'ProductName'
            $installType = & $getValue 'InstallationType'
            $build       = & $getValue 'CurrentBuild'

            if (-not $editionID -and -not $productName) { return $null }

            $osKey = ConvertTo-LabOSKey -EditionID $(if ($editionID) { $editionID } else { '' }) -ProductName $(if ($productName) { $productName } else { '' }) -InstallationType $(if ($installType) { $installType } else { '' })
            return [pscustomobject]@{
                EditionID         = $editionID
                ProductName       = $productName
                InstallationType  = $installType
                CurrentBuild      = $build
                OSKey             = $osKey
            }
        } finally {
            & reg.exe unload $hiveKey 2>&1 | Out-Null
        }
    } finally {
        # Only dismount if we mounted it in this function (not if already mounted)
        if ($mounted -and -not $alreadyMounted) {
            try { Dismount-VHD -Path $VhdxPath -ErrorAction Stop } catch { }
        }
    }
}

function Invoke-LabMediaScan {
    <#
        Top-level scan. Discovers every ISO/VHDX in scope, enriches each with
        edition info (VHDX via offline-hive read, ISO via install.wim enumeration),
        prints a results table, and returns the enriched list so Invoke-LabMediaSelection
        (in the master script) can offer auto-matched picks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $MediaRoot,
        [Parameter(Mandatory)] [string] $VMsRoot
    )

    Write-LabLog "Scanning for existing Windows media (ISO / VHDX)..." -Level Step
    $items = @(Find-LabMedia -MediaRoot $MediaRoot -VMsRoot $VMsRoot)

    if ($items.Count -eq 0) {
        Write-LabLog "No cached ISO or VHDX files found under $MediaRoot or $VMsRoot." -Level Info
        return @()
    }

    Write-LabLog ("Found {0} media file(s). Inspecting editions..." -f $items.Count) -Level Info

    # Ensure items is a proper array (not nested)
    if ($items -is [array] -and $items.Count -eq 1 -and $items[0] -is [array]) {
        Write-LabLog "DEBUG: Unwrapping nested array" -Level Info
        $items = $items[0]
    }
    
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        # Debug: verify item properties exist
        if (-not $item.PSObject.Properties['Editions']) {
            Write-LabLog "DEBUG: Item at index $i missing Editions property. Type: $($item.GetType().Name), Properties: $($item.PSObject.Properties.Name -join ', ')" -Level Info
        }
        try {
            if ($item.Kind -eq 'Iso') {
                # Ensure Path is a string (not an array)
                $isoPath = if ($item.Path -is [array]) { $item.Path[0] } else { $item.Path }
                Write-LabLog "  Reading ISO edition info: $isoPath" -Level Info
                $editions = Read-LabIsoEditionInfo -IsoPath $isoPath
                # Ensure editions is an array
                if (-not ($editions -is [array])) { $editions = @($editions) }
                # An ISO can hold several editions; pick the first whose name maps to
                # a known OSKey, else fall back to the first edition for display.
                if ($editions -and $editions.Count -gt 0) {
                    Write-LabLog "    Found $($editions.Count) edition(s) in ISO" -Level Info
                    if ($items[$i].PSObject.Properties['Editions']) { $items[$i].Editions = $editions }
                    $chosen = $null
                    foreach ($ed in $editions) {
                        if ($ed -and $ed.ImageName) {
                            Write-LabLog "    Checking edition: $($ed.ImageName)" -Level Info
                            $guess = ConvertTo-LabOSKey -EditionID $ed.ImageName -ProductName $ed.ImageName -InstallationType $(if ($ed.ImageName -match 'Server') { 'Server' } else { 'Client' })
                            if ($guess) { $chosen = $guess; Write-LabLog "    Matched OSKey: $chosen" -Level Info; break }
                        }
                    }
                    if ($items[$i].PSObject.Properties['OSKey']) { $items[$i].OSKey = $chosen }
                    if ($items[$i].PSObject.Properties['EditionID'] -and $editions[0]) { $items[$i].EditionID = $editions[0].ImageName }
                } else {
                    Write-LabLog "  No editions found in ISO" -Level Warn
                    if ($items[$i].PSObject.Properties['Editions']) { $items[$i].Editions = @() }
                    if ($items[$i].PSObject.Properties['OSKey']) { $items[$i].OSKey = $null }
                    if ($items[$i].PSObject.Properties['EditionID']) { $items[$i].EditionID = $null }
                }
            } else {
                # Ensure Path is a string (not an array)
                $vhdxPath = if ($item.Path -is [array]) { $item.Path[0] } else { $item.Path }
                $info = Read-LabVhdxEditionInfo -VhdxPath $vhdxPath
                if ($info) {
                    # Safety check: ensure the object has all required properties
                    if ($items[$i].PSObject.Properties['EditionID'] -and $info.PSObject.Properties.Name -contains 'EditionID') { $items[$i].EditionID = $info.EditionID }
                    if ($items[$i].PSObject.Properties['ProductName'] -and $info.PSObject.Properties.Name -contains 'ProductName') { $items[$i].ProductName = $info.ProductName }
                    if ($items[$i].PSObject.Properties['InstallationType'] -and $info.PSObject.Properties.Name -contains 'InstallationType') { $items[$i].InstallationType = $info.InstallationType }
                    if ($items[$i].PSObject.Properties['OSKey'] -and $info.PSObject.Properties.Name -contains 'OSKey') { $items[$i].OSKey = $info.OSKey }
                }
                if ($items[$i].PSObject.Properties['Editions']) { $items[$i].Editions = @() }
            }
        } catch {
            # Ensure Path is a string for the error message
            $errorMsgPath = if ($item.Path -is [array]) { $item.Path[0] } else { $item.Path }
            Write-LabLog "Could not read edition from ${errorMsgPath}: $($_.Exception.Message)" -Level Warn
            # Only set properties if they exist (handle nested array case)
            if ($items[$i].PSObject.Properties['OSKey']) { $items[$i].OSKey = $null }
            if ($items[$i].PSObject.Properties['Editions']) { $items[$i].Editions = @() }
        }
    }

    # Report table.
    $rows = $items | ForEach-Object {
        $label = if ($_.OSKey) { $_.OSKey } elseif ($_.EditionID) { $_.EditionID } else { '(unknown)' }
        [pscustomobject]@{
            Kind    = $_.Kind
            OSKey   = $label
            Edition = $_.EditionID
            Source  = $_.Source
            SizeGB  = [math]::Round($_.SizeBytes / 1GB, 1)
            Path    = $_.Path
        }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host
    
    # Warn if any media couldn't be read (likely because it's already mounted or in use)
    $unreadable = @($items | Where-Object { -not $_.OSKey -and $_.Source -eq 'MediaCache' })
    if ($unreadable.Count -gt 0) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "WARNING: Could not read edition from $($unreadable.Count) cached media file(s)." -ForegroundColor Yellow
        Write-Host "These files may be in use by another process or already mounted." -ForegroundColor Yellow
        Write-Host "You can still select them during media selection, but they will appear as '(unknown)'." -ForegroundColor Yellow
        foreach ($u in $unreadable) {
            Write-Host "  - $($u.Path)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    return ,$items
}
'@

    'Scripts\10-Validate-LabState.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Reconciles the persisted CompletedSteps progress file against ground truth
    (Hyper-V + live-guest state read via PowerShell Direct) so a re-run can skip
    what's genuinely done and re-run what isn't.
.DESCRIPTION
    For each step ID the orchestrator cares about, this module probes the actual
    state of the world and reports one of:
        Present       the step is verifiably complete on the guest
        Missing       the guest does NOT have this step done (regardless of file)
        Unverifiable  VM is off / unreachable -> caller trusts the persisted file

    The results are registered into the shared $Script:StepOverrides map via
    Register-LabStepOverride, which Test-LabStepNeeded (in LabDeploy.Common.psm1)
    consults. Per the toolkit's "trust ground truth, never auto-fix" rule:
      - Missing always wins (a tracked-but-missing step is RE-RUN).
      - Present is trusted (a done-but-untracked step is SKIPPED, but NOT marked
        complete, so manual setup is never silently absorbed).

    Every guest probe goes through Wait-LabVMPowerShellDirect first, so this works
    even before networking is fully up - same transport DC/DHCP/DNS setup uses.
#>

Set-StrictMode -Version Latest

function Test-LabVMExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $VMName)
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) { return $false }
    # Confirm the backing VHDX file is actually on disk (a VM with a missing disk
    # file is effectively destroyed for our purposes).
    $drive = $vm | Get-VMHardDiskDrive -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($drive -and $drive.Path -and (Test-Path $drive.Path)) { return $true }
    if (-not $drive) { return $true } # no VHD attached is odd, but the VM object exists
    return $false
}

function Invoke-LabGuestProbe {
    <#
        Generic "run a script block in the guest and return its result object".
        Centralizes the readiness wait + credential + error handling so every
        probe below stays tiny. Returns $null on any failure (caller treats that
        as Unverifiable, not Missing - we can't tell the difference from out here).

        Fast-fail: if the VM doesn't exist or isn't Running, return $null right
        away instead of spending up to 300s polling a dead heartbeat. The default
        validation path does NOT power on stopped VMs, so an off lab validates in
        milliseconds rather than 300s-per-VM. (When -BootForValidation has started
        a VM, it's Running by the time we get here, so this guard is transparent.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList = @()
    )
    $vmObj = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vmObj)         { return $null }   # no VM -> don't poll a dead heartbeat
    if ($vmObj.State -ne 'Running') { return $null }   # off & not being booted -> trust file
    try {
        Wait-LabVMPowerShellDirect -VMName $VMName -Credential $Credential -TimeoutSeconds 300 | Out-Null
    } catch {
        return $null  # VM not reachable -> Unverifiable
    }
    try {
        return (Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Test-LabGuestFeatureInstalled {
    <# Returns 'Installed', 'NotInstalled', or $null (unreachable) for a feature name. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $FeatureName
    )
    $r = Invoke-LabGuestProbe -VMName $VMName -Credential $Credential -ScriptBlock {
        param($f)
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat -and $feat.Installed) { return 'Installed' }
        return 'NotInstalled'
    } -ArgumentList $FeatureName
    return $r
}

function Test-LabGuestDomainMembership {
    <# Returns @{ PartOfDomain; Domain } or $null (unreachable). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential
    )
    return Invoke-LabGuestProbe -VMName $VMName -Credential $Credential -ScriptBlock {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if (-not $cs) { return $null }
        return [pscustomobject]@{ PartOfDomain = [bool]$cs.PartOfDomain; Domain = $cs.Domain }
    }
}

function Test-LabForestState {
    <#
        Confirms the PRIMARY DC's forest actually exists for the expected domain.
        'Installed' means Get-ADForest for the domain succeeded; 'Absent' means
        ADDS not installed; $null means unreachable. We use the AD module's
        Get-ADForest rather than just checking the feature, because the feature
        being installed != the forest being promoted (a half-built DC has the
        binaries but no forest).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $DomainName
    )
    return Invoke-LabGuestProbe -VMName $VMName -Credential $Credential -ScriptBlock {
        param($domain)
        $feat = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue
        if (-not ($feat -and $feat.Installed)) { return 'Absent' }
        try {
            $null = Get-ADForest -Identity $domain -ErrorAction Stop
            # Also confirm this host is actually a DC in that forest.
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
            if ($cs.DomainRole -ge 4) { return 'Installed' }
            return 'Partial'
        } catch {
            return 'Partial'
        }
    } -ArgumentList $DomainName
}

function Test-LabAdditionalDCState {
    <#
        For a non-primary DC: confirms it has the ADDS feature AND this host is a
        domain controller in the expected domain (Win32_ComputerSystem.Roles contains
        'DomainController' and Domain matches).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $DomainName
    )
    return Invoke-LabGuestProbe -VMName $VMName -Credential $Credential -ScriptBlock {
        param($domain)
        $feat = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue
        if (-not ($feat -and $feat.Installed)) { return 'Absent' }
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
        if (-not $cs) { return 'Partial' }
        if ($cs.DomainRole -lt 4) { return 'NotDC' }
        if ($cs.Domain -ne $domain) { return 'WrongDomain' }
        return 'Installed'
    } -ArgumentList $DomainName
}

function Test-LabDhcpState {
    <# DHCP installed, authorized in AD, and the expected scope exists. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $ScopeId
    )
    return Invoke-LabGuestProbe -VMName $VMName -Credential $Credential -ScriptBlock {
        param($scopeId)
        $feat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
        if (-not ($feat -and $feat.Installed)) { return 'Absent' }
        $auth = @(Get-DhcpServerInDC -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -and $_.DnsName })
        $scope = Get-DhcpServerV4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue
        if ($auth.Count -gt 0 -and $scope) { return 'Installed' }
        if (-not $scope) { return 'NoScope' }
        return 'Partial'
    } -ArgumentList $ScopeId
}

function Test-LabDnsSecondaryState {
    <# DNS installed and a Secondary zone for the domain is present. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [string] $ZoneName
    )
    return Invoke-LabGuestProbe -VMName $VMName -Credential $Credential -ScriptBlock {
        param($zone)
        $feat = Get-WindowsFeature -Name DNS -ErrorAction SilentlyContinue
        if (-not ($feat -and $feat.Installed)) { return 'Absent' }
        $z = Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue
        if ($z -and $z.ZoneType -eq 'Secondary') { return 'Installed' }
        return 'Missing'
    } -ArgumentList $ZoneName
}

function Invoke-LabStateValidation {
    <#
        Walks every step in the config, probes ground truth, registers each result
        into $Script:StepOverrides, and prints a reconciliation table comparing
        ground truth vs the persisted CompletedSteps array. Returns the count of
        steps that will be (re-)run and the count that couldn't be verified.

        Credential strategy mirrors the orchestrator: VM-created -> local Admin
        before any promotion, domain Admin after the forest exists. For a VM that
        isn't promoted yet we use the local cred; once the forest is confirmed up
        we switch to the domain cred.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [securestring] $LocalAdminPassword
    )

    Clear-LabStepOverrides

    $localCred  = New-Object PSCredential(".\Administrator", $LocalAdminPassword)
    $domainCred = New-Object PSCredential("$($Config.NetBIOSName)\Administrator", $LocalAdminPassword)

    $reRun      = 0   # steps we'll execute because ground truth says Missing
    $unverifiable = 0 # steps we couldn't verify (VM off) -> trust file
    $report      = @()

    $completed = @()
    if ($Config.PSObject.Properties['CompletedSteps']) { $completed = @($Config.CompletedSteps) }
    $isTracked = { param($id) $completed -contains $id }

    # Existence short-circuit helper. A VM that has NO Hyper-V object is
    # definitively gone -> any role step for it is Missing (re-run), NOT
    # Unverifiable. This matters because Invoke-LabGuestProbe returns $null both
    # for a gone VM and for a merely-off VM, but they should be handled
    # differently: gone = rebuild it; off = trust the file. Returns 'Present'
    # when a VM object exists (including an off one -> caller then probes; if the
    # probe yields $null it's treated as Unverifiable = trust file).
    $vmPresent = { param($n) [bool](Get-VM -Name $n -ErrorAction SilentlyContinue) }

    # ---- Switch step (no guest needed; pure Hyper-V) ----
    $swStep = "Switch:$($Config.SwitchName):Created"
    $existing = Get-VMSwitch -Name $Config.SwitchName -ErrorAction SilentlyContinue
    $gt = if ($existing) { 'Present' } else { 'Missing' }
    Register-LabStepOverride -StepId $swStep -State $gt
    $report += [pscustomobject]@{ Step = $swStep; Tracked = (& $isTracked $swStep); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } else { 'run' }) }

    # ---- Domain controllers ----
    $allDCs = @($Config.DomainControllers)
    for ($i = 0; $i -lt $allDCs.Count; $i++) {
        $dc = $allDCs[$i]
        $name = $dc.Name

        # VM created?
        $createStep = "VM:$name:Created"
        if (Test-LabVMExists -VMName $name) {
            $gt = 'Present'
        } elseif (Get-VM -Name $name -ErrorAction SilentlyContinue) {
            $gt = 'Missing' # VM object exists but disk gone -> treat as not built
        } else {
            $gt = 'Missing'
        }
        Register-LabStepOverride -StepId $createStep -State $gt
        $report += [pscustomobject]@{ Step = $createStep; Tracked = (& $isTracked $createStep); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } else { 'run' }) }

        # Forest / DC promotion. Use domain cred (promoted DCs only accept domain creds),
        # but if the VM is off / un-reachable, Unverifiable falls out naturally.
        # If the VM is gone entirely, skip the probe and mark Missing (re-run) - a
        # gone DC must be rebuilt, not trusted from a stale progress file.
        if (-not (& $vmPresent $name)) {
            $gt = 'Missing'
            $step = if ($i -eq 0) { "DC:$name:ForestPromoted" } else { "DC:$name:Promoted" }
        } else {
            if ($i -eq 0) {
                $step = "DC:$name:ForestPromoted"
                $r = Test-LabForestState -VMName $name -Credential $domainCred -DomainName $Config.DomainName
            } else {
                $step = "DC:$name:Promoted"
                $r = Test-LabAdditionalDCState -VMName $name -Credential $domainCred -DomainName $Config.DomainName
            }
            if ($null -eq $r) { $gt = 'Unverifiable' }
            elseif ($r -eq 'Installed') { $gt = 'Present' }
            else { $gt = 'Missing' }
        }
        Register-LabStepOverride -StepId $step -State $gt
        $report += [pscustomobject]@{ Step = $step; Tracked = (& $isTracked $step); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } elseif ($gt -eq 'Unverifiable') { 'skip (trust file)' } else { 'RE-RUN' }) }
    }

    # ---- DHCP on the chosen DC ----
    $dhcpDC = $Config.DomainControllers | Where-Object { $_.Name -eq $Config.DhcpHostName } | Select-Object -First 1
    if ($dhcpDC) {
        $step = "DHCP:$($dhcpDC.Name):Configured"
        if (-not (& $vmPresent $dhcpDC.Name)) {
            $gt = 'Missing'   # DHCP host gone -> rebuild it
        } else {
            $r = Test-LabDhcpState -VMName $dhcpDC.Name -Credential $domainCred -ScopeId $Config.ScopeId
            if ($null -eq $r) { $gt = 'Unverifiable' }
            elseif ($r -eq 'Installed') { $gt = 'Present' }
            else { $gt = 'Missing' }
        }
        Register-LabStepOverride -StepId $step -State $gt
        $report += [pscustomobject]@{ Step = $step; Tracked = (& $isTracked $step); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } elseif ($gt -eq 'Unverifiable') { 'skip (trust file)' } else { 'RE-RUN' }) }
    }

    # ---- Additional VMs: created + domain-joined (+ DNS where applicable) ----
    foreach ($vm in $Config.AdditionalVMs) {
        $name = $vm.Name
        $present = & $vmPresent $name

        $createStep = "VM:$name:Created"
        if (Test-LabVMExists -VMName $name) { $gt = 'Present' }
        elseif ($present) { $gt = 'Missing' }
        else { $gt = 'Missing' }
        Register-LabStepOverride -StepId $createStep -State $gt
        $report += [pscustomobject]@{ Step = $createStep; Tracked = (& $isTracked $createStep); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } else { 'run' }) }

        $joinStep = "VM:$name:DomainJoined"
        if (-not $present) {
            $gt = 'Missing'   # VM gone -> re-run the join when it's rebuilt
        } else {
            $r = Test-LabGuestDomainMembership -VMName $name -Credential $domainCred
            if ($null -eq $r) { $gt = 'Unverifiable' }
            elseif ($r.PartOfDomain -and $r.Domain -eq $Config.DomainName) { $gt = 'Present' }
            else { $gt = 'Missing' }
        }
        Register-LabStepOverride -StepId $joinStep -State $gt
        $report += [pscustomobject]@{ Step = $joinStep; Tracked = (& $isTracked $joinStep); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } elseif ($gt -eq 'Unverifiable') { 'skip (trust file)' } else { 'RE-RUN' }) }

        if ($vm.Role -eq 'DNS') {
            $dnsStep = "DNS:$name:Configured"
            if (-not $present) {
                $gt = 'Missing'
            } else {
                $r = Test-LabDnsSecondaryState -VMName $name -Credential $domainCred -ZoneName $Config.DomainName
                if ($null -eq $r) { $gt = 'Unverifiable' }
                elseif ($r -eq 'Installed') { $gt = 'Present' }
                else { $gt = 'Missing' }
            }
            Register-LabStepOverride -StepId $dnsStep -State $gt
            $report += [pscustomobject]@{ Step = $dnsStep; Tracked = (& $isTracked $dnsStep); GroundTruth = $gt; Action = $(if ($gt -eq 'Present') { 'skip (confirmed)' } elseif ($gt -eq 'Unverifiable') { 'skip (trust file)' } else { 'RE-RUN' }) }
        }
    }

    # ---- Print reconciliation table ----
    Write-LabLog "=== Lab state reconciliation ===" -Level Step
    $report | Format-Table -AutoSize | Out-String | Write-Host

    # Summarize counts for the orchestrator / final summary.
    foreach ($row in $report) {
        if ($row.GroundTruth -eq 'Missing') { $reRun++ }
        elseif ($row.GroundTruth -eq 'Unverifiable' -and -not $row.Tracked) { $reRun++ }
        if ($row.GroundTruth -eq 'Unverifiable' -and $row.Tracked) { $unverifiable++ }
    }

    if ($reRun -eq 0 -and $unverifiable -eq 0) {
        Write-LabLog "All steps reconciled with ground truth." -Level Success
    } else {
        Write-LabLog ("{0} step(s) will (re-)run, {1} unverifiable step(s) trusted from progress file." -f $reRun, $unverifiable) -Level Info
    }

    return [pscustomobject]@{ Report = $report; ReRun = $reRun; Unverifiable = $unverifiable }
}
'@

    'Scripts\11-Remove-Lab.ps1' = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Tears down an existing lab: removes every VM the orchestrator created and
    clears saved build progress, so the next run rebuilds from scratch.
.DESCRIPTION
    The "fresh lab, fast" primitive. For each VM named in the config (DCs and
    additional VMs alike) it stops the VM if running, removes it from Hyper-V,
    and deletes its per-VM folder under VMs\<name>\ (which holds its VHDX). It
    then empties Config\LabConfig.json's CompletedSteps array.

    What it deliberately PRESERVES, so the next run is fast:
      - Topology + network settings + the per-VM MediaSource choices -> cached
        ISO/golden VHDX under Media\ are reused, nothing is re-downloaded.
      - The rest of the config object (you don't have to re-run the wizard).

    With -RemoveSwitch it additionally removes the Hyper-V virtual switch and
    its NetNat object.

    Idempotent: a VM/disk/switch that is already gone is silently skipped, never
    thrown on. No Administrator password is needed (destruction needs no guest
    credentials).
#>

Set-StrictMode -Version Latest

function Remove-LabVM {
    <#
        Removes a single VM and its per-VM folder. Returns $true if anything was
        actually removed, $false if the VM didn't exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $VMsRoot
    )

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-LabLog "VM '$VMName' not found in Hyper-V - skipping." -Level Info
        # Still attempt to clean a leftover folder (e.g. from a partial previous run).
    } else {
        # Capture disk paths BEFORE removal so we can delete the files reliably
        # (Remove-VM -Force does not always delete the underlying VHDX, and we
        # own the whole per-VM folder anyway).
        $diskPaths = @($vm | Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } | Select-Object -ExpandProperty Path)

        if ($vm.State -ne 'Off') {
            Write-LabLog "Stopping '$VMName' (current state: $($vm.State))..." -Level Info
            try {
                Stop-VM -Name $VMName -Force -TurnOff -ErrorAction Stop
            } catch {
                # If a graceful stop is refused, a hard stop is the fallback.
                Stop-VM -Name $VMName -Force -TurnOff -ErrorAction SilentlyContinue
            }
        }

        Write-LabLog "Removing VM '$VMName' from Hyper-V..." -Level Step
        Remove-VM -Name $VMName -Force -ErrorAction SilentlyContinue

        # Belt-and-suspenders: detach any VHDX Hyper-V might still reference.
        foreach ($p in $diskPaths) {
            try { Dismount-VHD -Path $p -ErrorAction SilentlyContinue } catch { }
        }
    }

    # Remove the per-VM folder (holds the VHDX + any snapshot/config files).
    $vmDir = Join-Path $VMsRoot $VMName
    if (Test-Path $vmDir) {
        Write-LabLog "Deleting VM files at '$vmDir'..." -Level Info
        try {
            Remove-Item -Path $vmDir -Recurse -Force -ErrorAction Stop
        } catch {
            # A still-attached VHDX can resist deletion; surface it but keep going
            # so one stubborn VM doesn't abort the whole tear-down.
            Write-LabLog "Could not fully remove '$vmDir': $($_.Exception.Message) - you may need to delete it by hand." -Level Warn
        }
    }

    return [bool]$vm
}

function Invoke-LabTearDown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [string] $VMsRoot,
        [switch] $RemoveSwitch
    )

    Write-LabLog "=== Tearing down lab '$($Config.DomainName)' ===" -Level Step

    # Union of every VM this lab created, DCs first then the rest.
    $vmNames = @()
    if ($Config.PSObject.Properties['DomainControllers']) {
        $vmNames += @($Config.DomainControllers | ForEach-Object { $_.Name })
    }
    if ($Config.PSObject.Properties['AdditionalVMs']) {
        $vmNames += @($Config.AdditionalVMs | ForEach-Object { $_.Name })
    }
    # De-dup while keeping order (defensive; names should already be unique).
    $vmNames = @($vmNames | Select-Object -Unique)

    if ($vmNames.Count -eq 0) {
        Write-LabLog "No VMs recorded in the config - nothing to remove." -Level Warn
    }

    $removed = 0
    foreach ($name in $vmNames) {
        if (Remove-LabVM -VMName $name -VMsRoot $VMsRoot) { $removed++ }
    }

    # Clear build progress so the next run rebuilds everything. Keep everything
    # else (topology, network, per-VM MediaSource) so cached media is reused.
    if ($Config.PSObject.Properties['CompletedSteps']) {
        $Config.CompletedSteps = @()
    } else {
        $Config | Add-Member -MemberType NoteProperty -Name CompletedSteps -Value @()
    }
    Save-LabConfig -Config $Config -Path $ConfigPath
    Write-LabLog "Cleared saved build progress (CompletedSteps). Topology + media choices preserved." -Level Info

    if ($RemoveSwitch) {
        $switchName = $null
        if ($Config.PSObject.Properties['SwitchName']) { $switchName = $Config.SwitchName }
        if ($switchName) {
            $natName = "$switchName-NAT"
            Write-LabLog "Removing NetNat '$natName' (if present)..." -Level Step
            Get-NetNat -Name $natName -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
            Write-LabLog "Removing virtual switch '$switchName' (if present)..." -Level Step
            Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue
        } else {
            Write-LabLog "No SwitchName in config - skipping switch/NAT removal." -Level Warn
        }
    }

    Write-LabLog "Tear-down complete: $removed VM(s) removed, progress cleared." -Level Success
    Write-Host ""
    Write-Host "The lab is now 'fresh' for a rebuild. Cached media under Media\ was preserved," -ForegroundColor Cyan
    Write-Host "so the next run reuses it instead of re-downloading." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Fastest rebuild (no validation probing):" -ForegroundColor Green
    Write-Host "    .\Begin.ps1 -SkipValidation" -ForegroundColor Green
    Write-Host "  Normal rebuild (validates state, builds what's missing):" -ForegroundColor Green
    Write-Host "    .\Begin.ps1" -ForegroundColor Green
    Write-Host ""
    if ($RemoveSwitch) {
        Write-Host "The virtual switch + NAT were also removed. A rebuild will recreate them." -ForegroundColor Yellow
    } else {
        Write-Host "The virtual switch + NAT were left in place. A rebuild will reuse them." -ForegroundColor DarkGray
    }

    return [pscustomobject]@{ VMsRemoved = $removed }
}
'@

}
# Config\MediaSources.psd1 is special: it gets EDITED by you (Evaluation Center
# links) after creation, so it is only ever written if it doesn't already exist -
# never overwritten by re-runs or -ForceRegenerateScripts, to avoid clobbering
# your edits.
$Script:DefaultMediaSourcesContent = @'
@{
    # ===========================================================================================
    # MEDIA SOURCES
    # ===========================================================================================
    # This is the ONLY file you should need to touch when a download stops working.
    #
    # All Windows editions (including Home, Pro, Enterprise, and Server) require a one-time
    # registration at Microsoft Evaluation Center. The resulting fwlink URL must be supplied
    # below for each edition you want to deploy.
    #
    # HOW TO GET / REFRESH A LINK (about 2 minutes, one time per OS):
    #   1. Go to https://www.microsoft.com/evalcenter and pick the product (e.g. "Windows
    #      Server 2025" or "Windows 11 Enterprise").
    #   2. Click Download, fill in the short registration form.
    #   3. On the confirmation page, RIGHT-CLICK the language/ISO download button and choose
    #      "Copy link address" - do not click it, you want the URL, not the file.
    #   4. Paste that URL as the value below for the matching key.
    #
    # The placeholder values below are NOT valid - replace them before deploying any VM that
    # needs media. Get-WindowsMedia will stop with a clear error and a reminder of these steps
    # if it hits a placeholder.

    Win10Pro        = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-10-pro'
    Win10Enterprise = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-10-enterprise'
    Win11Pro        = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-11-pro'
    Win11Enterprise = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-11-enterprise'
    Server2016      = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-server-2016'
    Server2022      = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-server-2022'
    Server2025      = 'REPLACE_ME_GET_LINK_FROM_https://www.microsoft.com/evalcenter/evaluate-windows-server-2025'

    # Tooling sources (downloaded once, cached under Tools\, re-used after that)
    FidoUrl              = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
    ConvertWindowsImageUrl = 'https://raw.githubusercontent.com/MicrosoftDocs/Virtualization-Documentation/main/hyperv-tools/Convert-WindowsImage/Convert-WindowsImage.ps1'
}
'@

foreach ($entry in $Script:ChildFiles.GetEnumerator()) {
    Write-LabGeneratedFile -RelativePath $entry.Key -Content $entry.Value -Root $LabRoot -Force:$ForceRegenerateScripts | Out-Null
}

$mediaSourcesPath = Join-Path $Paths.Config 'MediaSources.psd1'
if (-not (Test-Path $mediaSourcesPath)) {
    Write-Bootstrap "Creating Config\MediaSources.psd1"
    Set-Content -Path $mediaSourcesPath -Value $Script:DefaultMediaSourcesContent -Encoding UTF8
}

# ===================================================================================
# LOAD GENERATED MODULE / SCRIPTS
# ===================================================================================
Import-Module (Join-Path $Paths.Modules 'LabDeploy.Common.psm1') -Force -DisableNameChecking

$LogFilePath = Join-Path $Paths.Logs "Deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Initialize-LabLog -Path $LogFilePath
Write-LabLog "=== Hyper-V Lab Deploy starting (LabRoot: $LabRoot) ===" -Level Step

Test-LabPrerequisite

Get-ChildItem -Path $Paths.Scripts -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

# ===================================================================================
# INTERACTIVE CONFIGURATION WIZARD
# ===================================================================================
function Read-LabString {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [string]$ValidationMessage = 'Invalid value.')
    while ($true) {
        $promptText = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $raw = Read-Host $promptText
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $Default }
        if (-not $raw) { Write-Host $ValidationMessage -ForegroundColor Yellow; continue }
        if ($Validate -and -not (& $Validate $raw)) { Write-Host $ValidationMessage -ForegroundColor Yellow; continue }
        return $raw
    }
}

function Read-LabInt {
    param([string]$Prompt, [int]$Default, [int]$Min = [int]::MinValue, [int]$Max = [int]::MaxValue)
    while ($true) {
        $raw = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -ge $Min -and $val -le $Max) { return $val }
        Write-Host "Enter a whole number between $Min and $Max." -ForegroundColor Yellow
    }
}

function Read-LabYesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $raw = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        switch -Regex ($raw.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Host "Please answer y or n." -ForegroundColor Yellow }
        }
    }
}

function Read-LabMenuChoice {
    param([string]$Prompt, [string[]]$Options, [int]$DefaultIndex = 0)
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $tag = if ($i -eq $DefaultIndex) { ' (default)' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), $Options[$i], $tag)
    }
    while ($true) {
        $raw = Read-Host "Choice [$($DefaultIndex + 1)]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultIndex }
        $val = 0
        if ([int]::TryParse($raw, [ref]$val) -and $val -ge 1 -and $val -le $Options.Count) { return $val - 1 }
        Write-Host "Enter a number between 1 and $($Options.Count)." -ForegroundColor Yellow
    }
}

function Test-LabPasswordComplexity {
    param([string]$Password)
    if ($Password.Length -lt 8) { return $false }
    $categories = 0
    if ($Password -cmatch '[A-Z]') { $categories++ }
    if ($Password -cmatch '[a-z]') { $categories++ }
    if ($Password -match '[0-9]') { $categories++ }
    if ($Password -match '[^a-zA-Z0-9]') { $categories++ }
    return $categories -ge 3
}

function Read-LabAdminPassword {
    param([switch]$AllowKeepExisting)
    
    while ($true) {
        if ($AllowKeepExisting) {
            $pw1 = Read-Host "Administrator password (press Enter to keep existing)" -AsSecureString
            # Check if empty (keep existing)
            $plain1 = (New-Object PSCredential('x', $pw1)).GetNetworkCredential().Password
            if ([string]::IsNullOrEmpty($plain1) -and $AllowKeepExisting) {
                return $null  # Signal to keep existing
            }
        } else {
            $pw1 = Read-Host "Administrator password (local admin on every VM, Domain Administrator after promotion, and DSRM)" -AsSecureString
        }
        
        $plain1 = (New-Object PSCredential('x', $pw1)).GetNetworkCredential().Password
        
        if (-not (Test-LabPasswordComplexity -Password $plain1)) {
            Write-Host "Must be at least 8 characters and include at least 3 of: uppercase, lowercase, digit, symbol." -ForegroundColor Yellow
            continue
        }
        
        $pw2 = Read-Host "Confirm password" -AsSecureString
        $plain2 = (New-Object PSCredential('x', $pw2)).GetNetworkCredential().Password
        
        if ($plain1 -ne $plain2) {
            Write-Host "Passwords didn't match - try again." -ForegroundColor Yellow
            continue
        }
        
        return $pw1
    }
}

function ConvertTo-LabSubnetMask {
    param([int]$PrefixLength)
    $bits = ('1' * $PrefixLength).PadRight(32, '0')
    $bytes = for ($i = 0; $i -lt 32; $i += 8) { [Convert]::ToByte($bits.Substring($i, 8), 2) }
    return ($bytes -join '.')
}

function Get-LabBestMediaMatch {
    <#
        Given a list of scanned media items and a target OSKey, pick the best
        reusable candidate. Preference order depends on OS:
          - Server 2016/2019/2022: Prefer VHD (Generation 1 VMs)
          - Server 2025: Prefer VHDX (Generation 2 VMs required for UEFI/GPT)
        Within each category, preference order:
          1. Exact OSKey match from MediaCache
          2. Any ISO with matching OSKey
          3. $null (nothing matches -> download fresh)
    #>
    param(
        [Parameter(Mandatory)] $MediaItems,
        [Parameter(Mandatory)] [string] $OSKey
    )
    
    # Determine preferred kind based on OS version
    $preferredKind = if ($OSKey -eq 'Server2025') { 'Vhdx' } else { 'Vhd' }
    
    # First try: exact match with preferred kind
    $match = $MediaItems | Where-Object { $_.Kind -eq $preferredKind -and $_.Source -eq 'MediaCache' -and $_.OSKey -eq $OSKey } | Select-Object -First 1
    if ($match) { return $match }
    
    # Second try: exact match with alternate kind (fallback)
    $alternateKind = if ($preferredKind -eq 'Vhdx') { 'Vhd' } else { 'Vhdx' }
    $match = $MediaItems | Where-Object { $_.Kind -eq $alternateKind -and $_.Source -eq 'MediaCache' -and $_.OSKey -eq $OSKey } | Select-Object -First 1
    if ($match) { return $match }
    
    # Third try: any ISO match
    $isoMatch = $MediaItems | Where-Object { $_.Kind -eq 'Iso' -and $_.OSKey -eq $OSKey } | Select-Object -First 1
    if ($isoMatch) { return $isoMatch }
    
    return $null
}

function Invoke-LabMediaSelection {
    <#
        Auto-match + opt-in menu. For each VM in the plan:
          - compute the best cached match by edition (prefer golden VHDX > ISO)
          - default to that match; if none, default to "download fresh"
          - print a summary table; Enter accepts all defaults
          - otherwise walk each VM offering: [1] auto pick [2..n] specific media [last] download fresh

        Persists the decision onto each VM object as a MediaSource note property:
          @{ Type='Vhdx'|'Iso'|'Download'; Path=$path }
        so a resume reuses the same choice without re-asking (unless -Reset).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $MediaItems,        # output of Invoke-LabMediaScan
        [Parameter(Mandatory)] [object] $LabConfig
    )

    # Already-decided on a previous run? Respect it (don't re-ask) unless caller
    # explicitly wants a re-pick (handled by passing freshly-scanned items + -Reset).
    Write-Host ""
    Write-Host "=== Media selection ===" -ForegroundColor Cyan
    Write-Host "For each VM, a cached ISO/VHDX (if one matches its edition) is pre-selected." -ForegroundColor DarkGray
    Write-Host "Press Enter to accept all defaults, or type a number to override per-VM." -ForegroundColor DarkGray

    # Build the unified VM list (DCs first, then additional) carrying the OSKey.
    $targets = @()
    foreach ($dc in $LabConfig.DomainControllers) {
        $targets += [pscustomobject]@{ Name = $dc.Name; OSKey = $dc.OSKey; Node = $dc }
    }
    foreach ($vm in $LabConfig.AdditionalVMs) {
        $targets += [pscustomobject]@{ Name = $vm.Name; OSKey = $vm.OSKey; Node = $vm }
    }

    # Phase 1: compute defaults.
    $decisions = @{}  # name -> @{ Type; Path; Label; Generation }
    foreach ($t in $targets) {
        $best = Get-LabBestMediaMatch -MediaItems $MediaItems -OSKey $t.OSKey
        if ($best) {
            # Determine generation based on media kind: VHD=Gen1, VHDX/ISO=Gen2
            $generation = if ($best.Kind -eq 'Vhd') { 1 } else { 2 }
            
            $decisions[$t.Name] = @{
                Type       = $best.Kind           # 'Vhdx' or 'Iso'
                Path       = $best.Path
                Label      = ("{0} {1}" -f $best.Kind, (Split-Path $best.Path -Leaf))
                Generation = $generation
            }
        } else {
            $decisions[$t.Name] = @{ Type = 'Download'; Path = $null; Label = 'download fresh'; Generation = 2 }
        }
    }

    # Phase 2: summary + bulk-accept prompt.
    $summary = foreach ($t in $targets) {
        $genInfo = " (Gen $($decisions[$t.Name].Generation))" * ($decisions[$t.Name].Type -ne 'Download')
        [pscustomobject]@{ VM = $t.Name; OSKey = $t.OSKey; Default = "$($decisions[$t.Name].Label)$genInfo" }
    }
    $summary | Format-Table -AutoSize | Out-String | Write-Host
    
    # Warn if any VMs will download fresh because media couldn't be identified
    $downloadFresh = $targets | Where-Object { $decisions[$_.Name].Type -eq 'Download' }
    if ($downloadFresh.Count -gt 0) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "NOTE: The following VM(s) will download Windows media fresh:" -ForegroundColor Yellow
        foreach ($d in $downloadFresh) {
            Write-Host "  - $($d.Name) (OS: $($d.OSKey))" -ForegroundColor Yellow
        }
        Write-Host "This happens when cached media couldn't be read or doesn't exist." -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Check if any VHD files will be used and prompt for confirmation
    $usesVhd = $decisions.Values.Where({ $_.Type -eq 'Vhd' })
    if ($usesVhd) {
        Write-Host "" -ForegroundColor Yellow
        Write-Host "WARNING: The following VMs will use VHD files with Generation 1:" -ForegroundColor Yellow
        foreach ($v in $usesVhd) { Write-Host "  - $($v.Label) -> Gen 1" -ForegroundColor Yellow }
        Write-Host "Generation 1 uses BIOS/MBR instead of UEFI/GPT." -ForegroundColor Yellow
        $confirm = Read-Host "Continue with VHD/Gen1 deployment? [y/N]"
        if ([string]::IsNullOrWhiteSpace($confirm) -or $confirm.Trim() -notmatch '^(y|yes)$') {
            Write-Host "Deployment cancelled. Please use VHDX files for Generation 2 VMs." -ForegroundColor Red
            exit 1
        }
    }

    $bulk = Read-Host "Accept all defaults? [Y/n]"
    $acceptAll = [string]::IsNullOrWhiteSpace($bulk) -or $bulk.Trim() -match '^(y|yes)$'

    # Phase 3: per-VM override if not accepting all.
    foreach ($t in $targets) {
        if ($acceptAll) { continue }
        $oskey = $t.OSKey
        # Candidate media for this VM: exact OSKey matches first, then any recognized
        # edition, then "download fresh" as the final option.
        $candidates = @($MediaItems | Where-Object { $_.OSKey -eq $oskey })
        $others     = @($MediaItems | Where-Object { $_.OSKey -ne $oskey -and $_.OSKey })
        $allOpts    = @($candidates) + @($others)

        Write-Host ""
        Write-Host "--- $($t.Name) (edition: $oskey) ---" -ForegroundColor Cyan
        $autoIdx = 0
        for ($i = 0; $i -lt $allOpts.Count; $i++) {
            $tag = ''
            if ($allOpts[$i].Path -eq $decisions[$t.Name].Path) { $tag = ' (default)'; $autoIdx = $i }
            # Determine generation for display
            $genInfo = ''
            if ($allOpts[$i].Kind -eq 'Vhd') { $genInfo = ' -> Gen 1' } elseif ($allOpts[$i].Kind -eq 'Vhdx' -or $allOpts[$i].Kind -eq 'Iso') { $genInfo = ' -> Gen 2' }
            Write-Host ("  {0}) {1} - {2}{3}{4}" -f ($i + 1), $allOpts[$i].Kind, (Split-Path $allOpts[$i].Path -Leaf), $tag, $genInfo)
        }
        $downloadIdx = $allOpts.Count
        $dlTag = if ($decisions[$t.Name].Type -eq 'Download') { ' (default)' } else { '' }
        Write-Host ("  {0}) download fresh{1} -> Gen 2" -f ($downloadIdx + 1), $dlTag)

        while ($true) {
            $raw = Read-Host "Choice [$($autoIdx + 1)]"
            if ([string]::IsNullOrWhiteSpace($raw)) {
                # keep current default
                break
            }
            $val = 0
            if ([int]::TryParse($raw, [ref]$val) -and $val -ge 1 -and $val -le ($downloadIdx + 1)) {
                if ($val -eq ($downloadIdx + 1)) {
                    $decisions[$t.Name] = @{ Type = 'Download'; Path = $null; Label = 'download fresh'; Generation = 2 }
                } else {
                    $chosen = $allOpts[$val - 1]
                    # Determine generation based on media kind
                    $generation = if ($chosen.Kind -eq 'Vhd') { 1 } else { 2 }
                    $decisions[$t.Name] = @{
                        Type       = $chosen.Kind
                        Path       = $chosen.Path
                        Label      = ("{0} {1}" -f $chosen.Kind, (Split-Path $chosen.Path -Leaf))
                        Generation = $generation
                    }
                }
                break
            }
            Write-Host "Enter a number between 1 and $($downloadIdx + 1)." -ForegroundColor Yellow
        }
    }

    # Phase 4: stamp decisions onto the config objects (carried through to Get-WindowsMedia).
    foreach ($t in $targets) {
        $d = $decisions[$t.Name]
        # Use a fresh ordered dict so this serializes cleanly into LabConfig.json.
        # Include Generation for VM creation logic
        $mediaSource = [ordered]@{ Type = $d.Type; Path = $d.Path; Generation = $d.Generation }
        $t.Node.PSObject.Properties.Remove('MediaSource')  # clear any stale value
        $t.Node | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
    }

    Write-LabLog "Media selection applied to $($targets.Count) VM(s)." -Level Info
}


$Script:ServerOSChoices = [ordered]@{
    'Server2025'   = 'Windows Server 2025'
    'Server2022'   = 'Windows Server 2022'
    'Server2019'   = 'Windows Server 2019'
    'Server2016'   = 'Windows Server 2016'
}
$Script:AnyOSChoices = [ordered]@{
    'Win11Pro'        = 'Windows 11 Pro'
    'Win11Enterprise' = 'Windows 11 Enterprise'
    'Win10Pro'        = 'Windows 10 Pro'
    'Win10Enterprise' = 'Windows 10 Enterprise'
    'Server2025'      = 'Windows Server 2025'
    'Server2022'      = 'Windows Server 2022'
    'Server2019'      = 'Windows Server 2019'
    'Server2016'      = 'Windows Server 2016'
}

function Invoke-LabConfigWizard {
    param(
        [pscustomobject]$ExistingConfig = $null,
        [array]$DomainControllers = @(),
        [array]$AdditionalVMs = @()
    )
    
    Write-Host ""
    Write-Host "=== Hyper-V Lab Configuration ===" -ForegroundColor Cyan
    Write-Host "Press Enter at any prompt to accept the default shown in [brackets]." -ForegroundColor DarkGray
    
    if ($ExistingConfig) {
        Write-Host "(Editing existing configuration. Press Enter to keep current value.)" -ForegroundColor DarkGray
        Write-Host ""
    }

    # Ask for lab mode: Domain or Workgroup
    $labModeOptions = @('Domain joined environment (Active Directory)', 'Workgroup environment (no domain)')
    $labModeDefaultIndex = if ($ExistingConfig) { 
        if ($ExistingConfig.DomainName) { 0 } else { 1 } 
    } else { 0 }
    
    Write-Host ""
    $labModeChoice = Read-LabMenuChoice -Prompt "Select lab environment type" -Options $labModeOptions -DefaultIndex $labModeDefaultIndex
    
    $isDomainLab = ($labModeChoice -eq 0)
    
    if (-not $isDomainLab) {
        # Workgroup mode - minimal configuration
        Write-Host ""
        Write-Host "=== Workgroup Lab Configuration ===" -ForegroundColor Cyan
        $domainName = ''
        $netbiosName = ''
        
        # Get existing VM count if editing config (normalize single-item arrays)
        $existingVmCount = 0
        if ($ExistingConfig -and $ExistingConfig.AdditionalVMs) {
            $vmList = $ExistingConfig.AdditionalVMs
            if ($vmList -isnot [array]) { $vmList = @($vmList) }
            $existingVmCount = $vmList.Count
        }
        
        # Skip DC configuration for workgroup mode
        # Ensure DomainControllers is always an array (single item from JSON becomes object)
        if ($DomainControllers -isnot [array]) { 
            $dcs = @($DomainControllers) 
        } else { 
            $dcs = $DomainControllers 
        }
        if (-not $dcs) { $dcs = @() }
        $sameConfigAllDCs = $false
        $dcVCpu = 2; $dcMemStartup = 4; $dcMemMax = 8
        $dcCount = 0  # Workgroup mode has no domain controllers
    } else {
        Write-Host ""
        $domainNameDefault = if ($ExistingConfig) { $ExistingConfig.DomainName } else { 'lab.local' }
        $domainName = Read-LabString -Prompt "Domain FQDN" -Default $domainNameDefault `
            -Validate { param($v) $v -match '^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$' } `
            -ValidationMessage "Enter a valid FQDN, e.g. lab.local or corp.contoso.com"
        $defaultNetbios = if ($ExistingConfig) { $ExistingConfig.NetBIOSName } else { ($domainName.Split('.')[0]).ToUpper() }
        if ($defaultNetbios.Length -gt 15) { $defaultNetbios = $defaultNetbios.Substring(0, 15) }
        $netbiosName = Read-LabString -Prompt "NetBIOS domain name" -Default $defaultNetbios `
            -Validate { param($v) $v.Length -le 15 -and $v -match '^[A-Za-z0-9-]+$' } `
            -ValidationMessage "15 characters or fewer, letters/digits/hyphens only."

        # Get existing DC count if editing config (default to 1 for new labs)
        $existingDcCount = 1
        if ($ExistingConfig -and $ExistingConfig.DomainControllers) {
            # Normalize single-item arrays to ensure .Count works correctly
            $dcList = $ExistingConfig.DomainControllers
            if ($dcList -isnot [array]) { $dcList = @($dcList) }
            $existingDcCount = $dcList.Count
        }
        
        Write-Host ""
        $dcCount = Read-LabInt -Prompt "How many domain controllers?" -Default ([Math]::Max(1, $existingDcCount)) -Min 1 -Max 5
        
        $serverOptions = @($Script:ServerOSChoices.Values)
        $serverKeys = @($Script:ServerOSChoices.Keys)

        # Ask if all DCs should have the same configuration
        Write-Host ""
        Write-Host "--- Domain Controller Configuration ---" -ForegroundColor Cyan
        $sameConfigAllDCsDefault = if ($ExistingConfig) { $ExistingConfig.SameConfigAllDCs } else { $true }
        $sameConfigAllDCs = Read-LabYesNo -Prompt "Do all domain controllers have the same configuration (CPU/RAM)?" -Default $sameConfigAllDCsDefault

        # Reuse existing DCs if editing config, otherwise create new
        # Ensure DomainControllers is always an array (single item from JSON becomes object)
        if ($DomainControllers -isnot [array]) { 
            $dcs = @($DomainControllers) 
        } else { 
            $dcs = $DomainControllers 
        }
        if (-not $dcs) { $dcs = @() }
        
        # If no passed-in DCs and we have ExistingConfig, use it (for backward compatibility)
        if ($dcs.Count -eq 0 -and $ExistingConfig -and $ExistingConfig.DomainControllers) {
            $dcList = $ExistingConfig.DomainControllers
            # Normalize single-item arrays to ensure .Count works correctly
            if ($dcList -isnot [array]) {
                $dcs = @($dcList)
            } else {
                $dcs = $dcList
            }
        }
    }
    for ($i = 0; $i -lt $dcCount; $i++) {
        Write-Host ""
        Write-Host "--- Domain Controller $($i + 1) of $dcCount ---" -ForegroundColor Cyan
        
        # Get existing DC if editing config (use normalized $dcs array)
        $existingDc = if ($dcs -and $i -lt $dcs.Count) {
            $dcs[$i]
        } else {
            $null
        }
        
        $nameDefault = if ($existingDc) { $existingDc.Name } else { "DC$($i + 1)" }
        $name = Read-LabString -Prompt "VM name" -Default $nameDefault `
            -Validate { param($v) $v -match '^[A-Za-z0-9-]{1,15}$' } -ValidationMessage "1-15 characters, letters/digits/hyphens only."
        
        # Get OS key
        $osKey = if ($existingDc) {
            $existingDc.OSKey
        } else {
            $serverKeys[(Read-LabMenuChoice -Prompt "Operating system" -Options $serverOptions -DefaultIndex 0)]
        }
        
        # Get DC-specific configuration if not using same config for all
        $vCpu = $null
        $memStartup = $null
        $memMax = $null
        if (-not $sameConfigAllDCs) {
            Write-Host "  Configuration for ${name}:" -ForegroundColor DarkGray
            $vCpuDefault = if ($existingDc) { $existingDc.VCpu } else { 2 }
            $memStartupDefault = if ($existingDc) { $existingDc.MemoryStartupGB } else { 4 }
            $memMaxDefault = if ($existingDc) { $existingDc.MemoryMaxGB } else { 8 }
            
            $vCpu = Read-LabInt -Prompt "    Virtual CPU count" -Default $vCpuDefault -Min 1 -Max 8
            $memStartup = Read-LabInt -Prompt "    Startup RAM (GB)" -Default $memStartupDefault -Min 1 -Max 64
            $memMax = Read-LabInt -Prompt "    Maximum RAM (GB)" -Default $memMaxDefault -Min 1 -Max 128
        }
        
        # Update existing DC or create new entry
        if ($existingDc) {
            $existingDc.Name = $name
            $existingDc.OSKey = $osKey
            if (-not $sameConfigAllDCs) {
                $existingDc.VCpu = $vCpu
                $existingDc.MemoryStartupGB = $memStartup
                $existingDc.MemoryMaxGB = $memMax
            }
            # Ensure IPAddress property exists (for backward compatibility with old configs)
            if (-not ($existingDc.PSObject.Properties.Name -contains 'IPAddress')) {
                $existingDc | Add-Member -MemberType NoteProperty -Name 'IPAddress' -Value $null
            }
            $dcs[$i] = $existingDc
        } else {
            $dcs += [pscustomobject][ordered]@{ Name = $name; OSKey = $osKey; VCpu = $vCpu; MemoryStartupGB = $memStartup; MemoryMaxGB = $memMax; IPAddress = $null }
        }
    }
    
    # Truncate array if DC count was reduced
    if ($dcs.Count -gt $dcCount) {
        $dcs = $dcs[0..($dcCount-1)]
    }
    
    # Domain-specific configuration (only for domain labs)
    if ($isDomainLab) {
        # If all DCs have same config, prompt for those specs now
        if ($sameConfigAllDCs) {
            Write-Host ""
            Write-Host "--- Domain Controller Global Configuration ---" -ForegroundColor Cyan
            Write-Host "Enter configuration for all domain controllers:" -ForegroundColor DarkGray
            
            $dcVCpuDefault = 2; $dcMemStartupDefault = 4; $dcMemMaxDefault = 8
            if ($dcs.Count -gt 0) {
                # Use existing values only if they're not null (i.e., from editing existing config)
                if ($null -ne $dcs[0].VCpu) { $dcVCpuDefault = $dcs[0].VCpu }
                if ($null -ne $dcs[0].MemoryStartupGB) { $dcMemStartupDefault = $dcs[0].MemoryStartupGB }
                if ($null -ne $dcs[0].MemoryMaxGB) { $dcMemMaxDefault = $dcs[0].MemoryMaxGB }
            }
            
            $dcVCpu = Read-LabInt -Prompt "Virtual CPU count per DC" -Default $dcVCpuDefault -Min 1 -Max 8
            $dcMemStartup = Read-LabInt -Prompt "Startup RAM (GB) per DC" -Default $dcMemStartupDefault -Min 1 -Max 64
            $dcMemMax = Read-LabInt -Prompt "Maximum RAM (GB) per DC" -Default $dcMemMaxDefault -Min 1 -Max 128
            
            # Update all DCs with the global config
            foreach ($dc in $dcs) {
                $dc.VCpu = $dcVCpu
                $dc.MemoryStartupGB = $dcMemStartup
                $dc.MemoryMaxGB = $dcMemMax
            }
        }

        # Forest/domain functional level can't exceed what the oldest-OS DC supports.
        $forestModeDefault = if ($ExistingConfig) { $ExistingConfig.ForestMode } else { 'Win2016' }
        $availableForestModes = @('Win2016', 'Win2019', 'Win2022', 'Win2025')
        $forestModePrompt = "Forest/Domain functional level [$($availableForestModes -join ', ')]"
        $forestMode = Read-LabString -Prompt $forestModePrompt -Default $forestModeDefault `
            -Validate { param($v) $v -match '^(Win2016|Win2019|Win2022|Win2025)$' } `
            -ValidationMessage "Must be one of: Win2016, Win2019, Win2022, Win2025"

        $dhcpHostNameDefault = if ($ExistingConfig) { $ExistingConfig.DhcpHostName } else { if ($dcs.Count -gt 0) { $dcs[0].Name } else { '' } }
        $validDcNames = @($dcs.Name | Where-Object { $_ })
        $dhcpHostName = Read-LabString -Prompt "DHCP host (domain controller)" -Default $dhcpHostNameDefault `
            -Validate { param($v) $v -in $validDcNames } `
            -ValidationMessage ("Must be one of: " + ($validDcNames -join ', '))
        if ($dcCount -gt 1) {
            Write-Host ""
            $idx = Read-LabMenuChoice -Prompt "Which domain controller should run DHCP?" -Options $validDcNames -DefaultIndex 0
            $dhcpHostName = $validDcNames[$idx]
        }

        # Get existing DNS and VM count if editing config (normalize single-item arrays)
        $existingWantDns = $false
        $existingVmCount = 0
        if ($ExistingConfig) {
            if ($ExistingConfig.AdditionalVMs) {
                $vmList = $ExistingConfig.AdditionalVMs
                if ($vmList -isnot [array]) { $vmList = @($vmList) }
                $existingVmCount = $vmList.Count
                # For DNS check, normalize to array for Where-Object
                $dnsCount = @($vmList | Where-Object { $_.Role -eq 'DNS' }).Count
                $existingWantDns = $dnsCount -gt 0
            }
        }
        
        Write-Host ""
        $wantSeparateDns = Read-LabYesNo -Prompt "Also deploy a separate, dedicated DNS server (secondary zone, on top of the DCs' built-in DNS)?" -Default $existingWantDns

        # Get VM count for additional machines (normalize single-item arrays)
        $vmCountDefault = if ($ExistingConfig -and $ExistingConfig.AdditionalVMs) {
            $vmList = $ExistingConfig.AdditionalVMs
            if ($vmList -isnot [array]) { $vmList = @($vmList) }
            $vmList.Count
        } else { 0 }
        Write-Host ""
        $vmCount = Read-LabInt -Prompt "How many other VMs (member servers / workstations)?" -Default $vmCountDefault -Min 0 -Max 20
    } else {
        # Workgroup mode: skip domain-specific prompts, just get VM count
        $forestMode = ''
        $dhcpHostName = ''
        $wantSeparateDns = $false
        
        # Get existing VM count if editing config (normalize single-item arrays)
        $existingVmCount = 0
        if ($ExistingConfig -and $ExistingConfig.AdditionalVMs) {
            $vmList = $ExistingConfig.AdditionalVMs
            if ($vmList -isnot [array]) { $vmList = @($vmList) }
            $existingVmCount = $vmList.Count
        }
        
        Write-Host ""
        $vmCount = Read-LabInt -Prompt "How many VMs (member servers / workstations)?" -Default $existingVmCount -Min 0 -Max 20
        
        # For workgroup mode, use defaults for DC config (not used but needed for config object)
        $dcVCpu = 2; $dcMemStartup = 4; $dcMemMax = 8
        
        # Ask about DHCP installation in workgroup mode
        $existingWantDhcp = if ($ExistingConfig) { [bool]$ExistingConfig.DhcpHostName } else { $false }
        Write-Host ""
        $wantDhcpInWorkgroup = Read-LabYesNo -Prompt "Install DHCP on one of the member VMs?" -Default $existingWantDhcp
    }

    $anyOptions = @($Script:AnyOSChoices.Values)
    $anyKeys = @($Script:AnyOSChoices.Keys)

    # Ask if all VMs should have the same configuration
    Write-Host ""
    Write-Host "--- VM Configuration ---" -ForegroundColor Cyan
    $sameConfigAllVMsDefault = if ($ExistingConfig) { $ExistingConfig.SameConfigAllVMs } else { $true }
    $sameConfigAllVMs = Read-LabYesNo -Prompt "Do all additional VMs have the same configuration (CPU/RAM)?" -Default $sameConfigAllVMsDefault

    # Reuse existing VMs if editing config, otherwise create new
    # Ensure AdditionalVMs is always an array (single item from JSON becomes object)
    if ($AdditionalVMs -isnot [array]) { 
        $additionalVMs = @($AdditionalVMs) 
    } else { 
        $additionalVMs = $AdditionalVMs 
    }
    if (-not $additionalVMs) { $additionalVMs = @() }
    
    # If no passed-in VMs and we have ExistingConfig, use it (for backward compatibility)
    if ($additionalVMs.Count -eq 0 -and $ExistingConfig -and $ExistingConfig.AdditionalVMs) {
        $vmList = $ExistingConfig.AdditionalVMs
        if ($vmList -isnot [array]) {
            $additionalVMs = @($vmList)
        } else {
            $additionalVMs = $vmList
        }
    }
    
    # Get network configuration before VM config (for workgroup DHCP support)
    $existingSubnetCidr = if ($ExistingConfig) { $ExistingConfig.SubnetCidr } else { '192.168.50.0/24' }
    $existingSwitchName = if ($ExistingConfig) { $ExistingConfig.SwitchName } else { 'LabSwitch' }
    
    Write-Host ""
    Write-Host "--- Network (Internal switch + NAT, isolated from your physical LAN) ---" -ForegroundColor Cyan
    $subnetCidr = Read-LabString -Prompt "Lab subnet (CIDR)" -Default $existingSubnetCidr `
        -Validate { param($v) $v -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$' } -ValidationMessage "Use CIDR notation, e.g. 192.168.50.0/24"
    $networkBase = $subnetCidr.Split('/')[0]
    $prefixLength = [int]($subnetCidr.Split('/')[1])
    $octets = $networkBase.Split('.')
    $thirdOctetPrefix = "$($octets[0]).$($octets[1]).$($octets[2])"
    
    $existingGateway = if ($ExistingConfig) { 
        # Extract gateway from existing config
        $existingSubnet = $ExistingConfig.SubnetCidr.Split('/')[0]
        $existingOctets = $existingSubnet.Split('.')
        "$($existingOctets[0]).$($existingOctets[1]).$($existingOctets[2]).1"
    } else { "$thirdOctetPrefix.1" }
    
    $gateway = Read-LabString -Prompt "Gateway / host address" -Default $existingGateway
    $switchName = Read-LabString -Prompt "Hyper-V switch name" -Default $existingSwitchName
    
    # Get existing DHCP range if editing config
    $existingDhcpStart = if ($ExistingConfig) { 
        $existingSubnet = $ExistingConfig.SubnetCidr.Split('/')[0]
        $existingOctets = $existingSubnet.Split('.')
        "$($existingOctets[0]).$($existingOctets[1]).$($existingOctets[2]).100"
    } else { "$thirdOctetPrefix.100" }
    
    $existingDhcpEnd = if ($ExistingConfig) { 
        $existingSubnet = $ExistingConfig.SubnetCidr.Split('/')[0]
        $existingOctets = $existingSubnet.Split('.')
        "$($existingOctets[0]).$($existingOctets[1]).$($existingOctets[2]).200"
    } else { "$thirdOctetPrefix.200" }
    
    $dhcpStart = Read-LabString -Prompt "DHCP scope start" -Default $existingDhcpStart
    $dhcpEnd = Read-LabString -Prompt "DHCP scope end" -Default $existingDhcpEnd

    # Static addresses for DCs, sequential starting at .10 - everything else uses DHCP.
    for ($i = 0; $i -lt $dcs.Count; $i++) {
        $dcs[$i].IPAddress = "$thirdOctetPrefix.$(10 + $i)"
    }

    Write-Host ""
    Write-Host "--- VM Configuration ---" -ForegroundColor Cyan
    for ($i = 0; $i -lt $vmCount; $i++) {
        Write-Host ""
        Write-Host "--- VM $($i + 1) of $vmCount ---" -ForegroundColor Cyan
        
        # Get existing VM if editing config (use normalized $additionalVMs array)
        $existingVm = if ($additionalVMs -and $i -lt $additionalVMs.Count) {
            $additionalVMs[$i]
        } else {
            $null
        }
        
        $nameDefault = if ($existingVm) { $existingVm.Name } else { "VM$($i + 1)" }
        $name = Read-LabString -Prompt "VM name" -Default $nameDefault `
            -Validate { param($v) $v -match '^[A-Za-z0-9-]{1,15}$' } -ValidationMessage "1-15 characters, letters/digits/hyphens only."
        
        # Get OS key
        $osKey = if ($existingVm) {
            $existingVm.OSKey
        } else {
            $anyKeys[(Read-LabMenuChoice -Prompt "Operating system" -Options $anyOptions -DefaultIndex 0)]
        }
        
        # Get role
        $role = if ($existingVm) {
            $existingVm.Role
        } else {
            'Member'
        }
        
        # Get VM-specific configuration if not using same config for all
        $vCpu = $null
        $memStartup = $null
        $memMax = $null
        if (-not $sameConfigAllVMs) {
            Write-Host "  Configuration for ${name}:" -ForegroundColor DarkGray
            $vCpuDefault = if ($existingVm) { $existingVm.VCpu } else { 2 }
            $memStartupDefault = if ($existingVm) { $existingVm.MemoryStartupGB } else { 4 }
            $memMaxDefault = if ($existingVm) { $existingVm.MemoryMaxGB } else { 8 }
            
            $vCpu = Read-LabInt -Prompt "    Virtual CPU count" -Default $vCpuDefault -Min 1 -Max 8
            $memStartup = Read-LabInt -Prompt "    Startup RAM (GB)" -Default $memStartupDefault -Min 1 -Max 64
            $memMax = Read-LabInt -Prompt "    Maximum RAM (GB)" -Default $memMaxDefault -Min 1 -Max 128
        }
        
        # Update existing VM or create new entry
        if ($existingVm) {
            $existingVm.Name = $name
            $existingVm.OSKey = $osKey
            if (-not $sameConfigAllVMs) {
                $existingVm.VCpu = $vCpu
                $existingVm.MemoryStartupGB = $memStartup
                $existingVm.MemoryMaxGB = $memMax
            }
            # Add IPAddress property for workgroup DHCP support (if not already present)
            if (-not $isDomainLab -and $wantDhcpInWorkgroup) {
                if ($i -eq 0) {
                    $existingVm.IPAddress = "$thirdOctetPrefix.50"  # First VM hosts DHCP
                } else {
                    $existingVm.IPAddress = $null  # Other VMs use DHCP
                }
            }
            $additionalVMs[$i] = $existingVm
        } else {
            # Add IPAddress property for workgroup DHCP support
            if (-not $isDomainLab -and $wantDhcpInWorkgroup -and $i -eq 0) {
                $additionalVMs += [pscustomobject][ordered]@{ Name = $name; OSKey = $osKey; Role = $role; VCpu = $vCpu; MemoryStartupGB = $memStartup; MemoryMaxGB = $memMax; IPAddress = "$thirdOctetPrefix.50" }
            } else {
                $additionalVMs += [pscustomobject][ordered]@{ Name = $name; OSKey = $osKey; Role = $role; VCpu = $vCpu; MemoryStartupGB = $memStartup; MemoryMaxGB = $memMax; IPAddress = $null }
            }
        }
    }

    # Truncate array if VM count was reduced
    if ($additionalVMs.Count -gt $vmCount) {
        $additionalVMs = $additionalVMs[0..($vmCount-1)]
    }

    if ($wantSeparateDns) {
        Write-Host ""
        Write-Host "--- Dedicated DNS server ---" -ForegroundColor Cyan
        
        # Check if DNS VM already exists
        $dnsVm = if ($ExistingConfig -and $ExistingConfig.AdditionalVMs) {
            $ExistingConfig.AdditionalVMs | Where-Object { $_.Role -eq 'DNS' } | Select-Object -First 1
        } else {
            $null
        }
        
        $nameDefault = if ($dnsVm) { $dnsVm.Name } else { "DNS1" }
        $name = Read-LabString -Prompt "VM name" -Default $nameDefault `
            -Validate { param($v) $v -match '^[A-Za-z0-9-]{1,15}$' } -ValidationMessage "1-15 characters, letters/digits/hyphens only."
        
        # Get OS key for DNS server
        $osKey = if ($dnsVm) {
            $dnsVm.OSKey
        } else {
            $serverKeys[(Read-LabMenuChoice -Prompt "Operating system" -Options $serverOptions -DefaultIndex 0)]
        }
        
        # Check if DNS VM already exists and update it, or add new
        if ($dnsVm) {
            $dnsVm.Name = $name
            $dnsVm.OSKey = $osKey
            # Find and replace in additionalVMs
            for ($i = 0; $i -lt $additionalVMs.Count; $i++) {
                if ($additionalVMs[$i].Role -eq 'DNS') {
                    $additionalVMs[$i] = $dnsVm
                    break
                }
            }
        } else {
            $additionalVMs += [pscustomobject][ordered]@{ Name = $name; OSKey = $osKey; Role = 'DNS' }
        }
    }

    # Get global VM config values (for LabConfig.json)
    Write-Host ""
    Write-Host "--- VM Configuration ---" -ForegroundColor Cyan
    Write-Host "Virtual CPU and memory settings for all VMs (can be customized per VM later)." -ForegroundColor DarkGray
    
    $existingVCpu = 2; $existingMemStartup = 4; $existingMemMax = 8
    if ($ExistingConfig) {
        $existingVCpu = $ExistingConfig.VMVCpuCount
        $existingMemStartup = $ExistingConfig.VMMemoryStartupGB
        $existingMemMax = $ExistingConfig.VMMemoryMaxGB
    }
    
    $vCpuCount = Read-LabInt -Prompt "Virtual CPU count per VM" -Default $existingVCpu -Min 1 -Max 8
    $memoryStartupGB = Read-LabInt -Prompt "Startup RAM (GB) per VM" -Default $existingMemStartup -Min 1 -Max 64
    $memoryMaxGB = Read-LabInt -Prompt "Maximum RAM (GB) per VM" -Default $existingMemMax -Min 1 -Max 128

    Write-Host ""
    Write-Host "--- Credentials ---" -ForegroundColor Cyan
    Write-Host "Configure passwords for your lab environment." -ForegroundColor DarkGray
    Write-Host ""
    
    # For domain labs, ask about custom passwords; for workgroup, always use same password
    if ($isDomainLab) {
        $useCustomPasswordsDefault = if ($ExistingConfig) { $ExistingConfig.UseCustomPasswords } else { $false }
        $useCustomPasswords = Read-LabYesNo -Prompt "Use different passwords for local admin and domain admin?" -Default $useCustomPasswordsDefault
    } else {
        # Workgroup mode: same password everywhere (just local admin)
        $useCustomPasswords = $false
    }
    
    # Determine if we're editing (to know if we should keep existing passwords)
    $isEditing = [bool]$ExistingConfig
    
    if ($useCustomPasswords) {
        Write-Host ""
        Write-Host "Local Administrator Password (for all VMs):" -ForegroundColor Cyan
        
        # Check if existing config has local admin password
        $existingLocalAdminSet = if ($ExistingConfig -and $ExistingConfig.LocalAdminPassword) { $true } else { $false }
        if ($isEditing -and $existingLocalAdminSet) {
            Write-Host "(Press Enter to keep existing local admin password)" -ForegroundColor DarkGray
        }
        
        # Only prompt for new password if not editing or no existing password
        if ($isEditing -and $existingLocalAdminSet) {
            $localAdminPassword = Read-LabAdminPassword -AllowKeepExisting
            if (-not $localAdminPassword) {
                $localAdminPassword = $ExistingConfig.LocalAdminPassword
            }
        } else {
            $localAdminPassword = Read-LabAdminPassword
        }
        
        Write-Host ""
        Write-Host "Domain Administrator Password (for DCs):" -ForegroundColor Cyan
        
        # Check if existing config has domain admin password
        $existingDomainAdminSet = if ($ExistingConfig -and $ExistingConfig.DomainAdminPassword) { $true } else { $false }
        if ($isEditing -and $existingDomainAdminSet) {
            Write-Host "(Press Enter to keep existing domain admin password)" -ForegroundColor DarkGray
        }
        
        # Only prompt for new password if not editing or no existing password
        if ($isEditing -and $existingDomainAdminSet) {
            $domainAdminPassword = Read-LabAdminPassword -AllowKeepExisting
            if (-not $domainAdminPassword) {
                $domainAdminPassword = $ExistingConfig.DomainAdminPassword
            }
        } else {
            $domainAdminPassword = Read-LabAdminPassword
        }
        
        # Ask if adding a custom local admin account
        $addCustomAdminDefault = if ($ExistingConfig) { $ExistingConfig.AddCustomAdmin } else { $false }
        $addCustomAdmin = Read-LabYesNo -Prompt "Add a custom local administrator account on all VMs?" -Default $addCustomAdminDefault
        
        $customAdminName = $null
        $customAdminPassword = $null
        if ($addCustomAdmin) {
            $existingCustomName = if ($ExistingConfig) { $ExistingConfig.CustomAdminName } else { "labadmin" }
            $customAdminName = Read-LabString -Prompt "Custom admin username" -Default $existingCustomName `
                -Validate { param($v) $v -match '^[A-Za-z][A-Za-z0-9_]{1,20}$' } -ValidationMessage "Starts with letter, 2-20 chars (letters, digits, underscore)."
            Write-Host ""
            Write-Host "Custom admin password:" -ForegroundColor Cyan
            $customAdminPassword = Read-LabAdminPassword
        }
    } else {
        # Same password everywhere
        Write-Host ""
        Write-Host "One password is used everywhere in this lab (local admin on every VM, Domain" -ForegroundColor DarkGray
        Write-Host "Administrator once promoted, and DSRM). It is kept in memory only for this run" -ForegroundColor DarkGray
        Write-Host "and never written to disk - you'll be asked for it again next time you resume." -ForegroundColor DarkGray
        Write-Host ""
        
        # Check if existing config has password
        $existingPasswordSet = if ($ExistingConfig -and $ExistingConfig.DomainAdminPassword) { $true } else { $false }
        if ($isEditing -and $existingPasswordSet) {
            Write-Host "(Press Enter to keep existing password)" -ForegroundColor DarkGray
        }
        
        # Only prompt for new password if not editing or no existing password
        if ($isEditing -and $existingPasswordSet) {
            $adminPassword = Read-LabAdminPassword -AllowKeepExisting
            if (-not $adminPassword) {
                $adminPassword = $ExistingConfig.DomainAdminPassword
            }
        } else {
            $adminPassword = Read-LabAdminPassword
        }
        
        $localAdminPassword = $adminPassword
        $domainAdminPassword = $adminPassword
        $addCustomAdmin = $false
        $customAdminName = $null
        $customAdminPassword = $null
    }

    $config = [ordered]@{
        SchemaVersion      = 1
        IsDomainLab        = $isDomainLab
        DomainName         = $domainName
        NetBIOSName        = $netbiosName
        ForestMode         = $forestMode
        DomainControllers  = $dcs
        DhcpHostName       = $dhcpHostName
        AdditionalVMs      = $additionalVMs
        SwitchName         = $switchName
        NetworkMode        = 'InternalNAT'
        SubnetCidr         = $subnetCidr
        Gateway            = $gateway
        DhcpScopeStart     = $dhcpStart
        DhcpScopeEnd       = $dhcpEnd
        DhcpSubnetMask     = (ConvertTo-LabSubnetMask -PrefixLength $prefixLength)
        ScopeId            = $networkBase
        TimeZone           = (Get-TimeZone).Id
        Locale             = (Get-Culture).Name
        VMVCpuCount        = $vCpuCount
        VMMemoryStartupGB  = $memoryStartupGB
        VMMemoryMaxGB      = $memoryMaxGB
        SameConfigAllDCs   = $sameConfigAllDCs
        SameConfigAllVMs   = $sameConfigAllVMs
        UseCustomPasswords = $useCustomPasswords
        LocalAdminPassword = $localAdminPassword
        DomainAdminPassword = $domainAdminPassword
        AddCustomAdmin     = $addCustomAdmin
        CustomAdminName    = $customAdminName
        CustomAdminPassword = $customAdminPassword
        WantDhcpInWorkgroup = if ($isDomainLab) { $false } else { $wantDhcpInWorkgroup }
        CompletedSteps     = @()
    }

    return @([pscustomobject]$config, $localAdminPassword, $domainAdminPassword, $customAdminName, $customAdminPassword)
}

# ===================================================================================
# MAIN EXECUTION - Wrapped in try-catch for detailed error reporting
# ===================================================================================
try {
    # ===================================================================================
    # LOAD OR BUILD CONFIGURATION
    # ===================================================================================
    $ConfigPath = Join-Path $Paths.Config 'LabConfig.json'

# Only load existing config if not using -Reset
$ExistingConfig = if (-not $Reset) { Get-LabConfig -Path $ConfigPath } else { $null }

# Normalize arrays in ExistingConfig for use throughout the script (single-item JSON arrays become PSObjects)
if ($ExistingConfig) {
    if (-not $ExistingConfig.DomainControllers -or @($ExistingConfig.DomainControllers | Where-Object { $_ -ne $null }).Count -eq 0) { $ExistingConfig.DomainControllers = @() } elseif ($ExistingConfig.DomainControllers -isnot [array]) { $ExistingConfig.DomainControllers = @($ExistingConfig.DomainControllers | Where-Object { $_ -ne $null }) }
    if (-not $ExistingConfig.AdditionalVMs -or @($ExistingConfig.AdditionalVMs | Where-Object { $_ -ne $null }).Count -eq 0) { $ExistingConfig.AdditionalVMs = @() } elseif ($ExistingConfig.AdditionalVMs -isnot [array]) { $ExistingConfig.AdditionalVMs = @($ExistingConfig.AdditionalVMs | Where-Object { $_ -ne $null }) }
    if (-not $ExistingConfig.CompletedSteps) { $ExistingConfig.CompletedSteps = @() } elseif ($ExistingConfig.CompletedSteps -isnot [array]) { $ExistingConfig.CompletedSteps = @($ExistingConfig.CompletedSteps) }
}

# Initialize variables for DCs and VMs (used throughout the script)
$dcs = if ($ExistingConfig -and $ExistingConfig.DomainControllers -and @($ExistingConfig.DomainControllers | Where-Object { $_ -ne $null }).Count -gt 0) { $ExistingConfig.DomainControllers | Where-Object { $_ -ne $null } } else { @() }
$additionalVMs = if ($ExistingConfig -and $ExistingConfig.AdditionalVMs -and @($ExistingConfig.AdditionalVMs | Where-Object { $_ -ne $null }).Count -gt 0) { $ExistingConfig.AdditionalVMs | Where-Object { $_ -ne $null } } else { @() }

# ===================================================================================
# TEAR-DOWN SHORT-CIRCUIT  (-TearDown: destroy VMs, clear progress, keep media, exit)
# ===================================================================================
# Placed before the wizard/reset branch so -TearDown never re-runs the wizard.
# Removing VMs needs no guest credentials, so no password prompt is shown. The
# shared module + child scripts are already dot-sourced above, so Invoke-LabTearDown
# and Save-LabConfig are available here.
if ($TearDown) {
    if (-not $ExistingConfig) {
        Write-LabLog "No existing config found at $ConfigPath - nothing to tear down." -Level Warn
        return
    }
    Invoke-LabTearDown -Config $ExistingConfig -ConfigPath $ConfigPath -VMsRoot $Paths.VMs -RemoveSwitch:$RemoveSwitch
    return
}

if ($Reset -or -not $ExistingConfig) {
    $wizardResult = Invoke-LabConfigWizard -DomainControllers @() -AdditionalVMs @()
    $LabConfig = $wizardResult[0]
    $LocalAdminSecurePassword = $wizardResult[1]
    $DomainAdminSecurePassword = $wizardResult[2]
    $CustomAdminName = $wizardResult[3]
    $CustomAdminPassword = $wizardResult[4]
    # Set AdminSecurePassword as fallback for non-custom configs
    if ($LabConfig.UseCustomPasswords) {
        $AdminSecurePassword = $DomainAdminSecurePassword
    } else {
        $AdminSecurePassword = $DomainAdminSecurePassword
    }
    Save-LabConfig -Config $LabConfig -Path $ConfigPath
    Write-LabLog "Configuration saved to $ConfigPath" -Level Info
} else {
    Write-LabLog "Resuming existing configuration from $ConfigPath (steps already completed will be skipped; use -Reset to start over)." -Level Info
    
    # Ask if user wants to edit the existing configuration
    Write-Host ""
    Write-Host "=== Configuration Loaded ===" -ForegroundColor Cyan
    Write-Host "Domain: $($ExistingConfig.DomainName)" -ForegroundColor DarkGray
    # Normalize arrays for display (single-item JSON arrays become PSObjects)
    $dcCountDisplay = if ($ExistingConfig.DomainControllers -is [array]) { $ExistingConfig.DomainControllers.Count } else { 1 }
    $vmCountDisplay = if ($ExistingConfig.AdditionalVMs -is [array]) { $ExistingConfig.AdditionalVMs.Count } else { 1 }
    Write-Host "Domain Controllers: $dcCountDisplay" -ForegroundColor DarkGray
    Write-Host "Additional VMs: $vmCountDisplay" -ForegroundColor DarkGray
    $editConfig = Read-LabYesNo -Prompt "Would you like to edit any part of this configuration?" -Default $false
    
    if ($editConfig) {
        Write-Host ""
        Write-Host "=== Editing Configuration ===" -ForegroundColor Cyan
        # Re-run the wizard but with existing values as defaults
        # Ensure arrays are passed correctly by wrapping in @()
        $wizardResult = Invoke-LabConfigWizard -ExistingConfig $ExistingConfig -DomainControllers @($dcs) -AdditionalVMs @($additionalVMs)
        $LabConfig = $wizardResult[0]
        
        # Preserve CompletedSteps from original config
        if ($ExistingConfig.CompletedSteps) {
            $LabConfig.CompletedSteps = $ExistingConfig.CompletedSteps
        }
    } else {
        $LabConfig = $ExistingConfig
    }
    
    # Assign normalized arrays to variables used later in the script (redundant but safe)
    $dcs = $LabConfig.DomainControllers
    $additionalVMs = $LabConfig.AdditionalVMs
    
    Write-Host ""
    
    # If we just edited the config, re-prompt for passwords (they were returned from wizard)
    if ($editConfig) {
        $LocalAdminSecurePassword = $wizardResult[1]
        $DomainAdminSecurePassword = $wizardResult[2]
        $CustomAdminName = $wizardResult[3]
        $CustomAdminPassword = $wizardResult[4]
        
        # Save updated config
        Save-LabConfig -Config $LabConfig -Path $ConfigPath
        Write-LabLog "Updated configuration saved to $ConfigPath" -Level Info
    } else {
        # For existing config (not edited), ask for passwords based on configuration
        if ($LabConfig.UseCustomPasswords) {
            $LocalAdminSecurePassword = Read-Host "Re-enter the Local Administrator password for this lab" -AsSecureString
            $DomainAdminSecurePassword = Read-Host "Re-enter the Domain Administrator password for this lab" -AsSecureString
            $AdminSecurePassword = $DomainAdminSecurePassword  # fallback for non-custom configs
        } else {
            $AdminSecurePassword = Read-Host "Re-enter the Administrator password for this lab (needed to talk to already-created VMs)" -AsSecureString
            $LocalAdminSecurePassword = $AdminSecurePassword
            $DomainAdminSecurePassword = $AdminSecurePassword
            $CustomAdminName = $LabConfig.CustomAdminName
            $CustomAdminPassword = $LabConfig.CustomAdminPassword
        }
    }
    
    # Initialize scannedMedia for this session - will be populated by the main scan later
    $scannedMedia = @()
    
    # Ensure MediaSource properties are set for all VMs (in case they were missing from old configs)
    $hasPriorMediaSelection = $false
    foreach ($dc in $LabConfig.DomainControllers) {
        # Check if MediaSource is missing, incomplete, or has wrong Generation
        $needsUpdate = -not $dc.PSObject.Properties['MediaSource'] -or -not $dc.MediaSource.Type
        if (-not $needsUpdate -and $dc.MediaSource.Path -and $scannedMedia) {
            # Check if the cached media matches and if Generation is correct
            $cachedItem = $scannedMedia | Where-Object { $_.Path -eq $dc.MediaSource.Path } | Select-Object -First 1
            if ($cachedItem) {
                $expectedGen = if ($cachedItem.Kind -eq 'Vhd') { 1 } else { 2 }
                if (-not $dc.MediaSource.Generation -or $dc.MediaSource.Generation -ne $expectedGen) {
                    $needsUpdate = $true
                }
            }
        }
        
        if ($needsUpdate) {
            # Try to find cached media for this VM
            $best = Get-LabBestMediaMatch -MediaItems $scannedMedia -OSKey $dc.OSKey
            if ($best) {
                # Determine generation based on media kind: VHD=Gen1, VHDX/ISO=Gen2
                $generation = if ($best.Kind -eq 'Vhd') { 1 } else { 2 }
                $mediaSource = [ordered]@{ Type = $best.Kind; Path = $best.Path; Generation = $generation }
                $dc | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
            } else {
                $mediaSource = [ordered]@{ Type = 'Download'; Path = $null; Generation = 2 }
                $dc | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
            }
        }
        if ($dc.PSObject.Properties['MediaSource'] -and $dc.MediaSource.Type) { $hasPriorMediaSelection = $true }
    }
    foreach ($vm in $LabConfig.AdditionalVMs) {
        # Check if MediaSource is missing, incomplete, or has wrong Generation
        $needsUpdate = -not $vm.PSObject.Properties['MediaSource'] -or -not $vm.MediaSource.Type
        if (-not $needsUpdate -and $vm.MediaSource.Path -and $scannedMedia) {
            # Check if the cached media matches and if Generation is correct
            $cachedItem = $scannedMedia | Where-Object { $_.Path -eq $vm.MediaSource.Path } | Select-Object -First 1
            if ($cachedItem) {
                $expectedGen = if ($cachedItem.Kind -eq 'Vhd') { 1 } else { 2 }
                if (-not $vm.MediaSource.Generation -or $vm.MediaSource.Generation -ne $expectedGen) {
                    $needsUpdate = $true
                }
            }
        }
        
        if ($needsUpdate) {
            # Try to find cached media for this VM
            $best = Get-LabBestMediaMatch -MediaItems $scannedMedia -OSKey $vm.OSKey
            if ($best) {
                # Determine generation based on media kind: VHD=Gen1, VHDX/ISO=Gen2
                $generation = if ($best.Kind -eq 'Vhd') { 1 } else { 2 }
                $mediaSource = [ordered]@{ Type = $best.Kind; Path = $best.Path; Generation = $generation }
                $vm | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
            } else {
                $mediaSource = [ordered]@{ Type = 'Download'; Path = $null; Generation = 2 }
                $vm | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
            }
        }
        if ($vm.PSObject.Properties['MediaSource'] -and $vm.MediaSource.Type) { $hasPriorMediaSelection = $true }
    }
}
# Note: MediaSource update logic moved to after the main media scan (line ~4505)
# so it has actual media data to work with instead of an empty array
$SafeModePassword = $DomainAdminSecurePassword  # deliberately reused - see wizard banner above

$MediaSourcesPath = Join-Path $Paths.Config 'MediaSources.psd1'

# ===================================================================================
# MEDIA SCAN + SELECTION  (re-use existing ISO/VHDX instead of re-downloading)
# ===================================================================================
# Always scan: it's cheap (file enumeration + per-item edition read), and on a
# fresh lab with no cached media it simply returns an empty list and every VM
# falls back to "download fresh". On a resume it surfaces what's already on disk.
$scannedMedia = @()
try {
    Write-Host ""
    Write-Host "=== Scanning for Windows media (ISO, VHDX, VHD) ===" -ForegroundColor Cyan
    $scannedMedia = Invoke-LabMediaScan -MediaRoot $Paths.Media -VMsRoot $Paths.VMs
} catch {
    Write-LabLog "Media scan failed: $($_.Exception.Message)" -Level Warn
    $scannedMedia = @()
}

# Ensure scannedMedia is always an array
if (-not $scannedMedia) { $scannedMedia = @() }

Write-LabLog "Media scan complete. Found $($scannedMedia.Count) unique media file(s)" -Level Info

# Show summary of available media
Write-Host ""
Write-Host "=== Media Scan Summary ===" -ForegroundColor Cyan
if ($scannedMedia.Count -eq 0) {
    Write-Host "No cached ISO, VHDX, or VHD files found under Media folder." -ForegroundColor Yellow
} else {
    Write-Host "Found $($scannedMedia.Count) media file(s):" -ForegroundColor Green
    
    # Show detailed breakdown by type
    $isoFiles = @($scannedMedia | Where-Object { $_.Kind -eq 'Iso' })
    $vhdxFiles = @($scannedMedia | Where-Object { $_.Kind -eq 'Vhdx' })
    $vhdFiles = @($scannedMedia | Where-Object { $_.Kind -eq 'Vhd' })
    
    if ($isoFiles.Count -gt 0) {
        Write-Host "  ISO files: $($isoFiles.Count)" -ForegroundColor Cyan
        foreach ($f in $isoFiles) {
            Write-Host "    - $(Split-Path $f.Path -Leaf) [$($f.OSKey)]" -ForegroundColor DarkCyan
        }
    }
    
    if ($vhdxFiles.Count -gt 0) {
        Write-Host "  VHDX files: $($vhdxFiles.Count)" -ForegroundColor Cyan
        foreach ($f in $vhdxFiles) {
            Write-Host "    - $(Split-Path $f.Path -Leaf) [$($f.OSKey)]" -ForegroundColor DarkCyan
        }
    }
    
    if ($vhdFiles.Count -gt 0) {
        Write-Host "  VHD files: $($vhdFiles.Count)" -ForegroundColor Cyan
        foreach ($f in $vhdFiles) {
            Write-Host "    - $(Split-Path $f.Path -Leaf) [$($f.OSKey)]" -ForegroundColor DarkCyan
        }
    }
    
    Write-Host ""
    $mediaTable = $scannedMedia | ForEach-Object {
        $genInfo = if ($_.Kind -eq 'Vhd') { '(Gen 1)' } elseif ($_.Kind -eq 'Vhdx') { '(Gen 2)' } else { '' }
        [pscustomobject]@{
            Kind   = $_.Kind
            OSKey  = if ($_.OSKey) { $_.OSKey } else { '(unknown)' }
            SizeGB = [math]::Round($_.SizeBytes / 1GB, 1)
            Path   = Split-Path $_.Path -Leaf
        }
    }
    $mediaTable | Format-Table -AutoSize | Out-String | Write-Host
    
    # Ask user if they want to proceed with media selection
    Write-Host ""
    $proceedWithSelection = Read-LabYesNo -Prompt "Proceed with media selection for VMs?" -Default $true
    if (-not $proceedWithSelection) {
        Write-Host "Skipping media selection - all VMs will download fresh." -ForegroundColor Cyan
        # Stamp a Download decision on each VM so the orchestration path is uniform.
        foreach ($dc in $LabConfig.DomainControllers) {
            if (-not ($dc.PSObject.Properties['MediaSource'] -and $dc.MediaSource.Type)) {
                $dc | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]@{ Type = 'Download'; Path = $null; Generation = 2 }) -Force
            }
        }
        foreach ($vm in $LabConfig.AdditionalVMs) {
            if (-not ($vm.PSObject.Properties['MediaSource'] -and $vm.MediaSource.Type)) {
                $vm | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]@{ Type = 'Download'; Path = $null; Generation = 2 }) -Force
            }
        }
        Save-LabConfig -Config $LabConfig -Path $ConfigPath
    }
}

# Run the selection wizard unless -ScanOnly (which just reports and exits) or
# unless every VM already has a persisted MediaSource from a prior run. We still
# ask on -Reset so a re-plan can pick up newly-arrived media.

# Update MediaSource for all VMs based on scanned media (fixes wrong Generation values)
$hasPriorMediaSelection = $false
foreach ($dc in $LabConfig.DomainControllers) {
    # Check if MediaSource is missing, incomplete, or has wrong Generation
    $needsUpdate = -not $dc.PSObject.Properties['MediaSource'] -or -not $dc.MediaSource.Type
    if (-not $needsUpdate -and $dc.MediaSource.Path -and $scannedMedia) {
        # Check if the cached media matches and if Generation is correct
        $cachedItem = @($scannedMedia | Where-Object { $_.Path -eq $dc.MediaSource.Path } | Select-Object -First 1)
        if ($cachedItem) {
            $expectedGen = if ($cachedItem.Kind -eq 'Vhd') { 1 } else { 2 }
            if (-not $dc.MediaSource.Generation -or $dc.MediaSource.Generation -ne $expectedGen) {
                $needsUpdate = $true
            }
        }
    }
    
    if ($needsUpdate) {
        # Try to find cached media for this VM
        $best = Get-LabBestMediaMatch -MediaItems $scannedMedia -OSKey $dc.OSKey
        if ($best) {
            # Determine generation based on media kind: VHD=Gen1, VHDX/ISO=Gen2
            $generation = if ($best.Kind -eq 'Vhd') { 1 } else { 2 }
            $mediaSource = [ordered]@{ Type = $best.Kind; Path = $best.Path; Generation = $generation }
            $dc | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
        } else {
            $mediaSource = [ordered]@{ Type = 'Download'; Path = $null; Generation = 2 }
            $dc | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
        }
    }
    if ($dc.PSObject.Properties['MediaSource'] -and $dc.MediaSource.Type) { $hasPriorMediaSelection = $true }
}
foreach ($vm in $LabConfig.AdditionalVMs) {
    # Check if MediaSource is missing, incomplete, or has wrong Generation
    $needsUpdate = -not $vm.PSObject.Properties['MediaSource'] -or -not $vm.MediaSource.Type
    if (-not $needsUpdate -and $vm.MediaSource.Path -and $scannedMedia) {
        # Check if the cached media matches and if Generation is correct
        $cachedItem = @($scannedMedia | Where-Object { $_.Path -eq $vm.MediaSource.Path } | Select-Object -First 1)
        if ($cachedItem) {
            $expectedGen = if ($cachedItem.Kind -eq 'Vhd') { 1 } else { 2 }
            if (-not $vm.MediaSource.Generation -or $vm.MediaSource.Generation -ne $expectedGen) {
                $needsUpdate = $true
            }
        }
    }
    
    if ($needsUpdate) {
        # Try to find cached media for this VM
        $best = Get-LabBestMediaMatch -MediaItems $scannedMedia -OSKey $vm.OSKey
        if ($best) {
            # Determine generation based on media kind: VHD=Gen1, VHDX/ISO=Gen2
            $generation = if ($best.Kind -eq 'Vhd') { 1 } else { 2 }
            $mediaSource = [ordered]@{ Type = $best.Kind; Path = $best.Path; Generation = $generation }
            $vm | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
        } else {
            $mediaSource = [ordered]@{ Type = 'Download'; Path = $null; Generation = 2 }
            $vm | Add-Member -MemberType NoteProperty -Name MediaSource -Value ([pscustomobject]$mediaSource) -Force
        }
    }
    if ($vm.PSObject.Properties['MediaSource'] -and $vm.MediaSource.Type) { $hasPriorMediaSelection = $true }
}
$shouldAskMedia = (-not $ScanOnly) -and ($Reset -or -not $hasPriorMediaSelection)

if ($ScanOnly) {
    Write-Host ""
    Write-Host "(-ScanOnly: media scan complete. Skipping media selection - no VMs will be built.)" -ForegroundColor DarkGray
} elseif ($shouldAskMedia -and $scannedMedia.Count -gt 0) {
    if ($proceedWithSelection -ne $false) {
        Invoke-LabMediaSelection -MediaItems $scannedMedia -LabConfig $LabConfig
        # Persist the per-VM MediaSource decisions so a resume doesn't re-ask.
        Save-LabConfig -Config $LabConfig -Path $ConfigPath
    }
}

# ===================================================================================
# EXISTING-LAB VALIDATION  (reconcile CompletedSteps against ground truth)
# ===================================================================================
# Unless -SkipValidation, probe Hyper-V + every live guest to find out which steps
# are genuinely done. Results land in $Script:StepOverrides and are consulted by
# Test-LabStepNeeded (used at every build gate below).
#
# Default behaviour (fast): off VMs are NOT started. Invoke-LabGuestProbe returns
# $null for any VM that isn't Running, so its steps become 'Unverifiable' and the
# persisted file is trusted - validating a shut-down lab is effectively instant.
# Supply -BootForValidation to restore the older deep-check behaviour of starting
# every stopped VM so its roles can be probed live (slower, but a full read).
$validationSummary = $null
if (-not $SkipValidation -and -not $ScanOnly) {
    if ($BootForValidation) {
        Write-LabLog "Validating existing lab state against ground truth (-BootForValidation: stopped VMs will be started and probed via PowerShell Direct)..." -Level Step
    } else {
        Write-LabLog "Validating existing lab state against ground truth (off VMs are trusted from the progress file; use -BootForValidation to deep-probe)..." -Level Step
    }

    # Only power on stopped VMs when explicitly asked. Otherwise leave them off and
    # let Invoke-LabGuestProbe's fast-fail mark them 'Unverifiable' (file trusted).
    if ($BootForValidation) {
        $allVmNames = @()
        if ($LabConfig.DomainControllers -and $LabConfig.DomainControllers.Count -gt 0) {
            $allVmNames += @($LabConfig.DomainControllers.Name)
        }
        if ($LabConfig.AdditionalVMs -and $LabConfig.AdditionalVMs.Count -gt 0) {
            $allVmNames += @($LabConfig.AdditionalVMs.Name)
        }
        foreach ($name in $allVmNames) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm -and $vm.State -ne 'Running') {
                Write-LabLog "'$name' is not running - starting it so its state can be validated..." -Level Info
                try { Start-VM -Name $name -ErrorAction Stop } catch { Write-LabLog "Could not start '$name': $($_.Exception.Message)" -Level Warn }
            }
        }
    }

    $validationSummary = Invoke-LabStateValidation -Config $LabConfig -ConfigPath $ConfigPath -LocalAdminPassword $LocalAdminSecurePassword
} else {
    Clear-LabStepOverrides  # trust only the persisted file
    if ($SkipValidation) { Write-LabLog "Validation skipped (-SkipValidation) - trusting persisted CompletedSteps only." -Level Info }
}

if ($ScanOnly) {
    Write-LabLog "=== Scan-only complete. No changes made. Re-run without -ScanOnly to build. ===" -Level Step
    return
}

# ===================================================================================
# ORCHESTRATION
# ===================================================================================
Write-LabLog "=== Building lab: $($LabConfig.DomainName) ===" -Level Step
$mediaSourceLabels = @{}  # VMName -> label string, for the final summary

# Helper: resolve the MediaSource from each VM's persisted decision into the
# appropriate parameter for Get-WindowsMedia (-LocalVhdxPath / -LocalIsoPath / neither).
function Get-LabMediaParams {
    param([object] $Node)
    $params = @{ LocalVhdxPath = $null; LocalIsoPath = $null }
    if ($Node.PSObject.Properties['MediaSource'] -and $Node.MediaSource.Type) {
        switch ($Node.MediaSource.Type) {
            'Vhdx'     { $params.LocalVhdxPath = $Node.MediaSource.Path }
            'Iso'      { $params.LocalIsoPath  = $Node.MediaSource.Path }
            default    { }  # Download -> pass nothing
        }
    }
    return $params
}

# 1. Virtual switch + NAT
$switchStepId = "Switch:$($LabConfig.SwitchName):Created"
Write-Host ""
Write-Host "=== Step 1 of $(2 + $LabConfig.DomainControllers.Count + $LabConfig.AdditionalVMs.Count): Creating Virtual Switch ===" -ForegroundColor Cyan
if (Test-LabStepNeeded -Config $LabConfig -StepId $switchStepId) {
    Write-Progress -Activity "Building Lab" -Status "Creating virtual switch..." -PercentComplete 5
    New-LabSwitch -SwitchName $LabConfig.SwitchName -NetworkMode $LabConfig.NetworkMode `
        -NatSubnetCidr $LabConfig.SubnetCidr -GatewayIPAddress $LabConfig.Gateway | Out-Null
    Set-LabStepComplete -Config $LabConfig -StepId $switchStepId -ConfigPath $ConfigPath
    Write-Progress -Activity "Building Lab" -Status "Virtual switch created successfully" -PercentComplete 10
} else {
    Write-LabLog "Switch already created - skipping." -Level Info
}

# 2. Domain controllers (first one creates the forest, the rest join as additional DCs)
$DcIPs = @($LabConfig.DomainControllers | ForEach-Object { $_.IPAddress })
$DomainCredential = $null
$prefixLen = [int]($LabConfig.SubnetCidr.Split('/')[1])

$allLabDCs = @($LabConfig.DomainControllers)
for ($i = 0; $i -lt $allLabDCs.Count; $i++) {
    $dc = $allLabDCs[$i]

    $createStep = "VM:$($dc.Name):Created"
    if (Test-LabStepNeeded -Config $LabConfig -StepId $createStep) {
        # Get generation from MediaSource if available, otherwise default to 2
        $vmGeneration = if ($dc.MediaSource -and $dc.MediaSource.Generation) { $dc.MediaSource.Generation } else { 2 }
        
        $mParams = Get-LabMediaParams -Node $dc
        $media = Get-WindowsMedia -OSKey $dc.OSKey -MediaRoot $Paths.Media -MediaSourcesPath $MediaSourcesPath `
            -LocalVhdxPath $mParams.LocalVhdxPath -LocalIsoPath $mParams.LocalIsoPath -Generation $vmGeneration
        if (-not $media -or -not $media.MediaSource) {
            throw "Get-WindowsMedia failed to return a valid media object for $dc.OSKey"
        }
        $mediaSourceLabels[$dc.Name] = $media.MediaSource
        
        # Get VM configuration from config or use defaults
        # Check for per-DC config first, then fall back to global config
        $vCpu = if ($dc.PSObject.Properties['VCpu'] -and $dc.VCpu) { $dc.VCpu } else { if ($LabConfig.PSObject.Properties['VMVCpuCount']) { $LabConfig.VMVCpuCount } else { 2 } }
        $memStartup = if ($dc.PSObject.Properties['MemoryStartupGB'] -and $dc.MemoryStartupGB) { $dc.MemoryStartupGB } else { if ($LabConfig.PSObject.Properties['VMMemoryStartupGB']) { $LabConfig.VMMemoryStartupGB } else { 4 } }
        $memMax = if ($dc.PSObject.Properties['MemoryMaxGB'] -and $dc.MemoryMaxGB) { $dc.MemoryMaxGB } else { if ($LabConfig.PSObject.Properties['VMMemoryMaxGB']) { $LabConfig.VMMemoryMaxGB } else { 8 } }
        
        # Use local admin password for DCs
        $dcLocalPassword = if ($LabConfig.UseCustomPasswords) { $LocalAdminSecurePassword } else { $AdminSecurePassword }
        
        # Get custom admin parameters
        $customAdminName = if ($LabConfig.AddCustomAdmin) { $CustomAdminName } else { '' }
        $customAdminPassword = if ($LabConfig.AddCustomAdmin) { $CustomAdminPassword } else { '' }
        
        # Use correct path property based on media format (VHD vs VHDX)
        # Media object returns either VhdPath or VhdxPath depending on OS version
        if ($media.PSObject.Properties['VhdPath']) {
            $goldenPath = $media.VhdPath
            $vmGeneration = 1
        } else {
            $goldenPath = $media.VhdxPath
            $vmGeneration = 2
        }
        Write-LabLog "Using Generation $vmGeneration for '$($dc.Name)' (source: $($media.MediaSource), path: $goldenPath)" -Level Info
        
        New-LabVM -VMName $dc.Name -GoldenVhdxPath $goldenPath -VMRoot $Paths.VMs -SwitchName $LabConfig.SwitchName `
            -LocalAdminPassword $dcLocalPassword -TimeZone $LabConfig.TimeZone -Locale $LabConfig.Locale `
            -StaticIPAddress $dc.IPAddress -StaticPrefixLength $prefixLen -StaticGateway $LabConfig.Gateway `
            -StaticDnsServers @($DcIPs[0]) -VCpuCount $vCpu -MemoryStartupBytes ($memStartup * 1GB) -MemoryMaximumBytes ($memMax * 1GB) `
            -CustomAdminName $customAdminName -CustomAdminPassword $customAdminPassword -Generation $vmGeneration -Force | Out-Null
        Set-LabStepComplete -Config $LabConfig -StepId $createStep -ConfigPath $ConfigPath
    } else {
        Write-LabLog "'$($dc.Name)' already created - skipping." -Level Info
    }

    if ($i -eq 0) {
        $promoteStep = "DC:$($dc.Name):ForestPromoted"
        if (Test-LabStepNeeded -Config $LabConfig -StepId $promoteStep) {
            $result = Install-PrimaryDomainController -VMName $dc.Name -LocalAdminPassword $DomainAdminSecurePassword `
                -DomainName $LabConfig.DomainName -NetBIOSName $LabConfig.NetBIOSName `
                -SafeModeAdministratorPassword $DomainAdminSecurePassword -ForestMode $LabConfig.ForestMode `
                -DCIPAddress $dc.IPAddress
            if ($null -eq $result) {
                # DC was already promoted (null return), mark step complete
                Write-LabLog "'$($dc.Name)' was already promoted - marking step complete." -Level Info
                Set-LabStepComplete -Config $LabConfig -StepId $promoteStep -ConfigPath $ConfigPath
            } else {
                $DomainCredential = $result.DomainCredential
                Set-LabStepComplete -Config $LabConfig -StepId $promoteStep -ConfigPath $ConfigPath
            }
        } else {
            Write-LabLog "'$($dc.Name)' already promoted - skipping." -Level Info
        }
    } else {
        if (-not $DomainCredential) {
            $DomainCredential = New-Object PSCredential("$($LabConfig.NetBIOSName)\Administrator", $DomainAdminSecurePassword)
        }
        $promoteStep = "DC:$($dc.Name):Promoted"
        if (Test-LabStepNeeded -Config $LabConfig -StepId $promoteStep) {
            Install-AdditionalDomainController -VMName $dc.Name -LocalAdminPassword $DomainAdminSecurePassword `
                -DomainName $LabConfig.DomainName -DomainCredential $DomainCredential `
                -SafeModeAdministratorPassword $DomainAdminSecurePassword -DCIPAddress $dc.IPAddress | Out-Null
            Set-LabStepComplete -Config $LabConfig -StepId $promoteStep -ConfigPath $ConfigPath
        } else {
            Write-LabLog "'$($dc.Name)' already promoted - skipping." -Level Info
        }
    }
}

if (-not $DomainCredential) {
    $DomainCredential = New-Object PSCredential("$($LabConfig.NetBIOSName)\Administrator", $DomainAdminSecurePassword)
}

# 3. DHCP (hosted on DC in domain labs, or on a member VM in workgroup mode)
$dhcpVM = $null
if ($LabConfig.IsDomainLab) {
    # Domain lab: DHCP hosted on domain controller
    $dhcpDC = $LabConfig.DomainControllers | Where-Object { $_.Name -eq $LabConfig.DhcpHostName } | Select-Object -First 1
    if ($dhcpDC) {
        $dhcpVM = $dhcpDC
        $dhcpStep = "DHCP:$($dhcpDC.Name):Configured"
    }
} else {
    # Workgroup lab: DHCP hosted on a member VM if configured
    if ($LabConfig.WantDhcpInWorkgroup -and $LabConfig.AdditionalVMs.Count -gt 0) {
        # Use first additional VM as DHCP host
        $dhcpVM = $LabConfig.AdditionalVMs | Select-Object -First 1
        $dhcpStep = "DHCP:$($dhcpVM.Name):Configured"
    }
}

if ($dhcpVM) {
    if (Test-LabStepNeeded -Config $LabConfig -StepId $dhcpStep) {
        # Determine credentials based on lab type
        if ($LabConfig.IsDomainLab) {
            $dhcpCredential = $DomainCredential
        } else {
            # Workgroup mode: use local admin credentials
            $dhcpCredential = New-Object PSCredential("$($dhcpVM.Name)\Administrator", $LocalAdminSecurePassword)
        }
        
        # Determine if we need to skip AD authorization (workgroup mode)
        $skipADAuthorization = -not $LabConfig.IsDomainLab
        
        # For domain labs, pass the domain name; for workgroup, leave it empty
        $dnsDomainName = if ($LabConfig.IsDomainLab) { $LabConfig.DomainName } else { "" }
        
        Install-LabDhcpServer -VMName $dhcpVM.Name -DomainCredential $dhcpCredential -ServerIPAddress $dhcpVM.IPAddress `
            -ScopeId $LabConfig.ScopeId -ScopeName "Lab Scope" `
            -ScopeStartRange $LabConfig.DhcpScopeStart -ScopeEndRange $LabConfig.DhcpScopeEnd `
            -ScopeSubnetMask $LabConfig.DhcpSubnetMask -ScopeRouter $LabConfig.Gateway `
            -DnsServers @($LabConfig.Gateway) -DnsDomainName $dnsDomainName -SkipADAuthorization:$skipADAuthorization | Out-Null
        Set-LabStepComplete -Config $LabConfig -StepId $dhcpStep -ConfigPath $ConfigPath
    } else {
        Write-LabLog "DHCP already configured - skipping." -Level Info
    }
} else {
    if ($LabConfig.IsDomainLab) {
        Write-Host "`nWARNING: No domain controller found for DHCP hosting. DHCP configuration skipped.`n" -ForegroundColor Yellow
    } else {
        Write-Host "`nDHCP installation skipped (configure in VMs manually or re-run with -Reset to enable).`n" -ForegroundColor Cyan
    }
}

# Wait a moment for DHCP to be fully operational before creating additional VMs
if ($dhcpVM) {
    Write-Host "Waiting for DHCP to be fully operational..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5
}

# 4. Everything else: member servers, workstations, and the optional dedicated DNS server.
#    All of these get their IP via DHCP (the scope we just configured).
Write-Host ""
Write-Host "=== Step 3 of $(2 + $LabConfig.DomainControllers.Count + $LabConfig.AdditionalVMs.Count): Creating Additional VMs ===" -ForegroundColor Cyan
$totalAdditionalVMs = $LabConfig.AdditionalVMs.Count
$completedAdditional = 0
foreach ($vm in $LabConfig.AdditionalVMs) {
    $vmNum = $completedAdditional + 1
    $vmName = $vm.Name
    Write-Host ""
    Write-Host ("--- Creating VM {0} of {1}: {2} ---" -f $vmNum, $totalAdditionalVMs, $vmName) -ForegroundColor Cyan
    
    $createStep = ("VM:{0}:Created" -f $vm.Name)
    if (Test-LabStepNeeded -Config $LabConfig -StepId $createStep) {
        # Default to Generation 2 (VHDX). Will be overridden by Get-WindowsMedia if cached media exists
        $vmGeneration = 2
        
        $mParams = Get-LabMediaParams -Node $vm
        $media = Get-WindowsMedia -OSKey $vm.OSKey -MediaRoot $Paths.Media -MediaSourcesPath $MediaSourcesPath `
            -LocalVhdxPath $mParams.LocalVhdxPath -LocalIsoPath $mParams.LocalIsoPath -Generation $vmGeneration
        $mediaSourceLabels[$vm.Name] = $media.MediaSource
        $isWin11 = $vm.OSKey -in @('Win11Pro', 'Win11Enterprise')
        
        # Get VM configuration from config or use defaults
        # Check for per-VM config first, then fall back to global config
        $vCpu = if ($vm.PSObject.Properties['VCpu'] -and $vm.VCpu) { $vm.VCpu } else { if ($LabConfig.PSObject.Properties['VMVCpuCount']) { $LabConfig.VMVCpuCount } else { 2 } }
        $memStartup = if ($vm.PSObject.Properties['MemoryStartupGB'] -and $vm.MemoryStartupGB) { $vm.MemoryStartupGB } else { if ($LabConfig.PSObject.Properties['VMMemoryStartupGB']) { $LabConfig.VMMemoryStartupGB } else { 4 } }
        $memMax = if ($vm.PSObject.Properties['MemoryMaxGB'] -and $vm.MemoryMaxGB) { $vm.MemoryMaxGB } else { if ($LabConfig.PSObject.Properties['VMMemoryMaxGB']) { $LabConfig.VMMemoryMaxGB } else { 8 } }
        
        # Get custom admin parameters
        $customAdminName = if ($LabConfig.AddCustomAdmin) { $CustomAdminName } else { '' }
        $customAdminPassword = if ($LabConfig.AddCustomAdmin) { $CustomAdminPassword } else { '' }
        
        # Use correct path property based on media format (VHD vs VHDX)
        # Media object returns either VhdPath or VhdxPath depending on OS version
        if ($media.PSObject.Properties['VhdPath']) {
            $goldenPath = $media.VhdPath
            $vmGeneration = 1
        } else {
            $goldenPath = $media.VhdxPath
            $vmGeneration = 2
        }
        Write-LabLog "Using Generation $vmGeneration for '$($vm.Name)' (source: $($media.MediaSource), path: $goldenPath)" -Level Info
        
        Write-Progress -Activity "Building Lab" -Status "Creating VM '$($vm.Name)'..." -PercentComplete (70 + ($completedAdditional / $totalAdditionalVMs * 15))
        New-LabVM -VMName $vm.Name -GoldenVhdxPath $goldenPath -VMRoot $Paths.VMs -SwitchName $LabConfig.SwitchName `
            -LocalAdminPassword $LocalAdminSecurePassword -TimeZone $LabConfig.TimeZone -Locale $LabConfig.Locale -IsWindows11:$isWin11 `
            -VCpuCount $vCpu -MemoryStartupBytes ($memStartup * 1GB) -MemoryMaximumBytes ($memMax * 1GB) `
            -CustomAdminName $customAdminName -CustomAdminPassword $customAdminPassword -Generation $vmGeneration -Force | Out-Null
        Set-LabStepComplete -Config $LabConfig -StepId $createStep -ConfigPath $ConfigPath
        Write-Progress -Activity "Building Lab" -Status "VM '$($vm.Name)' created successfully" -PercentComplete (70 + ($completedAdditional / $totalAdditionalVMs * 15))
    } else {
        Write-LabLog "'$($vm.Name)' already created - skipping." -Level Info
    }

    # Only join domain if this is a domain lab (not workgroup)
    if ($LabConfig.IsDomainLab) {
        $joinStep = "VM:$($vm.Name):DomainJoined"
        if (Test-LabStepNeeded -Config $LabConfig -StepId $joinStep) {
            Write-Progress -Activity "Building Lab" -Status "Joining '$($vm.Name)' to domain..." -PercentComplete (85 + ($completedAdditional / $totalAdditionalVMs * 10))
            Add-LabComputerToDomain -VMName $vm.Name -LocalAdminPassword $LocalAdminSecurePassword `
                -DomainName $LabConfig.DomainName -DomainCredential $DomainCredential | Out-Null
            Set-LabStepComplete -Config $LabConfig -StepId $joinStep -ConfigPath $ConfigPath
            Write-Progress -Activity "Building Lab" -Status "VM '$($vm.Name)' joined domain successfully" -PercentComplete (85 + ($completedAdditional / $totalAdditionalVMs * 10))
        } else {
            Write-LabLog "'$($vm.Name)' already domain-joined - skipping." -Level Info
        }
    } else {
        Write-LabLog "Skipping domain join for '$($vm.Name)' (workgroup mode)" -Level Info
    }

    if ($vm.Role -eq 'DNS') {
        $dnsStep = "DNS:$($vm.Name):Configured"
        if (Test-LabStepNeeded -Config $LabConfig -StepId $dnsStep) {
            if (-not $LabConfig.DomainControllers -or @($LabConfig.DomainControllers | Where-Object { $_ -ne $null }).Count -eq 0) {
                Write-LabLog "Cannot install DNS server on '$($vm.Name)' - no domain controllers found. Skipping." -Level Warn
            } else {
                Install-LabDnsServer -VMName $vm.Name -DomainCredential $DomainCredential `
                    -PrimaryDCVMName ($LabConfig.DomainControllers | Where-Object { $_ -ne $null })[0].Name -PrimaryDCIPAddress $DcIPs[0] `
                    -ZoneName $LabConfig.DomainName | Out-Null
            }
            Set-LabStepComplete -Config $LabConfig -StepId $dnsStep -ConfigPath $ConfigPath
        } else {
            Write-LabLog "'$($vm.Name)' DNS already configured - skipping." -Level Info
        }
    }
    
    $completedAdditional++
}
Write-Progress -Activity "Building Lab" -Status "All VMs created and configured" -PercentComplete 100

# ===================================================================================
# SUMMARY
# ===================================================================================
Write-LabLog "=== Lab deployment complete ===" -Level Success
Write-Host ""
Write-Host "Domain:        $($LabConfig.DomainName)  ($($LabConfig.NetBIOSName))" -ForegroundColor Green
Write-Host "Switch / NAT:  $($LabConfig.SwitchName) - $($LabConfig.SubnetCidr), gateway $($LabConfig.Gateway)" -ForegroundColor Green
Write-Host "DHCP:          running on $($LabConfig.DhcpHostName), scope $($LabConfig.DhcpScopeStart) - $($LabConfig.DhcpScopeEnd)" -ForegroundColor Green
Write-Host ""
Write-Host "VMs:" -ForegroundColor Green
$summaryRows = @()
foreach ($dc in $LabConfig.DomainControllers) {
    $mediaLabel = if ($mediaSourceLabels[$dc.Name]) { $mediaSourceLabels[$dc.Name] } else { '(cached)' }
    $summaryRows += [pscustomobject]@{ Name = $dc.Name; OS = $dc.OSKey; Role = 'Domain Controller'; IPAddress = $dc.IPAddress; Media = $mediaLabel }
}
foreach ($vm in $LabConfig.AdditionalVMs) {
    # Determine role label based on lab type and VM role
    if (-not $LabConfig.IsDomainLab) {
        # Workgroup mode: show workgroup roles
        $roleLabel = if ($vm.Role -eq 'DNS') { 'Workgroup (secondary DNS)' } else { 'Workgroup' }
    } else {
        # Domain mode: show domain roles
        $roleLabel = if ($vm.Role -eq 'DNS') { 'Member Server (secondary DNS)' } else { 'Domain Member' }
    }
    $mediaLabel = if ($mediaSourceLabels[$vm.Name]) { $mediaSourceLabels[$vm.Name] } else { '(cached)' }
    $summaryRows += [pscustomobject]@{ Name = $vm.Name; OS = $vm.OSKey; Role = $roleLabel; IPAddress = if ($vm.IPAddress) { $vm.IPAddress } else { '(DHCP)' }; Media = $mediaLabel }
}
$summaryRows | Format-Table -AutoSize | Out-String | Write-Host

# Validation summary (if validation ran).
if ($validationSummary) {
    $vLine = "Validation:    $($validationSummary.ReRun) step(s) (re-)run, $($validationSummary.Unverifiable) unverifiable (trusted from file)"
    Write-Host $vLine -ForegroundColor $(if ($validationSummary.ReRun -eq 0) { 'Green' } else { 'Yellow' })
}

Write-Host "Log file:      $LogFilePath" -ForegroundColor Green
Write-Host "Config file:   $ConfigPath" -ForegroundColor Green
Write-Host ""
Write-Host "Sign in to any VM as '$($LabConfig.NetBIOSName)\Administrator' (or '.\Administrator' before it joined the domain) with the password you entered." -ForegroundColor Yellow
Write-Host "Re-run this script any time: it scans for reusable media, validates each VM's state, then skips whatever's already done." -ForegroundColor Yellow
Write-Host "Use -Reset to redo the wizard (add/remove VMs). Use -ScanOnly to inspect media and state without building. Use -SkipValidation to trust the progress file only." -ForegroundColor Yellow
Write-Host "Use -TearDown to destroy the VMs and clear progress while keeping cached media (then re-run to rebuild from it). Add -RemoveSwitch to also drop the switch + NAT." -ForegroundColor Yellow
Write-Host "Use -BootForValidation to start stopped VMs and deep-probe their roles during validation." -ForegroundColor Yellow
}
catch {
    # Capture the error and display detailed information
    Write-Host "`n" -NoNewline
    Write-Host "!!! UNEXPECTED ERROR OCCURRED !!!" -ForegroundColor Red -BackgroundColor Black
    Write-Host "`n"
    
    $errorDetails = Get-DetailedErrorMessage -ErrorRecord $_ -Context 'Main Script Execution'
    Write-Host $errorDetails
    
    # Export error details to log file for troubleshooting
    $logDir = Join-Path $LabRoot 'Logs'
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $errorLogPath = Join-Path $logDir "Error_$timestamp.txt"
    
    # Build comprehensive error report
    $report = @()
    $report += "=" * 80
    $report += "HYPER-V LAB DEPLOY ERROR REPORT"
    $report += "=" * 80
    $report += ""
    $report += "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "LabRoot:   $LabRoot"
    $report += ""
    $report += $errorDetails
    $report += ""
    $report += "=" * 80
    $report += "SYSTEM INFORMATION"
    $report += "=" * 80
    $report += ""
    $report += "OS Version:        $(Get-ComputerInfo -Property 'OsName', 'OsVersion' | Format-List | Out-String)"
    $report += "PowerShell Version: $($PSVersionTable.PSVersion.ToString())"
    $report += "Hyper-V Role:      $((Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V -Online -ErrorAction SilentlyContinue).State)"
    $report += ""
    
    # Save error report
    try {
        $report | Out-File -FilePath $errorLogPath -Encoding UTF8
        Write-Host "`n" -NoNewline
        Write-Host "ERROR REPORT EXPORTED TO:" -ForegroundColor Yellow
        Write-Host "  $errorLogPath" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Please share this file when asking for help." -ForegroundColor Yellow
    } catch {
        Write-Host "`n" -NoNewline
        Write-Host "WARNING: Could not export error report to log file." -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Exit with error code
    exit 1
}

# ===================================================================================
# UTILITY FUNCTIONS - Run these manually if needed to clean up orphaned resources
# ===================================================================================
function Get-LabOrphanedResources {
    <#
    .SYNOPSIS
        Lists orphaned resources that may have been left behind by failed operations.
    .DESCRIPTION
        Scans for:
        - VMs not in the config file
        - VHDX files not attached to any VM
        - Dangling network configurations
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [string] $VMsRoot
    )
    
    Write-Host "=== Checking for orphaned resources ===" -ForegroundColor Cyan
    
    $config = Get-LabConfig -Path $ConfigPath
    $configuredVMs = @()
    if ($config -and $config.DomainControllers -and @($config.DomainControllers | Where-Object { $_ -ne $null }).Count -gt 0) {
        $configuredVMs += ($config.DomainControllers | Where-Object { $_ -ne $null }).Name
    }
    if ($config -and $config.AdditionalVMs -and @($config.AdditionalVMs | Where-Object { $_ -ne $null }).Count -gt 0) {
        $configuredVMs += ($config.AdditionalVMs | Where-Object { $_ -ne $null }).Name
    }
    
    Write-Host ""
    Write-Host "Configured VMs: $($configuredVMs -join ', ')" -ForegroundColor Green
    
    # Check for VMs not in config
    $allVMs = Get-VM -ErrorAction SilentlyContinue
    $orphanedVMs = $allVMs | Where-Object { $_.Name -notin $configuredVMs }
    
    if ($orphanedVMs.Count -gt 0) {
        Write-Host ""
        Write-Host "WARNING: Found VMs not in config file:" -ForegroundColor Yellow
        $orphanedVMs | Format-Table Name, State, Path -AutoSize | Out-String | Write-Host
    } else {
        Write-Host ""
        Write-Host "No orphaned VMs found." -ForegroundColor Green
    }
    
    # Check for VHDX files not attached to any VM
    Write-Host ""
    Write-Host "Checking for unattached VHDX files..." -ForegroundColor Cyan
    $allVhdxFiles = Get-ChildItem -Path $VMsRoot -Recurse -Filter "*.vhdx" -File -ErrorAction SilentlyContinue
    $attachedVhdxPaths = $allVMs | Get-VMHardDiskDrive | Select-Object -ExpandProperty Path
    
    $unattachedVhdx = $allVhdxFiles | Where-Object { $_.FullName -notin $attachedVhdxPaths }
    
    if ($unattachedVhdx.Count -gt 0) {
        Write-Host ""
        Write-Host "WARNING: Found unattached VHDX files:" -ForegroundColor Yellow
        $unattachedVhdx | Format-Table FullName, Length -AutoSize | Out-String | Write-Host
    } else {
        Write-Host ""
        Write-Host "No unattached VHDX files found." -ForegroundColor Green
    }
    
    Write-Host ""
    Write-Host "Orphaned resource check complete." -ForegroundColor Cyan
}

function Remove-LabOrphanedVM {
    <#
    .SYNOPSIS
        Removes a VM and its files that are not in the config.
    .DESCRIPTION
        Use with caution - this will permanently delete VMs and their data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $VMsRoot
    )
    
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM '$VMName' not found." -ForegroundColor Yellow
        return
    }
    
    if ($vm.State -ne 'Off') {
        Write-Host "Stopping VM '$VMName'..." -ForegroundColor Cyan
        Stop-VM -Name $VMName -Force -TurnOff -ErrorAction Stop
    }
    
    Write-Host "Removing VM '$VMName' from Hyper-V..." -ForegroundColor Cyan
    Remove-VM -Name $VMName -Force -ErrorAction Stop
    
    $vmDir = Join-Path $VMsRoot $VMName
    if (Test-Path $vmDir) {
        Write-Host "Deleting VM files at '$vmDir'..." -ForegroundColor Cyan
        Remove-Item -Path $vmDir -Recurse -Force -ErrorAction Stop
    }
    
    Write-Host "VM '$VMName' and its files have been removed." -ForegroundColor Green
}

# ===================================================================================
# UTILITY FUNCTIONS - Run these manually if needed to clean up orphaned resources
# ===================================================================================
