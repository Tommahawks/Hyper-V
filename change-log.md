# Change Log - Hyper-V Automation Lab Deploy

## [2026-07-11] Indentation Fix in DHCP Script
- **File(s) modified:** `E:\HyperV\Scripts\07-Install-DhcpServer.ps1`, `c:\Users\Tom\Downloads\Claude Hyper V auto\HPV\Begin.ps1`
- **Function/Section:** `Install-LabDhcpServer` - AD authorization while loop
- **Issue addressed:** Indentation issue where the `while` loop inside the ScriptBlock had incorrect indentation (line 65 in generated script, ~line 2034 in master template)
- **What changed:** Fixed `while ($retryCount -lt $maxRetries)` to be properly indented as a child of the ScriptBlock
- **Reason:** Code style and maintainability - the loop should be indented inside the ScriptBlock for proper PowerShell syntax and readability

## [2026-07-11] Workgroup Mode DHCP Support
- **File(s) modified:** `E:\HyperV\Scripts\07-Install-DhcpServer.ps1`, `c:\Users\Tom\Downloads\Claude Hyper V auto\Gen1.0.0\Begin.ps1`
- **Function/Section:** `Install-LabDhcpServer` function parameters and AD authorization logic
- **Issue addressed:** DHCP server installation failing in workgroup mode due to mandatory DnsDomainName parameter and AD authorization requirement
- **What changed:**
  - Made `DnsDomainName` parameter optional with default empty string (`[string] $DnsDomainName = ""`)
  - Added `[switch] $SkipADAuthorization` parameter
  - Wrapped AD authorization code in conditional check for `-not $SkipADAuthorization`
  - Added conditional logic to omit `-DnsDomain` parameter when empty/null in `Set-DhcpServerV4OptionValue`
- **Reason:** Enable DHCP server installation on non-domain-joined VMs (workgroup mode) without requiring AD authorization or DNS domain name

## [2026-07-11] Enhanced Error Reporting Documentation Added
- **File(s) modified:** `README.md`, `review-log.md`
- **Function/Section:** Script documentation and review findings
- **Issue addressed:** Error reporting feature (`Get-DetailedErrorMessage` function) was not documented in any user-facing files
- **What changed:**
  - Added "Enhanced Error Reporting" section to README.md describing the detailed diagnostic output
  - Updated review-log.md to mention enhanced error handling as a positive finding
- **Reason:** Ensure users and reviewers are aware of the comprehensive error reporting capability for troubleshooting deployment failures
## [2026-07-11] Automatic Error Log Export Documentation Added
- **File(s) modified:** README.md
- **Function/Section:** Script documentation (Error Log Files section)
- **Issue addressed:** Deployment error log files were not documented in user-facing files
- **What changed:**
  - Added "Error Log Files" section to README.md describing automatic export of error reports to `[LabRoot]\Logs\Error_yyyyMMdd_HHmmss.txt` (default: `C:\HyperV-Lab\Logs`)
  - Documented that the path depends on the `-LabRoot` parameter value
  - Documented that logs include full system information and should be shared when seeking help
- **Reason:** Ensure users understand where to find deployment error logs and what information they contain for troubleshooting

## [2026-07-11] DNS Configuration Verification After Domain Join
- **File(s) modified:** E:\HyperV\Scripts\06-Join-Domain.ps1
- **Function/Section:** Add-LabComputerToDomain function
- **Issue addressed:** VMs created with incorrect DNS settings (empty or pointing to wrong servers)
- **What changed:**
  - Added DNS verification after domain join
  - Checks if DNS is using DHCP or static configuration
  - Verifies DNS servers point to domain controllers
  - Automatically fixes DNS configuration if incorrect
- **Reason:** Ensure proper domain resolution even if DHCP options weren't applied correctly

## [2026-07-11] Workgroup Mode with Standalone DNS Server
- **File(s) modified:** c:\Users\Tom\Downloads\Claude Hyper V auto\Gen1.0.0\Begin.ps1
- **Function/Section:** DHCP configuration section (workgroup mode)
- **Issue addressed:** Workgroup mode VMs had no DNS server for internet access and name resolution
- **What changed:**
  - Added standalone DNS server installation on the first additional VM in workgroup mode
  - Creates a forward lookup zone for the lab domain (non-AD-integrated)
  - Configures Google (8.8.8.8) and Cloudflare (1.1.1.1) as forwarders for internet access
