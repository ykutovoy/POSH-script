#Requires -Modules VMware.VimAutomation.Core, Posh-SSH

# Configuration
$script:OperationScope = @{
    Type = 'Undefined'   # 'Undefined', 'Host', 'Cluster', 'vCenterAll'
    Name = $null
    Hosts = @()
    Cluster = $null
}

# NOTE: Update these defaults for your environment, or they will be prompted at runtime
$script:vCenterServer = ""  # e.g., "vcenter.example.com"
$script:defaultCluster = ""  # e.g., "Production-Cluster-01"
$script:vCenterCreds = $null      # vCenter/cluster credentials
$script:hostCreds = $null         # ESXi host/SSH credentials
$script:connected = $false
$script:connectionType = $null    # "vCenter" or "Standalone"
$script:lastOperation = $null

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
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header
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
        Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header
        foreach ($item in $FailedItems) {
            Write-Host "|  " -NoNewline -ForegroundColor $script:Theme.Header
            Write-Host "$($item.Name): $($item.Error)" -ForegroundColor $script:Theme.Error
        }
    }
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header

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
    Write-Host "+------------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Warning

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

#region Scope Management Functions
function Show-SimplifiedScopeMenu {
    <#
    .SYNOPSIS
        Displays the simplified scope selection menu (Host, Cluster, All Hosts).
    #>
    
    # Validate connection
    if (-not $script:connected) {
        Write-Status -Type Error -Message "Not connected" -Detail "Connect first to set scope"
        Pause
        return
    }
    
    while ($true) {
        Clear-Host
        Write-Host "=== Operation Scope Selection ===" -ForegroundColor $script:Theme.Header
        Write-Host "Current Scope: $($script:OperationScope.Type) - $($script:OperationScope.Name)" -ForegroundColor $script:Theme.Title
        Write-Host "Hosts in scope: $($script:OperationScope.Hosts.Count)" -ForegroundColor $script:Theme.MenuOption
        
        Write-Host "`nAvailable scope types:" -ForegroundColor $script:Theme.MenuOption
        
        if ($script:connectionType -eq "vCenter") {
            # Connected to vCenter
            $clusters = Get-Cluster | Sort-Object Name -ErrorAction SilentlyContinue
            
            if ($clusters -and $clusters.Count -gt 0) {
                Write-Host "1. Select Cluster" -ForegroundColor $script:Theme.Success
            } else {
                Write-Host "1. Select Cluster [No clusters available]" -ForegroundColor $script:Theme.Disabled
            }
            
            Write-Host "2. All Hosts in vCenter" -ForegroundColor $script:Theme.Success
            Write-Host "3. Single Host" -ForegroundColor $script:Theme.Success
            
        } elseif ($script:connectionType -eq "Standalone") {
            # Connected to standalone ESXi
            Write-Host "1. Current Host (standalone)" -ForegroundColor $script:Theme.Success
        }
        
        Write-Host "`n0. Cancel"
        
        $choice = Read-HostPrompt -Message "`nSelect scope type"
        
        if ($choice -eq "0") {
            return
        }
        
        ProcessSimplifiedScopeSelection $choice
        return
    }
}

