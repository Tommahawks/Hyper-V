# Hyper-V Automation Lab Deploy - 1.0.2

## Overview

This script automates the creation of a complete Hyper-V Active Directory lab environment in a single execution. It handles everything from virtual switch setup to domain controller promotion, DHCP configuration, and domain-joined VM deployment.

### Optimized for Speed & Efficiency
- **Fast Re-runs**: Skips completed steps automatically
- **Smart Validation**: Only validates running VMs; trusts saved state for offline VMs
- **Cached Media**: Downloads Windows ISOs once, reuses cached VHDX images
- **Parallel Deployment**: Deploys multiple VMs efficiently with minimal manual intervention

## Prerequisites

### System Requirements
- **Operating System**: Windows 10 or Windows 11 (any edition)
- **PowerShell**: Version 5.1 or later
- **Hyper-V**: Must be enabled
- **Administrator**: Must run as Administrator

### Hardware Requirements
- **CPU**: 4+ cores recommended (more for multiple VMs)
- **RAM**: 16GB+ recommended (8GB per VM + host overhead)
- **Storage**: 
  - 50GB+ free space for each Windows edition (ISO + VHDX)
  - 20GB+ per VM (dynamic VHDX grows as needed)
  - SSD highly recommended for performance

### Network Requirements
- Internet connection for first-time media downloads
- No existing Hyper-V switches with conflicting IP ranges

## Quick Start

### 1.0.2 Improvements
- **Intelligent File Format Selection**: Automatically uses `.vhd` for Server 2016/2019/2022 (Generation 1) and `.vhdx` for Server 2025+ (Generation 2)
- **OSKey Inference Fallback**: Determines Windows version from filename patterns when edition reading fails (e.g., "Access is denied" errors)
- **Automatic Generation Correction**: Fixes incorrect generation values in saved configurations
- **Better Error Handling**: Improved handling of media access issues and strict mode compatibility

### First Run (Interactive Wizard)

```powershell
# Run as Administrator
.\1.0.2.ps1 -LabRoot E:\HyperV
```

The script will:
1. Check prerequisites
2. Launch an interactive configuration wizard
3. Download and cache Windows media (first time only)
4. Create the virtual switch and NAT
5. Deploy domain controllers
6. Configure DHCP
7. Deploy additional VMs
8. Join VMs to the domain

### Subsequent Runs

```powershell
# Resume interrupted deployment
.\1.0.2.ps1 -LabRoot E:\HyperV

# Skip validation (faster, trusts saved state)
.\1.0.2.ps1 -LabRoot E:\HyperV -SkipValidation

# Rebuild from cached media (after -TearDown)
.\1.0.2.ps1 -LabRoot E:\HyperV -SkipValidation
```

## Parameters

### `-LabRoot` (Required)
**Type**: String  
**Default**: `C:\HyperV-Lab`

