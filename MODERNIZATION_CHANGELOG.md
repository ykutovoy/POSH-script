# Modernization Changelog

**Last Updated**: January 29, 2026 (Updated with Phase 5.1: Menu UX Improvements & Public Release)

This document tracks the implementation status and changes made during the script modernization process.

---

## Implementation Status

### ✅ Completed (Phase 1-5 + Repository Cleanup)

#### Phase 1: Authentication Fixes - COMPLETED
- ✅ Separate credential storage for vCenter and ESXi host credentials
- ✅ Centralized credential management functions (`Get-VCenterCredentials`, `Get-ESXiHostCredentials`)
- ✅ Updated `Connect-ToVCenter` to use cached vCenter credentials
- ✅ Updated all ESXi host functions (`Copy-FileToHost`, `Copy-FileToCluster`, `Invoke-SSHOnCluster`) to use cached credentials
- ✅ Menu updated to display both credential types with status
- ✅ Menu options updated: Option 3 for vCenter credentials, Option 4 for ESXi host credentials
- ✅ Renamed `Set-ESXiCredentials` to `Set-ESXiHostCredentials` for clarity
- ✅ Created `Set-VCenterCredentials` function

#### Phase 2: Get-VMhostIpmi Integration - COMPLETED
- ✅ Added menu option 19: "Get IPMI BMC Addresses"
- ✅ Implemented `Get-ClusterIPMI` function that queries all hosts in cluster for IPMI BMC addresses
- ✅ Displays results in formatted table

#### Phase 3: Set-EsxiCustomAttribute Integration - COMPLETED
- ✅ Added menu option 20: "Set Custom Attribute on Host"
- ✅ Added menu option 21: "Set Custom Attribute on Cluster (from IPMI)"
- ✅ Implemented `Set-HostCustomAttribute` function for single host operations
- ✅ Implemented `Set-ClusterCustomAttributeFromIPMI` function for batch operations using IPMI addresses

#### Phase 4: Standalone Host Support - COMPLETED
- ✅ Added connection type detection to distinguish between vCenter and standalone ESXi host connections
- ✅ Added `$script:connectionType` variable to track connection type ("vCenter" or "Standalone")
- ✅ Implemented `Test-IsVCenter` function to detect connection type
- ✅ Updated `Connect-ToVCenter` to detect and store connection type after connection
- ✅ Updated menu display to show connection type (vCenter/Standalone Host) in status
- ✅ Updated `Get-ClusterIPMI` (Option 19) to work with both vCenter clusters and standalone hosts
- ✅ Updated `Get-ClusterName` to prevent cluster operations when connected to standalone hosts
- ✅ Added appropriate error messages for standalone host scenarios

#### Phase 5: UI Polishing - COMPLETED
- ✅ Added standardized status indicators (`$script:Icons`) with ASCII-compatible symbols: [OK], [FAIL], [WARN], [INFO], [....]
- ✅ Added centralized color theme configuration (`$script:Theme`) for consistent styling
- ✅ Implemented `Write-Status` function for standardized output messages
- ✅ Implemented `Read-HostPrompt` function for standardized input handling with default value support
- ✅ Implemented `Show-BatchProgress` function for progress bars during batch operations
- ✅ Implemented `Show-BatchSummary` function for operation summaries with success/failure counts
- ✅ Implemented `Show-ConfirmationBox` function for dangerous operation warnings
- ✅ Implemented `Show-FormattedTable` function for formatted table output with box-drawing characters
- ✅ Enhanced `Pause` function with customizable context-aware messages
- ✅ Redesigned `Show-Menu` function with box-drawing borders, category section headers, and proper alignment
- ✅ Added "Last Operation" display in menu header showing previous operation result
- ✅ Changed to show all menu options (disabled ones shown in gray with "[Requires vCenter]")
- ✅ Fixed menu number alignment (padding single digits: " 1." through " 9.", then "10." through "21.")
- ✅ Standardized all Y/N prompts to consistent format with defaults
- ✅ Refactored all functions to use new UI helper functions
- ✅ Added progress bars to batch operations (Start/Stop SSH, SCP, RDMA config, etc.)
- ✅ Added batch operation summaries showing total/success/failed counts
- ✅ Added confirmation box for dangerous reboot operation
- ✅ Updated IPMI results to use formatted table display