function ProcessSimplifiedScopeSelection {
    <#
    .SYNOPSIS
        Processes the scope selection choice.
    .PARAMETER choice
        The user's scope selection (1-3).
    #>
    param([string]$choice)
    
    switch ($choice) {
        "1" {
            if ($script:connectionType -eq "Standalone") {
                # Standalone host - auto-set to current host
                $hostObj = Get-VMHost -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hostObj) {
                    $script:OperationScope.Type = "Host"
                    $script:OperationScope.Name = $hostObj.Name
                    $script:OperationScope.Hosts = @($hostObj)
                    $script:OperationScope.Cluster = $null
                    
                    Write-Status -Type Success -Message "Scope set to host" -Detail $hostObj.Name
                } else {
                    Write-Status -Type Error -Message "Failed to get host information"
                }
                Pause
                return
            }
            
            # Cluster selection for vCenter
            $clusters = Get-Cluster | Sort-Object Name -ErrorAction SilentlyContinue
            if (-not $clusters -or $clusters.Count -eq 0) {
                Write-Status -Type Error -Message "No clusters found in vCenter!"
                Write-Status -Type Info -Message "Use 'All Hosts in vCenter' instead."
                Pause
                return
            }
            
            Clear-Host
            Write-Host "=== Select Cluster ===" -ForegroundColor $script:Theme.Header
            Write-Host "Available clusters:" -ForegroundColor $script:Theme.MenuOption
            
            for ($i = 0; $i -lt $clusters.Count; $i++) {
                $hostCount = ($clusters[$i] | Get-VMHost -ErrorAction SilentlyContinue).Count
                $connectionStates = ($clusters[$i] | Get-VMHost -ErrorAction SilentlyContinue | Group-Object ConnectionState | 
                    ForEach-Object { "$($_.Name):$($_.Count)" }) -join ", "
                
                Write-Host "$($i+1). $($clusters[$i].Name)" -ForegroundColor $script:Theme.MenuOption
                Write-Host "    Hosts: $hostCount | $connectionStates" -ForegroundColor $script:Theme.Disabled
            }
            
            Write-Host "`nC. Cancel"
            
            $clusterChoice = Read-Host "`nSelect cluster (1-$($clusters.Count)) or C to cancel"
            
            if ($clusterChoice -eq "C") { 
                Write-Status -Type Info -Message "Cluster selection cancelled"
                Pause
                return 
            }
            
            $selectedIndex = [int]$clusterChoice - 1
            if ($selectedIndex -ge 0 -and $selectedIndex -lt $clusters.Count) {
                $selectedCluster = $clusters[$selectedIndex]
                $clusterHosts = Get-VMHost -Cluster $selectedCluster -ErrorAction SilentlyContinue
                
                if (-not $clusterHosts -or $clusterHosts.Count -eq 0) {
                    Write-Status -Type Warning -Message "No hosts found in cluster" -Detail $selectedCluster.Name
                    Pause
                    return
                }
                
                $script:OperationScope.Type = "Cluster"
                $script:OperationScope.Name = $selectedCluster.Name
                $script:OperationScope.Hosts = $clusterHosts
                $script:OperationScope.Cluster = $selectedCluster
                
                Write-Status -Type Success -Message "Scope set to cluster" -Detail $selectedCluster.Name
                Write-Status -Type Info -Message "Hosts in scope" -Detail "$($clusterHosts.Count) ($(($clusterHosts | Where-Object { $_.ConnectionState -eq "Connected" }).Count) connected)"
                Pause
            } else {
                Write-Status -Type Error -Message "Invalid selection"
                Pause
            }
        }
        
        "2" {
            # All hosts in vCenter
            if ($script:connectionType -ne "vCenter") {
                Write-Status -Type Error -Message "This option requires vCenter connection"
                Pause
                return
            }
            
            $allHosts = Get-VMHost | Sort-Object Name -ErrorAction SilentlyContinue
            
            if (-not $allHosts -or $allHosts.Count -eq 0) {
                Write-Status -Type Error -Message "No hosts found in vCenter!"
                Pause
                return
            }
            
            $script:OperationScope.Type = "vCenterAll"
            $script:OperationScope.Name = "All Hosts in vCenter"
            $script:OperationScope.Hosts = $allHosts
            $script:OperationScope.Cluster = $null
            
            Write-Status -Type Success -Message "Scope set to all hosts in vCenter"
            
            # Show summary
            $connectedCount = ($allHosts | Where-Object { $_.ConnectionState -eq "Connected" }).Count
            $disconnectedCount = ($allHosts | Where-Object { $_.ConnectionState -eq "Disconnected" }).Count
            
            if ($connectedCount -gt 0) {
                Write-Status -Type Info -Message "Connected hosts" -Detail $connectedCount
            }
            if ($disconnectedCount -gt 0) {
                Write-Status -Type Warning -Message "Disconnected hosts" -Detail $disconnectedCount
            }
            
            Pause
        }
        
        "3" {
            # Single host selection (vCenter only)
            if ($script:connectionType -ne "vCenter") {
                Write-Status -Type Info -Message "Already on standalone host" -Detail "Scope automatically set to current host"
                Pause
                return
            }
            
            $allHosts = Get-VMHost | Sort-Object Name -ErrorAction SilentlyContinue
            
            if (-not $allHosts -or $allHosts.Count -eq 0) {
                Write-Status -Type Error -Message "No hosts found!"
                Pause
                return
            }
            
            Clear-Host
            Write-Host "=== Select Single Host ===" -ForegroundColor $script:Theme.Header
            
            # Show hosts in pages of 20
            $pageSize = 20
            $totalPages = [math]::Ceiling($allHosts.Count / $pageSize)
            $currentPage = 1
            
            while ($true) {
                $startIndex = ($currentPage - 1) * $pageSize
                $endIndex = [math]::Min($startIndex + $pageSize - 1, $allHosts.Count - 1)
                
                Write-Host "`nHosts $($startIndex+1)-$($endIndex+1) of $($allHosts.Count):" -ForegroundColor $script:Theme.MenuOption
                
                for ($i = $startIndex; $i -le $endIndex; $i++) {
                    $hostNum = $i + 1
                    $hostName = $allHosts[$i].Name
                    $status = $allHosts[$i].ConnectionState
                    $color = if ($status -eq "Connected") { $script:Theme.Success } else { $script:Theme.Error }
                    
                    Write-Host "$hostNum. $hostName" -ForegroundColor $color
                }
                
                Write-Host "`nCommands:" -ForegroundColor $script:Theme.Info
                if ($currentPage -gt 1) { Write-Host "  P - Previous page" -ForegroundColor $script:Theme.MenuOption }
                if ($currentPage -lt $totalPages) { Write-Host "  N - Next page" -ForegroundColor $script:Theme.MenuOption }
                Write-Host "  C - Cancel" -ForegroundColor $script:Theme.MenuOption
                
                $input = Read-Host "`nSelect host number or command"
                
                if ($input -eq "N" -and $currentPage -lt $totalPages) {
                    $currentPage++
                    Clear-Host
                    continue
                } elseif ($input -eq "P" -and $currentPage -gt 1) {
                    $currentPage--
                    Clear-Host
                    continue
                } elseif ($input -eq "C") {
                    Write-Status -Type Info -Message "Host selection cancelled"
                    Pause
                    return
                } elseif ($input -match '^\d+$') {
                    $selectedIndex = [int]$input - 1
                    if ($selectedIndex -ge 0 -and $selectedIndex -lt $allHosts.Count) {
                        $selectedHost = $allHosts[$selectedIndex]
                        
                        $script:OperationScope.Type = "Host"
                        $script:OperationScope.Name = $selectedHost.Name
                        $script:OperationScope.Hosts = @($selectedHost)
                        $script:OperationScope.Cluster = $null
                        
                        Write-Status -Type Success -Message "Scope set to host" -Detail $selectedHost.Name
                        Pause
                        return
                    }
                }
                
                Write-Status -Type Error -Message "Invalid selection. Try again."
                Start-Sleep -Milliseconds 500
                Clear-Host
            }
        }
        
        default {
            Write-Status -Type Warning -Message "Invalid selection, scope unchanged"
            Pause
        }
    }
}

