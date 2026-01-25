<# 
.SYNOPSIS
    Sets (or creates) a custom attribute on an ESXi host and assigns the host's IP address to it.
.DESCRIPTION
    The script can be called with explicit parameters or can accept objects from the pipeline that
    contain the properties Hostname, IPaddress (or IPv4Address) and CustomAttributeName. It connects 
    to a vCenter server (or an ESXi host directly), verifies/creates the custom attribute, and then 
    stores the supplied IP address in that attribute.
.PARAMETER Hostname
    The DNS name (or IP) of the ESXi host to target.
.PARAMETER IPaddress
    The IP address you want to store in the custom attribute. Cannot be 0.0.0.0 or empty.
.PARAMETER CustomAttributeName
    The name of the custom attribute to create/modify (e.g. "ManagementIP").
.PARAMETER VCenter
    vCenter/ESXi server to connect to. If omitted, the script will use the current PowerCLI
    session (Connect-VIServer must have been called beforehand).
.PARAMETER Credential
    PSCredential object for authentication. If omitted when -VCenter is specified, you will
    be prompted for credentials.
.EXAMPLE
    # Default behavior - prompts for confirmation (safe)
    .\Set-EsxiCustomAttribute.ps1 -Hostname esxi01.domain.local `
                                 -IPaddress 10.0.1.25 `
                                 -CustomAttributeName "ManagementIP" `
                                 -VCenter vc01.domain.local
.EXAMPLE
    # Using stored credentials
    $cred = Get-Credential
    .\Set-EsxiCustomAttribute.ps1 -Hostname esxi01.domain.local `
                                 -IPaddress 10.0.1.25 `
                                 -CustomAttributeName "ManagementIP" `
                                 -VCenter vc01.domain.local `
                                 -Credential $cred
.EXAMPLE
    # Using pipeline input
    Get-Content hosts.csv | ConvertFrom-Csv |
        .\Set-EsxiCustomAttribute.ps1 -CustomAttributeName "ManagementIP"
    # hosts.csv example:
    # Hostname,IPv4Address
    # esxi01.domain.local,10.0.1.25
    # esxi02.domain.local,10.0.1.26
.EXAMPLE
    # Bypass all confirmation prompts (for automation/batch operations)
    .\Set-EsxiCustomAttribute.ps1 -Hostname esxi01.domain.local `
                                 -IPaddress 10.0.1.25 `
                                 -CustomAttributeName "ManagementIP" `
                                 -VCenter vc01.domain.local `
                                 -Confirm:$false
.EXAMPLE
    # Pipeline with no prompts (automation-friendly)
    $results | .\Set-EsxiCustomAttribute.ps1 -CustomAttributeName "ManagementIP" -Confirm:$false
.EXAMPLE
    # Dry-run to see what would happen
    .\Set-EsxiCustomAttribute.ps1 -Hostname esxi01.domain.local `
                                 -IPaddress 10.0.1.25 `
                                 -CustomAttributeName "ManagementIP" `
                                 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param (
    [Parameter(Mandatory=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$Hostname,

    [Parameter(Mandatory=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=1)]
    [Alias('IPv4Address')]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        # Validate proper IPv4 format with octet range 0-255
        if ($_ -match '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$') {
            # Exclude 0.0.0.0
            if ($_ -eq '0.0.0.0') {
                throw "IP address cannot be 0.0.0.0"
            }
            $true
        } else {
            throw "Invalid IPv4 address format: $_"
        }
    })]
    [string]$IPaddress,

    [Parameter(Mandatory=$true,
               ValueFromPipelineByPropertyName=$true,
               Position=2)]
    [ValidateNotNullOrEmpty()]
    [string]$CustomAttributeName,

    [Parameter(Mandatory=$false)]
    [string]$VCenter,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential
)

begin {
    # Ensure PowerCLI module is available
    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        Write-Error "VMware PowerCLI module not found. Install it with: Install-Module -Name VMware.PowerCLI -Scope CurrentUser"
        break
    }

    # Import the module if not already loaded
    if (-not (Get-Module -Name VMware.VimAutomation.Core)) {
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    }

    # Track whether we created a connection in this script
    $script:ConnectionCreated = $false

    # Handle vCenter connection
    if ($VCenter) {
        Write-Verbose "Connecting to vCenter: $VCenter"
        try {
            $connectParams = @{
                Server      = $VCenter
                ErrorAction = 'Stop'
            }
            
            if ($Credential) {
                $connectParams['Credential'] = $Credential
            }
            
            Connect-VIServer @connectParams | Out-Null
            $script:ConnectionCreated = $true
            Write-Verbose "Successfully connected to $VCenter"
        }
        catch {
            Write-Error "Failed to connect to vCenter '$VCenter': $_"
            break
        }
    }
    else {
        # Check if there's an active connection
        if (-not $global:DefaultVIServer) {
            Write-Error "No active vCenter connection found. Please use -VCenter parameter or run Connect-VIServer first."
            break
        }
        Write-Verbose "Using existing connection to: $($global:DefaultVIServer.Name)"
    }

    # Check if the custom attribute already exists globally
    $script:GlobalAttributeChecked = $false
}

process {
    try {
        Write-Verbose "Processing host: $Hostname with IP: $IPaddress"

        # Retrieve the VMHost object
        $esxi = Get-VMHost -Name $Hostname -ErrorAction Stop
        
        if (-not $esxi) {
            throw "Host '$Hostname' not found or not accessible."
        }

        Write-Verbose "Found ESXi host: $($esxi.Name)"

        # Check if the global custom attribute exists (only once)
        if (-not $script:GlobalAttributeChecked) {
            $globalAttr = Get-CustomAttribute -Name $CustomAttributeName -TargetType VMHost -ErrorAction SilentlyContinue
            
            if (-not $globalAttr) {
                # Attribute doesn't exist globally - create it
                if ($PSCmdlet.ShouldProcess(
                        "vCenter '$($global:DefaultVIServer.Name)'",
                        "Create global custom attribute '$CustomAttributeName' for VMHost")) {
                    
                    Write-Verbose "Creating global custom attribute '$CustomAttributeName' for VMHost objects..."
                    New-CustomAttribute -Name $CustomAttributeName -TargetType VMHost -ErrorAction Stop | Out-Null
                    Write-Host "✅ Global custom attribute '$CustomAttributeName' created." -ForegroundColor Green
                }
                else {
                    Write-Warning "Skipped creation of custom attribute '$CustomAttributeName'. Script will exit."
                    break
                }
            }
            else {
                Write-Verbose "Global custom attribute '$CustomAttributeName' already exists."
            }
            $script:GlobalAttributeChecked = $true
        }

        # Set the attribute value on the host
        if ($PSCmdlet.ShouldProcess(
                "ESXi host '$Hostname'",
                "Set custom attribute '$CustomAttributeName' to '$IPaddress'")) {
            
            Set-Annotation -Entity $esxi `
                          -CustomAttribute $CustomAttributeName `
                          -Value $IPaddress `
                          -Confirm:$false `
                          -ErrorAction Stop | Out-Null
            
            Write-Host "✅ Host '$Hostname' - attribute '$CustomAttributeName' set to '$IPaddress'" -ForegroundColor Green
        }
        else {
            Write-Warning "Skipped setting attribute for host '$Hostname'."
        }
    }
    catch {
        Write-Error "Failed to process host '$Hostname': $_"
    }
}

end {
    # Disconnect only if we created the connection in this script
    if ($script:ConnectionCreated -and $VCenter) {
        Write-Verbose "Disconnecting from $VCenter"
        Disconnect-VIServer -Server $VCenter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}