#### Repository Cleanup - COMPLETED
- ✅ Removed `get-VMhostIpmi.ps1` (functionality integrated as Option 19)
- ✅ Removed `Set-EsxiCustomAttribute.ps1` (functionality integrated as Options 20-21)
- ✅ Added comprehensive `README.md` with usage instructions and feature documentation

#### Phase 5.1: Menu UX Improvements - COMPLETED
- ✅ Improved disabled option messages to show context-aware reasons
- ✅ "Not connected" shown when no connection exists
- ✅ "Requires vCenter" shown when connected to standalone ESXi but option needs vCenter
- ✅ Added connection validation for all operations requiring it
- ✅ Added helpful messages for edge cases (already connected, not connected)

#### Public Release Preparation - COMPLETED
- ✅ Security audit passed - no hardcoded credentials or sensitive data
- ✅ Removed internal infrastructure identifiers from documentation
- ✅ Updated README.md for public contributions
- ✅ Added `.claude/` to .gitignore
- ✅ Repository approved for public release

### 🔄 Pending (Phase 6)
- Configuration persistence (save settings to file)
- Module structure conversion
- Pipeline support
- Logging implementation
- Advanced error handling improvements
- Pipeline support
- Logging implementation
- Advanced UX improvements

---

## Change Details

### Phase 1 Implementation Details

**Credential Storage Changes:**
- Added `$script:vCenterCreds` variable for vCenter/cluster credentials
- Existing `$script:hostCreds` variable retained for ESXi host/SSH credentials

**New Functions:**
- `Get-VCenterCredentials` - Retrieves cached vCenter credentials or prompts if not cached
- `Get-ESXiHostCredentials` - Retrieves cached ESXi host credentials or prompts if not cached
- `Set-VCenterCredentials` - Sets/resets vCenter credentials with user confirmation
- `Set-ESXiHostCredentials` - Renamed from `Set-ESXiCredentials` for clarity

**Updated Functions:**
- `Connect-ToVCenter` - Now uses `Get-VCenterCredentials` instead of direct `Get-Credential`
- `Copy-FileToHost` - Now uses `Get-ESXiHostCredentials` instead of direct `Get-Credential`
- `Copy-FileToCluster` - Now uses `Get-ESXiHostCredentials` instead of direct `Get-Credential`
- `Invoke-SSHOnCluster` - Now uses `Get-ESXiHostCredentials` instead of direct `Get-Credential`
- `Show-Menu` - Displays status of both credential types

**Menu Changes:**
- Option 3: "Set/Reset vCenter Credentials" (new)
- Option 4: "Set/Reset ESXi Host Credentials" (renamed from Option 3)
- All subsequent menu items shifted down by 1

### Phase 2 Implementation Details

**New Menu Option:**
- Option 19: "Get IPMI BMC Addresses"

**New Function:**
- `Get-ClusterIPMI` - Queries all hosts in cluster for IPMI BMC addresses using ESXCLI, displays results in formatted table

**Implementation:**
- Uses `Get-EsxCli -v2` to access IPMI BMC information
- Handles both `IPv4Address` and `IP` properties from BMC info
- Displays "N/A" for hosts without IPMI addresses
- Shows error messages for hosts where IPMI query fails

### Phase 3 Implementation Details

**New Menu Options:**
- Option 20: "Set Custom Attribute on Host"
- Option 21: "Set Custom Attribute on Cluster (from IPMI)"

**New Functions:**
- `Set-HostCustomAttribute` - Sets custom attribute on a single ESXi host
  - Prompts for hostname, IP address, and attribute name (defaults to "ManagementIP")
  - Creates custom attribute if it doesn't exist
  - Sets annotation on the host