function Test-CurrentScope {
    <#
    .SYNOPSIS
        Validates the current scope for an operation.
    .PARAMETER AllowedTypes
        Array of allowed scope types.
    .PARAMETER MinHosts
        Minimum number of hosts required.
    .PARAMETER MaxHosts
        Maximum number of hosts allowed.
    .PARAMETER RequireConnectedHosts
        Whether all hosts must be connected.
    .RETURNS
        Boolean indicating if scope is valid for the operation.
    #>
    param(
        [string[]]$AllowedTypes = @("Cluster", "vCenterAll", "Host"),
        [int]$MinHosts = 1,
        [int]$MaxHosts = [int]::MaxValue,
        [switch]$RequireConnectedHosts = $true
    )
    
    # Check if scope is set
    if ($script:OperationScope.Type -eq "Undefined" -or $null -eq $script:OperationScope.Hosts) {
        Write-Status -Type Error -Message "Scope not set" -Detail "Use option 5 to set operation scope first"
        return $false
    }
    
    # Check if scope type is allowed
    if ($AllowedTypes -notcontains $script:OperationScope.Type) {
        Write-Status -Type Error -Message "Operation not available for scope type: $($script:OperationScope.Type)"
        Write-Status -Type Info -Message "Allowed scope types: $($AllowedTypes -join ', ')"
        return $false
    }
    
    # Check host count
    $hostCount = $script:OperationScope.Hosts.Count
    if ($hostCount -lt $MinHosts) {
        Write-Status -Type Error -Message "Operation requires at least $MinHosts host(s). Current scope has $hostCount."
        return $false
    }
    
    if ($hostCount -gt $MaxHosts) {
        Write-Status -Type Error -Message "Operation supports maximum $MaxHosts host(s). Current scope has $hostCount."
        return $false
    }
    
    # Check connectivity if required
    if ($RequireConnectedHosts) {
        $connectedCount = ($script:OperationScope.Hosts | Where-Object { $_.ConnectionState -eq "Connected" }).Count
        if ($connectedCount -eq 0) {
            Write-Status -Type Error -Message "No connected hosts in current scope!"
            return $false
        } elseif ($connectedCount -lt $hostCount) {
            Write-Status -Type Warning -Message "Only $connectedCount of $hostCount hosts are connected."
            $confirm = Read-HostPrompt -Message "Continue anyway?" -Type YesNo -Default 'N'
            if ($confirm -ne "Y") { return $false }
        }
    }
    
    return $true
}

function Invoke-ScopedOperation {
    <#
    .SYNOPSIS
        Executes an operation on all hosts in the current scope.
    .PARAMETER Operation
        ScriptBlock containing the operation to execute.
    .PARAMETER OperationName
        Name of the operation for display purposes.
    .PARAMETER AllowedScopeTypes
        Array of allowed scope types for this operation.
    .PARAMETER ConfirmOperation
        Whether to show confirmation prompt.
    .PARAMETER ShowSummary
        Whether to show operation summary.
    .RETURNS
        Array of operation results.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ScriptBlock]$Operation,
        
        [Parameter(Mandatory=$false)]
        [string]$OperationName = "Operation",
        
        [Parameter(Mandatory=$false)]
        [string[]]$AllowedScopeTypes = @("Cluster", "vCenterAll", "Host"),
        
        [Parameter(Mandatory=$false)]
        [switch]$ConfirmOperation = $true,
        
        [Parameter(Mandatory=$false)]
        [switch]$ShowSummary = $true
    )
    
    # Validate scope
    if (-not (Test-CurrentScope -AllowedTypes $AllowedScopeTypes)) {
        return $null
    }
    
    # Confirmation for potentially dangerous operations
    if ($ConfirmOperation) {
        Write-Host ""
        Write-Host "Operation: $OperationName" -ForegroundColor $script:Theme.Header
        Write-Host "Scope: $($script:OperationScope.Type) - $($script:OperationScope.Name)" -ForegroundColor $script:Theme.MenuOption
        Write-Host "Hosts: $($script:OperationScope.Hosts.Count)" -ForegroundColor $script:Theme.MenuOption
        
        $confirm = Read-HostPrompt -Message "`nConfirm execution?" -Type YesNo -Default 'Y'
        if ($confirm -ne "Y") {
            Write-Status -Type Warning -Message "Operation cancelled"
            return $null
        }
    }
    
    # Execute operation
    $results = @()
    $hostCount = $script:OperationScope.Hosts.Count
    $i = 0
    
    Write-Host ""
    Write-Status -Type Info -Message "Executing $OperationName" -Detail "on $hostCount host(s)"
    
    foreach ($targetHost in $script:OperationScope.Hosts) {
        $i++
        $percent = [math]::Round(($i / $hostCount) * 100)
        
        Write-Progress -Activity $OperationName `
                      -Status "Processing $($targetHost.Name) ($i of $hostCount)" `
                      -PercentComplete $percent
        
        # Skip disconnected hosts
        if ($targetHost.ConnectionState -ne "Connected") {
            $results += @{
                Host = $targetHost.Name
                Success = $false
                Result = $null
                Error = "Host is disconnected"
                Skipped = $true
            }
            Write-Status -Type Warning -Message "Skipped" -Detail "$($targetHost.Name) (disconnected)"
            continue
        }
        
        # Execute operation
        try {
            $result = & $Operation -TargetHost $targetHost
            $results += @{
                Host = $targetHost.Name
                Success = $true
                Result = $result
                Error = $null
                Skipped = $false
            }
            Write-Status -Type Success -Message "Success" -Detail $targetHost.Name
        }
        catch {
            $results += @{
                Host = $targetHost.Name
                Success = $false
                Result = $null
                Error = $_.Exception.Message
                Skipped = $false
            }
            Write-Status -Type Error -Message "Failed" -Detail "$($targetHost.Name): $($_.Exception.Message)"
        }
    }
    
    Write-Progress -Activity $OperationName -Completed
    
    # Show summary if requested
    if ($ShowSummary) {
        $successCount = ($results | Where-Object { $_.Success }).Count
        $failedItems = $results | Where-Object { -not $_.Success } | ForEach-Object {
            @{ Name = $_.Host; Error = $_.Error }
        }
        
        Show-BatchSummary -Operation $OperationName -Total $hostCount -SuccessCount $successCount -FailedItems $failedItems
    }
    
    return $results
}

