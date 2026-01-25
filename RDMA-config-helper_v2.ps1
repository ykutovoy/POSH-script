#Requires -Modules VMware.VimAutomation.Core, Posh-SSH

# Configuration
# NOTE: Update these defaults for your environment, or they will be prompted at runtime
$script:vCenterServer = ""  # e.g., "vcenter.example.com"
$script:defaultCluster = ""  # e.g., "Production-Cluster-01"
$script:vCenterCreds = $null      # vCenter/cluster credentials
$script:hostCreds = $null         # ESXi host/SSH credentials
$script:connected = $false

function Show-Menu {
    Clear-Host
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "          ESXi Cluster Management Tool" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Connection Status: " -NoNewline
    if ($script:connected) {
        Write-Host "Connected to $script:vCenterServer" -ForegroundColor Green
    } else {
        Write-Host "Not Connected" -ForegroundColor Red
    }
    Write-Host "Selected Cluster:  " -NoNewline
    Write-Host "$script:defaultCluster" -ForegroundColor Cyan
    Write-Host "vCenter Credentials: " -NoNewline
    if ($null -ne $script:vCenterCreds) {
        Write-Host "Cached (user: $($script:vCenterCreds.UserName))" -ForegroundColor Green
    } else {
        Write-Host "Not Set" -ForegroundColor Yellow
    }
    Write-Host "ESXi Host Credentials: " -NoNewline
    if ($null -ne $script:hostCreds) {
        Write-Host "Cached (user: $($script:hostCreds.UserName))" -ForegroundColor Green
    } else {
        Write-Host "Not Set" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  1. Connect to vCenter" -ForegroundColor White
    Write-Host "  2. Disconnect from vCenter" -ForegroundColor White
    Write-Host "  3. Set/Reset vCenter Credentials" -ForegroundColor White
    Write-Host "  4. Set/Reset ESXi Host Credentials" -ForegroundColor White
    Write-Host ""
    Write-Host "SSH Management:" -ForegroundColor Yellow
    Write-Host "  5. Start SSH on cluster hosts" -ForegroundColor White
    Write-Host "  6. Stop SSH on cluster hosts" -ForegroundColor White
    Write-Host ""
    Write-Host "ESXi CLI Operations:" -ForegroundColor Yellow
    Write-Host "  7. Run ESXCli command on all hosts" -ForegroundColor White
    Write-Host "  8. Run ESXCli command on single host" -ForegroundColor White
    Write-Host "  9. Reboot all hosts in cluster" -ForegroundColor White
    Write-Host ""
    Write-Host "File Transfer:" -ForegroundColor Yellow
    Write-Host " 10. SCP file to single host" -ForegroundColor White
    Write-Host " 11. SCP file to all hosts in cluster" -ForegroundColor White
    Write-Host ""
    Write-Host "Driver/VIB Management:" -ForegroundColor Yellow
    Write-Host " 12. Install VIB on single host" -ForegroundColor White
    Write-Host " 13. Install Mellanox driver on cluster" -ForegroundColor White
    Write-Host ""
    Write-Host "SSH Commands:" -ForegroundColor Yellow
    Write-Host " 14. Execute SSH command on cluster hosts" -ForegroundColor White
    Write-Host " 15. View active SSH sessions" -ForegroundColor White
    Write-Host " 16. Disconnect SSH session" -ForegroundColor White
    Write-Host ""
    Write-Host "RDMA/Network:" -ForegroundColor Yellow
    Write-Host " 17. Configure RDMA parameters" -ForegroundColor White
    Write-Host " 18. Check DCBX status" -ForegroundColor White
    Write-Host ""
    Write-Host "IPMI/Custom Attributes:" -ForegroundColor Yellow
    Write-Host " 19. Get IPMI BMC Addresses" -ForegroundColor White
    Write-Host " 20. Set Custom Attribute on Host" -ForegroundColor White
    Write-Host " 21. Set Custom Attribute on Cluster (from IPMI)" -ForegroundColor White
    Write-Host ""
    Write-Host "  0. Exit" -ForegroundColor Red
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Get-VCenterName {
    $defaultPrompt = if ([string]::IsNullOrWhiteSpace($script:vCenterServer)) { 
        "Enter vCenter name" 
    } else { 
        "Enter vCenter name [default: $script:vCenterServer]" 
    }
    $vCenter = Read-Host $defaultPrompt
    if ([string]::IsNullOrWhiteSpace($vCenter)) {
        if ([string]::IsNullOrWhiteSpace($script:vCenterServer)) {
            Write-Error "vCenter name is required and no default is set."
            return $null
        }
        return $script:vCenterServer
    }
    $script:vCenterServer = $vCenter  # Update default for next time
    return $vCenter
}

function Get-VCenterCredentials {
    param([switch]$Force)
    
    if (-not $Force -and $null -ne $script:vCenterCreds) {
        return $script:vCenterCreds
    }
    
    $script:vCenterCreds = Get-Credential -Message "Enter vCenter credentials"
    return $script:vCenterCreds
}

function Get-ESXiHostCredentials {
    param([switch]$Force)
    
    if (-not $Force -and $null -ne $script:hostCreds) {
        return $script:hostCreds
    }
    
    $script:hostCreds = Get-Credential -Message "Enter ESXi host credentials (typically 'root')"
    return $script:hostCreds
}

function Set-VCenterCredentials {
    Write-Host "Setting vCenter credentials..." -ForegroundColor Yellow
    if ($null -ne $script:vCenterCreds) {
        Write-Host "Current credentials: $($script:vCenterCreds.UserName)" -ForegroundColor Cyan
        $reset = Read-Host "Reset credentials? (Y/N)"
        if ($reset -ne "Y" -and $reset -ne "y") {
            Write-Host "Keeping existing credentials." -ForegroundColor Green
            Pause
            return
        }
    }
    
    try {
        $script:vCenterCreds = Get-Credential -Message "Enter vCenter credentials"
        if ($null -ne $script:vCenterCreds) {
            Write-Host "✓ Credentials set for user: $($script:vCenterCreds.UserName)" -ForegroundColor Green
        } else {
            Write-Host "✗ Credential entry cancelled." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "✗ Failed to set credentials: $_" -ForegroundColor Red
    }
    Pause
}

function Set-ESXiHostCredentials {
    Write-Host "Setting ESXi host credentials..." -ForegroundColor Yellow
    if ($null -ne $script:hostCreds) {
        Write-Host "Current credentials: $($script:hostCreds.UserName)" -ForegroundColor Cyan
        $reset = Read-Host "Reset credentials? (Y/N)"
        if ($reset -ne "Y" -and $reset -ne "y") {
            Write-Host "Keeping existing credentials." -ForegroundColor Green
            Pause
            return
        }
    }
    
    try {
        $script:hostCreds = Get-Credential -Message "Enter ESXi host credentials (typically 'root')"
        if ($null -ne $script:hostCreds) {
            Write-Host "✓ Credentials set for user: $($script:hostCreds.UserName)" -ForegroundColor Green
        } else {
            Write-Host "✗ Credential entry cancelled." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "✗ Failed to set credentials: $_" -ForegroundColor Red
    }
    Pause
}

function Get-ClusterName {
    $defaultPrompt = if ([string]::IsNullOrWhiteSpace($script:defaultCluster)) { 
        "Enter cluster name" 
    } else { 
        "Enter cluster name [default: $script:defaultCluster]" 
    }
    $cluster = Read-Host $defaultPrompt
    if ([string]::IsNullOrWhiteSpace($cluster)) {
        if ([string]::IsNullOrWhiteSpace($script:defaultCluster)) {
            Write-Error "Cluster name is required and no default is set."
            return $null
        }
        return $script:defaultCluster
    }
    $script:defaultCluster = $cluster  # Update the script variable
    return $cluster
}

function Connect-ToVCenter {
    $vCenter = Get-VCenterName
    
    # Get vCenter credentials (use cache if available)
    $vCenterCreds = Get-VCenterCredentials
    if ($null -eq $vCenterCreds) {
        Write-Host "Connection cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    try {
        Write-Host "Connecting to $vCenter..." -ForegroundColor Yellow
        Connect-VIServer $vCenter -Credential $vCenterCreds -Force -ErrorAction Stop
        $script:vCenterServer = $vCenter
        $script:connected = $true
        Write-Host "Successfully connected!" -ForegroundColor Green
    } catch { 
        Write-Host "Failed to connect: $_" -ForegroundColor Red
        $script:connected = $false
    }
    Pause
}

function Disconnect-FromVCenter {
    try {
        Disconnect-VIServer $script:vCenterServer -Confirm:$false -ErrorAction Stop
        $script:connected = $false
        Write-Host "Disconnected successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to disconnect: $_" -ForegroundColor Red
    }
    Pause
}

function Start-ClusterSSH {
    $cluster = Get-ClusterName
    Write-Host "Starting SSH on hosts in cluster: $cluster" -ForegroundColor Yellow
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "Processing: $hostName" -ForegroundColor Cyan
        try {
            Get-VMHost -Name $hostName | Get-VMHostService | 
                Where-Object Key -EQ "TSM-SSH" | Start-VMHostService -Confirm:$false
            Write-Host "  ✓ SSH started" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Stop-ClusterSSH {
    $cluster = Get-ClusterName
    Write-Host "Stopping SSH on hosts in cluster: $cluster" -ForegroundColor Yellow
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "Processing: $hostName" -ForegroundColor Cyan
        try {
            Get-VMHost -Name $hostName | Get-VMHostService | 
                Where-Object Key -EQ "TSM-SSH" | Stop-VMHostService -Confirm:$false
            Write-Host "  ✓ SSH stopped" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Invoke-ESXCliOnCluster {
    $cluster = Get-ClusterName
    $uuid = Read-Host "Enter UUID for vsan.debug.object.list"
    
    Write-Host "Running ESXCli command on cluster: $cluster" -ForegroundColor Yellow
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "`n$hostName" -ForegroundColor Cyan
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.vsan.debug.object.list.invoke(@{uuid=$uuid})
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Invoke-ESXCliOnHost {
    $hostName = Read-Host "Enter ESXi hostname"
    
    Write-Host "Getting ESXCli createargs for: $hostName" -ForegroundColor Yellow
    try {
        (Get-EsxCli -v2 -VMHost $hostName).vsan.debug.object.list.createargs()
    } catch {
        Write-Host "Failed: $_" -ForegroundColor Red
    }
    Pause
}

function Restart-ClusterHosts {
    $cluster = Get-ClusterName
    $confirm = Read-Host "WARNING: This will reboot ALL hosts in $cluster. Type YES to continue"
    
    if ($confirm -ne "YES") {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    $reason = Read-Host "Enter reboot reason"
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "Rebooting: $hostName" -ForegroundColor Cyan
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.system.shutdown.reboot.invoke(@{reason=$reason})
            Write-Host "  ✓ Reboot initiated" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Copy-FileToHost {
    $hostName = Read-Host "Enter ESXi hostname"
    $sourcePath = Read-Host "Enter source file path"
    $destination = Read-Host "Enter destination path [default: /tmp]"
    
    if ([string]::IsNullOrWhiteSpace($destination)) {
        $destination = "/tmp"
    }
    
    $hostCreds = Get-ESXiHostCredentials
    if ($null -eq $hostCreds) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    try {
        Write-Host "Copying file to $hostName..." -ForegroundColor Yellow
        Set-SCPItem -ComputerName $hostName -Credential $hostCreds `
            -Path $sourcePath -Destination $destination -Verbose
        Write-Host "✓ File copied successfully" -ForegroundColor Green
    } catch {
        Write-Host "✗ Failed: $_" -ForegroundColor Red
    }
    Pause
}

function Copy-FileToCluster {
    $cluster = Get-ClusterName
    $sourcePath = Read-Host "Enter source file path"
    $destination = Read-Host "Enter destination path [default: /tmp]"
    
    if ([string]::IsNullOrWhiteSpace($destination)) {
        $destination = "/tmp"
    }
    
    $hostCreds = Get-ESXiHostCredentials
    if ($null -eq $hostCreds) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "Copying to: $hostName" -ForegroundColor Cyan
        try {
            Set-SCPItem -ComputerName $hostName -Credential $hostCreds `
                -Path $sourcePath -Destination $destination -Verbose
            Write-Host "  ✓ Success" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Install-VIBOnHost {
    $hostName = Read-Host "Enter ESXi hostname"
    $vibUrl = Read-Host "Enter VIB URL (local path on ESXi host)"
    
    try {
        Write-Host "Installing VIB on $hostName..." -ForegroundColor Yellow
        $esxcli = Get-EsxCli -v2 -VMHost $hostName
        $esxcli.software.vib.install.invoke(@{viburl=$vibUrl; nosigcheck="true"})
        Write-Host "✓ VIB installed successfully" -ForegroundColor Green
    } catch {
        Write-Host "✗ Failed: $_" -ForegroundColor Red
    }
    Pause
}

function Install-MellanoxDriver {
    $cluster = Get-ClusterName
    $scriptPath = Read-Host "Enter path to SSH-mellanox-install.ps1"
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "Installing on: $hostName" -ForegroundColor Cyan
        try {
            & $scriptPath -sshHost $hostName
            Write-Host "  ✓ Success" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Invoke-SSHOnCluster {
    $cluster = Get-ClusterName
    
    # Command templates from original script
    Write-Host "`nSelect a command template or enter custom:" -ForegroundColor Yellow
    Write-Host "  1. rm -f /tmp/*.vib" -ForegroundColor White
    Write-Host "  2. rm -f /tmp/*.bin" -ForegroundColor White
    Write-Host "  3. ls -lah /tmp" -ForegroundColor White
    Write-Host "  4. esxcli mellanox mft flint query -d mt4117_pciconf0 -r" -ForegroundColor White
    Write-Host "  5. vsish -e get /vmkModules/rdt/allConnCount" -ForegroundColor White
    Write-Host "  6. vsish -e get /vmkModules/rdt/clusterProtocol" -ForegroundColor White
    Write-Host "  7. esxcli mellanox mft mst status" -ForegroundColor White
    Write-Host "  8. Custom command (type your own)" -ForegroundColor White
    Write-Host ""
    
    $templateChoice = Read-Host "Select template (1-8)"
    
    $command = switch ($templateChoice) {
        "1" { "rm -f /tmp/*.vib" }
        "2" { "rm -f /tmp/*.bin" }
        "3" { "ls -lah /tmp" }
        "4" { "esxcli mellanox mft flint query -d mt4117_pciconf0 -r" }
        "5" { "vsish -e get /vmkModules/rdt/allConnCount" }
        "6" { "vsish -e get /vmkModules/rdt/clusterProtocol" }
        "7" { "esxcli mellanox mft mst status" }
        "8" { Read-Host "Enter custom command" }
        default { 
            Write-Host "Invalid selection, using custom input" -ForegroundColor Red
            Read-Host "Enter command"
        }
    }
    
    # Allow editing the selected command
    Write-Host "`nSelected command: $command" -ForegroundColor Cyan
    $edit = Read-Host "Edit command? (Y/N) [default: N]"
    
    if ($edit -eq "Y" -or $edit -eq "y") {
        Write-Host "Current: $command" -ForegroundColor Gray
        $command = Read-Host "Enter modified command"
    }
    
    Write-Host "`nExecuting: $command" -ForegroundColor Green
    $confirm = Read-Host "Continue? (Y/N)"
    
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    $hostCreds = Get-ESXiHostCredentials
    if ($null -eq $hostCreds) {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "`n$hostName" -ForegroundColor Cyan
        try {
            $session = New-SSHSession -ComputerName $hostName -Credential $hostCreds
            $result = Invoke-SSHCommand -Command $command -SessionId $session.SessionId
            Write-Host $result.Output
            Remove-SSHSession -SessionId $session.SessionId
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Show-SSHSessions {
    Write-Host "Active SSH Sessions:" -ForegroundColor Yellow
    Get-SSHSession | Format-Table -AutoSize
    Pause
}

function Remove-SSHSessionById {
    Show-SSHSessions
    $sessionId = Read-Host "Enter Session ID to disconnect"
    try {
        Remove-SSHSession -SessionId $sessionId
        Write-Host "✓ Session disconnected" -ForegroundColor Green
    } catch {
        Write-Host "✗ Failed: $_" -ForegroundColor Red
    }
    Pause
}

function Set-RDMAParameters {
    $cluster = Get-ClusterName
    
    Write-Host "Configuring RDMA parameters on cluster: $cluster" -ForegroundColor Yellow
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "Configuring: $hostName" -ForegroundColor Cyan
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.system.module.parameters.set.invoke(@{module="nmlx5_core"; parameterstring="dcbx=1"})
            $esxcli.system.module.parameters.set.invoke(@{module="nmlx5_core"; parameterstring="pfctx=8 pfcrx=8 trust_state=2 max_vfs=4"})
            $esxcli.system.module.parameters.set.invoke(@{module="nmlx5_rdma"; parameterstring="pcp_force=3 dscp_force=26"})
            Write-Host "  ✓ Parameters set" -ForegroundColor Green
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Get-DCBXStatus {
    $cluster = Get-ClusterName
    $nicName = Read-Host "Enter NIC name (e.g., vmnic4)"
    
    Write-Host "Checking DCBX status on cluster: $cluster" -ForegroundColor Yellow
    
    Get-VMHost -Location $cluster | ForEach-Object {
        $hostName = $_.Name
        Write-Host "`n$hostName" -ForegroundColor Cyan
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.network.nic.dcb.status.get.invoke(@{nicname=$nicName})
        } catch {
            Write-Host "  ✗ Failed: $_" -ForegroundColor Red
        }
    }
    Pause
}

function Get-ClusterIPMI {
    $cluster = Get-ClusterName
    Write-Host "Retrieving IPMI BMC addresses for cluster: $cluster" -ForegroundColor Yellow
    
    $results = Get-VMHost -Location $cluster | ForEach-Object {
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $_.Name
            $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
            $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address } 
                   elseif ($bmcInfo.IP) { $bmcInfo.IP } 
                   else { "N/A" }
            
            [pscustomobject]@{
                HostName    = $_.Name
                IPv4Address = $ipv4
            }
        } catch {
            [pscustomobject]@{
                HostName    = $_.Name
                IPv4Address = "Error: $_"
            }
        }
    }
    
    $results | Format-Table -AutoSize
    Pause
}

function Set-HostCustomAttribute {
    $hostName = Read-Host "Enter ESXi hostname"
    $ipAddress = Read-Host "Enter IP address"
    $attrName = Read-Host "Enter custom attribute name [default: ManagementIP]"
    
    if ([string]::IsNullOrWhiteSpace($attrName)) {
        $attrName = "ManagementIP"
    }
    
    try {
        $esxi = Get-VMHost -Name $hostName -ErrorAction Stop
        
        # Create attribute if needed
        $attr = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
        if (-not $attr) {
            New-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction Stop | Out-Null
        }
        
        Set-Annotation -Entity $esxi -CustomAttribute $attrName -Value $ipAddress -Confirm:$false
        Write-Host "✓ Attribute set successfully" -ForegroundColor Green
    } catch {
        Write-Host "✗ Failed: $_" -ForegroundColor Red
    }
    Pause
}

function Set-ClusterCustomAttributeFromIPMI {
    $cluster = Get-ClusterName
    $attrName = Read-Host "Enter custom attribute name [default: ManagementIP]"
    
    if ([string]::IsNullOrWhiteSpace($attrName)) {
        $attrName = "ManagementIP"
    }
    
    Write-Host "This will:" -ForegroundColor Yellow
    Write-Host "  1. Get IPMI BMC addresses for all hosts in $cluster" -ForegroundColor Cyan
    Write-Host "  2. Set '$attrName' custom attribute with IPMI IP for each host" -ForegroundColor Cyan
    $confirm = Read-Host "Continue? (Y/N)"
    
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        Pause
        return
    }
    
    # Get IPMI addresses
    $ipmiData = Get-VMHost -Location $cluster | ForEach-Object {
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $_.Name
            $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
            $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address } 
                   elseif ($bmcInfo.IP) { $bmcInfo.IP } 
                   else { $null }
            
            [pscustomobject]@{
                Host = $_.Name
                IPMI = $ipv4
            }
        } catch {
            [pscustomobject]@{
                Host = $_.Name
                IPMI = $null
            }
        }
    }
    
    # Create attribute if needed
    $attr = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
    if (-not $attr) {
        New-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction Stop | Out-Null
    }
    
    # Set attributes
    foreach ($item in $ipmiData) {
        if ($item.IPMI) {
            try {
                $esxi = Get-VMHost -Name $item.Host -ErrorAction Stop
                Set-Annotation -Entity $esxi -CustomAttribute $attrName -Value $item.IPMI -Confirm:$false
                Write-Host "✓ $($item.Host): $($item.IPMI)" -ForegroundColor Green
            } catch {
                Write-Host "✗ $($item.Host): Failed - $_" -ForegroundColor Red
            }
        } else {
            Write-Host "⚠ $($item.Host): No IPMI address found" -ForegroundColor Yellow
        }
    }
    Pause
}

function Pause {
    Write-Host "`nPress any key to continue..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Main loop
do {
    Show-Menu
    $choice = Read-Host "`nEnter your choice"
    
    switch ($choice) {
        "1" { Connect-ToVCenter }
        "2" { Disconnect-FromVCenter }
        "3" { Set-VCenterCredentials }
        "4" { Set-ESXiHostCredentials }
        "5" { Start-ClusterSSH }
        "6" { Stop-ClusterSSH }
        "7" { Invoke-ESXCliOnCluster }
        "8" { Invoke-ESXCliOnHost }
        "9" { Restart-ClusterHosts }
        "10" { Copy-FileToHost }
        "11" { Copy-FileToCluster }
        "12" { Install-VIBOnHost }
        "13" { Install-MellanoxDriver }
        "14" { Invoke-SSHOnCluster }
        "15" { Show-SSHSessions }
        "16" { Remove-SSHSessionById }
        "17" { Set-RDMAParameters }
        "18" { Get-DCBXStatus }
        "19" { Get-ClusterIPMI }
        "20" { Set-HostCustomAttribute }
        "21" { Set-ClusterCustomAttributeFromIPMI }
        "0" { 
            if ($script:connected) {
                Disconnect-FromVCenter
            }
            Write-Host "Exiting..." -ForegroundColor Yellow
        }
        default { 
            Write-Host "Invalid choice. Please try again." -ForegroundColor Red
            Pause
        }
    }
} while ($choice -ne "0")