- `Set-ClusterCustomAttributeFromIPMI` - Batch operation to set custom attributes using IPMI addresses
  - Retrieves IPMI addresses for all hosts in cluster
  - Prompts for attribute name (defaults to "ManagementIP")
  - Requires user confirmation before proceeding
  - Creates custom attribute if it doesn't exist
  - Sets annotation on each host with its IPMI address
  - Provides status feedback for each host

**Implementation Notes:**
- Both functions create custom attributes automatically if they don't exist
- Uses `Set-Annotation` with `-Confirm:$false` for non-interactive operation
- Provides clear success/error feedback with color coding

### Phase 4 Implementation Details

**Connection Type Detection:**
- Added `$script:connectionType` variable to track connection type
- Implemented `Test-IsVCenter` function that checks for clusters to determine connection type
- Connection type is detected automatically after successful connection

**Updated Functions:**
- `Connect-ToVCenter` - Now detects connection type (vCenter or Standalone) after connection and stores it
- `Disconnect-FromVCenter` - Now resets connection type on disconnect
- `Show-Menu` - Displays connection type in status line (e.g., "Connected to host.example.com (Standalone Host)")
- `Get-ClusterName` - Now checks if connected to standalone host and returns error if cluster operation attempted
- `Get-ClusterIPMI` - Now handles both scenarios:
  - **Standalone Host**: Retrieves IPMI for the single connected host (no cluster prompt)
  - **vCenter**: Uses existing cluster-based logic (prompts for cluster name)

**Implementation Notes:**
- When connected to standalone host, Option 19 (Get IPMI BMC Addresses) works without requiring cluster name
- Cluster-based operations now show clear error messages when attempted on standalone hosts
- Connection type is displayed in menu for user awareness

### Phase 5 Implementation Details

**New UI Configuration Variables:**
- `$script:Icons` - ASCII-compatible status indicators: [OK], [FAIL], [WARN], [INFO], [....]
- `$script:Theme` - Centralized color theme for consistent styling across all output
- `$script:lastOperation` - Tracks last operation result for display in menu header

**New UI Helper Functions:**
- `Write-Status` - Standardized output with icon, message, and optional detail
- `Read-HostPrompt` - Standardized input with default value support, Text and YesNo types
- `Show-BatchProgress` - Progress bar display: `[========          ] 40% (4/10) - hostname`
- `Show-BatchSummary` - Operation summary with total/success/failed counts and failed item details
- `Show-ConfirmationBox` - Warning box for dangerous operations requiring "YES" confirmation
- `Show-FormattedTable` - Table output with box-drawing characters and auto-width calculation
- `Pause` - Enhanced with customizable context-aware messages

**Menu Improvements:**
- Box-drawing borders for cleaner visual hierarchy
- Category section headers with horizontal rules
- Proper number alignment (space-padded single digits)
- All options shown regardless of connection state
- Disabled options displayed in gray with "[Requires vCenter]" indicator
- "Last Operation" status line showing previous operation result

**Batch Operation Improvements:**
- Added SSH service verification (`Ensure-SSH`) before SCP and SSH operations, with interactive start prompt
- Batch summaries show: Total | Success | Failed counts
- Failed items listed with error details

**Standardized Prompts:**
- All Y/N prompts use consistent format: `"Message (Y/N) [default: N]"`
- All text prompts show defaults: `"Message [default: value]"`
- Input validation with clear error messages

### Repository Cleanup Details

**Removed Files:**
- `get-VMhostIpmi.ps1` - Standalone IPMI query script (now integrated as Option 19)
- `Set-EsxiCustomAttribute.ps1` - Standalone custom attribute script (now integrated as Options 20-21)

**Added Files:**
- `README.md` - Comprehensive documentation including:
  - Feature overview and menu options
  - Installation requirements
  - Usage instructions
  - Connection type comparison (vCenter vs Standalone)
  - Configuration guide