function Get-TargetHostsFromScope {
    <#
    .SYNOPSIS
        Returns hosts based on current scope.
    .RETURNS
        Array of VMHost objects.
    #>
    if ($script:OperationScope.Type -eq "Undefined") {
        Write-Status -Type Error -Message "Scope not set" -Detail "Use option 5 to set operation scope"
        return @()
    }
    
    return $script:OperationScope.Hosts
}
#endregion

function Write-MenuOption {
    <#
    .SYNOPSIS
        Writes a menu option with proper formatting.
    #>
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

function Show-Menu {
    <#
    .SYNOPSIS
        Displays the main menu with current status and scope information.
    #>
    
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
    
    # Check if scope is valid for operations
    $scopeValid = $isConnected -and $script:OperationScope.Type -ne "Undefined" -and $script:OperationScope.Hosts.Count -gt 0
    $scopeForClusterOps = $scopeValid -and ($script:OperationScope.Type -in @("Cluster", "vCenterAll"))
    
    # Header with scope info
    Clear-Host
    Write-Host "+===============================================================+" -ForegroundColor $script:Theme.Header
    Write-Host "|           ESXi Management Tool v2.1 (Simplified Scope)        |" -ForegroundColor $script:Theme.Title
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
        Write-Host "|  vCenter: $script:vCenterServer" -ForegroundColor $script:Theme.Info
    }

    # Scope information
    Write-Host "|  Scope: " -NoNewline -ForegroundColor $script:Theme.Header
    if ($scopeValid) {
        $scopeColor = if ($script:OperationScope.Type -eq "Cluster") { $script:Theme.Success } else { $script:Theme.Info }
        Write-Host "$($script:OperationScope.Type): $($script:OperationScope.Name)" -ForegroundColor $scopeColor
        Write-Host "|          Hosts: $($script:OperationScope.Hosts.Count)" -ForegroundColor $script:Theme.MenuOption
        
        # Show connection status
        $connectedCount = ($script:OperationScope.Hosts | Where-Object { $_.ConnectionState -eq "Connected" }).Count
        if ($connectedCount -lt $script:OperationScope.Hosts.Count) {
            Write-Host "|          Status: $connectedCount/$($script:OperationScope.Hosts.Count) connected" -ForegroundColor $script:Theme.Warning
        }
    } else {
        Write-Host "Not set (use option 5)" -ForegroundColor $script:Theme.Warning
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
    Write-Host "|  Operations 6-21 use current scope: $($script:OperationScope.Type)" -ForegroundColor $script:Theme.Info
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header

    # Connection section
    Write-Host ""
    Write-Host "-- Connection -----------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "1" "Connect to vCenter/ESXi"
    Write-MenuOption "2" "Disconnect" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "3" "Set/Reset Credentials"

    # Scope section
    Write-Host ""
    Write-Host "-- Scope Management -----------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "4" "Set Operation Scope [Current: $($script:OperationScope.Type)]" -Enabled $isConnected -DisabledReason "Not connected"

    # SSH Management
    Write-Host ""
    Write-Host "-- SSH Management -------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "5" "Start SSH on scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })
    Write-MenuOption "6" "Stop SSH on scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })

    # ESXi CLI Operations
    Write-Host ""
    Write-Host "-- ESXi CLI Operations --------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "7" "Run ESXCLI command on scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })
    Write-MenuOption "8" "Reboot scope hosts (with confirmation)" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })
    Write-MenuOption "9" "Run ESXCLI command on single host (prompts for host)" -Enabled $isConnected -DisabledReason "Not connected"

    # File Transfer
    Write-Host ""
    Write-Host "-- File Transfer --------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "10" "SCP file to single host (prompts for host)" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "11" "SCP file to scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })

    # Driver/VIB Management
    Write-Host ""
    Write-Host "-- Driver/VIB Management ------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "12" "Install VIB on single host" -Enabled $isConnected -DisabledReason "Not connected"
    Write-MenuOption "13" "Install Mellanox driver on scope hosts" -Enabled $scopeForClusterOps -DisabledReason $(if (-not $scopeForClusterOps) { "Cluster/vCenterAll scope required" })

    # SSH Commands
    Write-Host ""
    Write-Host "-- SSH Commands ---------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "14" "Execute SSH command on scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })
    Write-MenuOption "15" "View active SSH sessions"
    Write-MenuOption "16" "Disconnect SSH session"

    # RDMA/Network
    Write-Host ""
    Write-Host "-- RDMA/Network ---------------------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "17" "Configure RDMA parameters on scope hosts" -Enabled $scopeForClusterOps -DisabledReason $(if (-not $scopeForClusterOps) { "Cluster/vCenterAll scope required" })
    Write-MenuOption "18" "Check DCBX status on scope hosts" -Enabled $scopeForClusterOps -DisabledReason $(if (-not $scopeForClusterOps) { "Cluster/vCenterAll scope required" })

    # IPMI/Custom Attributes
    Write-Host ""
    Write-Host "-- IPMI/Custom Attributes -----------------------------------------" -ForegroundColor $script:Theme.Title
    Write-MenuOption "19" "Get IPMI BMC Addresses from scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })
    Write-MenuOption "20" "Set Custom Attribute on scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })
    Write-MenuOption "21" "Set Custom Attribute from IPMI on scope hosts" -Enabled $scopeValid -DisabledReason $(if (-not $scopeValid) { "Set scope first" })

    # Exit
    Write-Host ""
    Write-Host "   0. Exit" -ForegroundColor $script:Theme.Error
    Write-Host ""
    Write-Host "+===============================================================+`r" -ForegroundColor $script:Theme.Header
}

