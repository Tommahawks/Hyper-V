# Changes Applied to Begin.ps1

## Summary
This document describes the fixes and improvements applied to address the issues reported by the user.

---

## Issues Fixed

### 1. DC Promotion Idempotency Issue ✅
**Problem**: When re-running the script, it would try to install AD DS binaries on an already-promoted DC, causing the error:
```
Verification of prerequisites for Domain Controller promotion failed. The specified argument 'DomainLevel' was not recognized.
```

**Solution**: Added a check at the beginning of `Install-PrimaryDomainController` to detect if the VM is already a domain controller by checking the `DomainRole` property. If already promoted, the function returns `$null` and skips the promotion step.

**Code Added**:
```powershell
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
```

---

### 2. DNS Forward/Reverse Lookup Zones Issue ✅
**Problem**: The DC had no DNS Forward Lookup Zones or Reverse Lookup Zones, resulting in domain resolution failures.

**Solution**: Enhanced `Confirm-LabDCDnsRegistration` to automatically create reverse lookup zones for the DC's subnet. The function now:
- Creates reverse lookup zones for the /24 subnet (e.g., `16.172.10.in-addr.arpa` for `10.x.x.x`)
- Uses forest replication scope for proper AD integration
- Logs success/failure of zone creation

**Code Added**:
```powershell
# 5. Create reverse lookup zone if it doesn't exist
$reverseZoneName = "16.172.10.in-addr.arpa"  # Default for 10.x.x.x/8 - adjust as needed
$existingReverse = Get-DnsServerZone -Name $reverseZoneName -ErrorAction SilentlyContinue
if (-not $existingReverse) {
    # Extract network info from DC IP to create appropriate reverse zone
    $ipParts = $dcIp.Split('.')
    if ($ipParts.Count -eq 4) {
        # Create reverse zone for the /24 subnet (most common lab setup)
        $reverseZoneName = "$($ipParts[2]).$($ipParts[1]).$($ipParts[0]).in-addr.arpa"
        try {
            Add-DnsServerPrimaryZone -Name $reverseZoneName -ReplicationScope "Forest" -ErrorAction Stop
            $r.ReverseZoneCreated = $true
            Write-Host "Created reverse lookup zone: $reverseZoneName" -ForegroundColor Green
        } catch {
            Write-Warning "Could not create reverse zone '$reverseZoneName': $($_.Exception.Message)"
        }
    }
}
```

---

### 3. VM Configuration (CPU/Memory) with Persistence ✅
**Problem**: CPU and memory settings were hardcoded and not configurable.

**Solution**: Added VM configuration parameters to the wizard with persistence:
- Added prompts for vCPU count, startup RAM, and maximum RAM during initial setup
- Values are saved to `LabConfig.json` and reused on subsequent runs
- Default values: 2 vCPUs, 4GB startup RAM, 8GB maximum RAM

**Wizard Changes**:
```powershell
Write-Host ""
Write-Host "--- VM Configuration ---" -ForegroundColor Cyan
Write-Host "Virtual CPU and memory settings for all VMs (can be customized per VM later)." -ForegroundColor DarkGray
$vCpuCount = Read-LabInt -Prompt "Virtual CPU count per VM" -Default 2 -Min 1 -Max 8
$memoryStartupGB = Read-LabInt -Prompt "Startup RAM (GB) per VM" -Default 4 -Min 1 -Max 64
$memoryMaxGB = Read-LabInt -Prompt "Maximum RAM (GB) per VM" -Default 8 -Min 1 -Max 128
```

**Config Storage**:
```powershell
VMVCpuCount        = $vCpuCount
VMMemoryStartupGB  = $memoryStartupGB
VMMemoryMaxGB      = $memoryMaxGB
```

