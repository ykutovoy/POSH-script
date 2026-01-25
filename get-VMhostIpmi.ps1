<#
.SYNOPSIS
    Retrieves the BMC (IPMI) IPv4 address for one or more ESXi hosts.
.DESCRIPTION
    The script connects to a vCenter server, optionally takes a single host name or a
    cluster name, and calls the vSphere API method **hardware.ipmi.bmc.get** for each
    host.  By default it returns a PowerShell object with two properties:
        - HostName
        - IPv4Address
    If the **-Json** switch is supplied the result is emitted as JSON.
    
    **If neither HostName nor ClusterName is provided, the script processes ALL hosts
    in the vCenter.**
.PARAMETER VCenter
    The FQDN or IP address of the vCenter to connect to.
.PARAMETER Credential
    PSCredential object used to authenticate to vCenter.
.PARAMETER HostName
    Name of a single ESXi host to query.
.PARAMETER ClusterName
    Name of a vSphere cluster – all hosts in the cluster will be processed.
.PARAMETER InputObject
    Accepts pipeline input (host names, cluster names, or objects with Name property).
.PARAMETER Json
    Switch – when present the script outputs JSON instead of PowerShell objects.
.PARAMETER Help
    Shows this help text.
.INPUTS
    You can pipe in objects that have a **Name** property (e.g. strings, 
    Get-VMHost, Get-Cluster results).  When piped, the script will treat each
    incoming value as a host name or cluster name automatically.
.OUTPUTS
    PSCustomObject with properties **HostName** and **IPv4Address** or a JSON string.
.EXAMPLE
    .\Get-VMHostIpmi.ps1 -VCenter vc01.example.com -Credential $cred -HostName esxi01
    Returns the BMC IPv4 address for host *esxi01*.
.EXAMPLE
    .\Get-VMHostIpmi.ps1 -VCenter vc01.example.com -Credential $cred
    Returns the BMC IPv4 address for ALL hosts in the vCenter.
.EXAMPLE
    Get-Cluster -Name ProdCluster | .\Get-VMHostIpmi.ps1 -VCenter vc01 -Credential $cred -Json
    Returns a JSON array with the BMC IPv4 address of every host in *ProdCluster*.
.EXAMPLE
    "esxi01","esxi02" | .\Get-VMHostIpmi.ps1 -VCenter vc01 -Credential $cred
    Returns BMC info for multiple hosts via pipeline.
