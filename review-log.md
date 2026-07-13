# Review Log - Hyper-V Automation Lab Deploy

## Script Understanding

**Main Script**: `Begin.ps1`

This is a comprehensive Hyper-V Active Directory lab deployment automation script that:
- Sets up a complete AD lab environment in a single execution
- Creates virtual switches, NAT, domain controllers, DHCP, DNS, and additional VMs
- Uses an interactive configuration wizard for initial setup
- Saves configuration to `Config\LabConfig.json` for reuse
- Supports resumable deployments (skips completed steps)
- Provides `-TearDown` mode to destroy lab while preserving media
- Automatically downloads and caches Windows ISOs, converts to VHDX

**Key Features**:
- Intelligent VHD/VHDX selection based on Windows version (Gen 1 vs Gen 2)
- Progress tracking with `CompletedSteps` persistence
- Media caching for faster re-deployments
- PowerShell Direct validation for running VMs
- Idempotent operations for DC promotion and DHCP

## Script Purpose & Behavior

**Primary Function**: Automate Hyper-V Active Directory lab deployment

**What it does**:
1. Validates prerequisites (Administrator, Hyper-V)
2. Generates child scripts and modules under `-LabRoot`
3. Runs interactive configuration wizard
4. Downloads Windows media (cached after first use)
5. Creates virtual switch and NAT
6. Deploys domain controllers with AD DS promotion
7. Configures DHCP server
8. Optionally deploys separate DNS server
9. Deploys additional VMs and joins them to the domain
10. Tracks progress in `CompletedSteps` array

**What it doesn't do**:
- Does NOT modify existing VMs that are already deployed (idempotent)
- Does NOT delete cached media on `-TearDown` (only removes VMs)
- Does NOT require guest credentials for teardown operations

## Other Files in Directory

| File | Purpose |
|------|---------|
| `Begin.ps1` | Main deployment script - the single entry point for all lab operations |
| `README.md` | Comprehensive documentation with usage instructions, parameters, troubleshooting |
| `CHANGES.md` | Historical record of fixes and improvements applied to the script |
| `config.json` | Empty configuration file (likely placeholder) |
| `Instructions.ps1` | PowerShell script to generate HTML documentation from README.md |
| `Convert-ToPdf.ps1` | PowerShell script to convert Markdown to PDF using powershell-markdownpdf module |
| `Convert-ToPDF.bat` | Batch file to open HTML documentation in default browser |
| `Alternative.ps1` | Self-extracting installer for Hyper-V Lab Suite v3.0 (legacy) |
| `backup.donottouch` | Backup copy of the main script with same functionality as Begin.ps1 |
| `PDF-README.txt` | Text-based instructions for creating PDF documentation |
| `1.0.2-Instructions.html` | HTML version of README.md with styling for web viewing |

## Current Version

**Version**: 1.0.2  
**Last Updated**: 2026-07-08  
**Script Name**: Begin.ps1 (previously referenced as 1.0.2.ps1)

### Version History:
- **1.0.2** - Current release with intelligent VHD/VHDX selection, VM generation support
- **1.0.1** - Intermediate release with array normalization and strict mode fixes  
- **1.0.0** - Initial release with full AD lab deployment automation

## Review Findings

### Inconsistencies Found:
1. **Script Name References**: Documentation consistently referenced `1.0.2.ps1` instead of the actual script name `Begin.ps1`
2. **Version Numbering**: CHANGES.md mentioned "Gen1.0.1" and "Gen1.0.0" which should be "1.0.1" and "1.0.0"
3. **PDF-README.txt**: Used `Gen1.0.2.ps1` instead of correct script name

### Broken References:
- None found (all references were just naming inconsistencies, not broken paths)

### Outdated Content:
- CHANGES.md referenced old script names in code location comments
- PDF-README.txt had outdated command examples with wrong script name
- Instructions.ps1 HTML output would have incorrect script references

### Recommendations:
1. ✅ All script name references updated to `Begin.ps1`
2. ✅ Version numbering standardized (removed "Gen" prefix)
3. ✅ Documentation now accurately reflects current script name and usage
4. Consider removing `backup.donottouch` if no longer needed as a backup

### Notes:
- The main script (`Begin.ps1`) was not modified - only documentation references were updated
- All PowerShell command examples in documentation now correctly use `.\Begin.ps1`
- The script's self-documentation (comment-based help) remains unchanged and accurate