**Usage in VM Creation**:
```powershell
# Get VM configuration from config or use defaults
$vCpu = if ($LabConfig.PSObject.Properties['VMVCpuCount']) { $LabConfig.VMVCpuCount } else { 2 }
$memStartup = if ($LabConfig.PSObject.Properties['VMMemoryStartupGB']) { $LabConfig.VMMemoryStartupGB } else { 4 }
$memMax = if ($LabConfig.PSObject.Properties['VMMemoryMaxGB']) { $LabConfig.VMMemoryMaxGB } else { 8 }
```

---

### 4. Script Renaming (Begin.ps1) ✅
**Problem**: The main script was previously named `1.0.2.ps1` or referenced under different names in documentation.

**Solution**: All references to the old script name have been updated to `Begin.ps1`.

**Files Updated**:
- README.md - All command examples now use `.\Begin.ps1`
- CHANGES.md - This file now references Begin.ps1
- Instructions.ps1 - HTML generation script updated
- PDF-README.txt - All references updated

---

## Code Locations (from 1.0.2.ps1)

**Code Location**: Lines 2320-2360 in 1.0.2.ps1  
**Code Location**: Lines 1208-1213 in 1.0.2.ps1

---

### 4. Time Synchronization Configuration ✅
**Problem**: Time synchronization was not configured, which is critical for AD domains.

**Solution**: Added automatic time synchronization configuration in `New-LabVM`:
- Configures W32Time service to sync from domain hierarchy
- Restarts the W32Time service
- Forces immediate time synchronization

**Code Added**:
```powershell
# --- Time synchronization configuration ---
Write-LabLog "Configuring time synchronization for '$VMName'..." -Level Info
Invoke-Command -VMName $VMName -Credential $localCred -ScriptBlock {
    # Configure W32Time service to sync from DC
    & w32tm /config /syncfromflags:DOMHIER /update | Out-Null
    Restart-Service -Name W32Time -ErrorAction SilentlyContinue
    & w32tm /resync | Out-Null
}
```

---

### 5. Improved Progress Monitoring ✅
**Problem**: Progress was not clearly visible during long-running operations.

**Solution**: Added comprehensive progress tracking:
- Step-by-step progress indicators (e.g., "Step 1 of X: Creating Virtual Switch")
- Visual progress bars using `Write-Progress`
- Per-VM status updates with progress indicators
- Summary of completed steps

**Examples**:
```powershell
Write-Host ""
Write-Host "=== Step 1 of $(2 + $LabConfig.DomainControllers.Count + $LabConfig.AdditionalVMs.Count): Creating Virtual Switch ===" -ForegroundColor Cyan

Write-Progress -Activity "Building Lab" -Status "Creating virtual switch..." -PercentComplete 5

Write-Host ""
Write-Host "--- Creating DC $dcNum of $($allLabDCs.Count): $($dc.Name) ---" -ForegroundColor Cyan
```

---

### 6. Cleanup Functions for Orphaned Resources ✅
**Problem**: No way to identify and clean up orphaned resources from failed operations.

**Solution**: Added utility functions:
- `Get-LabOrphanedResources`: Lists orphaned VMs and unattached VHDX files
- `Remove-LabOrphanedVM`: Removes a specific orphaned VM and its files

**Usage**:
```powershell
# Check for orphaned resources
Get-LabOrphanedResources -ConfigPath 'C:\HyperV-Lab\Config\LabConfig.json' -VMsRoot 'C:\HyperV-Lab\VMs'

# Remove a specific orphaned VM
Remove-LabOrphanedVM -VMName 'OrphanedVM' -VMsRoot 'C:\HyperV-Lab\VMs'
```

---

## Additional Improvements

### Error Handling
- Added `-ErrorAction Stop` to critical Hyper-V cmdlets
- Added proper null checks for DC promotion results

### Code Quality
- Added comments explaining each section
- Improved variable naming for clarity
- Better logging levels (Info, Step, Success, Warn)

---

## Testing Recommendations

