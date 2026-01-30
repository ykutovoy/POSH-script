#Requires -Modules VMware.VimAutomation.Core, Posh-SSH

# Configuration
# NOTE: Update these defaults for your environment, or they will be prompted at runtime
$script:vCenterServer = ""  # e.g., "vcenter.example.com"
$script:defaultCluster = ""  # e.g., "Production-Cluster-01"
$script:vCenterCreds = $null      # vCenter/cluster credentials
$script:hostCreds = $null         # ESXi host/SSH credentials
$script:connected = $false
$script:connectionType = $null    # "vCenter" or "Standalone"
$script:lastOperation = $null     # Track last operation result

#region UI Configuration
# Status indicators (ASCII-compatible)
$script:Icons = @{
    Success    = "[OK]"
    Error      = "[FAIL]"
    Warning    = "[WARN]"
    Info       = "[INFO]"
    Processing = "[....]"
}

# Color theme for consistent styling
$script:Theme = @{
    Header     = 'Cyan'
    Title      = 'Yellow'
    Success    = 'Green'
    Error      = 'Red'
    Warning    = 'DarkYellow'
    Info       = 'Cyan'
    Disabled   = 'DarkGray'
    MenuOption = 'White'
    Prompt     = 'Gray'
}
#endregion

#region UI Helper Functions
function Write-Status {
    <#
    .SYNOPSIS
        Writes a standardized status message with consistent formatting.
    .PARAMETER Type
        The type of status message: Success, Error, Warning, Info, or Processing.
    .PARAMETER Message
        The main message to display.
    .PARAMETER Detail
        Optional additional detail to display after the message.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Error', 'Warning', 'Info', 'Processing')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Detail = ""
    )

    $icon = $script:Icons[$Type]
    $color = switch ($Type) {
        'Success'    { $script:Theme.Success }
        'Error'      { $script:Theme.Error }
        'Warning'    { $script:Theme.Warning }
        'Info'       { $script:Theme.Info }
        'Processing' { $script:Theme.Info }
    }

    $output = "  $icon $Message"
    if ($Detail) {
        $output += " - $Detail"
    }

    Write-Host $output -ForegroundColor $color
}

function Read-HostPrompt {
    <#
    .SYNOPSIS
        Reads user input with standardized formatting and default value support.
    .PARAMETER Message
        The prompt message to display.
    .PARAMETER Default
        Optional default value if user presses Enter without input.
    .PARAMETER Type
        The type of input expected: Text or YesNo.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Default = "",

        [ValidateSet('Text', 'YesNo')]
        [string]$Type = 'Text'
    )

    if ($Type -eq 'YesNo') {
        $defaultDisplay = if ($Default -eq 'Y') { 'Y' } else { 'N' }
        $prompt = "$Message (Y/N) [default: $defaultDisplay]"
        $response = Read-Host $prompt

        if ([string]::IsNullOrWhiteSpace($response)) {
            return $Default -eq 'Y'
        }
        return ($response -eq 'Y' -or $response -eq 'y')
    }
    else {
        $prompt = if ([string]::IsNullOrWhiteSpace($Default)) {
            $Message
        }
        else {
            "$Message [default: $Default]"
        }

        $response = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $Default
        }
        return $response
    }
}

function Show-BatchProgress {
    <#
    .SYNOPSIS
        Displays a progress bar for batch operations.
    .PARAMETER Operation
        The name of the operation being performed.
    .PARAMETER Current
        The current item number (1-based).
    .PARAMETER Total
        The total number of items.
    .PARAMETER CurrentItem
        The name/identifier of the current item being processed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [int]$Current,

        [Parameter(Mandatory)]
        [int]$Total,

        [string]$CurrentItem = ""
    )

    $percent = [math]::Round(($Current / $Total) * 100)
    $barWidth = 20
    $filledWidth = [math]::Round(($percent / 100) * $barWidth)
    $emptyWidth = $barWidth - $filledWidth

    $progressBar = "[" + ("=" * $filledWidth) + (" " * $emptyWidth) + "]"
    $status = "$progressBar $percent% ($Current/$Total)"

    if ($CurrentItem) {
        $status += " - $CurrentItem"
    }

    Write-Host "`r$status" -NoNewline -ForegroundColor $script:Theme.Info
}

function Show-BatchSummary {
    <#
    .SYNOPSIS
        Displays a summary after batch operations complete.
    .PARAMETER Operation
        The name of the operation that was performed.
    .PARAMETER Total
        The total number of items processed.
    .PARAMETER SuccessCount
        The number of successful operations.
    .PARAMETER FailedItems
        An array of hashtables with 'Name' and 'Error' keys for failed items.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [int]$Total,

        [Parameter(Mandatory)]
        [int]$SuccessCount,

        [array]$FailedItems = @()
    )

    $failedCount = $Total - $SuccessCount

    Write-Host ""
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
    Write-Host "|  Operation Complete: $Operation" -ForegroundColor $script:Theme.Title
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
    Write-Host "|  Total: $Total | " -NoNewline -ForegroundColor $script:Theme.Info
    Write-Host "Success: $SuccessCount" -NoNewline -ForegroundColor $script:Theme.Success
    Write-Host " | " -NoNewline -ForegroundColor $script:Theme.Info
    if ($failedCount -gt 0) {
        Write-Host "Failed: $failedCount" -ForegroundColor $script:Theme.Error
    }
    else {
        Write-Host "Failed: 0" -ForegroundColor $script:Theme.Success
    }

    if ($FailedItems.Count -gt 0) {
        Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
        foreach ($item in $FailedItems) {
            Write-Host "|  " -NoNewline -ForegroundColor $script:Theme.Header
            Write-Host "$($item.Name): $($item.Error)" -ForegroundColor $script:Theme.Error
        }
    }
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header

    # Update last operation status
    $script:lastOperation = @{
        Name    = $Operation
        Success = $SuccessCount -eq $Total
        Total   = $Total
        SuccessCount = $SuccessCount
    }
}