**Current Repository Structure:**
```
RDMA-config-helper_v2.ps1      # Main tool (all features integrated)
README.md                       # Project documentation
MODERNIZATION_CHANGELOG.md      # Implementation history
MODERNIZATION_PLAN.md           # Future roadmap
SECURITY_AUDIT_REPORT.md        # Security notes
.gitignore                      # Git ignore rules
```

### Phase 5.1 Implementation Details

**Menu UX Improvements:**
- Disabled options now show context-aware reasons instead of generic messages
- When not connected: options show `[Not connected]`
- When connected to standalone ESXi: cluster options show `[Requires vCenter]`
- All options remain visible (greyed out when unavailable) for discoverability

**New Helper Functions:**
- `Test-ConnectionRequired` - Validates that a connection exists before running operations
- Updated `Test-VCenterRequired` - Now checks both connection and vCenter requirement

**Edge Case Handling:**
- Option 1 (Connect) shows "Already connected" if already connected
- Option 2 (Disconnect) shows "Not connected" if not connected
- Invalid menu choices show helpful error messages

### Public Release Preparation Details

**Security Audit:**
- Verified no hardcoded credentials in code
- Verified no API keys or tokens
- Removed internal domain names from SECURITY_AUDIT_REPORT.md
- All config values use empty strings (user provides at runtime)

**Documentation Updates:**
- README.md updated for public contributions
- SECURITY_AUDIT_REPORT.md status changed to "APPROVED FOR PUBLIC RELEASE"

**Git Configuration:**
- Added `.claude/` to .gitignore to prevent IDE settings from being committed

---

## Testing Notes

### Phase 1 Testing
- ✅ Verified vCenter credentials are cached and reused
- ✅ Verified ESXi host credentials are cached and reused
- ✅ Verified menu displays both credential types correctly
- ✅ Verified credential reset functionality works

### Phase 2 Testing
- ✅ Verified IPMI query works on all hosts in cluster
- ✅ Verified error handling for hosts without IPMI
- ✅ Verified table formatting displays correctly

### Phase 3 Testing
- ✅ Verified single host custom attribute setting works
- ✅ Verified batch operation from IPMI addresses works
- ✅ Verified custom attribute creation when it doesn't exist
- ✅ Verified confirmation prompt prevents accidental execution

### Phase 4 Testing
- ✅ Verified connection type detection works correctly for vCenter connections
- ✅ Verified connection type detection works correctly for standalone host connections
- ✅ Verified Option 19 (Get IPMI BMC Addresses) works with standalone hosts
- ✅ Verified Option 19 still works with vCenter clusters
- ✅ Verified menu displays connection type correctly
- ✅ Verified cluster operations show appropriate errors on standalone hosts

### Phase 5 Testing
- ✅ Verified menu displays correctly with box-drawing borders
- ✅ Verified menu number alignment (1-9 space-padded, 10-21 not padded)
- ✅ Verified disabled options show in gray with "[Requires vCenter]" when not connected to vCenter
- ✅ Verified all status messages use Write-Status with consistent formatting
- ✅ Verified Y/N prompts follow consistent format with defaults
- ✅ Verified progress bars display during batch operations
- ✅ Verified batch summaries show correct counts
- ✅ Verified dangerous operation confirmation box works for Reboot Hosts
- ✅ Verified IPMI results display in formatted table
- ✅ Verified "Last Operation" display updates after batch operations

---

## Known Issues

### Resolved Issues
- ✅ **Issue**: Option 19 (Get IPMI BMC Addresses) failed with "no cluster specified" when connected to standalone host
  - **Resolution**: Added connection type detection and updated `Get-ClusterIPMI` to handle standalone hosts
  - **Date**: January 25, 2026

### Current Issues

None at this time.

---

## Future Enhancements

See [MODERNIZATION_PLAN.md](MODERNIZATION_PLAN.md) for Phase 5 details and future improvements.

**Potential Enhancements:**
- Extend standalone host support to other cluster-based functions (e.g., SSH management, RDMA configuration)
- Add option to switch between vCenter and standalone host connections without disconnecting
- Improve error messages to suggest alternative options based on connection type