The root folder for all lab resources. This directory will contain:
- `Scripts\` - Generated PowerShell scripts
- `Modules\` - PowerShell modules
- `Config\` - Lab configuration (LabConfig.json)
- `Media\` - Downloaded ISOs and cached VHDX files
- `VMs\` - Virtual machine files
- `Logs\` - Deployment logs

**Example**:
```powershell
.\1.0.2.ps1 -LabRoot E:\HyperV
```

### `-ForceRegenerateScripts`
**Type**: Switch  
**Default**: Off

Re-writes every generated child file even if content hasn't changed.  
**Use case**: Rarely needed - only if you suspect script corruption.

### `-Reset`
**Type**: Switch  
**Default**: Off

Ignores saved `Config\LabConfig.json` and re-runs the configuration wizard from scratch.  
**Note**: Does NOT delete already-created VMs.

### `-ScanOnly`
**Type**: Switch  
**Default**: Off

Runs media scan and lab state validation, then exits WITHOUT building anything.  
**Use case**: "What do I already have here?"

### `-SkipValidation`
**Type**: Switch  
**Default**: Off

Skips ground-truth validation and trusts only the persisted `CompletedSteps` file.  
**Use case**: All VMs intentionally off, or PowerShell Direct probing is undesirable.

### `-TearDown`
**Type**: Switch  
**Default**: Off

Destroys existing lab VMs and clears saved build progress, then exits WITHOUT rebuilding.  
**Preserves**:
- Topology and network settings
- Per-VM MediaSource choices
- Cached ISO/VHDX media

**Use case**: Fast-fresh flow:
```powershell
.\1.0.2.ps1 -TearDown      # Destroy VMs, clear progress, keep media
.\1.0.2.ps1 -SkipValidation # Rebuild all VMs from cached media
```

### `-RemoveSwitch`
**Type**: Switch  
**Default**: Off  
**Requires**: `-TearDown`

Also removes the Hyper-V virtual switch and its NetNat object.  
**Safety**: Off by default to prevent accidental network disruption.

### `-BootForValidation`
**Type**: Switch  
**Default**: Off

Powers on stopped VMs during validation to probe roles live via PowerShell Direct.  
**Default behavior**: Off VMs are treated as "Unverifiable" (progress trusted), making validation instant.

## Configuration Wizard

### Domain Settings
- **Domain Name**: e.g., `lab.local`
- **NetBIOS Name**: e.g., `LAB`
- **Forest Mode**: Win2016, Win2019, Win2022, or Win2025
- **Safe Mode Password**: For Directory Services Restore Mode (DSRM)

### Network Settings
- **Subnet CIDR**: e.g., `192.168.50.0/24`
- **Gateway**: e.g., `192.168.50.1`
- **DHCP Scope**: e.g., `192.168.50.100 - 192.168.50.200`

### Domain Controllers
- **Number of DCs**: 1 or more
- **IP Addresses**: Static IPs for each DC
- **OS Edition**: Server2016, Server2022, or Server2025

### Additional VMs
- **Number of VMs**: 0 or more
- **Role**: Domain Controller, Domain Member, or DNS Server
- **OS Edition**: Windows 10/11 Pro/Enterprise or Windows Server editions

## Media Sources

### Automatic (No Registration)
- Windows 10 Pro
- Windows 11 Pro

### Manual Registration Required
Windows 10/11 Enterprise and Windows Server editions require a one-time registration at Microsoft Evaluation Center:

1. After first run, check `Config\MediaSources.psd1`
2. Follow the instructions in that file
3. Update the fwlink URLs with your registered links

## Troubleshooting

### Common Issues

#### 1. "Hyper-V module isn't available"
**Solution**: Enable Hyper-V role
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
```
Then reboot and re-run the script.

#### 2. "Run from an elevated PowerShell session"
**Solution**: Right-click PowerShell â†’ "Run as Administrator"

#### 3. DNS Zone Creation Failed
**Cause**: AD DS still initializing after DC promotion  
**Solution**: The script now retries automatically (up to 30 times with 20-second delays). If it still fails:
```powershell
# Check DC status
Get-VM -Name DC1 | Select-Object State, Heartbeat

# Re-run script to complete DNS setup
.\1.0.2.ps1 -LabRoot E:\HyperV
```

#### 4. DHCP Authorization Failed
**Cause**: AD DS still initializing  
**Solution**: The script now retries DHCP authorization (up to 10 times with 15-second delays). If it still fails:
```powershell
# Check DHCP service
Invoke-Command -VMName DC1 -Credential (Get-Credential) -ScriptBlock {
    Get-Service DHCPServer | Select-Object Status, Name
}

# Re-run script to complete DHCP setup
.\1.0.2.ps1 -LabRoot E:\HyperV
```

#### 5. VM Stuck at "Please wait for the Group Policy Client"
**Cause**: AD DS is still initializing, Group Policy is applying  
**Solution**: Wait 5-10 minutes. The script handles this with extended timeouts.

#### 6. "The system failed to mount" or "file corrupted" errors
**Cause**: VM generation mismatch (trying to mount VHD as VHDX or vice versa)  
**Solution**: 1.0.2 automatically selects correct file format based on Windows version:
- Server 2016/2019/2022 → Generation 1 with `.vhd` files
- Server 2025+ → Generation 2 with `.vhdx` files

