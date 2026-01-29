# ESXi Cluster Management Tool

A PowerShell-based interactive menu-driven tool for managing VMware ESXi hosts and clusters.

## Features

- **Connection Management**: Connect to vCenter Server or standalone ESXi hosts
- **SSH Management**: Start/stop SSH service on cluster hosts
- **ESXi CLI Operations**: Run ESXCLI commands on single hosts or entire clusters
- **File Transfer**: SCP files to single hosts or all hosts in a cluster
- **Driver/VIB Management**: Install VIBs and Mellanox drivers
- **RDMA/Network Configuration**: Configure RDMA parameters and check DCBX status
- **IPMI Management**: Retrieve BMC/IPMI addresses from hosts
- **Custom Attributes**: Set custom attributes on hosts (e.g., management IPs from IPMI)

## Requirements

- PowerShell 5.1+ or PowerShell Core 7+
- VMware PowerCLI module (`VMware.VimAutomation.Core`)
- Posh-SSH module

### Install Required Modules

```powershell
Install-Module -Name VMware.PowerCLI -Scope CurrentUser
Install-Module -Name Posh-SSH -Scope CurrentUser
```

## Usage

```powershell
.\RDMA-config-helper_v2.ps1
```

The script presents an interactive menu:

```
+===============================================================+
|           ESXi Cluster Management Tool v2.0                   |
+===============================================================+
|  Status: Connected to vCenter: vcenter.example.com            |
|  Cluster: Production-Cluster-01                               |
|  vCenter Creds: Cached (administrator@vsphere.local)          |
|  ESXi Host Creds: Cached (root)                               |
+---------------------------------------------------------------+

-- Connection -----------------------------------------------------
   1. Connect to vCenter/ESXi
   2. Disconnect
   3. Set/Reset vCenter Credentials
   4. Set/Reset ESXi Host Credentials

-- SSH Management -------------------------------------------------
   5. Start SSH on cluster hosts
   6. Stop SSH on cluster hosts

-- ESXi CLI Operations --------------------------------------------
   7. Run ESXCli command on all hosts
   8. Run ESXCli command on single host
   9. Reboot all hosts in cluster

-- File Transfer --------------------------------------------------
  10. SCP file to single host
  11. SCP file to all hosts in cluster

-- Driver/VIB Management ------------------------------------------
  12. Install VIB on single host
  13. Install Mellanox driver on cluster

-- SSH Commands ---------------------------------------------------
  14. Execute SSH command on cluster hosts
  15. View active SSH sessions
  16. Disconnect SSH session

-- RDMA/Network ---------------------------------------------------
  17. Configure RDMA parameters
  18. Check DCBX status

-- IPMI/Custom Attributes -----------------------------------------
  19. Get IPMI BMC Addresses
  20. Set Custom Attribute on Host
  21. Set Custom Attribute on Cluster (from IPMI)

   0. Exit
+===============================================================+
```

## Features Overview

### Connection Types

The tool supports two connection types:
- **vCenter Server**: Full cluster management capabilities
- **Standalone ESXi Host**: Single host operations (cluster-wide options are disabled)

Options that are unavailable are shown in gray with context-aware reasons:
- `[Not connected]` - when no connection exists
- `[Requires vCenter]` - when connected to standalone ESXi but the option needs vCenter

### Credential Management

- Separate credential caching for vCenter and ESXi host operations
- Option to reuse vCenter credentials for ESXi host access
- Credentials persist for the session (no repeated prompts)

### Batch Operations

Cluster-wide operations include:
- Progress bars showing operation status
- Batch summaries with success/failure counts
- Failed host details for troubleshooting

### Safety Features

- Confirmation prompts for dangerous operations (e.g., cluster reboot)
- Disabled options shown in gray when not applicable
- Clear error messages for unsupported operations

## Menu Options

| # | Option | vCenter | Standalone |
|---|--------|---------|------------|
| 1-4 | Connection & Credentials | Yes | Yes |
| 5-6 | SSH Management (cluster) | Yes | No |
| 7 | ESXCli on all hosts | Yes | No |
| 8 | ESXCli on single host | Yes | Yes |
| 9 | Reboot cluster hosts | Yes | No |
| 10 | SCP to single host | Yes | Yes |
| 11 | SCP to cluster | Yes | No |
| 12 | Install VIB (single) | Yes | Yes |
| 13 | Install Mellanox (cluster) | Yes | No |
| 14 | SSH command (cluster) | Yes | No |
| 15-16 | SSH session management | Yes | Yes |
| 17-18 | RDMA/DCBX (cluster) | Yes | No |
| 19 | Get IPMI addresses | Yes | Yes |
| 20-21 | Custom attributes | Yes | No |

## Configuration

Edit the script header to set defaults:

```powershell
$script:vCenterServer = "vcenter.example.com"
$script:defaultCluster = "Production-Cluster-01"
```

## Documentation

- [MODERNIZATION_CHANGELOG.md](MODERNIZATION_CHANGELOG.md) - Implementation history and change details
- [MODERNIZATION_PLAN.md](MODERNIZATION_PLAN.md) - Future enhancement roadmap
- [SECURITY_AUDIT_REPORT.md](SECURITY_AUDIT_REPORT.md) - Security considerations

## License

This project is provided as-is for VMware infrastructure management.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.