#region Connection and Credential Functions
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
    if (-not $script:connected) { return $false }

    # Primary detection – try to get at least one cluster
    try {
        $clusters = Get-Cluster -ErrorAction SilentlyContinue
        if ($null -ne $clusters -and $clusters.Count -gt 0) {
            return $true   # definitely a vCenter
        }
    } catch {
        # ignore – fall through to fallback detection
    }

    # Fallback detection – inspect the API type of the connected server
    try {
        $apiType = $global:DefaultVIServer.ExtensionData.Content.About.ApiType
        return ($apiType -eq 'VirtualCenter')
    } catch {
        return $false
    }
}

function Connect-And-SetDefaultScope {
    # Get connection type
    Write-Host ""
    Write-Host "Select connection type:" -ForegroundColor $script:Theme.Title
    Write-Host "  1. vCenter Server" -ForegroundColor $script:Theme.MenuOption
    Write-Host "  2. Standalone ESXi Host" -ForegroundColor $script:Theme.MenuOption
    $connType = Read-HostPrompt -Message "Enter choice (1-2)" -Default "1"
    
    if ($connType -eq "1") {
        Connect-ToVCenter
    } else {
        Connect-ToStandaloneESXi
    }
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
        Write-Status -Type Processing -Message "Connecting to vCenter" -Detail $vCenter
        Connect-VIServer $vCenter -Credential $vCenterCreds -Force -ErrorAction Stop
        $script:vCenterServer = $vCenter
        $script:connected = $true
        $script:connectionType = "vCenter"

        # Get all hosts and clusters for smart scope selection
        $allHosts = Get-VMHost | Sort-Object Name -ErrorAction SilentlyContinue
        $clusters = Get-Cluster | Sort-Object Name -ErrorAction SilentlyContinue
        
        # Set smart default scope
        if ($clusters -and $clusters.Count -gt 0) {
            # Default to first cluster
            $defaultCluster = $clusters[0]
            $clusterHosts = Get-VMHost -Cluster $defaultCluster -ErrorAction SilentlyContinue
            
            $script:OperationScope.Type = "Cluster"
            $script:OperationScope.Name = $defaultCluster.Name
            $script:OperationScope.Hosts = $clusterHosts
            $script:OperationScope.Cluster = $defaultCluster
            
            Write-Status -Type Success -Message "Connected to vCenter" -Detail $vCenter
            Write-Status -Type Info -Message "Default scope set to cluster" -Detail "$($defaultCluster.Name) ($($clusterHosts.Count) hosts)"
            
        } elseif ($allHosts -and $allHosts.Count -gt 0) {
            # No clusters, use all hosts
            $script:OperationScope.Type = "vCenterAll"
            $script:OperationScope.Name = "All Hosts in vCenter"
            $script:OperationScope.Hosts = $allHosts
            $script:OperationScope.Cluster = $null
            
            Write-Status -Type Success -Message "Connected to vCenter" -Detail $vCenter
            Write-Status -Type Info -Message "Default scope set to all hosts" -Detail "$($allHosts.Count) hosts"
            
        } else {
            # Empty vCenter
            $script:OperationScope.Type = "Undefined"
            Write-Status -Type Success -Message "Connected to vCenter" -Detail $vCenter
            Write-Status -Type Warning -Message "No hosts found. Please set scope manually."
        }
    }
    catch {
        Write-Status -Type Error -Message "Failed to connect" -Detail $_
        $script:connected = $false
        $script:connectionType = $null
        $script:OperationScope.Type = "Undefined"
        $script:OperationScope.Name = $null
        $script:OperationScope.Hosts = @()
        $script:OperationScope.Cluster = $null
    }
    Pause
}