- **Reason:** Enable internet access and name resolution in workgroup mode without requiring a domain controller

## [2026-07-11] DNS Configuration Verification Timing Fix
- **File(s) modified:** E:\HyperV\Scripts\06-Join-Domain.ps1
- **Function/Section:** Add-LabComputerToDomain function
- **Issue addressed:** DNS verification was running before domain join completed, causing failures when VMs had no DNS configured
- **What changed:**
  - Moved DNS verification to run AFTER the VM restarts following domain join
  - Added logic to resolve domain controllers and verify they're reachable
  - Only fixes DNS if static configuration doesn't point to a domain controller
  - Gracefully handles cases where domain resolution fails (logs warning but continues)
- **Reason:** Ensure DNS verification runs on a properly configured, restarted VM that has successfully joined the domain

## [2026-07-11] Automatic DNS Configuration Before Domain Join
- **File(s) modified:** E:\HyperV\Scripts\06-Join-Domain.ps1, c:\Users\Tom\Downloads\Claude Hyper V auto\Gen1.0.0\Begin.ps1
- **Function/Section:** Add-LabComputerToDomain function
- **Issue addressed:** VMs failed to join domain because they had no DNS configured and couldn't resolve the domain name before DHCP lease was obtained
- **What changed:**
  - Added -LabConfig parameter to pass configuration to the function
  - Before waiting for domain resolution, script sets DNS server to gateway/DC IP
  - This ensures VM can resolve domain even without DHCP lease
  - DNS is set on all active network adapters
- **Reason:** Prevents timeout failures when VMs are created but haven't received DHCP options yet

## [2026-07-11] Template Update for 06-Join-Domain.ps1
- **File(s) modified:** c:\Users\Tom\Downloads\Claude Hyper V auto\Gen1.0.0\Begin.ps1
- **Function/Section:** Master script template for generated child scripts
- **Issue addressed:** Changes to 06-Join-Domain.ps1 were not propagated to the master script template, causing "Parameter cannot be found" errors when running with -Reset or ForceRegenerateScripts
- **What changed:**
  - Updated the here-string template for 06-Join-Domain.ps1 in the master script
  - Added -LabConfig parameter to function signature
  - Added DNS configuration before domain join (sets gateway IP)
  - Added DNS verification after restart
- **Reason:** Ensure generated scripts have all fixes when using -Reset or ForceRegenerateScripts

## [2026-07-11] DNS Server IP Fixed to Use DC IP Instead of Gateway
- **File(s) modified:** E:\HyperV\Scripts\06-Join-Domain.ps1, c:\Users\Tom\Downloads\Claude Hyper V auto\Gen1.0.0\Begin.ps1
- **Function/Section:** Add-LabComputerToDomain function - DNS configuration before domain join
- **Issue addressed:** Script was using gateway IP (e.g., 192.168.50.1) as DNS server, but DCs are at different IPs (e.g., 192.168.50.10, .11)
- **What changed:**
  - Changed DNS server selection to use the first domain controller's IP address
  - Falls back to gateway if no DC info available
  - Default fallback is now 192.168.50.10 (first DC) instead of 192.168.50.1 (gateway)
- **Reason:** Ensure VMs can resolve domain names by pointing DNS to actual domain controllers, not the gateway

## [2026-07-11] Network Configuration Documentation Added
- **File(s) modified:** README.md, 
eview-log.md
- **Function/Section:** Script documentation (Network Configuration section)
- **Issue addressed:** Network configuration details were not documented, causing confusion about IP addressing and DC DNS settings
- **What changed:**
  - Added comprehensive "Network Configuration" section to README.md
  - Documented default addresses for all network components (gateway, DCs, DHCP range)
  - Clarified that DC IPs are hardcoded at .10, .11, etc.
  - Explained DNS server selection uses first DC's IP, not gateway
- **Reason:** Help users understand the network topology and why DNS is set to specific addresses