#>
[CmdletBinding(DefaultParameterSetName = 'FromParams')]
param (
    [Parameter(ParameterSetName = 'FromParams')]
    [Parameter(ParameterSetName = 'FromPipe')]
    [string]$VCenter,
    
    [Parameter(ParameterSetName = 'FromParams')]
    [Parameter(ParameterSetName = 'FromPipe')]
    [pscredential]$Credential,
    
    [Parameter(ParameterSetName = 'FromParams')]
    [string]$HostName,
    
    [Parameter(ParameterSetName = 'FromParams')]
    [string]$ClusterName,
    
    [Parameter(ValueFromPipeline = $true, ParameterSetName = 'FromPipe')]
    [ValidateNotNullOrEmpty()]
    [object[]]$InputObject,
    
    [switch]$Json,
    [switch]$Help
)
begin {
    function Show-Help {
        Get-Help -Detailed $PSCommandPath
        exit
    }
    
    # ----------------------------------------------------------------------
    # 1️⃣ Show help if needed
    # ----------------------------------------------------------------------
    if ($Help) {
        Show-Help
    }
    
    # CHANGE: Modified logic to allow execution with only VCenter and Credential
    # If no VCenter/Credential and not expecting pipeline input, show help
    if (-not $VCenter -and -not $Credential -and -not $MyInvocation.ExpectingInput) {
        Show-Help
    }
    
    # ----------------------------------------------------------------------
    # 2️⃣ Validate required parameters when not showing help
    # ----------------------------------------------------------------------
    if (-not $VCenter) {
        Write-Error "Parameter -VCenter is required."
        Show-Help
    }
    
    if (-not $Credential) {
        Write-Error "Parameter -Credential is required."
        Show-Help
    }
    
    # ----------------------------------------------------------------------
    # 3️⃣ Initialize
    # ----------------------------------------------------------------------
    $targetHosts = @()
    $pipelineNames = @()
    
    # Check for PowerCLI
    if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
        Write-Error "PowerCLI module not found. Install it with Install-Module -Name VMware.PowerCLI"
        exit 1
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    
    # Suppress certificate warnings (optional – remove if you prefer strict cert checking)
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope User -Confirm:$false | Out-Null
    
    # Connect to vCenter (once)
    Write-Verbose "Connecting to vCenter: $VCenter"
    try {
        Connect-VIServer -Server $VCenter -Credential $Credential -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Failed to connect to vCenter '$VCenter': $_"
        exit 1
    }
    
    # Helper: resolve a string (host or cluster) to a collection of VMHost objects
    function Resolve-NameToHosts {
        param([string]$Name)
        
        # Try host first
        $VMhost = Get-VMHost -Name $Name -ErrorAction SilentlyContinue
        if ($VMhost) {
            return $VMhost
        }
        
        # Then try cluster
        $cluster = Get-Cluster -Name $Name -ErrorAction SilentlyContinue
        if ($cluster) {
            return Get-VMHost -Location $cluster
        }
        
        Write-Warning "Could not resolve '$Name' to a host or cluster."
        return @()
    }
}
process {
    # ----------------------------------------------------------------------
    # 4️⃣ Collect pipeline input
    # ----------------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'FromPipe') {
        foreach ($item in $InputObject) {
            # Handle objects with Name property or plain strings
            if ($item -is [string]) {
                $pipelineNames += $item
            }
            elseif ($item.Name) {
                $pipelineNames += $item.Name
            }
            else {
                Write-Warning "Cannot process pipeline object: $item"
            }
        }
    }
}
end {
    # ----------------------------------------------------------------------
    # 5️⃣ Build target host list
    # ----------------------------------------------------------------------
    
    # Process explicit parameters (FromParams parameter set)
    if ($PSCmdlet.ParameterSetName -eq 'FromParams') {
        if ($HostName) {
            $targetHosts += Resolve-NameToHosts -Name $HostName
        }
        if ($ClusterName) {
            $targetHosts += Resolve-NameToHosts -Name $ClusterName
        }
        
        # CHANGE: If neither HostName nor ClusterName provided, get ALL hosts
        if (-not $HostName -and -not $ClusterName) {
            Write-Verbose "No specific host or cluster provided - retrieving ALL hosts from vCenter"
            $targetHosts += Get-VMHost
        }
    }
    
    # Process piped values (FromPipe parameter set)
    if ($PSCmdlet.ParameterSetName -eq 'FromPipe') {
        foreach ($pn in $pipelineNames) {
            $targetHosts += Resolve-NameToHosts -Name $pn
        }
    }
    
    # Remove duplicates (by MoRef)
    $targetHosts = $targetHosts | Sort-Object -Property Id -Unique
    
    if ($targetHosts.Count -eq 0) {
        Write-Warning "No valid hosts found to process."
        Disconnect-VIServer -Server $VCenter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        return
    }
    
    Write-Verbose "Processing $($targetHosts.Count) host(s)"
    
    # ----------------------------------------------------------------------
    # 6️⃣ Query IPMI BMC info for each host
    # ----------------------------------------------------------------------
    $results = foreach ($vmHost in $targetHosts) {
        try {
            Write-Verbose "Querying IPMI for host: $($vmHost.Name)"
            
            # Get EsxCli interface (V2 is the modern version)
            $esxcli = Get-EsxCli -VMHost $vmHost -V2
            
            # Invoke the IPMI BMC get method
            $bmcInfo = $esxcli.hardware.ipmi.bmc.get.Invoke()
            
            # Extract IPv4 address from the BMC info
            $ipv4 = if ($bmcInfo -and $bmcInfo.IPv4Address) { 
                $bmcInfo.IPv4Address 
            } elseif ($bmcInfo -and $bmcInfo.IP) {
                $bmcInfo.IP
            } else { 
                $null 
            }
            
            [pscustomobject]@{
                HostName    = $vmHost.Name
                IPv4Address = $ipv4
            }
        }
        catch {
            Write-Warning "Failed to get IPMI info for host $($vmHost.Name): $_"
            [pscustomobject]@{
                HostName    = $vmHost.Name
                IPv4Address = $null
            }
        }
    }
    
    # ----------------------------------------------------------------------
    # 7️⃣ Output – object or JSON
    # ----------------------------------------------------------------------
    if ($Json) {
        $results | ConvertTo-Json -Depth 3
    }
    else {
        $results
    }
    
    # Disconnect (optional, but tidy)
    Disconnect-VIServer -Server $VCenter -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}