function Show-ConfirmationBox {
    <#
    .SYNOPSIS
        Displays a warning confirmation box for dangerous operations.
    .PARAMETER Title
        The title/warning message.
    .PARAMETER Message
        The detailed message explaining the impact.
    .PARAMETER Detail
        Optional additional detail (e.g., "Affected hosts: 8").
    .RETURNS
        $true if user types 'YES', $false otherwise.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Detail = ""
    )

    Write-Host ""
    Write-Host "+-- WARNING -------------------------------------------------------+" -ForegroundColor $script:Theme.Warning
    Write-Host "|  $Title" -ForegroundColor $script:Theme.Warning
    Write-Host "|  $Message" -ForegroundColor $script:Theme.MenuOption
    if ($Detail) {
        Write-Host "|  $Detail" -ForegroundColor $script:Theme.Info
    }
    Write-Host "+------------------------------------------------------------------+" -ForegroundColor $script:Theme.Warning

    $confirm = Read-Host "Type 'YES' to confirm"
    return ($confirm -eq "YES")
}

function Show-FormattedTable {
    <#
    .SYNOPSIS
        Displays data in a formatted table with box-drawing characters.
    .PARAMETER Data
        Array of objects to display.
    .PARAMETER Columns
        Array of column names to display.
    .PARAMETER ColumnWidths
        Hashtable of column name to width mappings.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Data,

        [Parameter(Mandatory)]
        [string[]]$Columns,

        [hashtable]$ColumnWidths = @{}
    )

    # Calculate column widths if not specified
    foreach ($col in $Columns) {
        if (-not $ColumnWidths.ContainsKey($col)) {
            $maxLen = ($Data | ForEach-Object { $_.$col.ToString().Length } | Measure-Object -Maximum).Maximum
            $headerLen = $col.Length
            $ColumnWidths[$col] = [math]::Max($maxLen, $headerLen) + 2
        }
    }

    # Build separator line
    $separator = "+"
    foreach ($col in $Columns) {
        $separator += ("-" * ($ColumnWidths[$col] + 2)) + "+"
    }

    # Print header
    Write-Host $separator -ForegroundColor $script:Theme.Header
    $headerLine = "|"
    foreach ($col in $Columns) {
        $headerLine += "  " + $col.PadRight($ColumnWidths[$col]) + "|"
    }
    Write-Host $headerLine -ForegroundColor $script:Theme.Title
    Write-Host $separator -ForegroundColor $script:Theme.Header

    # Print data rows
    foreach ($row in $Data) {
        $dataLine = "|"
        foreach ($col in $Columns) {
            $value = if ($null -eq $row.$col) { "" } else { $row.$col.ToString() }
            $dataLine += "  " + $value.PadRight($ColumnWidths[$col]) + "|"
        }
        Write-Host $dataLine -ForegroundColor $script:Theme.MenuOption
    }
    Write-Host $separator -ForegroundColor $script:Theme.Header
}

function Pause {
    <#
    .SYNOPSIS
        Pauses execution and waits for user input.
    .PARAMETER Message
        Optional custom message to display.
    #>
    param(
        [string]$Message = "Press any key to return to menu..."
    )

    Write-Host ""
    Write-Host $Message -ForegroundColor $script:Theme.Prompt
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}
#endregion