function Connect-ToStandaloneESXi {
    $hostName = Get-VCenterName
    if ($null -eq $hostName) {
        Pause
        return
    }

    # Get host credentials (use cache if available)
    $hostCreds = Get-VCenterCredentials
    if ($null -eq $hostCreds) {
        Write-Status -Type Warning -Message "Connection cancelled"
        Pause
        return
    }

    try {
        Write-Status -Type Processing -Message "Connecting to ESXi host" -Detail $hostName
        Connect-VIServer $hostName -Credential $hostCreds -Force -ErrorAction Stop
        $script:vCenterServer = $hostName
        $script:connected = $true
        $script:connectionType = "Standalone"

        # Get host object and set scope
        $hostObj = Get-VMHost -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hostObj) {
            $script:OperationScope.Type = "Host"
            $script:OperationScope.Name = $hostObj.Name
            $script:OperationScope.Hosts = @($hostObj)
            $script:OperationScope.Cluster = $null
            
            Write-Status -Type Success -Message "Connected to standalone ESXi host" -Detail $hostObj.Name
            Write-Status -Type Info -Message "Scope automatically set to host" -Detail $hostObj.Name
        } else {
            $script:OperationScope.Type = "Host"
            $script:OperationScope.Name = $hostName
            $script:OperationScope.Hosts = @()
            $script:OperationScope.Cluster = $null
            
            Write-Status -Type Success -Message "Connected to standalone ESXi host" -Detail $hostName
            Write-Status -Type Warning -Message "Could not retrieve host details"
        }
    }
    catch {
        Write-Status -Type Error -Message "Failed to connect" -Detail $_
        $script:connected = $false
        $script:connectionType = $null
        $script:OperationScope.Type = "Undefined"
        $script:OperationScope.Name = $null
        $script:OperationScope.Hosts = @()
        $script:OperationScope.Cluster = $null
    }
    Pause
}

function Disconnect-FromVCenter {
    try {
        Write-Status -Type Processing -Message "Disconnecting from $script:vCenterServer"
        Disconnect-VIServer $script:vCenterServer -Confirm:$false -ErrorAction Stop
        $script:connected = $false
        $script:connectionType = $null
        
        # Reset scope
        $script:OperationScope.Type = "Undefined"
        $script:OperationScope.Name = $null
        $script:OperationScope.Hosts = @()
        $script:OperationScope.Cluster = $null
        
        Write-Status -Type Success -Message "Disconnected successfully"
    }
    catch {
        Write-Status -Type Error -Message "Failed to disconnect" -Detail $_
    }
    Pause
}
#endregion

#region Operation Functions
function Start-ClusterSSH {
    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        Get-VMHost -Name $TargetHost.Name | Get-VMHostService |
            Where-Object Key -EQ "TSM-SSH" | Start-VMHostService -Confirm:$false | Out-Null
    } -OperationName "Start SSH" -AllowedScopeTypes @("Cluster", "vCenterAll", "Host")
    
    Pause
}

function Stop-ClusterSSH {
    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        Get-VMHost -Name $TargetHost.Name | Get-VMHostService |
            Where-Object Key -EQ "TSM-SSH" | Stop-VMHostService -Confirm:$false | Out-Null
    } -OperationName "Stop SSH" -AllowedScopeTypes @("Cluster", "vCenterAll", "Host")
    
    Pause
}

function Invoke-ESXCliOnCluster {
    $uuid = Read-HostPrompt -Message "Enter UUID for vsan.debug.object.list"
    if ([string]::IsNullOrWhiteSpace($uuid)) {
        Write-Status -Type Error -Message "UUID is required"
        Pause
        return
    }

    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        $esxcli = Get-EsxCli -v2 -VMHost $TargetHost.Name
        $esxcli.vsan.debug.object.list.invoke(@{uuid = $uuid })
    } -OperationName "ESXCli on Cluster" -AllowedScopeTypes @("Cluster", "vCenterAll")
    
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
    # Get host count for warning message
    $hosts = Get-TargetHostsFromScope
    if ($hosts.Count -eq 0) {
        Write-Status -Type Error -Message "No hosts in current scope"
        Pause
        return
    }
    
    $hostCount = $hosts.Count

    $confirmed = Show-ConfirmationBox `
        -Title "REBOOT ALL HOSTS IN SCOPE" `
        -Message "This will reboot ALL hosts in current scope: $($script:OperationScope.Type) - $($script:OperationScope.Name)" `
        -Detail "Affected hosts: $hostCount"

    if (-not $confirmed) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    $reason = Read-HostPrompt -Message "Enter reboot reason" -Default "Scheduled maintenance"

    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        $esxcli = Get-EsxCli -v2 -VMHost $TargetHost.Name
        $esxcli.system.shutdown.reboot.invoke(@{reason = $reason })
    } -OperationName "Reboot Hosts" -AllowedScopeTypes @("Cluster", "vCenterAll") -ConfirmOperation:$false
    
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

    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        # Check SSH before copying
        $sshOk = Ensure-SSH -HostName $TargetHost.Name
        if (-not $sshOk) {
            throw "SSH not running on host"
        }
        
        Set-SCPItem -ComputerName $TargetHost.Name -Credential $hostCreds `
            -Path $sourcePath -Destination $destination
    } -OperationName "SCP File to Cluster" -AllowedScopeTypes @("Cluster", "vCenterAll")
    
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

    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        & $scriptPath -sshHost $TargetHost.Name
    } -OperationName "Install Mellanox Driver" -AllowedScopeTypes @("Cluster", "vCenterAll")
    
    Pause
}