If you see this error, verify your VM generation:
```powershell
# Check the VM's generation
Get-VM -Name DC1 | Select-Object Name, Generation

# Check the local VHDX file extension in the VM folder
Get-ChildItem "E:\HyperV\VMs\DC1\Virtual Hard Disks" | Format-Table Name, Extension

# Expected: DC1.vhd for Gen 1, DC1.vhdx for Gen 2
```

#### 7. "Access is denied" when reading cached media
**Cause**: Script cannot mount VHD/VHDX files offline to read edition information  
**Solution**: 1.0.2 automatically infers Windows version from filename patterns (e.g., `Win2022.vhd` → Server2022). This is normal behavior and deployment will proceed with cached media.

### Log Files
Check deployment logs for detailed information:
```
E:\HyperV\Logs\Deploy-YYYYMMDD-HHMMSS.log
```

### Validation Commands

```powershell
# Check all VMs
Get-VM | Select-Object Name, State, Heartbeat

# Check DC DNS
Invoke-Command -VMName DC1 -Credential (Get-Credential) -ScriptBlock {
    Get-DnsServerZone | Select-Object ZoneName, ZoneType
}

# Check DHCP
Invoke-Command -VMName DC1 -Credential (Get-Credential) -ScriptBlock {
    Get-DhcpServerV4Scope | Select-Object ScopeId, Name, State
}
```

## Utility Functions

### Get-LabOrphanedResources
Check for orphaned VMs and VHDX files not tracked by the lab config.

```powershell
Get-LabOrphanedResources -ConfigPath 'E:\HyperV\Config\LabConfig.json' -VMsRoot 'E:\HyperV\VMs'
```

### Remove-LabOrphanedVM
Remove a specific orphaned VM.

```powershell
Remove-LabOrphanedVM -VMName 'OrphanedVM' -VMsRoot 'E:\HyperV\VMs'
```

## Advanced Usage

### Rebuild from Scratch (Complete Fresh Start)
```powershell
# Destroy everything
.\1.0.2.ps1 -TearDown -RemoveSwitch

# Rebuild
.\1.0.2.ps1 -LabRoot E:\HyperV
```

### Add More VMs to Existing Lab
1. Edit `Config\LabConfig.json`
2. Add new VM entries
3. Re-run the script
4. The script will detect new VMs and create them

### Understanding VM Generation and File Format Selection
1.0.2 automatically selects the correct file format based on Windows version:

| Windows Version | VM Generation | File Extension | Firmware | Disk Format |
|-----------------|---------------|----------------|----------|-------------|
| Server 2016/2019/2022 | Generation 1 | `.vhd` | BIOS/MBR | VHD |
| Server 2025+ | Generation 2 | `.vhdx` | UEFI/GPT | VHDX |

**Why this matters**:
- Generation 1 VMs use BIOS firmware and MBR partitioning, which only supports `.vhd` files
- Generation 2 VMs use UEFI firmware and GPT partitioning, which requires `.vhdx` files
- Server 2025+ requires UEFI firmware (Generation 2), so it must use `.vhdx` files

**Verifying your setup**:
```powershell
# Check the VM's generation
Get-VM -Name DC1 | Select-Object Name, Generation

# Check the local VHDX file extension in the VM folder
Get-ChildItem "E:\HyperV\VMs\DC1\Virtual Hard Disks" | Format-Table Name, Extension

# Expected: DC1.vhd for Gen 1, DC1.vhdx for Gen 2
```

### Change Network Settings
1. Use `-Reset` to re-run the wizard
2. Or manually edit `Config\LabConfig.json`
3. Use `-TearDown` then rebuild (network changes require VM recreation)

## File Structure

