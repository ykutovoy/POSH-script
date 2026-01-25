# Modernization Changelog

**Last Updated**: January 25, 2026

This document tracks the implementation status and changes made during the script modernization process.

---

## Implementation Status

### ✅ Completed (Phase 1-3)

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

### 🔄 Pending (Phase 4)
- Error handling improvements
- Output formatting standardization
- Configuration persistence
- Module structure conversion
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

---

## Known Issues

None at this time.

---

## Future Enhancements

See [MODERNIZATION_PLAN.md](MODERNIZATION_PLAN.md) for Phase 4 details and future improvements.