function Invoke-SSHOnCluster {
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

    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        $session = New-SSHSession -ComputerName $TargetHost.Name -Credential $hostCreds
        $result = Invoke-SSHCommand -Command $command -SessionId $session.SessionId
        Remove-SSHSession -SessionId $session.SessionId | Out-Null
        return $result.Output
    } -OperationName "SSH Command on Cluster" -AllowedScopeTypes @("Cluster", "vCenterAll", "Host") -ShowSummary:$false
    
    # Show individual results
    Write-Host ""
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
    Write-Host "|  SSH Command Results                                         |" -ForegroundColor $script:Theme.Title
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header
    
    foreach ($result in $operationResults) {
        Write-Host ""
        Write-Host "Host: $($result.Host)" -ForegroundColor $script:Theme.Info
        if ($result.Success) {
            Write-Host "Output:" -ForegroundColor $script:Theme.Success
            Write-Host $result.Result
        } else {
            Write-Status -Type Error -Message "Failed" -Detail $result.Error
        }
    }
    
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header
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
    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        $esxcli = Get-EsxCli -v2 -VMHost $TargetHost.Name
        $esxcli.system.module.parameters.set.invoke(@{module = "nmlx5_core"; parameterstring = "dcbx=1" })
        $esxcli.system.module.parameters.set.invoke(@{module = "nmlx5_core"; parameterstring = "pfctx=8 pfcrx=8 trust_state=2 max_vfs=4" })
        $esxcli.system.module.parameters.set.invoke(@{module = "nmlx5_rdma"; parameterstring = "pcp_force=3 dscp_force=26" })
    } -OperationName "Configure RDMA Parameters" -AllowedScopeTypes @("Cluster", "vCenterAll")
    
    Pause
}

function Get-DCBXStatus {
    $nicName = Read-HostPrompt -Message "Enter NIC name (e.g., vmnic4)" -Default "vmnic4"

    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        $esxcli = Get-EsxCli -v2 -VMHost $TargetHost.Name
        $esxcli.network.nic.dcb.status.get.invoke(@{nicname = $nicName })
    } -OperationName "Check DCBX Status" -AllowedScopeTypes @("Cluster", "vCenterAll") -ShowSummary:$false
    
    # Show individual results
    Write-Host ""
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
    Write-Host "|  DCBX Status Results                                         |" -ForegroundColor $script:Theme.Title
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header
    
    foreach ($result in $operationResults) {
        Write-Host ""
        Write-Host "Host: $($result.Host)" -ForegroundColor $script:Theme.Info
        if ($result.Success) {
            Write-Host "Status:" -ForegroundColor $script:Theme.Success
            Write-Host $result.Result
        } else {
            Write-Status -Type Error -Message "Failed" -Detail $result.Error
        }
    }
    
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header
    Pause
}

function Get-ClusterIPMI {
    $operationResults = Invoke-ScopedOperation -Operation {
        param($TargetHost)
        $esxcli = Get-EsxCli -v2 -VMHost $TargetHost.Name
        $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
        $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address }
        elseif ($bmcInfo.IP) { $bmcInfo.IP }
        else { "N/A" }
        
        return $ipv4
    } -OperationName "Get IPMI BMC Addresses" -AllowedScopeTypes @("Cluster", "vCenterAll", "Host") -ShowSummary:$false
    
    # Format results as table
    $results = @()
    foreach ($result in $operationResults) {
        $results += [pscustomobject]@{
            HostName = $result.Host
            IPMI_Address = if ($result.Success) { $result.Result } else { "Error: $($result.Error)" }
            Status = if ($result.Success) { "Success" } else { "Failed" }
        }
    }
    
    Write-Host ""
    Show-FormattedTable -Data $results -Columns @('HostName', 'IPMI_Address', 'Status') -ColumnWidths @{
        HostName = 30
        IPMI_Address = 20
        Status = 10
    }
    Pause
}

function Set-HostCustomAttribute {
    # Since we need to prompt for values, handle this differently
    Write-Host ""
    Write-Host "Set Custom Attribute for current scope" -ForegroundColor $script:Theme.Header
    Write-Host "Scope: $($script:OperationScope.Type) - $($script:OperationScope.Name)" -ForegroundColor $script:Theme.MenuOption
    Write-Host "Hosts: $($script:OperationScope.Hosts.Count)" -ForegroundColor $script:Theme.MenuOption
    
    $attrName = Read-HostPrompt -Message "Enter custom attribute name" -Default "ManagementIP"
    $attrValue = Read-HostPrompt -Message "Enter attribute value"
    
    if ([string]::IsNullOrWhiteSpace($attrValue)) {
        Write-Status -Type Error -Message "Attribute value is required"
        Pause
        return
    }
    
    $confirm = Read-HostPrompt -Message "Set '$attrName' = '$attrValue' on $($script:OperationScope.Hosts.Count) hosts?" -Type YesNo -Default 'N'
    if (-not $confirm) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }
    
    # Create attribute if needed
    $attr = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
    if (-not $attr) {
        try {
            New-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction Stop | Out-Null
            Write-Status -Type Info -Message "Created new custom attribute" -Detail $attrName
        }
        catch {
            Write-Status -Type Error -Message "Failed to create attribute" -Detail $_
            Pause
            return
        }
    }
    
    # Set attributes on all hosts in scope
    $total = $script:OperationScope.Hosts.Count
    $current = 0
    $successCount = 0
    $failedItems = @()
    
    foreach ($vmHost in $script:OperationScope.Hosts) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Set Attribute" -Current $current -Total $total -CurrentItem $hostName
        
        try {
            Set-Annotation -Entity $vmHost -CustomAttribute $attrName -Value $attrValue -Confirm:$false
            $successCount++
        }
        catch {
            $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
        }
    }
    
    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "Set Custom Attribute" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}