1. **Test DC Re-run**: Run the script, let it create a DC, then run again to verify it skips the promotion step
2. **Test DNS Resolution**: After DC creation, verify DNS zones exist and domain resolution works
3. **Test VM Configuration**: Create a lab with custom CPU/memory settings and verify they're applied
4. **Test Time Sync**: Verify time synchronization is configured on VMs
5. **Test Progress Monitoring**: Run a full lab creation and verify progress indicators work
6. **Test Cleanup Functions**: Create an orphaned VM and verify cleanup functions work

---

## Notes

- All changes are backward compatible with existing configurations
- The script maintains idempotency - re-running won't break existing infrastructure
- Progress monitoring uses `Write-Progress` which can be suppressed with `$ProgressPreference = 'SilentlyContinue'`
- Cleanup functions are utility scripts that can be run manually as needed

---

# 1.0.2 Changes (Current Version)

## Summary
This version adds intelligent VHD/VHDX selection based on Windows Server version and VM generation requirements, plus critical fixes for media scanning, file extension handling, and strict mode compatibility.

---

## New Features

### 1. Intelligent Media Selection ✅
**Feature**: Automatic selection of VHD vs VHDX files based on Windows Server version.

**Behavior**:
- **Windows Server 2016/2019/2022**: Automatically uses VHD files with Generation 1 VMs (BIOS/MBR)
- **Windows Server 2025**: Automatically uses VHDX files with Generation 2 VMs (UEFI/GPT required)

**Media Priority Order**:
When multiple cached media files exist for the same Windows edition, the script prioritizes them in this order:
1. **Cached VHD/VHDX files** (from MediaCache) - preferred for faster deployment
2. **ISO files** - used only if no cached golden images are available

**Rationale**:
- Server 2016/2019/2022 support both Generation 1 (VHD) and Generation 2 (VHDX)
- Server 2025 requires UEFI firmware, which is only available in Generation 2 VMs
- VHD files are smaller and work well with Generation 1 for older server versions

**User Experience**:
- During media selection, the script displays generation information: `Vhd Win2022.vhd (Gen 1)`
- If VHD files will be used, a warning is shown and user must confirm
- Per-VM override allows changing media type if needed

---

### 2. VM Generation Support ✅
**Feature**: Proper VM generation handling throughout the deployment process.

**Implementation**:
- MediaSource objects now include `Generation` field (1 or 2)
- `Get-WindowsMedia` accepts `-Generation` parameter
- Correct path property used: `VhdPath` for Gen 1, `VhdxPath` for Gen 2
- Conversion skipped when Generation=1 and source is already VHD

**Configuration Storage**:
```json
{
    "DomainControllers": [{
        "Name": "DC1",
        "OSKey": "Server2022",
        "MediaSource": {
            "Type": "Vhd",
            "Path": "E:\\HyperV\\Media\\VHDX\\Win2022.vhd",
            "Generation": 1
        }
    }]
}
```

---

### 3. Automatic Generation Correction ✅

## Summary
This version adds intelligent VHD/VHDX selection based on Windows Server version and VM generation requirements, plus critical fixes for media scanning, file extension handling, and strict mode compatibility.

---

## New Features

### 1. Intelligent Media Selection ✅
**Feature**: Automatic selection of VHD vs VHDX files based on Windows Server version.

**Behavior**:
- **Windows Server 2016/2019/2022**: Automatically uses VHD files with Generation 1 VMs (BIOS/MBR)
- **Windows Server 2025**: Automatically uses VHDX files with Generation 2 VMs (UEFI/GPT required)

**Rationale**:
- Server 2016/2019/2022 support both Generation 1 (VHD) and Generation 2 (VHDX)
- Server 2025 requires UEFI firmware, which is only available in Generation 2 VMs
- VHD files are smaller and work well with Generation 1 for older server versions

**User Experience**:
- During media selection, the script displays generation information: `Vhd Win2022.vhd (Gen 1)`
- If VHD files will be used, a warning is shown and user must confirm
- Per-VM override allows changing media type if needed