function Show-Menu {
    Clear-Host

    # Helper to write menu option with proper alignment
    function Write-MenuOption {
        param(
            [string]$Number,
            [string]$Text,
            [bool]$Enabled = $true,
            [string]$DisabledReason = ""
        )
        # Pad single-digit numbers for alignment
        $paddedNum = if ($Number.Length -eq 1) { " $Number" } else { $Number }

        if ($Enabled) {
            Write-Host "  $paddedNum. $Text" -ForegroundColor $script:Theme.MenuOption
        }
        else {
            $displayText = "$paddedNum. $Text"
            if ($DisabledReason) {
                $displayText += "  [$DisabledReason]"
            }
            Write-Host "  $displayText" -ForegroundColor $script:Theme.Disabled
        }
    }

    # Connection state flags
    $isConnected = $script:connected
    $isVCenter = ($script:connectionType -eq "vCenter")

    # Header
    Write-Host "+===============================================================+" -ForegroundColor $script:Theme.Header
    Write-Host "|           ESXi Cluster Management Tool v2.0                   |" -ForegroundColor $script:Theme.Title
    Write-Host "+===============================================================+" -ForegroundColor $script:Theme.Header

    # Status section
    Write-Host "|  Status: " -NoNewline -ForegroundColor $script:Theme.Header
    if ($isConnected) {
        if ($script:connectionType -eq "Standalone") {
            Write-Host "Connected to ESXi Host: $script:vCenterServer" -ForegroundColor $script:Theme.Success
        }
        else {
            Write-Host "Connected to vCenter: $script:vCenterServer" -ForegroundColor $script:Theme.Success
        }
    }
    else {
        Write-Host "Not Connected" -ForegroundColor $script:Theme.Error
    }

    if ($script:connectionType -eq "Standalone") {
        # For standalone, show ESXi host info instead of cluster
        try {
            $hostObj = Get-VMHost -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $hostObj) {
                Write-Host "|  ESXi Host: $($hostObj.Name)" -ForegroundColor $script:Theme.Info
                Write-Host "|  ESXi Version: $($hostObj.Version)" -ForegroundColor $script:Theme.Info
            }
        }
        catch {
            Write-Host "|  ESXi Host: $script:vCenterServer" -ForegroundColor $script:Theme.Info
        }
    }
    elseif ($isConnected) {
        Write-Host "|  Cluster: $script:defaultCluster" -ForegroundColor $script:Theme.Info
    }

    # Credentials status - context-aware labels
    if ($script:connectionType -eq "Standalone") {
        # For standalone ESXi, show simpler credential info
        Write-Host "|  ESXi Creds: " -NoNewline -ForegroundColor $script:Theme.Header
        if ($null -ne $script:vCenterCreds) {
            Write-Host "Cached ($($script:vCenterCreds.UserName))" -ForegroundColor $script:Theme.Success
        }
        else {
            Write-Host "Not Set" -ForegroundColor $script:Theme.Warning
        }
        # Show SSH creds only if different from connection creds
        if ($null -ne $script:hostCreds -and $script:hostCreds -ne $script:vCenterCreds) {
            Write-Host "|  SSH Creds: " -NoNewline -ForegroundColor $script:Theme.Header
            Write-Host "Cached ($($script:hostCreds.UserName))" -ForegroundColor $script:Theme.Success
        }
    }
    else {
        # For vCenter or not connected, show both credential types
        Write-Host "|  vCenter Creds: " -NoNewline -ForegroundColor $script:Theme.Header
        if ($null -ne $script:vCenterCreds) {
            Write-Host "Cached ($($script:vCenterCreds.UserName))" -ForegroundColor $script:Theme.Success
        }
        else {
            Write-Host "Not Set" -ForegroundColor $script:Theme.Warning
        }
        Write-Host "|  ESXi Host Creds: " -NoNewline -ForegroundColor $script:Theme.Header
        if ($null -ne $script:hostCreds) {
            Write-Host "Cached ($($script:hostCreds.UserName))" -ForegroundColor $script:Theme.Success
        }
        else {
            Write-Host "Not Set" -ForegroundColor $script:Theme.Warning
        }
    }

    # Show last operation result if available
    if ($null -ne $script:lastOperation) {
        Write-Host "|  Last: " -NoNewline -ForegroundColor $script:Theme.Header
        $opStatus = if ($script:lastOperation.Success) { "SUCCESS" } else { "FAILED" }
        $opColor = if ($script:lastOperation.Success) { $script:Theme.Success } else { $script:Theme.Error }
        Write-Host "$($script:lastOperation.Name) ($opStatus - $($script:lastOperation.SuccessCount)/$($script:lastOperation.Total) hosts)" -ForegroundColor $opColor
    }

    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header

    # Connection section
    Write-Host ""
    Write-Host "-- Connection -----------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "1" "Connect to vCenter/ESXi"
    Write-MenuOption "2" "Disconnect"
    Write-MenuOption "3" "Set/Reset vCenter Credentials"
    Write-MenuOption "4" "Set/Reset ESXi Host Credentials"

    # SSH Management section
    Write-Host ""
    Write-Host "-- SSH Management -------------------------------------------------" -ForegroundColor $script:Theme.Title
    # Option 5 & 6: SSH management – description changes based on connection type
    if ($script:connectionType -eq "vCenter") {
        Write-MenuOption "5" "Start SSH (choose host/cluster/all)" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })
        Write-MenuOption "6" "Stop SSH (choose host/cluster/all)" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })
    } else {
        Write-MenuOption "5" "Start SSH on host" -Enabled $isConnected -DisabledReason $(if (-not $isConnected) { "Not connected" })
        Write-MenuOption "6" "Stop SSH on host" -Enabled $isConnected -DisabledReason $(if (-not $isConnected) { "Not connected" })
    }

    # ESXi CLI Operations section
    Write-Host ""
    Write-Host "-- ESXi CLI Operations --------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "7" "Run ESXCli command on all hosts" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })
    Write-MenuOption "8" "Run ESXCli command on single host" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "9" "Reboot all hosts in cluster" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })

    # File Transfer section
    Write-Host ""
    Write-Host "-- File Transfer --------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "10" "SCP file to single host" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "11" "SCP file to all hosts in cluster" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })

    # Driver/VIB Management section
    Write-Host ""
    Write-Host "-- Driver/VIB Management ------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "12" "Install VIB on single host" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "13" "Install Mellanox driver on cluster" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })

    # SSH Commands section
    Write-Host ""
    Write-Host "-- SSH Commands ---------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "14" "Execute SSH command on cluster hosts" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })
    Write-MenuOption "15" "View active SSH sessions"
    Write-MenuOption "16" "Disconnect SSH session"

    # RDMA/Network section
    Write-Host ""
    Write-Host "-- RDMA/Network ---------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "17" "Configure RDMA parameters" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })
    Write-MenuOption "18" "Check DCBX status" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })

    # IPMI/Custom Attributes section
    Write-Host ""
    Write-Host "-- IPMI/Custom Attributes -----------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "19" "Get IPMI BMC Addresses" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "20" "Set Custom Attribute on Host" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })
    Write-MenuOption "21" "Set Custom Attribute on Cluster (from IPMI)" -Enabled $isVCenter -DisabledReason $(if (-not $isConnected) { "Not connected" } else { "Requires vCenter" })

    # Exit
    Write-Host ""
    Write-Host "   0. Exit" -ForegroundColor $script:Theme.Error
    Write-Host ""
    Write-Host "+===============================================================+" -ForegroundColor $script:Theme.Header
}