function Set-ClusterCustomAttributeFromIPMI {
    Write-Host ""
    Write-Host "Set Custom Attribute from IPMI for current scope" -ForegroundColor $script:Theme.Header
    Write-Host "Scope: $($script:OperationScope.Type) - $($script:OperationScope.Name)" -ForegroundColor $script:Theme.MenuOption
    Write-Host "Hosts: $($script:OperationScope.Hosts.Count)" -ForegroundColor $script:Theme.MenuOption
    
    $attrName = Read-HostPrompt -Message "Enter custom attribute name" -Default "ManagementIP"
    
    Write-Host ""
    Write-Host "+---------------------------------------------------------------+" -ForegroundColor $script:Theme.Header
    Write-Host "|  This operation will:" -ForegroundColor $script:Theme.Title
    Write-Host "|    1. Get IPMI BMC addresses for all hosts in scope" -ForegroundColor $script:Theme.Info
    Write-Host "|    2. Set '$attrName' custom attribute with IPMI IP" -ForegroundColor $script:Theme.Info
    Write-Host "|  Affected hosts: $($script:OperationScope.Hosts.Count)" -ForegroundColor $script:Theme.Info
    Write-Host "+---------------------------------------------------------------+`r" -ForegroundColor $script:Theme.Header

    $confirm = Read-HostPrompt -Message "Continue?" -Type YesNo -Default 'N'
    if (-not $confirm) {
        Write-Status -Type Warning -Message "Operation cancelled"
        Pause
        return
    }

    # Get IPMI addresses first
    Write-Status -Type Processing -Message "Retrieving IPMI addresses"
    $ipmiResults = @()
    $total = $script:OperationScope.Hosts.Count
    $current = 0
    
    foreach ($vmHost in $script:OperationScope.Hosts) {
        $current++
        $hostName = $vmHost.Name
        Show-BatchProgress -Operation "Get IPMI" -Current $current -Total $total -CurrentItem $hostName
        
        try {
            $esxcli = Get-EsxCli -v2 -VMHost $hostName
            $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
            $ipv4 = if ($bmcInfo.IPv4Address) { $bmcInfo.IPv4Address }
            elseif ($bmcInfo.IP) { $bmcInfo.IP }
            else { $null }
            
            $ipmiResults += [pscustomobject]@{
                Host = $hostName
                IPMI = $ipv4
            }
        }
        catch {
            $ipmiResults += [pscustomobject]@{
                Host = $hostName
                IPMI = $null
            }
        }
    }
    
    Write-Host ""  # Clear progress line
    
    # Create attribute if needed
    $attr = Get-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction SilentlyContinue
    if (-not $attr) {
        try {
            New-CustomAttribute -Name $attrName -TargetType VMHost -ErrorAction Stop | Out-Null
            Write-Status -Type Info -Message "Created new custom attribute" -Detail $attrName
        }
        catch {
            Write-Status -Type Error -Message "Failed to create attribute" -Detail $_
            Pause
            return
        }
    }
    
    # Set attributes
    Write-Status -Type Processing -Message "Setting custom attributes"
    $successCount = 0
    $failedItems = @()
    
    $current = 0
    foreach ($item in $ipmiResults) {
        $current++
        $hostName = $item.Host
        Show-BatchProgress -Operation "Set Attribute" -Current $current -Total $total -CurrentItem $hostName
        
        if ($item.IPMI) {
            try {
                $esxi = Get-VMHost -Name $hostName -ErrorAction Stop
                Set-Annotation -Entity $esxi -CustomAttribute $attrName -Value $item.IPMI -Confirm:$false
                $successCount++
            }
            catch {
                $failedItems += @{ Name = $hostName; Error = $_.Exception.Message }
            }
        }
        else {
            $failedItems += @{ Name = $hostName; Error = "No IPMI address found" }
        }
    }
    
    Write-Host ""  # Clear progress line
    Show-BatchSummary -Operation "Set Custom Attribute from IPMI" -Total $total -SuccessCount $successCount -FailedItems $failedItems
    Pause
}
#endregion

# Helper function to check vCenter requirement
function Test-ConnectionRequired {
    if (-not $script:connected) {
        Write-Status -Type Error -Message "This option requires a connection" -Detail "Use option 1 to connect first"
        Pause
        return $false
    }
    return $true
}

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
                Connect-And-SetDefaultScope
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
        "3" { 
            if ($script:connected -and $script:connectionType -eq "vCenter") {
                Set-VCenterCredentials 
            } else {
                Set-ESXiHostCredentials
            }
        }
        "4" { if (Test-ConnectionRequired) { Show-SimplifiedScopeMenu } }
        "5" { if (Test-ConnectionRequired) { Start-ClusterSSH } }
        "6" { if (Test-ConnectionRequired) { Stop-ClusterSSH } }
        "7" { if (Test-ConnectionRequired) { Invoke-ESXCliOnCluster } }
        "8" { if (Test-ConnectionRequired) { Invoke-ESXCliOnHost } }
        "9" { if (Test-ConnectionRequired) { Restart-ClusterHosts } }
        "10" { if (Test-ConnectionRequired) { Copy-FileToHost } }
        "11" { if (Test-ConnectionRequired) { Copy-FileToCluster } }
        "12" { if (Test-ConnectionRequired) { Install-VIBOnHost } }
        "13" { if (Test-ConnectionRequired) { Install-MellanoxDriver } }
        "14" { if (Test-ConnectionRequired) { Invoke-SSHOnCluster } }
        "15" { Show-SSHSessions }
        "16" { Remove-SSHSessionById }
        "17" { if (Test-ConnectionRequired) { Set-RDMAParameters } }
        "18" { if (Test-ConnectionRequired) { Get-DCBXStatus } }
        "19" { if (Test-ConnectionRequired) { Get-ClusterIPMI } }
        "20" { if (Test-ConnectionRequired) { Set-HostCustomAttribute } }
        "21" { if (Test-ConnectionRequired) { Set-ClusterCustomAttributeFromIPMI } }
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