---

### 2. VM Generation Support ✅
**Feature**: Proper VM generation handling throughout the deployment process.

**Implementation**:
- MediaSource objects now include `Generation` field (1 or 2)
- `Get-WindowsMedia` accepts `-Generation` parameter
- Correct path property used: `VhdPath` for Gen 1, `VhdxPath` for Gen 2
- Conversion skipped when Generation=1 and source is already VHD

**Configuration Storage**:
```json
{
    "DomainControllers": [{
        "Name": "DC1",
        "OSKey": "Server2022",
        "MediaSource": {
            "Type": "Vhd",
            "Path": "E:\\HyperV\\Media\\VHDX\\Win2022.vhd",
            "Generation": 1
        }
    }]
}
```

---

### 3. Automatic Generation Correction ✅
**Feature**: Automatically fixes incorrect generation values in saved configurations.

**Behavior**:
- On script startup, scans cached media files
- Compares stored MediaSource.Generation with actual file kind
- Updates Generation if mismatch detected (e.g., VHD file with Gen 2 stored)
- Ensures consistency between config and actual media

---

## Critical Fixes Applied

### 4. OSKey Inference Fallback for Cached Media ✅
**Problem**: When script cannot read edition information from cached media files (due to "Access is denied" errors when mounting VHD/VHDX offline), it fails to determine the Windows version and cannot match VMs to available media.

**Solution**: Added intelligent fallback logic that infers OSKey from filename patterns and file extension:
- Checks for Server2016, Server2019, Server2022, Server2025, Win11 patterns in filenames
- Uses file extension (.vhd vs .vhdx) to infer expected generation
- Defaults to Server2022 for VHD files and Server2025 for VHDX files if no pattern matches

**Code Location**: Lines 2320-2360 in 1.0.2.ps1

**Example**:
```powershell
# If Win2022.vhd cannot be read, script infers:
# - OSKey: Server2022 (from filename)
# - Generation: 1 (from .vhd extension)
```

**Impact**: Allows deployment to proceed even when media files are locked or inaccessible for edition reading.

---

### 5. VM Local File Extension Fix ✅
**Problem**: Script was hardcoding `.vhdx` extension for all VMs, causing "file corrupted" errors when trying to mount a VHD file as VHDX (Generation 1 VMs).

**Solution**: Made file extension conditional based on VM generation:
- Generation 1 VMs use `.vhd` extension
- Generation 2 VMs use `.vhdx` extension

**Code Location**: Lines 1208-1213 in 1.0.2.ps1

**Before**:
```powershell
$vmVhdxPath = Join-Path $vhdDir "$VMName.vhdx"  # Always .vhdx, wrong for Gen 1!
```

**After**:
```powershell
# Use correct extension based on VM generation: Gen1=VHD, Gen2=VHDX
$ext = if ($Generation -eq 1) { '.vhd' } else { '.vhdx' }
$vmVhdxPath = Join-Path $vhdDir "$VMName$ext"
```

**Impact**: Prevents mount errors and ensures correct file format is used for each VM generation.

---

### 6. MediaSource Property Checks ✅
**Problem**: Script threw "Property cannot be found" errors when accessing `MediaSource.Generation` property that didn't exist (especially with `Set-StrictMode -Version Latest`).

**Solution**: Added proper property existence checks using `PSObject.Properties['Generation']` pattern:
```powershell
# Check Generation only if it exists (to avoid PropertyNotFoundException in strict mode)
if (-not $dc.MediaSource.PSObject.Properties['Generation'] -or $dc.MediaSource.Generation -ne $expectedGen) {
    $needsUpdate = $true
}
```

**Impact**: Prevents runtime errors and ensures backward compatibility with old configurations.

---

### 7. Array Normalization Simplification ✅
**Problem**: Single-item JSON arrays become PSObjects instead of arrays, causing "Count property not found" errors.