function Get-VCenterName {
    $vCenter = Read-HostPrompt -Message "Enter vCenter/ESXi hostname" -Default $script:vCenterServer
    if ([string]::IsNullOrWhiteSpace($vCenter)) {
        Write-Status -Type Error -Message "Hostname is required and no default is set"
        return $null
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

    # If connection credentials are available, offer to use them for SSH/SCP operations
    if ($null -ne $script:vCenterCreds) {
        # Use context-aware label
        $credLabel = if ($script:connectionType -eq "Standalone") { "ESXi credentials" } else { "vCenter credentials" }
        Write-Status -Type Info -Message "$credLabel available" -Detail "user: $($script:vCenterCreds.UserName)"
        $useVCreds = Read-HostPrompt -Message "Use same credentials for SSH/SCP?" -Type YesNo -Default 'Y'
        if ($useVCreds) {
            $script:hostCreds = $script:vCenterCreds
            Write-Status -Type Success -Message "Using cached credentials for SSH/SCP operations"
            return $script:hostCreds
        }
    }

    $script:hostCreds = Get-Credential -Message "Enter ESXi host credentials (typically 'root')"
    return $script:hostCreds
}

function Set-VCenterCredentials {
    Write-Status -Type Info -Message "Setting vCenter credentials"
    if ($null -ne $script:vCenterCreds) {
        Write-Status -Type Info -Message "Current credentials" -Detail $script:vCenterCreds.UserName
        $reset = Read-HostPrompt -Message "Reset credentials?" -Type YesNo -Default 'N'
        if (-not $reset) {
            Write-Status -Type Success -Message "Keeping existing credentials"
            Pause
            return
        }
    }

    try {
        $script:vCenterCreds = Get-Credential -Message "Enter vCenter credentials"
        if ($null -ne $script:vCenterCreds) {
            Write-Status -Type Success -Message "Credentials set" -Detail "user: $($script:vCenterCreds.UserName)"
        }
        else {
            Write-Status -Type Warning -Message "Credential entry cancelled"
        }
    }
    catch {
        Write-Status -Type Error -Message "Failed to set credentials" -Detail $_
    }
    Pause
}

function Set-ESXiHostCredentials {
    Write-Status -Type Info -Message "Setting ESXi host credentials"
    if ($null -ne $script:hostCreds) {
        Write-Status -Type Info -Message "Current credentials" -Detail $script:hostCreds.UserName
        $reset = Read-HostPrompt -Message "Reset credentials?" -Type YesNo -Default 'N'
        if (-not $reset) {
            Write-Status -Type Success -Message "Keeping existing credentials"
            Pause
            return
        }
    }

    # If vCenter credentials are available, offer to use them
    if ($null -ne $script:vCenterCreds) {
        Write-Status -Type Info -Message "vCenter credentials available" -Detail "user: $($script:vCenterCreds.UserName)"
        $useVCreds = Read-HostPrompt -Message "Use vCenter credentials for ESXi host?" -Type YesNo -Default 'N'
        if ($useVCreds) {
            $script:hostCreds = $script:vCenterCreds
            Write-Status -Type Success -Message "Using vCenter credentials for ESXi host operations"
            Pause
            return
        }
    }

    try {
        $script:hostCreds = Get-Credential -Message "Enter ESXi host credentials (typically 'root')"
        if ($null -ne $script:hostCreds) {
            Write-Status -Type Success -Message "Credentials set" -Detail "user: $($script:hostCreds.UserName)"
        }
        else {
            Write-Status -Type Warning -Message "Credential entry cancelled"
        }
    }
    catch {
        Write-Status -Type Error -Message "Failed to set credentials" -Detail $_
    }
    Pause
}

function Test-IsVCenter {
    # Check if connected to vCenter or standalone host
    if (-not $script:connected) {
        return $false
    }
    
    try {
        # Try to get clusters - if we can get clusters, it's vCenter
        $clusters = Get-Cluster -ErrorAction SilentlyContinue
        return ($null -ne $clusters -and $clusters.Count -gt 0)
    } catch {
        # If Get-Cluster fails or returns nothing, it's likely a standalone host
        return $false
    }
}

function Get-ClusterName {
    # Check if we're connected to a standalone host
    if ($script:connectionType -eq "Standalone") {
        Write-Status -Type Error -Message "This operation requires a cluster" -Detail "connected to standalone host"
        return $null
    }

    $cluster = Read-HostPrompt -Message "Enter cluster name" -Default $script:defaultCluster
    if ([string]::IsNullOrWhiteSpace($cluster)) {
        Write-Status -Type Error -Message "Cluster name is required and no default is set"
        return $null
    }
    $script:defaultCluster = $cluster  # Update the script variable
    return $cluster
}

function Connect-ToVCenter {
    $vCenter = Get-VCenterName
    if ($null -eq $vCenter) {
        Pause
        return
    }

    # Get vCenter credentials (use cache if available)
    $vCenterCreds = Get-VCenterCredentials
    if ($null -eq $vCenterCreds) {
        Write-Status -Type Warning -Message "Connection cancelled"
        Pause
        return
    }

    try {
        Write-Status -Type Processing -Message "Connecting to $vCenter"
        Connect-VIServer $vCenter -Credential $vCenterCreds -Force -ErrorAction Stop
        $script:vCenterServer = $vCenter
        $script:connected = $true

        # Detect connection type
        if (Test-IsVCenter) {
            $script:connectionType = "vCenter"
            Write-Status -Type Success -Message "Connected to vCenter" -Detail $vCenter
        }
        else {
            $script:connectionType = "Standalone"
            Write-Status -Type Success -Message "Connected to standalone ESXi host" -Detail $vCenter
        }
    }
    catch {
        Write-Status -Type Error -Message "Failed to connect" -Detail $_
        $script:connected = $false
        $script:connectionType = $null
    }
    Pause
}

function Disconnect-FromVCenter {
    try {
        Write-Status -Type Processing -Message "Disconnecting from $script:vCenterServer"
        Disconnect-VIServer $script:vCenterServer -Confirm:$false -ErrorAction Stop
        $script:connected = $false
        $script:connectionType = $null
        Write-Status -Type Success -Message "Disconnected successfully"
    }
    catch {
        Write-Status -Type Error -Message "Failed to disconnect" -Detail $_
    }
    Pause
}

function Start-ClusterSSH {
    # Determine target hosts based on connection type and user scope
    $targets = Get-TargetHosts
    if ($targets.Count -eq 0) { Write-Status -Type Warning -Message "No hosts selected"; Pause; return }
    $total = $targets.Count
    $current = 0
    $successCount = 0
    $failedItems = @()
    foreach ($vmHost in $targets) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Start SSH" -Current $current -Total $total -CurrentItem $hostName
        try {
            Get-VMHost -Name $hostName | Get-VMHostService |
                Where-Object Key -EQ "TSM-SSH" | Start-VMHostService -Confirm:$false | Out-Null
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }
    Write-Host ""
    Show-BatchSummary -Operation "Start SSH" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Stop-ClusterSSH {
    # Determine target hosts based on connection type and user scope
    $targets = Get-TargetHosts
    if ($targets.Count -eq 0) { Write-Status -Type Warning -Message "No hosts selected"; Pause; return }
    $total = $targets.Count
    $current = 0
    $successCount = 0
    $failedItems = @()
    foreach ($vmHost in $targets) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Stop SSH" -Current $current -Total $total -CurrentItem $hostName
        try {
            Get-VMHost -Name $hostName | Get-VMHostService |
                Where-Object Key -EQ "TSM-SSH" | Stop-VMHostService -Confirm:$false | Out-Null
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }
    Write-Host ""
    Show-BatchSummary -Operation "Stop SSH" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Invoke-ESXCliOnCluster {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    $uuid = Read-HostPrompt -Message "Enter UUID for vsan.debug.object.list"
    if ([string]::IsNullOrWhiteSpace($uuid)) {
        Write-Status -Type Error -Message "UUID is required"
        Pause
        return
    }

    Write-Status -Type Info -Message "Running ESXCli command on cluster" -Detail $cluster

    $hosts = @(Get-VMHost -Location $cluster)
    $total = $hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Write-Host ""
        Write-Host "[$current/$total] $hostName" -ForegroundColor $script:Theme.Info

        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.vsan.debug.object.list.invoke(@{uuid = $uuid })
            $successCount++
        }
        catch {
            Write-Status -Type Error -Message "Failed" -Detail $_
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Show-BatchSummary -Operation "ESXCli on Cluster" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Invoke-ESXCliOnHost {
    # Auto-fill hostname when connected to standalone ESXi
    $defaultHost = if ($script:connectionType -eq "Standalone") { $script:vCenterServer } else { "" }
    $hostName = Read-HostPrompt -Message "Enter ESXi hostname" -Default $defaultHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Write-Status -Type Error -Message "Hostname is required"
        Pause
        return
    }

    Write-Status -Type Processing -Message "Getting ESXCli createargs for" -Detail $hostName
    try {
        (Get-EsxCli -v2 -VMHost $hostName).vsan.debug.object.list.createargs()
        Write-Status -Type Success -Message "Command completed"
    }
    catch {
        Write-Status -Type Error -Message "Failed" -Detail $_.Exception.Message
    }
    Pause
}

function Restart-ClusterHosts {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    # Get host count for warning message
    $hosts = @(Get-VMHost -Location $cluster)
    $hostCount = $hosts.Count

    $confirmed = Show-ConfirmationBox `
        -Title "REBOOT ALL HOSTS" `
        -Message "This will reboot ALL hosts in cluster: $cluster" `
        -Detail "Affected hosts: $hostCount"

    if (-not $confirmed) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    $reason = Read-HostPrompt -Message "Enter reboot reason" -Default "Scheduled maintenance"

    $total = $hostCount
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Reboot Hosts" -Current $current -Total $total -CurrentItem $hostName

        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.system.shutdown.reboot.invoke(@{reason = $reason })
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "Reboot Cluster Hosts" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Ensure-SSH {
    param(
        [string]$HostName
    )
    # Retrieve the VMHost object
    $vmHost = Get-VMHost -Name $HostName -ErrorAction SilentlyContinue
    if (-not $vmHost) {
        Write-Status -Type Error -Message "Host $HostName not found"
        return $false
    }

    $sshService = Get-VMHostService -VMHost $vmHost | Where-Object {$_.Key -eq "TSM-SSH"}
    if ($sshService -and $sshService.Running) {
        Write-Status -Type Success -Message "SSH service already running on $HostName"
        return $true
    }

    Write-Status -Type Warning -Message "SSH service not running on $HostName"
    $start = Read-HostPrompt -Message "Start SSH service now?" -Type YesNo -Default 'Y'
    if ($start) {
        try {
            $sshService | Start-VMHostService -Confirm:$false | Out-Null
            Write-Status -Type Success -Message "SSH started on $HostName"
            return $true
        }
        catch {
            Write-Status -Type Error -Message "Failed to start SSH on $HostName" -Detail $_.Exception.Message
            return $false
        }
    }
    else {
        Write-Status -Type Warning -Message "SSH not started; operation may fail"
        return $false
    }
}
function Copy-FileToHost {
    # Auto-fill hostname when connected to standalone ESXi
    $defaultHost = if ($script:connectionType -eq "Standalone") { $script:vCenterServer } else { "" }
    $hostName = Read-HostPrompt -Message "Enter ESXi hostname" -Default $defaultHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Write-Status -Type Error -Message "Hostname is required"
        Pause
        return
    }

    $sourcePath = Read-HostPrompt -Message "Enter source file path"
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        Write-Status -Type Error -Message "Source path is required"
        Pause
        return
    }

    # Check if source file exists
    if (-not (Test-Path $sourcePath)) {
        Write-Status -Type Error -Message "Source file not found" -Detail $sourcePath
        Pause
        return
    }

    $destination = Read-HostPrompt -Message "Enter destination path" -Default "/tmp"

    $hostCreds = Get-ESXiHostCredentials
    if ($null -eq $hostCreds) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    # Ensure SSH service is running
    $sshOk = Ensure-SSH -HostName $hostName
    if (-not $sshOk) {
        $proceed = Read-HostPrompt -Message "SSH not running. Continue anyway?" -Type YesNo -Default 'N'
        if (-not $proceed) {
            Write-Status -Type Warning -Message "Operation cancelled due to SSH not running"
            Pause
            return
        }
    }

    try {
        Write-Status -Type Processing -Message "Copying file to $hostName" -Detail $destination
        Set-SCPItem -ComputerName $hostName -Credential $hostCreds `
            -Path $sourcePath -Destination $destination -ErrorAction Stop
        Write-Status -Type Success -Message "File copied successfully"
    }
    catch {
        Write-Status -Type Error -Message "SCP failed" -Detail $_.Exception.Message
    }
    Pause
}

function Copy-FileToCluster {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    $sourcePath = Read-HostPrompt -Message "Enter source file path"
    if ([string]::IsNullOrWhiteSpace($sourcePath)) {
        Write-Status -Type Error -Message "Source path is required"
        Pause
        return
    }

    $destination = Read-HostPrompt -Message "Enter destination path" -Default "/tmp"

    $hostCreds = Get-ESXiHostCredentials
    if ($null -eq $hostCreds) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    $hosts = @(Get-VMHost -Location $cluster)
    $total = $hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "SCP to Cluster" -Current $current -Total $total -CurrentItem $hostName
        $sshOk = Ensure-SSH -HostName $hostName
        if (-not $sshOk) {
            $proceed = Read-HostPrompt -Message "SSH not running on $hostName. Continue anyway?" -Type YesNo -Default 'N'
            if (-not $proceed) {
                $failedItems += @{ Name = $hostName; Error = "SSH not running" }
                continue
            }
        }
        try {
            Set-SCPItem -ComputerName $hostName -Credential $hostCreds `
                -Path $sourcePath -Destination $destination
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "SCP File to Cluster" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Install-VIBOnHost {
    # Auto-fill hostname when connected to standalone ESXi
    $defaultHost = if ($script:connectionType -eq "Standalone") { $script:vCenterServer } else { "" }
    $hostName = Read-HostPrompt -Message "Enter ESXi hostname" -Default $defaultHost
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Write-Status -Type Error -Message "Hostname is required"
        Pause
        return
    }

    $vibUrl = Read-HostPrompt -Message "Enter VIB URL (local path on ESXi host)"
    if ([string]::IsNullOrWhiteSpace($vibUrl)) {
        Write-Status -Type Error -Message "VIB URL is required"
        Pause
        return
    }

    try {
        Write-Status -Type Processing -Message "Installing VIB on $hostName"
        $esxcli = Get-EsxCli -v2 -VMHost $hostName
        $esxcli.software.vib.install.invoke(@{viburl = $vibUrl; nosigcheck = "true" })
        Write-Status -Type Success -Message "VIB installed successfully"
    }
    catch {
        Write-Status -Type Error -Message "Failed" -Detail $_.Exception.Message
    }
    Pause
}

function Install-MellanoxDriver {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    $scriptPath = Read-HostPrompt -Message "Enter path to SSH-mellanox-install.ps1"
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        Write-Status -Type Error -Message "Script path is required"
        Pause
        return
    }

    if (-not (Test-Path $scriptPath)) {
        Write-Status -Type Error -Message "Script not found" -Detail $scriptPath
        Pause
        return
    }

    $hosts = @(Get-VMHost -Location $cluster)
    $total = $hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Install Mellanox Driver" -Current $current -Total $total -CurrentItem $hostName

        try {
            & $scriptPath -sshHost $hostName
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "Install Mellanox Driver" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Invoke-SSHOnCluster {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    # Command templates from original script
    Write-Host ""
    Write-Host "-- Select Command Template ----------------------------------------" -ForegroundColor $script:Theme.Title
    Write-Host "   1. rm -f /tmp/*.vib" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   2. rm -f /tmp/*.bin" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   3. ls -lah /tmp" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   4. esxcli mellanox mft flint query -d mt4117_pciconf0 -r" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   5. vsish -e get /vmkModules/rdt/allConnCount" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   6. vsish -e get /vmkModules/rdt/clusterProtocol" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   7. esxcli mellanox mft mst status" -ForegroundColor $script:Theme.MenuOption
    Write-Host "   8. Custom command (type your own)" -ForegroundColor $script:Theme.MenuOption
    Write-Host ""

    $templateChoice = Read-HostPrompt -Message "Select template (1-8)"

    $command = switch ($templateChoice) {
        "1" { "rm -f /tmp/*.vib" }
        "2" { "rm -f /tmp/*.bin" }
        "3" { "ls -lah /tmp" }
        "4" { "esxcli mellanox mft flint query -d mt4117_pciconf0 -r" }
        "5" { "vsish -e get /vmkModules/rdt/allConnCount" }
        "6" { "vsish -e get /vmkModules/rdt/clusterProtocol" }
        "7" { "esxcli mellanox mft mst status" }
        "8" { Read-HostPrompt -Message "Enter custom command" }
        default {
            Write-Status -Type Warning -Message "Invalid selection, using custom input"
            Read-HostPrompt -Message "Enter command"
        }
    }

    # Allow editing the selected command
    Write-Status -Type Info -Message "Selected command" -Detail $command
    $edit = Read-HostPrompt -Message "Edit command?" -Type YesNo -Default 'N'

    if ($edit) {
        $command = Read-HostPrompt -Message "Enter modified command" -Default $command
    }

    Write-Host ""
    Write-Status -Type Info -Message "Will execute" -Detail $command
    $confirm = Read-HostPrompt -Message "Continue?" -Type YesNo -Default 'Y'

    if (-not $confirm) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    $hostCreds = Get-ESXiHostCredentials
    if ($null -eq $hostCreds) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    $hosts = @(Get-VMHost -Location $cluster)
    $total = $hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Write-Host ""
        Write-Host "[$current/$total] $hostName" -ForegroundColor $script:Theme.Info

        try {
            $session = New-SSHSession -ComputerName $hostName -Credential $hostCreds
            $result = Invoke-SSHCommand -Command $command -SessionId $session.SessionId
            Write-Host $result.Output
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
            $successCount++
        }
        catch {
            Write-Status -Type Error -Message "Failed" -Detail $_
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Show-BatchSummary -Operation "SSH Command on Cluster" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Show-SSHSessions {
    Write-Status -Type Info -Message "Active SSH Sessions"
    $sessions = Get-SSHSession
    if ($sessions) {
        $sessions | Format-Table -AutoSize
    }
    else {
        Write-Status -Type Info -Message "No active SSH sessions"
    }
    Pause
}

function Remove-SSHSessionById {
    Write-Status -Type Info -Message "Active SSH Sessions"
    $sessions = Get-SSHSession
    if ($sessions) {
        $sessions | Format-Table -AutoSize
    }
    else {
        Write-Status -Type Info -Message "No active SSH sessions"
        Pause
        return
    }

    $sessionId = Read-HostPrompt -Message "Enter Session ID to disconnect"
    if ([string]::IsNullOrWhiteSpace($sessionId)) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    try {
        Remove-SSHSession -SessionId $sessionId
        Write-Status -Type Success -Message "Session disconnected"
    }
    catch {
        Write-Status -Type Error -Message "Failed" -Detail $_
    }
    Pause
}

function Set-RDMAParameters {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    Write-Status -Type Info -Message "Configuring RDMA parameters on cluster" -Detail $cluster

    $hosts = @(Get-VMHost -Location $cluster)
    $total = $hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Configure RDMA" -Current $current -Total $total -CurrentItem $hostName

        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.system.module.parameters.set.invoke(@{module = "nmlx5_core"; parameterstring = "dcbx=1" })
            $esxcli.system.module.parameters.set.invoke(@{module = "nmlx5_core"; parameterstring = "pfctx=8 pfcrx=8 trust_state=2 max_vfs=4" })
            $esxcli.system.module.parameters.set.invoke(@{module = "nmlx5_rdma"; parameterstring = "pcp_force=3 dscp_force=26" })
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "Configure RDMA Parameters" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Get-DCBXStatus {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    $nicName = Read-HostPrompt -Message "Enter NIC name (e.g., vmnic4)" -Default "vmnic4"

    Write-Status -Type Info -Message "Checking DCBX status on cluster" -Detail $cluster

    $hosts = @(Get-VMHost -Location $cluster)
    $total = $hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()

    foreach ($vmHost in $hosts) {
        $current++
        $hostName = $vmHost.Name
        Write-Host ""
        Write-Host "[$current/$total] $hostName" -ForegroundColor $script:Theme.Info

        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $esxcli.network.nic.dcb.status.get.invoke(@{nicname = $nicName })
            $successCount++
        }
        catch {
            Write-Status -Type Error -Message "Failed" -Detail $_
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }

    Show-BatchSummary -Operation "Check DCBX Status" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Get-ClusterIPMI {
    # Check connection type and handle accordingly
    if ($script:connectionType -eq "Standalone") {
        # Connected to standalone host - get IPMI for this host only
        Write-Status -Type Info -Message "Retrieving IPMI BMC address for standalone host" -Detail $script:vCenterServer

        try {
            # Get the connected host (when connected to standalone, there's only one)
            $hostObj = Get-VMHost -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $hostObj) {
                # Fallback: try using the server name
                $hostObj = Get-VMHost -Name $script:vCenterServer -ErrorAction Stop
            }

            $esxcli = Get-EsxCli -v2 -VMHost $hostObj
            $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
            $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address }
            elseif ($bmcInfo.IP) { $bmcInfo.IP }
            else { "N/A" }

            $results = @([pscustomobject]@{
                    HostName    = $hostObj.Name
                    IPv4Address = $ipv4
                })
        }
        catch {
            $results = @([pscustomobject]@{
                    HostName    = $script:vCenterServer
                    IPv4Address = "Error: $_"
                })
        }
    }
    else {
        # Connected to vCenter - get IPMI for cluster hosts
        $cluster = Get-ClusterName
        if ($null -eq $cluster) {
            Pause
            return
        }

        Write-Status -Type Info -Message "Retrieving IPMI BMC addresses for cluster" -Detail $cluster

        $hosts = @(Get-VMHost -Location $cluster)
        $total = $hosts.Count
        $current = 0
        $results = @()

        foreach ($vmHost in $hosts) {
            $current++
            Show-BatchProgress -Operation "Get IPMI" -Current $current -Total $total -CurrentItem $vmHost.Name

            try {
                $esxcli = Get-EsxCli -v2 -VMHost $vmHost.Name
                $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
                $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address }
                elseif ($bmcInfo.IP) { $bmcInfo.IP }
                else { "N/A" }

                $results += [pscustomobject]@{
                    HostName    = $vmHost.Name
                    IPv4Address = $ipv4
                }
            }
            catch {
                $results += [pscustomobject]@{
                    HostName    = $vmHost.Name
                    IPv4Address = "Error: $($_.Exception.Message)"
                }
            }
        }
        Write-Host ""  # Clear progress line
    }

    # Display results in formatted table
    Write-Host ""
    Show-FormattedTable -Data $results -Columns @('HostName', 'IPv4Address') -ColumnWidths @{
        HostName    = 30
        IPv4Address = 20
    }
    Pause
}

function Set-HostCustomAttribute {
    $hostName = Read-HostPrompt -Message "Enter ESXi hostname"
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Write-Status -Type Error -Message "Hostname is required"
        Pause
        return
    }

    $ipAddress = Read-HostPrompt -Message "Enter IP address"
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        Write-Status -Type Error -Message "IP address is required"
        Pause
        return
    }

    $attrName = Read-HostPrompt -Message "Enter custom attribute name" -Default "ManagementIP"

    try {
        Write-Status -Type Processing -Message "Setting custom attribute on $hostName"
        $esxi = Get-VMHost -Name $hostName -ErrorAction Stop

        # Create attribute if needed
        $attr = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
        if (-not $attr) {
            New-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction Stop | Out-Null
            Write-Status -Type Info -Message "Created new custom attribute" -Detail $attrName
        }

        Set-Annotation -Entity $esxi -CustomAttribute $attrName -Value $ipAddress -Confirm:$false
        Write-Status -Type Success -Message "Attribute set successfully" -Detail "$attrName = $ipAddress"
    }
    catch {
        Write-Status -Type Error -Message "Failed" -Detail $_
    }
    Pause
}

function Set-ClusterCustomAttributeFromIPMI {
    $cluster = Get-ClusterName
    if ($null -eq $cluster) {
        Pause
        return
    }

    $attrName = Read-HostPrompt -Message "Enter custom attribute name" -Default "ManagementIP"

    # Get host count for confirmation
    $hosts = @(Get-VMHost -Location $cluster)
    $hostCount = $hosts.Count

    Write-Host ""
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
    Write-Host "|  This operation will:" -ForegroundColor $script:Theme.Title
    Write-Host "|    1. Get IPMI BMC addresses for all hosts in $cluster" -ForegroundColor $script:Theme.Info
    Write-Host "|    2. Set '$attrName' custom attribute with IPMI IP" -ForegroundColor $script:Theme.Info
    Write-Host "|  Affected hosts: $hostCount" -ForegroundColor $script:Theme.Info
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header

    $confirm = Read-HostPrompt -Message "Continue?" -Type YesNo -Default 'N'

    if (-not $confirm) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    # Get IPMI addresses
    Write-Status -Type Processing -Message "Retrieving IPMI addresses"
    $total = $hosts.Count
    $current = 0
    $ipmiData = @()

    foreach ($vmHost in $hosts) {
        $current++
        Show-BatchProgress -Operation "Get IPMI" -Current $current -Total $total -CurrentItem $vmHost.Name

        try {
            $esxcli = Get-EsxCli -v2 -VMHost $vmHost.Name
            $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
            $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address }
            elseif ($bmcInfo.IP) { $bmcInfo.IP }
            else { $null }

            $ipmiData += [pscustomobject]@{
                Host = $vmHost.Name
                IPMI = $ipv4
            }
        }
        catch {
            $ipmiData += [pscustomobject]@{
                Host = $vmHost.Name
                IPMI = $null
            }
        }
    }

    Write-Host ""  # Clear progress line

    # Create attribute if needed
    $attr = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
    if (-not $attr) {
        New-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction Stop | Out-Null
        Write-Status -Type Info -Message "Created new custom attribute" -Detail $attrName
    }

    # Set attributes
    Write-Status -Type Processing -Message "Setting custom attributes"
    $successCount = 0
    $failedItems = @()

    $current = 0
    foreach ($item in $ipmiData) {
        $current++
        Show-BatchProgress -Operation "Set Attribute" -Current $current -Total $total -CurrentItem $item.Host

        if ($item.IPMI) {
            try {
                $esxi = Get-VMHost -Name $item.Host -ErrorAction Stop
                Set-Annotation -Entity $esxi -CustomAttribute $attrName -Value $item.IPMI -Confirm:$false
                $successCount++
            }
            catch {
                $failedItems += @{ Name = $item.Host; Error = $_.Exception.Message }
            }
        }
        else {
            $failedItems += @{ Name = $item.Host; Error = "No IPMI address found" }
        }
    }

    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "Set Custom Attribute from IPMI" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Get-TargetHosts {
    <#
    .SYNOPSIS
        Returns an array of VMHost objects based on user-selected scope.
    .DESCRIPTION
        For vCenter connections, prompts the user to select a scope: single host, cluster, or all hosts.
        For standalone connections, returns the single connected host.
    #>
    if ($script:connectionType -eq "Standalone") {
        # Single host connection
        $hostObj = Get-VMHost -ErrorAction SilentlyContinue | Select-Object -First 1
        return @($hostObj)
    }
    else {
        # vCenter – ask for scope
        Write-Host "Select SSH scope:" -ForegroundColor $script:Theme.Title
        Write-Host "  1) Single host" -ForegroundColor $script:Theme.MenuOption
        Write-Host "  2) Entire cluster" -ForegroundColor $script:Theme.MenuOption
        Write-Host "  3) All hosts in vCenter" -ForegroundColor $script:Theme.MenuOption
        $choice = Read-HostPrompt -Message "Enter choice (1-3)" -Default "2"
        switch ($choice) {
            "1" {
                $hostName = Read-HostPrompt -Message "Enter hostname" -Default $script:vCenterServer
                $host = Get-VMHost -Name $hostName -ErrorAction Stop
                return @($host)
            }
            "2" {
                $cluster = Get-ClusterName
                if ($null -eq $cluster) { return @() }
                $hosts = Get-VMHost -Location $cluster
                return $hosts
            }
            "3" {
                $hosts = Get-VMHost
                return $hosts
            }
            default { return @() }
        }
    }
}

# Helper function to check vCenter requirement
function Test-VCenterRequired {
    if (-not $script:connected) {
        Write-Status -Type Error -Message "This option requires a connection" -Detail "Use option 1 to connect first"
        Pause
        return $false
    }
    if ($script:connectionType -ne "vCenter") {
        Write-Status -Type Error -Message "This option requires vCenter connection" -Detail "Connected to standalone host"
        Pause
        return $false
    }
    return $true
}

# Main loop
do {
    Show-Menu
    $choice = Read-HostPrompt -Message "Enter your choice"

    switch ($choice) {
        "1" {
            if ($script:connected) {
                Write-Status -Type Warning -Message "Already connected" -Detail "Use option 2 to disconnect first"
                Pause
            }
            else {
                Connect-ToVCenter
            }
        }
        "2" {
            if (-not $script:connected) {
                Write-Status -Type Warning -Message "Not connected" -Detail "Nothing to disconnect"
                Pause
            }
            else {
                Disconnect-FromVCenter
            }
        }
        "3" { Set-VCenterCredentials }
        "4" { Set-ESXiHostCredentials }
        "5" { if (Test-ConnectionRequired) { Start-ClusterSSH } }
        "6" { if (Test-ConnectionRequired) { Stop-ClusterSSH } }
        "7" { if (Test-VCenterRequired) { Invoke-ESXCliOnCluster } }
        "8" { if (Test-ConnectionRequired) { Invoke-ESXCliOnHost } }
        "9" { if (Test-VCenterRequired) { Restart-ClusterHosts } }
        "10" { if (Test-ConnectionRequired) { Copy-FileToHost } }
        "11" { if (Test-VCenterRequired) { Copy-FileToCluster } }
        "12" { if (Test-ConnectionRequired) { Install-VIBOnHost } }
        "13" { if (Test-VCenterRequired) { Install-MellanoxDriver } }
        "14" { if (Test-VCenterRequired) { Invoke-SSHOnCluster } }
        "15" { Show-SSHSessions }
        "16" { Remove-SSHSessionById }
        "17" { if (Test-VCenterRequired) { Set-RDMAParameters } }
        "18" { if (Test-VCenterRequired) { Get-DCBXStatus } }
        "19" { if (Test-ConnectionRequired) { Get-ClusterIPMI } }
        "20" { if (Test-VCenterRequired) { Set-HostCustomAttribute } }
        "21" { if (Test-VCenterRequired) { Set-ClusterCustomAttributeFromIPMI } }
        "0" {
            if ($script:connected) {
                Disconnect-FromVCenter
            }
            Write-Status -Type Info -Message "Exiting..."
        }
        default {
            Write-Status -Type Error -Message "Invalid choice" -Detail "Enter a valid option number"
            Pause
        }
    }
} while ($choice -ne "0")