```
E:\HyperV\
|-- Scripts\              # Generated PowerShell scripts
|   |-- 01-New-LabSwitch.ps1
|   |-- 02-Get-WindowsMedia.ps1
|   |-- 03-New-LabVM.ps1
|   |-- 04-Install-PrimaryDC.ps1
|   |-- 05-Install-AdditionalDC.ps1
|   |-- 06-Join-Domain.ps1
|   |-- 07-Install-DhcpServer.ps1
|   |-- 08-Install-DnsServer.ps1
|   |-- 09-Scan-LabMedia.ps1
|   |-- 10-Validate-LabState.ps1
|   `-- 11-Remove-Lab.ps1
|-- Modules\
|   `-- LabDeploy.Common.psm1
|-- Config\
|   |-- LabConfig.json          # Lab topology and settings
|   `-- MediaSources.psd1       # Windows media download URLs
|-- Media\
|   |-- ISO\                    # Downloaded ISO files
|   |-- VHDX\                   # Cached golden VHDX files
|   `-- Tools\                  # Fido.ps1, Convert-WindowsImage.ps1
|-- VMs\                        # Virtual machine files
|   |-- DC1\
|   |   |-- Virtual Hard Disks\
|   |   `-- Virtual Machines\
|   `-- VM1\
|       |-- Virtual Hard Disks\
|       `-- Virtual Machines
`-- Logs\                       # Deployment logs
    `-- Deploy-YYYYMMDD-HHMMSS.log
```

## Best Practices

1. **Use SSD Storage**: VHDX files grow large; SSD provides better performance
2. **Monitor Disk Space**: Each Windows edition needs 50GB+; VMs need 20GB+
3. **Check Logs**: If deployment fails, check the log file for details
4. **Use -SkipValidation**: For faster re-runs when VMs are intentionally off
5. **Backup Config**: Keep a copy of `LabConfig.json` for reference
6. **Test First**: Start with 1 DC and 1 member VM, then expand

## Security Notes

- **Passwords**: All VMs use the same Administrator password you specify
- **Credentials**: Stored in memory during deployment; saved to disk only temporarily
- **Network**: Lab is isolated on private subnet (192.168.50.0/24 by default)
- **Firewall**: Windows Firewall is enabled on all VMs

## Support

For issues or questions:
1. Check the log file first
2. Verify prerequisites are met
3. Ensure you're running as Administrator
4. Check for existing VMs with `Get-VM`

## Version History

### 1.0.2 (Current)
- **Intelligent VHD/VHDX Selection**: Automatic selection based on Windows Server version
  - Server 2016/2019/2022 → VHD files with Generation 1 VMs (BIOS/MBR)
  - Server 2025 → VHDX files with Generation 2 VMs (UEFI/GPT required)
- **VM Generation Support**: Proper handling of Gen 1 vs Gen 2 throughout deployment
- **Automatic Generation Correction**: Fixes incorrect generation values in saved configs
- **OSKey Inference Fallback**: Automatically determines Windows version from filename patterns when edition reading fails (e.g., access denied errors)
  - Detects Server2016, Server2019, Server2022, Server2025, Win11 patterns
  - Uses file extension (.vhd vs .vhdx) to infer expected generation
- **VM Local File Extension Fix**: Correctly uses `.vhd` for Generation 1 VMs and `.vhdx` for Generation 2 VMs
  - Prevents "file corrupted" errors when trying to mount VHD as VHDX or vice versa
- Enhanced DNS zone creation with AD DS initialization detection
- Improved DHCP authorization with retry logic
- Better error handling for AD DS synchronization delays
- Automatic retry for DNS and DHCP operations during AD DS initialization

### Gen1.0.1 (Intermediate Release)
- Array normalization fixes for single-item JSON arrays
- PSObject property access improvements for strict mode compatibility
- Duplicate Mount-VHD removal to fix file lock issues
- Get-VHD cleanup code to dismount orphaned VHDs before media scan
- MediaSource.Type and Generation property access protection

### Gen1.0.0 (Initial Release)
- Full Hyper-V Active Directory lab deployment automation
- Interactive configuration wizard
- Domain controller promotion with idempotency support
- Additional VM deployment (DC, member servers, DNS servers)
- DHCP and DNS server configuration
- Progress tracking and validation

---

**Last Updated**: 2026-07-08  
**Script Version**: 1.0.2

