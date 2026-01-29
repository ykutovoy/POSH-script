# Script Modernization Plan

## Executive Summary

This document outlines a plan to modernize the PowerShell scripts in this repository, with a focus on:
1. **Fixing excessive authentication prompts** - Implement separate credential management for vCenter and ESXi host credentials
2. **Integrating Get-VMhostIpmi and Set-EsxiCustomAttribute functionality** into the helper script
3. **General code quality improvements** and modernization

**Important Note**: vCenter credentials (for `Connect-VIServer`) are different from ESXi host credentials (for SSH/SCP operations). The modernization plan addresses both separately.

---

## Current State Analysis

### Scripts Overview

1. **RDMA-config-helper_v2.ps1** (Main Helper Script)
   - Interactive menu-driven ESXi cluster management tool
   - Functions: SSH management, ESXCLI operations, file transfer, VIB installation, RDMA configuration

2. **get-VMhostIpmi.ps1**
   - Retrieves BMC (IPMI) IPv4 addresses for ESXi hosts
   - Well-structured with proper parameter handling and pipeline support

3. **Set-EsxiCustomAttribute.ps1**
   - Sets custom attributes on ESXi hosts with IP addresses
   - Supports pipeline input and proper error handling

### Authentication Issues

**IMPORTANT**: There are **two distinct credential types**:
1. **vCenter Credentials** - Used for `Connect-VIServer` to connect to vCenter/cluster
2. **ESXi Host Credentials** - Used for SSH, SCP, and direct host operations (typically 'root')

**Problem**: The helper script prompts for credentials in multiple places without proper caching or separation between credential types.

**Root Cause**: 
- vCenter credentials are not cached at all
- ESXi host credential functions don't consistently check cache before prompting
- No separation between the two credential types in the code

---

## Modernization Plan

### Phase 1: Fix Authentication Issues (Priority: HIGH) ✅

#### 1.1 Separate Credential Storage
- Add separate variables for vCenter and ESXi host credentials

#### 1.2 Centralize Credential Management Functions
- Create `Get-VCenterCredentials` and `Get-ESXiHostCredentials` functions
- Both should check cache before prompting

#### 1.3 Update vCenter Connection Function
- Update `Connect-ToVCenter` to use cached vCenter credentials

#### 1.4 Update ESXi Host Functions
- Update `Copy-FileToHost`, `Copy-FileToCluster`, `Invoke-SSHOnCluster` to use cached credentials

#### 1.5 Update Menu Display
- Show status of both credential types in menu

#### 1.6 Update Menu Options
- Add separate menu options for vCenter and ESXi host credentials

#### 1.7 Create Credential Set Functions
- Create `Set-VCenterCredentials` and `Set-ESXiHostCredentials` functions

#### 1.8 Add Credential Validation (Optional)
- Add functions to test credentials before caching

---

### Phase 2: Integrate Get-VMhostIpmi Functionality (Priority: MEDIUM) ✅

#### 2.1 Add Menu Option
- Add menu item "Get IPMI BMC Addresses"

#### 2.2 Create Helper Function
- Create `Get-ClusterIPMI` function
- Query all hosts in cluster for IPMI BMC addresses
- Display results in formatted table

---

### Phase 3: Integrate Set-EsxiCustomAttribute Functionality (Priority: MEDIUM) ✅

#### 3.1 Add Menu Options
- Add "Set Custom Attribute on Host"
- Add "Set Custom Attribute on Cluster (from IPMI)"

#### 3.2 Create Helper Functions
- `Set-HostCustomAttribute` - Set custom attribute on a single host
- `Set-ClusterCustomAttributeFromIPMI` - Batch operation using IPMI addresses

---

### Phase 4: Standalone Host Support (Priority: MEDIUM) ✅

#### 4.1 Connection Type Detection
- Add connection type detection to distinguish between vCenter and standalone ESXi host connections
- Store connection type in `$script:connectionType` variable

#### 4.2 Update Connection Function
- Update `Connect-ToVCenter` to detect and store connection type after connection
- Display connection type in menu status