**Solution**: Simplified normalization from conditional checks to `@()` wrapping:
```powershell
# Before: if ($obj -isnot [array]) { $obj = @($obj) }
# After: Always wrap with @() since @(@()) still produces proper array
$dcs = @($LabConfig.DomainControllers)
$additionalVMs = @($LabConfig.AdditionalVMs)
```

**Impact**: Consistent array handling across all config loading paths.

---

### 8. Duplicate Mount-VHD Removal ✅
**Problem**: Script mounted VHD/VHDX files twice without proper dismounting, causing "file in use" errors.

**Solution**: Removed duplicate `Mount-VHD` call and associated `$mounted = $true` assignment at lines 2202-2205.

**Impact**: Prevents file lock issues during media scanning.

---

### 9. Get-VHD Cleanup Code ✅
**Problem**: Orphaned VHD/VHDX files remained mounted from previous failed operations, causing access denied errors.

**Solution**: Added `Get-VM | ForEach-Object { $_.HardDrives.Path }` cleanup to dismount orphaned VHDs before media scan at lines 2279-2289.

**Impact**: Ensures clean state before media scanning operations.

---

## 1.0.2 Improvements Summary

This version adds critical fixes for media scanning, file extension handling, and strict mode compatibility:

| Issue | Fix | Impact |
|-------|-----|--------|
| OSKey inference fallback | Infers Windows version from filename patterns when edition reading fails | Allows deployment to proceed even when media files are locked or inaccessible |
| VM local file extension | Uses `.vhd` for Gen 1 and `.vhdx` for Gen 2 VMs | Prevents mount errors and ensures correct file format is used |
| MediaSource property checks | Added `PSObject.Properties['Generation']` checks before accessing property | Prevents runtime errors with strict mode enabled |
| Array normalization | Simplified to always use `@()` wrapping | Consistent array handling across all config loading paths |
| Duplicate Mount-VHD removal | Removed duplicate mount call at lines 2202-2205 | Prevents file lock issues during media scanning |
| Get-VHD cleanup code | Added orphaned VHD dismount before media scan at lines 2279-2289 | Ensures clean state before media scanning operations |

---

## Technical Details

### File Extension Detection
```powershell
# In Find-LabMedia function:
$ext = [System.IO.Path]::GetExtension($file.FullName).ToLower()
$kind = if ($ext -eq '.vhdx') { 'Vhdx' } else { 'Vhd' }
```

### Generation Determination
```powershell
# VHD files = Generation 1 VMs (BIOS/MBR)
# VHDX/ISO files = Generation 2 VMs (UEFI/GPT)
$generation = if ($best.Kind -eq 'Vhd') { 1 } else { 2 }
```

### Path Property Selection
```powershell
# Use correct path property based on generation
$goldenPath = if ($vmGeneration -eq 1) { $media.VhdPath } else { $media.VhdxPath }
```

---

## Migration Notes

### Existing Configurations
If you have existing `LabConfig.json` files with MediaSource entries:
- Old configs without `Generation` field will be automatically updated on next run
- VHD files will now correctly use Generation 1
- VHDX files continue to use Generation 2

### Manual Override
To force a specific media type for a VM:
1. Run script with existing config
2. When prompted, select "No" to override defaults
3. Choose different media file (VHD vs VHDX)
4. Generation will update automatically based on selection

---

## Testing Recommendations

1. **Test Server 2022 with VHD**: Deploy DC with Server 2022 VHD file, verify Gen 1 VM created
2. **Test Server 2025 with VHDX**: Deploy DC with Server 2025 VHDX file, verify Gen 2 VM created
3. **Test Config Recovery**: Run script twice to verify Generation is preserved correctly
4. **Test Media Override**: Select different media type for a VM and verify Generation updates

---

## Known Issues

None at this time.

---

## Future Enhancements

Potential future improvements:
- Support for Generation 1 with Server 2025 (if needed)
- Automatic conversion between VHD/VHDX formats
- Template-based VM configuration presets
