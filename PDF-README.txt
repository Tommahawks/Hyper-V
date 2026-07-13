================================================================================
Hyper-V Automation Lab Deploy 1.0.2 - Documentation
================================================================================

INSTRUCTIONS TO CREATE PDF:

Method 1: Using Chrome/Edge (Easiest - RECOMMENDED)
-----------------------------------------------------
1. Open the file: 1.0.2-Instructions.html
2. Press Ctrl+P (Print)
3. Select 'Save as PDF' as destination
4. Click 'Save'

Method 2: Using PowerShell (if you have PDF tools installed)
-------------------------------------------------------------
Option A - Using Print-Module:
  Install-Module -Name Print-Module -Force
  Print-HTMLToPDF -HtmlFile '1.0.2-Instructions.html' -PdfFile '1.0.2-Instructions.pdf'

Option B - Using Pandoc:
  Install Pandoc from https://pandoc.org
  pandoc '1.0.2-Instructions.html' -o '1.0.2-Instructions.pdf' --pdf-engine=wkhtmltopdf

Option C - Using Node.js (markdownpdf):
  npm install -g markdownpdf
  markdownpdf 'README.md' '1.0.2-Instructions.pdf'

================================================================================
DOCUMENTATION FILES CREATED:
================================================================================

1. README.md
   - Original markdown documentation
   - Size: ~10.7 KB

2. 1.0.2-Instructions.html
   - HTML version with styling
   - Size: ~15.2 KB
   - Can be opened in any web browser
   - Best for viewing on screen

3. Convert-ToPDF.bat
   - Quick batch file to open HTML in browser
   - Double-click to open documentation

================================================================================
QUICK START GUIDE:
================================================================================

1. First Run:
   .\Begin.ps1 -LabRoot E:\HyperV

2. Subsequent Runs:
   .\Begin.ps1 -LabRoot E:\HyperV

3. Resume Interrupted Deployment:
   .\Begin.ps1 -LabRoot E:\HyperV

4. Skip Validation (Faster):
   .\Begin.ps1 -LabRoot E:\HyperV -SkipValidation

5. Rebuild from Scratch:
   .\Begin.ps1 -TearDown -RemoveSwitch
   .\Begin.ps1 -LabRoot E:\HyperV

================================================================================
PARAMETERS SUMMARY:
================================================================================

-LabRoot              Root folder for lab resources (default: C:\HyperV-Lab)
-ForceRegenerateScripts Re-generate all scripts (rarely needed)
-Reset                Re-run configuration wizard
-ScanOnly             Scan media and validate state (no deployment)
-SkipValidation       Skip ground-truth validation (faster)
-TearDown             Destroy VMs and clear progress (keep media)
-RemoveSwitch         Also remove virtual switch (with -TearDown)
-BootForValidation    Power on VMs for live validation

================================================================================
TROUBLESHOOTING:
================================================================================

DNS Zone Creation Failed:
  - Script now retries automatically (30 times, 20s delays)
  - Re-run script if still fails

DHCP Authorization Failed:
  - Script now retries automatically (10 times, 15s delays)
  - Re-run script if still fails

VM Stuck at "Please wait for the Group Policy Client":
  - Wait 5-10 minutes
  - Script handles this with extended timeouts

Check Logs:
  E:\HyperV\Logs\Deploy-YYYYMMDD-HHMMSS.log

================================================================================
LAST UPDATED: 2026-07-01
SCRIPT VERSION: 2.8 (Gen1.0.2)

NEW IN Gen1.0.2:
- Intelligent VHD/VHDX selection based on Windows Server version
- Server 2016/2019/2022 → Generation 1 VMs with VHD files
- Server 2025 → Generation 2 VMs with VHDX files
- Automatic correction of incorrect generation values in saved configs
================================================================================

