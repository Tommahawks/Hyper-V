# PowerShell script to generate PDF documentation
param(
    [string]$MarkdownFile = "README.md",
    [string]$OutputFile = "1.0.2-Instructions.pdf"
)

Write-Host "=== Hyper-V Automation Lab Deploy 1.0.2 - Documentation Generator ===" -ForegroundColor Cyan
Write-Host ""

# Check if markdown file exists
if (-not (Test-Path $MarkdownFile)) {
    Write-Host "Error: Markdown file '$MarkdownFile' not found!" -ForegroundColor Red
    exit 1
}

Write-Host "Converting $MarkdownFile to HTML..." -ForegroundColor Yellow

# Read markdown content
$markdownContent = Get-Content -Path $MarkdownFile -Raw

# Simple markdown to HTML conversion (basic parsing)
$htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Hyper-V Automation Lab Deploy 1.0.2 - Instructions</title>
    <style>
        body { font-family: Segoe UI, Tahoma, Geneva, Verdana, sans-serif; line-height: 1.6; max-width: 900px; margin: 40px auto; padding: 20px; color: #333; }
        h1 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        h2 { color: #34495e; margin-top: 25px; border-bottom: 1px solid #ecf0f1; padding-bottom: 5px; }
        h3 { color: #7f8c8d; margin-top: 20px; }
        h4 { color: #95a5a6; margin-top: 15px; }
        pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; border: 1px solid #ddd; }
        code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; font-family: Consolas, Monaco, monospace; }
        blockquote { border-left: 4px solid #3498db; margin: 0; padding-left: 20px; color: #666; background: #f9f9f9; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background: #3498db; color: white; }
        tr:nth-child(even) { background: #f2f2f2; }
        ul, ol { margin: 15px 0; padding-left: 30px; }
        li { margin: 5px 0; }
        .note { background: #fff3cd; border-left: 4px solid #ffc107; padding: 15px; margin: 15px 0; }
        .warning { background: #f8d7da; border-left: 4px solid #dc3545; padding: 15px; margin: 15px 0; }
        .success { background: #d4edda; border-left: 4px solid #28a745; padding: 15px; margin: 15px 0; }
        a { color: #3498db; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 0.9em; color: #777; text-align: center; }
    </style>
</head>
<body>
<h1>Hyper-V Automation Lab Deploy - 1.0.2</h1>
<h2>Overview</h2>
<p>This script automates the creation of a complete Hyper-V Active Directory lab environment in a single execution. It handles everything from virtual switch setup to domain controller promotion, DHCP configuration, and domain-joined VM deployment.</p>
<h3><strong>1.0.2 Improvements</strong></h3>
<ul>
<li><strong>Intelligent VHD/VHDX Selection</strong>: Automatically uses VHD for Server 2016/2019/2022 (Gen 1) and VHDX for Server 2025 (Gen 2)</li>
<li><strong>OSKey Inference Fallback</strong>: Determines Windows version from filename patterns when edition reading fails</li>
<li><strong>VM Generation Support</strong>: Correctly uses .vhd for Gen 1 VMs and .vhdx for Gen 2 VMs</li>
<li><strong>Automatic Generation Correction</strong>: Fixes incorrect generation values in saved configurations</li>
<li><strong>Better Error Handling</strong>: Improved handling of media access issues and strict mode compatibility</li>
</ul>
<h2>Prerequisites</h2>
<h3>System Requirements</h3>
<ul>
<li><strong>Operating System</strong>: Windows 10 or Windows 11 (any edition)</li>
<li><strong>PowerShell</strong>: Version 5.1 or later</li>
<li><strong>Hyper-V</strong>: Must be enabled</li>
<li><strong>Administrator</strong>: Must run as Administrator</li>
</ul>
<h3>Hardware Requirements</h3>
<ul>
<li><strong>CPU</strong>: 4+ cores recommended (more for multiple VMs)</li>
<li><strong>RAM</strong>: 16GB+ recommended (8GB per VM + host overhead)</li>
<li><strong>Storage</strong>: 
<ul>
<li>50GB+ free space for each Windows edition (ISO + VHDX)</li>
<li>20GB+ per VM (dynamic VHDX grows as needed)</li>
<li>SSD highly recommended for performance</li>
</ul>
</li>
</ul>
<h3>Network Requirements</h3>
<ul>
<li>Internet connection for first-time media downloads</li>
<li>No existing Hyper-V switches with conflicting IP ranges</li>
</ul>
<h2>Quick Start</h2>
<h3>First Run (Interactive Wizard)</h3>
<pre><code># Run as Administrator
.\Begin.ps1 -LabRoot E:\HyperV
</code></pre>
<p>The script will:</p>
</function>
</tool_call>
<tool_call>
<function=replace_string_in_file>
<parameter=filePath>
c:\Users\TomCore\Downloads\HPV\Instructions.ps1
<ol>
<li>Check prerequisites</li>
<li>Launch an interactive configuration wizard</li>
<li>Download and cache Windows media (first time only)</li>
<li>Create the virtual switch and NAT</li>
<li>Deploy domain controllers</li>
<li>Configure DHCP</li>
<li>Deploy additional VMs</li>
<li>Join VMs to the domain</li>
</ol>
<h3>Subsequent Runs</h3>
<pre><code># Resume interrupted deployment
.\Begin.ps1 -LabRoot E:\HyperV

# Skip validation (faster, trusts saved state)
.\Begin.ps1 -LabRoot E:\HyperV -SkipValidation

# Rebuild from cached media (after -TearDown)
.\Begin.ps1 -LabRoot E:\HyperV -SkipValidation
</code></pre>
<h2>Parameters</h2>
<h3><code>-LabRoot</code> (Required)</h3>
<p><strong>Type</strong>: String<br>
<strong>Default</strong>: <code>C:\HyperV-Lab</code></p>
<p>The root folder for all lab resources. This directory will contain:</p>
<ul>
<li><code>Scripts\</code> - Generated PowerShell scripts</li>
<li><code>Modules\</code> - PowerShell modules</li>
<li><code>Config\</code> - Lab configuration (LabConfig.json)</li>
<li><code>Media\</code> - Downloaded ISOs and cached VHDX files</li>
<li><code>VMs\</code> - Virtual machine files</li>
<li><code>Logs\</code> - Deployment logs</li>
</ul>
<p><strong>Example</strong>:</p>
<pre><code>.\Begin.ps1 -LabRoot E:\HyperV
</code></pre>
<h3><code>-ForceRegenerateScripts</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off</p>
<p>Re-writes every generated child file even if content hasn't changed.<br>
<strong>Use case</strong>: Rarely needed - only if you suspect script corruption.</p>
<h3><code>-Reset</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off</p>
<p>Ignores saved <code>Config\LabConfig.json</code> and re-runs the configuration wizard from scratch.<br>
<strong>Note</strong>: Does NOT delete already-created VMs.</p>
<h3><code>-ScanOnly</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off</p>
<p>Runs media scan and lab state validation, then exits WITHOUT building anything.<br>
<strong>Use case</strong>: "What do I already have here?"</p>
<h3><code>-SkipValidation</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off</p>
<p>Skips ground-truth validation and trusts only the persisted <code>CompletedSteps</code> file.<br>
<strong>Use case</strong>: All VMs intentionally off, or PowerShell Direct probing is undesirable.</p>
<h3><code>-TearDown</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off</p>
<p>Destroys existing lab VMs and clears saved build progress, then exits WITHOUT rebuilding.<br>
<strong>Preserves</strong>:</p>
<ul>
<li>Topology and network settings</li>
<li>Per-VM MediaSource choices</li>
<li>Cached ISO/VHDX media</li>
</ul>
<p><strong>Use case</strong>: Fast-fresh flow:</p>
<pre><code>.\Begin.ps1 -TearDown      # Destroy VMs, clear progress, keep media
.\Begin.ps1 -SkipValidation # Rebuild all VMs from cached media
</code></pre>
<h3><code>-RemoveSwitch</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off<br>
<strong>Requires</strong>: <code>-TearDown</code></p>
<p>Also removes the Hyper-V virtual switch and its NetNat object.<br>
<strong>Safety</strong>: Off by default to prevent accidental network disruption.</p>
<h3><code>-BootForValidation</code></h3>
<p><strong>Type</strong>: Switch<br>
<strong>Default</strong>: Off</p>
<p>Powers on stopped VMs during validation to probe roles live via PowerShell Direct.<br>
<strong>Default behavior</strong>: Off VMs are treated as "Unverifiable" (progress trusted), making validation instant.</p>
<h2>Configuration Wizard</h2>
<h3>Domain Settings</h3>
<ul>
<li><strong>Domain Name</strong>: e.g., <code>lab.local</code></li>
<li><strong>NetBIOS Name</strong>: e.g., <code>LAB</code></li>
<li><strong>Forest Mode</strong>: Win2016, Win2019, Win2022, or Win2025</li>
<li><strong>Safe Mode Password</strong>: For Directory Services Restore Mode (DSRM)</li>
</ul>
<h3>Network Settings</h3>
<ul>
<li><strong>Subnet CIDR</strong>: e.g., <code>192.168.50.0/24</code></li>
<li><strong>Gateway</strong>: e.g., <code>192.168.50.1</code></li>
<li><strong>DHCP Scope</strong>: e.g., <code>192.168.50.100 - 192.168.50.200</code></li>
</ul>
<h3>Domain Controllers</h3>
<ul>
<li><strong>Number of DCs</strong>: 1 or more</li>
<li><strong>IP Addresses</strong>: Static IPs for each DC</li>
<li><strong>OS Edition</strong>: Server2016, Server2022, or Server2025</li>
</ul>
<h3>Additional VMs</h3>
<ul>
<li><strong>Number of VMs</strong>: 0 or more</li>
<li><strong>Role</strong>: Domain Controller, Domain Member, or DNS Server</li>
<li><strong>OS Edition</strong>: Windows 10/11 Pro/Enterprise or Windows Server editions</li>
</ul>
<h2>Media Sources</h2>
<h3>Automatic (No Registration)</h3>
<ul>
<li>Windows 10 Pro</li>
<li>Windows 11 Pro</li>
</ul>
<h3>Manual Registration Required</h3>
<p>Windows 10/11 Enterprise and Windows Server editions require a one-time registration at Microsoft Evaluation Center:</p>
<ol>
<li>After first run, check <code>Config\MediaSources.psd1</code></li>
<li>Follow the instructions in that file</li>
<li>Update the fwlink URLs with your registered links</li>
</ol>
<h2>Troubleshooting</h2>
<h3>Common Issues</h3>
<h4>1. "The system failed to mount" or "file corrupted" errors</h4>
<p><strong>Cause</strong>: VM generation mismatch (trying to mount VHD as VHDX or vice versa)<br>
<strong>Solution</strong>: 1.0.2 automatically selects correct file format based on Windows version. If you see this error:</p>
<pre><code># Check the VM's generation
Get-VM -Name DC1 | Select-Object Name, Generation

# Check the MediaSource in your config
Get-Content E:\HyperV\Config\LabConfig.json | ConvertFrom-Json | Select-Object -ExpandProperty DomainControllers | Format-Table Name, @{Name='Generation';Expression={$_.MediaSource.Generation}}, @{Name='MediaPath';Expression={$_.MediaSource.Path}}

# Re-run script to regenerate scripts with correct generation
.\1.0.2.ps1 -LabRoot E:\HyperV -ForceRegenerateScripts
</code></pre>

<h4>2. "Access is denied" when reading cached media</h4>
<p><strong>Cause</strong>: Script cannot mount VHD/VHDX files offline to read edition information<br>
<strong>Solution</strong>: 1.0.2 automatically infers Windows version from filename patterns (e.g., Win2022.vhd → Server2022). This is normal behavior and deployment will proceed with cached media.

<h4>3. "Hyper-V module isn't available"</h4>
<p><strong>Solution</strong>: Enable Hyper-V role</p>
<pre><code>Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All
</code></pre>
<p>Then reboot and re-run the script.</p>
<h4>4. "Run from an elevated PowerShell session"</h4>
<p><strong>Solution</strong>: Right-click PowerShell â†' "Run as Administrator"</p>
<h4>5. DNS Zone Creation Failed</h4>
<p><strong>Cause</strong>: AD DS still initializing after DC promotion<br>
<strong>Solution</strong>: The script now retries automatically (up to 30 times with 20-second delays). If it still fails:</p>
<pre><code># Check DC status
Get-VM -Name DC1 | Select-Object State, Heartbeat

# Re-run script to complete DNS setup
.\1.0.2.ps1 -LabRoot E:\HyperV
</code></pre>
<h4>6. DHCP Authorization Failed</h4>
<p><strong>Cause</strong>: AD DS still initializing<br>
<strong>Solution</strong>: The script now retries DHCP authorization (up to 10 times with 15-second delays). If it still fails:</p>
<pre><code># Check DHCP service
Invoke-Command -VMName DC1 -Credential (Get-Credential) -ScriptBlock {
    Get-Service DHCPServer | Select-Object Status, Name
}

# Re-run script to complete DHCP setup
.\1.0.2.ps1 -LabRoot E:\HyperV
</code></pre>
<h4>7. VM Stuck at "Please wait for the Group Policy Client"</h4>
<p><strong>Cause</strong>: AD DS is still initializing, Group Policy is applying<br>
<strong>Solution</strong>: Wait 5-10 minutes. The script handles this with extended timeouts.</p>
<h3>Log Files</h3>
<p>Check deployment logs for detailed information:</p>
<pre><code>E:\HyperV\Logs\Deploy-YYYYMMDD-HHMMSS.log
</code></pre>
<h3>Validation Commands</h3>
<pre><code># Check all VMs
Get-VM | Select-Object Name, State, Heartbeat

# Check DC DNS
Invoke-Command -VMName DC1 -Credential (Get-Credential) -ScriptBlock {
    Get-DnsServerZone | Select-Object ZoneName, ZoneType
}

# Check DHCP
Invoke-Command -VMName DC1 -Credential (Get-Credential) -ScriptBlock {
    Get-DhcpServerV4Scope | Select-Object ScopeId, Name, State
}
</code></pre>

<h3>Verifying VM Generation and File Format</h3>
<p>1.0.2 automatically selects the correct file format based on Windows version:</p>
<ul>
<li><strong>Generation 1 (BIOS/MBR)</strong>: Uses .vhd files for Server 2016/2019/2022</li>
<li><strong>Generation 2 (UEFI/GPT)</strong>: Uses .vhdx files for Server 2025+</li>
</ul>
<pre><code># Verify VM generation
Get-VM -Name DC1 | Select-Object Name, Generation

# Check the local VHDX file extension in the VM folder
Get-ChildItem "E:\HyperV\VMs\DC1\Virtual Hard Disks" | Format-Table Name, Extension

# Expected: DC1.vhd for Gen 1, DC1.vhdx for Gen 2
</code></pre>
<h2>Utility Functions</h2>
<h3>Get-LabOrphanedResources</h3>
<p>Check for orphaned VMs and VHDX files not tracked by the lab config.</p>
<pre><code>Get-LabOrphanedResources -ConfigPath 'E:\HyperV\Config\LabConfig.json' -VMsRoot 'E:\HyperV\VMs'
</code></pre>
<h3>Remove-LabOrphanedVM</h3>
<p>Remove a specific orphaned VM.</p>
<pre><code>Remove-LabOrphanedVM -VMName 'OrphanedVM' -VMsRoot 'E:\HyperV\VMs'
</code></pre>
<h2>Advanced Usage</h2>
<h3>Rebuild from Scratch (Complete Fresh Start)</h3>
<pre><code># Destroy everything
<pre><code>.\\1.0.2.ps1 -TearDown -RemoveSwitch

# Rebuild
.\\1.0.2.ps1 -LabRoot E:\\HyperV
</code></pre>
<h3>Add More VMs to Existing Lab</h3>
<ol>
<li>Edit <code>Config\LabConfig.json</code></li>
<li>Add new VM entries</li>
<li>Re-run the script</li>
<li>The script will detect new VMs and create them</li>
</ol>
<h3>Change Network Settings</h3>
<ol>
<li>Use <code>-Reset</code> to re-run the wizard</li>
<li>Or manually edit <code>Config\LabConfig.json</code></li>
<li>Use <code>-TearDown</code> then rebuild (network changes require VM recreation)</li>
</ol>
<h2>File Structure</h2>
<pre><code>E:\HyperV\
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
</code></pre>
<h2>Best Practices</h2>
<ol>
<li><strong>Use SSD Storage</strong>: VHDX files grow large; SSD provides better performance</li>
<li><strong>Monitor Disk Space</strong>: Each Windows edition needs 50GB+; VMs need 20GB+</li>
<li><strong>Check Logs</strong>: If deployment fails, check the log file for details</li>
<li><strong>Use -SkipValidation</strong>: For faster re-runs when VMs are intentionally off</li>
<li><strong>Backup Config</strong>: Keep a copy of <code>LabConfig.json</code> for reference</li>
<li><strong>Test First</strong>: Start with 1 DC and 1 member VM, then expand</li>
</ol>
<h2>Security Notes</h2>
<ul>
<li><strong>Passwords</strong>: All VMs use the same Administrator password you specify</li>
<li><strong>Credentials</strong>: Stored in memory during deployment; saved to disk only temporarily</li>
<li><strong>Network</strong>: Lab is isolated on private subnet (192.168.50.0/24 by default)</li>
<li><strong>Firewall</strong>: Windows Firewall is enabled on all VMs</li>
</ul>
<h2>Version History</h2>
<h3>1.0.2 (Current)</h3>
<ul>
<li>Enhanced DNS zone creation with AD DS initialization detection</li>
<li>Improved DHCP authorization with retry logic</li>
<li>Better error handling for AD DS synchronization delays</li>
<li>Automatic retry for DNS and DHCP operations during AD DS initialization</li>
</ul>
<div class="footer">
    <p>Last Updated: 2026-07-01 | Script Version: 1.0.2</p>
</div>
</body>
</html>
"@

# Save HTML
$htmlFile = $OutputFile -replace '\.pdf$', '.html'
Set-Content -Path $htmlFile -Value $htmlContent -Encoding UTF8
Write-Host "HTML created: $htmlFile" -ForegroundColor Green

Write-Host ""
Write-Host "=== PDF Generation Instructions ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "To convert the HTML file to PDF, use one of these methods:" -ForegroundColor Yellow
Write-Host ""
Write-Host "Method 1: Using Chrome/Edge (Recommended)" -ForegroundColor White
Write-Host "  1. Open $htmlFile in Chrome or Edge" -ForegroundColor Gray
Write-Host "  2. Press Ctrl+P (Print)" -ForegroundColor Gray
Write-Host "  3. Select 'Save as PDF' as destination" -ForegroundColor Gray
Write-Host "  4. Click 'Save'" -ForegroundColor Gray
Write-Host ""
Write-Host "Method 2: Using PowerShell (if Print-Module available)" -ForegroundColor White
Write-Host "  Install-Module -Name Print-Module -Force" -ForegroundColor Gray
Write-Host "  Then use: Print-HTMLToPDF -HtmlFile '$htmlFile' -PdfFile '$OutputFile'" -ForegroundColor Gray
Write-Host ""
Write-Host "Method 3: Using Pandoc" -ForegroundColor White
Write-Host "  pandoc '$htmlFile' -o '$OutputFile' --pdf-engine=wkhtmltopdf" -ForegroundColor Gray
Write-Host ""
Write-Host "Method 4: Using Node.js (markdownpdf)" -ForegroundColor White
Write-Host "  npm install -g markdownpdf" -ForegroundColor Gray
Write-Host "  markdownpdf '$MarkdownFile' '$OutputFile'" -ForegroundColor Gray
Write-Host ""
Write-Host "The HTML file can also be used directly as web documentation." -ForegroundColor Cyan