#### 4.3 Update Cluster-Based Functions
- Update `Get-ClusterIPMI` to work with both vCenter clusters and standalone hosts
- Update `Get-ClusterName` to prevent cluster operations on standalone hosts
- Add appropriate error messages for standalone host scenarios

#### 4.4 Menu Display Updates
- Show connection type (vCenter/Standalone Host) in menu status display

---

### Phase 5: UI Polishing (Priority: MEDIUM) ✅

#### 5.1 Standardized Status Indicators
- ASCII-compatible status icons: [OK], [FAIL], [WARN], [INFO], [....]
- Centralized color theme configuration

#### 5.2 UI Helper Functions
- `Write-Status` - Standardized output messages
- `Read-HostPrompt` - Standardized input with defaults
- `Show-BatchProgress` - Progress bars for batch operations
- `Show-BatchSummary` - Operation summaries with success/failure counts
- `Show-ConfirmationBox` - Warning boxes for dangerous operations
- `Show-FormattedTable` - Formatted table output

#### 5.3 Menu Improvements
- Box-drawing borders and category section headers
- Proper number alignment
- Disabled options shown in gray with reason
- "Last Operation" display in header

#### 5.4 Batch Operation Improvements
- Progress bars for all cluster operations
- Batch summaries with failed item details

---

### Phase 6: Future Enhancements (Priority: LOW)

#### 6.1 Configuration Management
- **Persistent Configuration**: Save vCenter/cluster to config file, secure credential caching
- **Logging**: Optional file logging, timestamps, `-Verbose` support

#### 6.2 PowerShell Best Practices
- **Module Structure**: Consider converting to PowerShell module (.psm1), proper exports, help documentation
- **Parameter Sets**: Use parameter sets for different modes, add `-WhatIf` and `-Confirm` support
- **Pipeline Support**: Add pipeline support where applicable

#### 6.3 Advanced Features
- **Export/Import**: Export to CSV/JSON, import configuration, execution history
- **Non-Interactive Mode**: Command-line parameters for automation

---

## Implementation Priority

### ✅ Completed (Phase 1-5)
- Phase 1: Authentication Fixes
- Phase 2: Get-VMhostIpmi Integration
- Phase 3: Set-EsxiCustomAttribute Integration
- Phase 4: Standalone Host Support
- Phase 5: UI Polishing

### Repository Cleanup ✅
- Removed standalone scripts (get-VMhostIpmi.ps1, Set-EsxiCustomAttribute.ps1)
- All functionality now integrated into main tool
- Added comprehensive README.md

### Future (Phase 6)
- Configuration persistence
- Module structure conversion
- Pipeline support
- Logging implementation
- Non-interactive mode for automation

---

## Success Criteria

1. ✅ **Authentication**:
   - No more than 1 vCenter credential prompt per session (unless explicitly reset)
   - No more than 1 ESXi host credential prompt per session (unless explicitly reset)
   - Clear separation between vCenter and ESXi host credentials
   - Menu clearly displays status of both credential types

2. ✅ **Integration**: Get-VMhostIpmi and Set-EsxiCustomAttribute fully integrated into menu

3. ✅ **Usability**: All new features accessible via menu with clear prompts

4. ✅ **User Experience**:
   - Consistent status messages and color coding
   - Progress bars for batch operations
   - Batch summaries with success/failure counts
   - Confirmation prompts for dangerous operations

5. **Reliability**: All operations have proper error handling (partial - basic try/catch implemented)

6. **Maintainability**: Code follows PowerShell best practices (partial - UI helpers standardized)

---

## Notes

- All changes should maintain the interactive menu-driven approach
- Consider adding a "non-interactive" mode for automation in future
- Keep the script self-contained (no external dependencies beyond modules)
- Test thoroughly with actual vCenter/ESXi environments before deployment

For implementation status and change tracking, see [MODERNIZATION_CHANGELOG.md](MODERNIZATION_CHANGELOG.md).
