<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>

 Import-Module Storage

<##################################################
#  Common Helper functions                        #
##################################################>

$CommonFunc = {

    #
    # Shows error, cancels script
    #
    function Show-Error(
        [string] $Message,
        [System.Management.Automation.ErrorRecord] $e = $null
        )
    {
        $Message = "$(get-date -format 's') : $Message - cmdlet was cancelled"
        if ($e) {
            Write-Error $Message
            throw $e
        } else {
            Write-Error $Message -ErrorAction Stop
        }
    }
 
    #
    # Shows warning, script continues
    #
    function Show-Warning(
        [string] $Message
        )
    {
        Write-Warning "$(get-date -format 's') : $Message"
    }

    #
    # Show arbitrary normal status message, with optional color coding
    #
    function Show-Update(
        [string] $Message,
        [System.ConsoleColor] $ForegroundColor = [System.ConsoleColor]::White
        )
    {
        Write-Host -ForegroundColor $ForegroundColor "$(get-date -format 's') : $Message"
    }

    function Show-JobRuntime(
        [object[]] $jobs
        )
    {
        $jobs | sort Name,Location |% {
            Show-Update "$($_.Name) [$($_.Location)]: Total $('{0:N1}' -f ($_.PSEndTime - $_.PSBeginTime).TotalSeconds)s : Start $($_.PSBeginTime.ToString('s')) - Stop $($_.PSEndTime.ToString('s'))"
        }
    }

    #
    #  Convert an absolute local path to the equivalent remote path via SMB admin shares
    #  ex: c:\foo\bar & scratch -> \\scratch\C$\foo\bar
    #

    function Get-AdminSharePathFromLocal(
        [string] $node,
        [string] $local
        )
    {
        "\\"+$node+"\"+$local[0]+"$\"+$local.Substring(3,$local.Length-3)
    }
}

# evaluate into the main session
# scriptblocks are flattened to strings on passing via $using
# iex will be used there
. $CommonFunc

#
# Checks if the current version of module is the latest version
#
function Compare-ModuleVersion {
    if ($PSVersionTable.PSVersion -lt [System.Version]"5.0.0") {
        Show-Warning "Current PS Version does not support this operation. `nPlease check for updated module from PS Gallery and update using: Update-Module PrivateCloud.DiagnosticInfo"
    }
    else {        
        if ((Find-Module -Name PrivateCloud.DiagnosticInfo).Version -gt (Get-Module PrivateCloud.DiagnosticInfo).Version) {        
            Show-Warning "There is an updated module available on PowerShell Gallery. Please update the module using: Update-Module PrivateCloud.DiagnosticInfo"
        }
    }
}

<##################################################
#  End Helper functions                           #
##################################################>

<# 
    .SYNOPSIS 
       Get state and diagnostic information for all software-defined datacenter (SDDC) features in a Windows Server 2016 cluster

    .DESCRIPTION 
       Get state and diagnostic information for all software-defined datacenter (SDDC) features in a Windows Server 2016 cluster
       Run from one of the nodes of the cluster or specify a cluster name.
       Results are saved to a folder (default C:\Users\<user>\HealthTest) for later review and replay.

    .LINK 
        To provide feedback and contribute visit https://github.com/PowerShell/PrivateCloud.Health

    .EXAMPLE 
       Get-SddcDiagnosticInfo
 
       Uses the default temporary working folder at C:\Users\<user>\HealthTest
       Saves the zipped results at C:\Users\<user>\HealthTest-<cluster>-<date>.ZIP

    .EXAMPLE 
       Get-SddcDiagnosticInfo -WriteToPath C:\Test
 
       Uses the specified folder as the temporary working folder.

    .EXAMPLE 
       Get-SddcDiagnosticInfo -ClusterName Cluster1
 
       Targets the cluster specified.

    .EXAMPLE 
       Get-SddcDiagnosticInfo -ReadFromPath C:\Test
 
       Results are obtained from the specified folder, not from a live cluster.

#> 

function Get-SddcDiagnosticInfo
{
    # disables the warning re: www.microsoft.com beacon check
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingComputerNameHardcoded", "")]

    [CmdletBinding(DefaultParameterSetName="Write")]
    [OutputType([String])]

    param(
        [parameter(ParameterSetName="Write", Position=0, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $WriteToPath = $($env:userprofile + "\HealthTest\"),

        [parameter(ParameterSetName="Write", Position=1, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $ClusterName = ".",
		
        [parameter(ParameterSetName="Write", Position=1, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Nodelist = @(),
		
        [parameter(ParameterSetName="Write", Position=2, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $ZipPrefix = $($env:userprofile + "\HealthTest"),

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeEvents = $true,
    
        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludePerformance = $true,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeReliabilityCounters = $false,

        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [switch] $MonitoringMode,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedNodes,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedNetworks,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedVolumes,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedDedupVolumes,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedPhysicalDisks,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedPools,
    
        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $ExpectedEnclosures,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $HoursOfEvents = -1,

		[parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $PerfSamples = 10,
		
        [parameter(ParameterSetName="Read", Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ReadFromPath = "",

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeDumps = $false,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeAssociations = $false,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeHealthReport = $false,

		[parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $ProcessCounter = $false,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeLiveDump = $false
        )

    #
    # Set strict mode to check typos on variable and property names
    #

    Set-StrictMode -Version Latest

    #
    # Makes a list of cluster nodes - filtered for if they are available, and hides the different options
	# passing cluster/nodes to the script
    #	

	$FilteredNodelist = @()

	Function GetFilteredNodeList {
		if ($FilteredNodelist.Count -eq 0)
		{
			$NodesToPing = @();
			
			if ($Nodelist.Count -gt 0)
			{
				foreach ($node in $Nodelist)
				{
					$NodesToPing += @(New-Object -TypeName PSObject -Prop (@{"Name"=$node;"State"="Up"}))
				}
			}
			else
			{
				foreach ($node in (Get-ClusterNode -Cluster $ClusterName))
				{
					if ($node.State -ne "Down")
					{
						$FilteredNodelist += @($node)
					}
					else
					{
						$NodesToPing += @($node)
					}
				}
			}
			
			foreach ($node in $NodesToPing)
			{
				if (Test-Connection -ComputerName $node.Name -Quiet -TimeToLive 5)
				{
					$FilteredNodelist += @($node)
				}
			}

		}
		return $FilteredNodelist	
	}

    #
    # Count number of elements in an array, including checks for $null or single object
    #
    function NCount { 
        Param ([object] $Item) 
        if ($null -eq $Item) {
            $Result = 0
        } else {
            if ($Item.GetType().BaseType.Name -eq "Array") {
                $Result = ($Item).Count
            } else { 
                $Result = 1
            }
        }
        return $Result
    }

    function VolumeToPath {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeID -eq $Volume) { $Result = $_.CSVPath }
             }
        return $Result	
    }

    function VolumeToCSV {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeID -eq $Volume) { $Result = $_.CSVVolume }
        }
        return $Result
    }
    
    function VolumeToVD {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeID -eq $Volume) { $Result = $_.FriendlyName }
        }
        return $Result
    }

    function VolumeToShare {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeID -eq $Volume) { $Result = $_.ShareName }
        }
        return $Result
    }

    function VolumeToResiliency {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeID -eq $Volume) { 
                $Result = $_.VDResiliency+","+$_.VDCopies
                if ($_.VDEAware) { 
                    $Result += ",E"
                } else {
                    $Result += ",NE"
                }
            }
        }
        return $Result
    }

    function VolumeToColumns {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeID -eq $Volume) { $Result = $_.VDColumns }
        }
        return $Result
    }

    function CSVToShare {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.CSVVolume -eq $Volume) { $Result = $_.ShareName }
        }
        return $Result
    }

    function VolumeToPool {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.PoolName }
        }
        return $Result
    }

    function CSVToVD {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.CSVVolume -eq $Volume) { $Result = $_.FriendlyName }
        }
        return $Result
    }

    function CSVToPool {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.CSVVolume -eq $Volume) { $Result = $_.PoolName }
        }
        return $Result
    }
    
    function CSVToNode {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.CSVVolume -eq $Volume) { $Result = $_.CSVNode }
        }
        return $Result
    }

    function VolumeToCSVName {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.CSVName }
        }
        return $Result
    }
    
    function CSVStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.CSVStatus.Value }
        }
        return $Result
    }
                
    function PoolOperationalStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.PoolOpStatus }
        }
        return $Result
    }

    function PoolHealthStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.PoolHealthStatus }
        }
        return $Result
    }

    function PoolHealthyPDs {
        Param ([String] $PoolName)
        $healthyPDs = ""
        if ($PoolName) {
            $totalPDs = (Get-StoragePool -FriendlyName $PoolName -CimSession $ClusterName -ErrorAction SilentlyContinue | Get-PhysicalDisk).Count
            $healthyPDs = (Get-StoragePool -FriendlyName $PoolName -CimSession $ClusterName -ErrorAction SilentlyContinue | Get-PhysicalDisk | Where-Object HealthStatus -eq "Healthy" ).Count
        }
        else {
            Show-Error("No storage pool specified")
        }
        return "$totalPDs/$healthyPDs"
    }

    function VDOperationalStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.OperationalStatus }
        }
        return $Result
    }

    function VDHealthStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { Show-Error("No device associations present.") }
        $Result = ""
        $Associations |% {
            if ($_.VolumeId -eq $Volume) { $Result = $_.HealthStatus }
        }
        return $Result    
    }

    #
    # Veriyfing basic prerequisites on script node.
    #

    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
    $S2DEnabled = $false

    if ([uint64]$OS.BuildNumber -lt 9600) { 
        Show-Error("Wrong OS Version - Need at least Windows Server 2012 R2 or Windows 8.1. You are running - " + $OS.Name) 
    }
 
    if (-not (Get-Command -Module FailoverClusters)) { 
        Show-Error("Cluster PowerShell not available. Download the Windows Failover Clustering RSAT tools.") 
    }

    function StartMonitoring {
        Show-Update "Entered continuous monitoring mode. Storage Infrastucture information will be refreshed every 3-6 minutes" -ForegroundColor Yellow    
        Show-Update "Press Ctrl + C to stop monitoring" -ForegroundColor Yellow

        try { $ClusterName = (Get-Cluster -Name $ClusterName).Name }
        catch { Show-Error("Cluster could not be contacted. `nError="+$_.Exception.Message) }

		$NodeList = GetFilteredNodeList
		
        $AccessNode = $NodeList[0].Name + "." + (Get-Cluster -Name $ClusterName).Domain

        try { $Volumes = Get-Volume -CimSession $AccessNode  }
        catch { Show-Error("Unable to get Volumes. `nError="+$_.Exception.Message) }

        $AssocJob = Start-Job -ArgumentList $AccessNode,$ClusterName {

            param($AccessNode,$ClusterName)

            $SmbShares = Get-SmbShare -CimSession $AccessNode
            $Associations = Get-VirtualDisk -CimSession $AccessNode |% {

                $o = $_ | Select-Object FriendlyName, CSVName, CSVNode, CSVPath, CSVVolume, 
                ShareName, SharePath, VolumeID, PoolName, VDResiliency, VDCopies, VDColumns, VDEAware

                $AssocCSV = $_ | Get-ClusterSharedVolume -Cluster $ClusterName

                if ($AssocCSV) {
                    $o.CSVName = $AssocCSV.Name
                    $o.CSVNode = $AssocCSV.OwnerNode.Name
                    $o.CSVPath = $AssocCSV.SharedVolumeInfo.FriendlyVolumeName
                    if ($o.CSVPath.Length -ne 0) {
                        $o.CSVVolume = $o.CSVPath.Split("\")[2]
                    }     
                    $AssocLike = $o.CSVPath+"\*"
                    $AssocShares = $SmbShares | Where-Object Path -like $AssocLike 
                    $AssocShare = $AssocShares | Select-Object -First 1
                    if ($AssocShare) {
                        $o.ShareName = $AssocShare.Name
                        $o.SharePath = $AssocShare.Path
                        $o.VolumeID = $AssocShare.Volume
                        if ($AssocShares.Count -gt 1) { $o.ShareName += "*" }
                    }
                }

                Write-Output $o
            }

            $AssocPool = Get-StoragePool -CimSession $AccessNode -ErrorAction SilentlyContinue
            $AssocPool |% {
                $AssocPName = $_.FriendlyName
                Get-StoragePool -CimSession $AccessNode -FriendlyName $AssocPName | 
                Get-VirtualDisk -CimSession $AccessNode |% {
                    $AssocVD = $_
                    $Associations |% {
                        if ($_.FriendlyName -eq $AssocVD.FriendlyName) { 
                            $_.PoolName = $AssocPName 
                            $_.VDResiliency = $AssocVD.ResiliencySettingName
                            $_.VDCopies = $AssocVD.NumberofDataCopies
                            $_.VDColumns = $AssocVD.NumberofColumns
                            $_.VDEAware = $AssocVD.IsEnclosureAware
                        }
                    }
                }
            }

            Write-Output $Associations
        }

        $Associations = $AssocJob | Wait-Job | Receive-Job
        $AssocJob | Remove-Job

        [System.Console]::Clear()

        $Volumes | Where-Object FileSystem -eq CSVFS | Sort-Object SizeRemaining | 
        Format-Table -AutoSize @{Expression={$poolName = VolumeToPool($_.Path); "[$(PoolOperationalStatus($_.Path))/$(PoolHealthStatus($_.Path))] " + $poolName};Label="[OpStatus/Health] Pool"}, 
        @{Expression={(PoolHealthyPDs(VolumeToPool($_.Path)))};Label="HealthyPhysicalDisks"; Align="Center"}, 
        @{Expression={$vd = VolumeToVD($_.Path);  "[$(VDOperationalStatus($_.Path))/$(VDHealthStatus($_.Path))] "+$vd};Label="[OpStatus/Health] VirtualDisk"}, 
        @{Expression={$csvVolume = VolumeToCSV($_.Path); "[" + $_.HealthStatus + "] " + $csvVolume};Label="[Health] CSV Volume"},
        @{Expression={$csvName = VolumeToCSVName($_.Path); $csvStatus = CSVStatus($_.Path);  " [$csvStatus] " + $csvName};Label="[Status] CSV Name"}, 
        @{Expression={CSVToNode(VolumeToCSV($_.Path))};Label="Volume Owner"},   
        @{Expression={VolumeToShare($_.Path)};Label="Share Name"}, 
        @{Expression={$VolResiliency = VolumeToResiliency($_.Path); $volColumns = VolumeToColumns($_.Path); "$VolResiliency,$volColumns" +"Col" };Label="Volume Configuration"},        
        @{Expression={"{0:N2}" -f ($_.Size/1GB)};Label="Total Size";Width=11;Align="Right"},  
        @{Expression={"{0:N2}" -f ($_.SizeRemaining/$_.Size*100)};Label="Avail%";Width=11;Align="Right"}         
        
        StartMonitoring
    }
    if ($MonitoringMode) {
        StartMonitoring 
    }

    #
    # Veriyfing path
    #

    if ($ReadFromPath -ne "") {
        $Path = $ReadFromPath
        $Read = $true
    } else {
        $Path = $WriteToPath
        $Read = $false
    }

    $PathOK = Test-Path $Path -ErrorAction SilentlyContinue
    if ($Read -and -not $PathOK) { Show-Error ("Path not found: $Path") }
    if (-not $Read) {
        Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse | Out-Null
        MKDIR -ErrorAction SilentlyContinue $Path | Out-Null
    } 
    $PathObject = Get-Item $Path
    if ($null -eq $PathObject) { Show-Error ("Invalid Path: $Path") }
    $Path = $PathObject.FullName

    if ($Path.ToUpper().EndsWith(".ZIP")) {
        [Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null
        $ExtractToPath = $Path.Substring(0, $Path.Length - 4)

        try { [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $ExtractToPath) }
        catch { Show-Error("Can't extract results as Zip file from '$Path' to '$ExtractToPath'") }

        $Path = $ExtractToPath
    }

    if (-not $Path.EndsWith("\")) { $Path = $Path + "\" }

    # Start Transcript
    $transcriptFile = $Path + "0_CloudHealthSummary.log"
    try{
        Stop-Transcript | Out-Null
    }
    catch [System.InvalidOperationException]{}
    Start-Transcript -Path $transcriptFile -Force

    if ($Read) { 
        Show-Update "Reading from path : $Path"
    } else { 
        Show-Update "Writing to path : $Path"
    }

<#
    if ($Read) {
        try { $SavedVersion = Import-Clixml ($Path + "GetVersion.XML") }
        catch { $SavedVersion = 1.1 }

        if ($SavedVersion -ne $ScriptVersion) 
        {Show-Error("Files are from script version $SavedVersion, but the script is version $ScriptVersion")};
    } else {
        $ScriptVersion | Export-Clixml ($Path + "GetVersion.XML")
    }
#>
    #
    # Handle parameters
    #

    if ($Read) {
        $Parameters = Import-Clixml ($Path + "GetParameters.XML")
        $TodayDate = $Parameters.TodayDate
        $ExpectedNodes = $Parameters.ExpectedNodes
        $ExpectedNetworks = $Parameters.ExpectedNetworks
        $ExpectedVolumes = $Parameters.ExpectedVolumes
        $ExpectedPhysicalDisks = $Parameters.ExpectedPhysicalDisks
        $ExpectedPools = $Parameters.ExpectedPools
        $ExpectedEnclosures = $Parameters.ExpectedEnclosures
        $HoursOfEvents = $Parameters.HoursOfEvents

    } else {
        $Parameters = "" | Select-Object TodayDate, ExpectedNodes, ExpectedNetworks, ExpectedVolumes, 
        ExpectedPhysicalDisks, ExpectedPools, ExpectedEnclosures, HoursOfEvents
        $TodayDate = Get-Date
        $Parameters.TodayDate = $TodayDate
        $Parameters.ExpectedNodes = $ExpectedNodes
        $Parameters.ExpectedNetworks = $ExpectedNetworks 
        $Parameters.ExpectedVolumes = $ExpectedVolumes 
        $Parameters.ExpectedPhysicalDisks = $ExpectedPhysicalDisks
        $Parameters.ExpectedPools = $ExpectedPools
        $Parameters.ExpectedEnclosures = $ExpectedEnclosures
        $Parameters.HoursOfEvents = $HoursOfEvents
        $Parameters | Export-Clixml ($Path + "GetParameters.XML")
    }
    "Date of capture : " + $TodayDate

    #
    # Phase 1
    #
    Show-Update "<<< Phase 1 - Storage Health Overview >>>`n" -ForegroundColor Cyan
	
    # Cluster Nodes

    if ($Read) {
        $ClusterNodes = Import-Clixml ($Path + "GetClusterNode.XML")
    } else {
        try { $ClusterNodes = GetFilteredNodeList }
        catch { Show-Error "Unable to get Cluster Nodes" $_ }
        $ClusterNodes | Export-Clixml ($Path + "GetClusterNode.XML")
    }

    #
    # Get-Cluster
    #

    if ($Read) {
        $Cluster = Import-Clixml ($Path + "GetCluster.XML")
    } else {
        try { 
				if ($ClusterName -eq ".")
				{
					$Cluster = Get-Cluster -Name $ClusterNodes[0].Name
					$ClusterName = $Cluster.Name
				}
				else
				{
					$Cluster = Get-Cluster -Name $ClusterName
				}
			}
        catch { Show-Error("Cluster could not be contacted. `nError="+$_.Exception.Message) }
        if ($null -eq $Cluster) { Show-Error("Server is not in a cluster") }
        $Cluster | Export-Clixml ($Path + "GetCluster.XML")
    }

    $ClusterName = $Cluster.Name + "." + $Cluster.Domain
    "Cluster Name               : $ClusterName"
    
    $S2DEnabled = $Cluster.S2DEnabled
    "S2D Enabled                : $S2DEnabled"

    if ($S2DEnabled -ne $true) {
        # note: this hardcoded beacon results in a powershell validation warning which we disable at the top of the fn
        # if this is ever removed, remove the disable
        if ((Test-NetConnection -ComputerName 'www.microsoft.com' -Hops 1 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).PingSucceeded) {
            # The update check requires the NuGet provider version 2.8.5.201 or greater
            $NuGetProvider = Get-PackageProvider -Name NuGet | ? {$_.Version -gt 2.8.5.201}
            If (-not $NuGetProvider) {
                # Install NuGet provider if necessary -- this will surpress the prompt to install
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
                $NuGetProvider = Get-PackageProvider -Name NuGet | ? {$_.Version -gt 2.8.5.201}
            }

            If ($NuGetProvider) {
                Compare-ModuleVersion
            }
        }
    }

    # Select an access node, which will be used to query the cluster

    $AccessNode = ($ClusterNodes)[0].Name + "." + $Cluster.Domain
    "Access node                : $AccessNode `n"
    
    #
    # Test if it's a scale-out file server
    #

    if ($Read) {
        $ClusterGroups = Import-Clixml ($Path + "GetClusterGroup.XML")
    } else {
        try { $ClusterGroups = Get-ClusterGroup -Cluster $ClusterName }
        catch { Show-Error("Unable to get Cluster Groups. `nError="+$_.Exception.Message) }
        $ClusterGroups | Export-Clixml ($Path + "GetClusterGroup.XML")
    }

    $ScaleOutServers = $ClusterGroups | Where-Object GroupType -like "ScaleOut*"
    if ($null -eq $ScaleOutServers) { 
        if ($S2DEnabled -ne $true) {
            Show-Warning "No Scale-Out File Server cluster roles found"
        }
    } else {
        $ScaleOutName = $ScaleOutServers[0].Name+"."+$Cluster.Domain
        "Scale-Out File Server Name : $ScaleOutName"
    }

    #
    # Verify deduplication prerequisites on access node, if in Write mode.
    #

    $DedupEnabled = $true
    if (-not $Read) {
        if ($(Invoke-Command -ComputerName $AccessNode {(-not (Get-Command -Module Deduplication))} )) { 
            $DedupEnabled = $false
            if ($S2DEnabled -ne $true) {
                Show-Warning "Deduplication PowerShell not installed on cluster node."
            }
        }
    }

	if ($IncludeAssociations) {

		# Gather nodes view of storage and build all the associations

		if (-not $Read) {                         
			$SNVJob = Start-Job -Name 'StorageNodePhysicalDiskView' -ArgumentList $clusterName {
			param ($clusterName)
				$clusterCimSession = New-CimSession -ComputerName $ClusterName
				$snvInstances = Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_StorageNodeToPhysicalDisk -CimSession $clusterCimSession            
				$allPhysicalDisks  = Get-PhysicalDisk -CimSession $clusterCimSession               
				$SNV = @()              
                
				Foreach ($phyDisk in $snvInstances) {
					$SNVObject = New-Object -TypeName System.Object                       
					$pdIndex = $phyDisk.PhysicalDiskObjectId.IndexOf("PD:")
					$pdLength = $phyDisk.PhysicalDiskObjectId.Length
					$pdID = $phyDisk.PhysicalDiskObjectId.Substring($pdIndex+3, $pdLength-($pdIndex+4))  
					$PDUID = ($allPhysicalDisks | Where-Object ObjectID -Match $pdID).UniqueID
					$pd = $allPhysicalDisks | Where-Object UniqueID -eq $PDUID
					$nodeIndex = $phyDisk.StorageNodeObjectId.IndexOf("SN:")
					$nodeLength = $phyDisk.StorageNodeObjectId.Length
					$storageNodeName = $phyDisk.StorageNodeObjectId.Substring($nodeIndex+3, $nodeLength-($nodeIndex+4))  
					$poolName = ($pd | Get-StoragePool -CimSession $clusterCimSession -ErrorAction SilentlyContinue | Where-Object IsPrimordial -eq $false).FriendlyName
					if (-not $poolName) {
						continue
					}

					$SNVObject | Add-Member -Type NoteProperty -Name PhysicalDiskUID -Value $PDUID                
					$SNVObject | Add-Member -Type NoteProperty -Name StorageNode -Value $storageNodeName
					$SNVObject | Add-Member -Type NoteProperty -Name StoragePool -Value $poolName
					$SNVObject | Add-Member -Type NoteProperty -Name MPIOPolicy -Value $phyDisk.LoadBalancePolicy
					$SNVObject | Add-Member -Type NoteProperty -Name MPIOState -Value $phyDisk.IsMPIOEnabled            
					$SNVObject | Add-Member -Type NoteProperty -Name StorageEnclosure -Value $pd.PhysicalLocation
					$SNVObject | Add-Member -Type NoteProperty -Name PathID -Value $phyDisk.PathID
					$SNVObject | Add-Member -Type NoteProperty -Name PathState -Value $phyDisk.PathState

					$SNV += $SNVObject
				}            
				Write-Output $SNV
			}              
		}
	}

    #
    # Generate SBL Connectivity report based on input clusport information
    #
    
    if ($S2DEnabled) {

        #
        # Gather only
        #

        if (-not $Read) {

            Show-Update "Unhealthy VD"

            try {
                $NonHealthyVDs = Get-VirtualDisk | where {$_.HealthStatus -ne "Healthy" -OR $_.OperationalStatus -ne "OK"}
                $NonHealthyVDs | Export-Clixml ($Path + "NonHealthyVDs.XML")

                foreach ($NonHealthyVD in $NonHealthyVDs) {
                    $NonHealthyExtents = $NonHealthyVD | Get-PhysicalExtent | ? OperationalStatus -ne Active | sort-object VirtualDiskOffset, CopyNumber
                    $NonHealthyExtents | Export-Clixml($Path + $NonHealthyVD.FriendlyName + "_Extents.xml")
                }
            } catch {
                Show-Warning "Not able to query extents for faulted virtual disks"
            } 

            Show-Update "SSB Disks and SSU"

            try {
                Get-StoragePool -ErrorAction SilentlyContinue | ? IsPrimordial -eq $false |% {
                    $Disks = $_ | Get-PhysicalDisk 
                    $Disks | Export-Clixml($Path + $_.FriendlyName + "_Disks.xml")
                    
                    $SSU = $Disks | Get-StorageFaultDomain -type StorageScaleUnit | group FriendlyName |% { $_.Group[0] }
                    $SSU | Export-Clixml($Path + $_.FriendlyName + "_SSU.xml")
                }
            } catch {
                Show-Warning "Not able to query faulty disks and SSU for faulted pools"
            }

            Show-Update "SSB Connectivity"

            try {
                $j = $ClusterNodes |? { $_.State.ToString() -eq 'Up' } |% {
                    $node = $_.Name
                    Start-Job -Name $node {
                        Get-CimInstance -Namespace root\wmi -ClassName ClusPortDeviceInformation -ComputerName $using:node |
                            Export-Clixml (Join-Path $using:Path ($using:node + "_ClusPort.xml"))
                        Get-CimInstance -Namespace root\wmi -ClassName ClusBfltDeviceInformation -ComputerName $using:node |
                            Export-Clixml (Join-Path $using:Path ($using:node + "_ClusBflt.xml"))
                    }
                }

                $null = $j | Wait-Job
                $j | Receive-Job
                $j | Remove-Job

            } catch {
                Show-Warning "Gathering SBL connectivity failed"
            }
        }
    }

	if ($IncludeAssociations) {
		# Gather association between pool, virtualdisk, volume, share.
		# This is first used at Phase 4 and is run asynchronously since
		# it can take some time to gather for large numbers of devices.

		if (-not $Read) {

			$AssocJob = Start-Job -Name 'StorageComponentAssociations' -ArgumentList $AccessNode,$ClusterName {
				param($AccessNode,$ClusterName)

				$SmbShares = Get-SmbShare -CimSession $AccessNode
				$Associations = Get-VirtualDisk -CimSession $AccessNode |% {

					$o = $_ | Select-Object FriendlyName, OperationalStatus, HealthStatus, CSVName, CSVStatus, CSVNode, CSVPath, CSVVolume, 
					ShareName, SharePath, VolumeID, PoolName, PoolOpStatus, PoolHealthStatus, VDResiliency, VDCopies, VDColumns, VDEAware

					$AssocCSV = $_ | Get-ClusterSharedVolume -Cluster $ClusterName

					if ($AssocCSV) {
						$o.CSVName = $AssocCSV.Name
						$o.CSVStatus = $AssocCSV.State
						$o.CSVNode = $AssocCSV.OwnerNode.Name
						$o.CSVPath = $AssocCSV.SharedVolumeInfo.FriendlyVolumeName
						if ($o.CSVPath.Length -ne 0) {
							$o.CSVVolume = $o.CSVPath.Split("\")[2]
						}     
						$AssocLike = $o.CSVPath+"\*"
						$AssocShares = $SmbShares | Where-Object Path -like $AssocLike 
						$AssocShare = $AssocShares | Select-Object -First 1
						if ($AssocShare) {
							$o.ShareName = $AssocShare.Name
							$o.SharePath = $AssocShare.Path
							$o.VolumeID = $AssocShare.Volume
							if ($AssocShares.Count -gt 1) { $o.ShareName += "*" }
						}
					}

					Write-Output $o
				}

				$AssocPool = Get-StoragePool -CimSession $AccessNode -ErrorAction SilentlyContinue
				$AssocPool |% {
					$AssocPName = $_.FriendlyName
					$AssocPOpStatus = $_.OperationalStatus
					$AssocPHStatus = $_.HealthStatus
					Get-StoragePool -CimSession $AccessNode -FriendlyName $AssocPName | 
					Get-VirtualDisk -CimSession $AccessNode |% {
						$AssocVD = $_
						$Associations |% {
							if ($_.FriendlyName -eq $AssocVD.FriendlyName) { 
								$_.PoolName = $AssocPName 
								$_.PoolOpStatus = $AssocPOpStatus
								$_.PoolHealthStatus = $AssocPHStatus
								$_.VDResiliency = $AssocVD.ResiliencySettingName
								$_.VDCopies = $AssocVD.NumberofDataCopies
								$_.VDColumns = $AssocVD.NumberofColumns
								$_.VDEAware = $AssocVD.IsEnclosureAware
							}
						}
					}
				}

				Write-Output $Associations
			}
		}
	}

    # Cluster node health

    $NodesTotal = NCount($ClusterNodes)
    $NodesHealthy = NCount($ClusterNodes | Where {$_.State -like "Paused" -or $_.State -like "Up"})
    "Cluster Nodes up              : $NodesHealthy / $NodesTotal"

    if ($NodesTotal -lt $ExpectedNodes) { Show-Warning "Fewer nodes than the $ExpectedNodes expected" }
    if ($NodesHealthy -lt $NodesTotal) { Show-Warning "Unhealthy nodes detected" }

    if ($Read) {
        $ClusterNetworks = Import-Clixml ($Path + "GetClusterNetwork.XML")
    } else {
        try { $ClusterNetworks = Get-ClusterNetwork -Cluster $ClusterName }
        catch { Show-Error("Could not get Cluster Nodes. `nError="+$_.Exception.Message) }
        $ClusterNetworks | Export-Clixml ($Path + "GetClusterNetwork.XML")
    }

    # Cluster network health

    $NetsTotal = NCount($ClusterNetworks)
    $NetsHealthy = NCount($ClusterNetworks | Where {$_.State -like "Up"})
    "Cluster Networks up           : $NetsHealthy / $NetsTotal"
    

    if ($NetsTotal -lt $ExpectedNetworks) { Show-Warning "Fewer cluster networks than the $ExpectedNetworks expected" }
    if ($NetsHealthy -lt $NetsTotal) { Show-Warning "Unhealthy cluster networks detected" }

    if ($Read) {
        $ClusterResources = Import-Clixml ($Path + "GetClusterResource.XML")
    } else {
        try { $ClusterResources = Get-ClusterResource -Cluster $ClusterName }
        catch { Show-Error("Unable to get Cluster Resources.  `nError="+$_.Exception.Message) }
        $ClusterResources | Export-Clixml ($Path + "GetClusterResource.XML")
    }


    if ($Read) {
        $ClusterResourceParameters = Import-Clixml ($Path + "GetClusterResourceParameters.XML")
    } else {
        try { $ClusterResourceParameters = Get-ClusterResource -Cluster $ClusterName | Get-ClusterParameter }
        catch { Show-Error("Unable to get Cluster Resource Parameters.  `nError="+$_.Exception.Message) }
        $ClusterResourceParameters | Export-Clixml ($Path + "GetClusterResourceParameters.XML")
    }

    # Cluster resource health

    $ResTotal = NCount($ClusterResources)
    $ResHealthy = NCount($ClusterResources | Where-Object State -like "Online")
    "Cluster Resources Online      : $ResHealthy / $ResTotal "
    if ($ResHealthy -lt $ResTotal) { Show-Warning "Unhealthy cluster resources detected" }

    if ($S2DEnabled) {
        $HealthProviderCount = @(($ClusterResourceParameters |? { $_.ClusterObject -eq 'Health' -and $_.Name -eq 'Providers' }).Value).Count
        if ($HealthProviderCount) {
            "Health Resource               : $HealthProviderCount health providers registered"
        } else {
            Show-Warning "Health Resource providers not registered"
        }
    }

    if ($Read) {
        $CSV = Import-Clixml ($Path + "GetClusterSharedVolume.XML")
    } else {
        try { $CSV = Get-ClusterSharedVolume -Cluster $ClusterName }
        catch { Show-Error("Unable to get Cluster Shared Volumes.  `nError="+$_.Exception.Message) }
        $CSV | Export-Clixml ($Path + "GetClusterSharedVolume.XML")
    }

    # Cluster shared volume health

    $CSVTotal = NCount($CSV)
    $CSVHealthy = NCount($CSV | Where-Object State -like "Online")
    "Cluster Shared Volumes Online : $CSVHealthy / $CSVTotal"
    if ($CSVHealthy -lt $CSVTotal) { Show-Warning "Unhealthy cluster shared volumes detected" }

    "`nHealthy Components count: [SMBShare -> CSV -> VirtualDisk -> StoragePool -> PhysicalDisk -> StorageEnclosure]"

    # SMB share health

    if ($Read) {
        #$SmbShares = Import-Clixml ($Path + "GetSmbShare.XML")
        $ShareStatus = Import-Clixml ($Path + "ShareStatus.XML")
    } else {
        try { $SmbShares = Get-SmbShare -CimSession $AccessNode }
        catch { Show-Error("Unable to get SMB Shares. `nError="+$_.Exception.Message) }

        $ShareStatus = $SmbShares | Where-Object ContinuouslyAvailable | Select-Object ScopeName, Name, SharePath, Health
        $Count1 = 0
        $Total1 = NCount($ShareStatus)

        if ($Total1 -gt 0)
        {
            $ShareStatus |% {
                $Progress = $Count1 / $Total1 * 100
                $Count1++
                Write-Progress -Activity "Testing file share access" -PercentComplete $Progress

                $_.SharePath = "\\"+$_.ScopeName+"."+$Cluster.Domain+"\"+$_.Name
                try { if (Test-Path -Path $_.SharePath  -ErrorAction SilentlyContinue) {
                            $_.Health = "Accessible"
                        } else {
                            $_.Health = "Inaccessible" 
                    } 
                }
                catch { $_.Health = "Accessible: "+$_.Exception.Message }
            }
            Write-Progress -Activity "Testing file share access" -Completed
        }

        #$SmbShares | Export-Clixml ($Path + "GetSmbShare.XML")
        $ShareStatus | Export-Clixml ($Path + "ShareStatus.XML")

    }

    $ShTotal = NCount($ShareStatus)
    $ShHealthy = NCount($ShareStatus | Where-Object Health -like "Accessible")
    "SMB CA Shares Accessible      : $ShHealthy / $ShTotal"
    if ($ShHealthy -lt $ShTotal) { Show-Warning "Inaccessible CA shares detected" }

    # Open files 

    if ($Read) {
        $SmbOpenFiles = Import-Clixml ($Path + "GetSmbOpenFile.XML")
    } else {
        try { $SmbOpenFiles = Get-SmbOpenFile -CimSession $AccessNode }
        catch { Show-Error("Unable to get Open Files. `nError="+$_.Exception.Message) }
        $SmbOpenFiles | Export-Clixml ($Path + "GetSmbOpenFile.XML")
    }

    $FileTotal = NCount( $SmbOpenFiles | Group-Object ClientComputerName)
    "Users with Open Files         : $FileTotal"
    if ($FileTotal -eq 0) { Show-Warning "No users with open files" }

    # SMB witness

    if ($Read) {
        $SmbWitness = Import-Clixml ($Path + "GetSmbWitness.XML")
    } else {
        try { $SmbWitness = Get-SmbWitnessClient -CimSession $AccessNode }
        catch { Show-Error("Unable to get Open Files. `nError="+$_.Exception.Message) }
        $SmbWitness | Export-Clixml ($Path + "GetSmbWitness.XML")
    }

    $WitTotal = NCount($SmbWitness | Where-Object State -eq RequestedNotifications | Group-Object ClientName)
    "Users with a Witness           : $WitTotal"
    if ($WitTotal -eq 0) { Show-Warning "No users with a Witness" }

    # Volume health

    if ($Read) {
        $Volumes = Import-Clixml ($Path + "GetVolume.XML")
    } else {
        try { $Volumes = Get-Volume -CimSession $AccessNode  }
        catch { Show-Error("Unable to get Volumes. `nError="+$_.Exception.Message) }
        $Volumes | Export-Clixml ($Path + "GetVolume.XML")
    }

    $VolsTotal = NCount($Volumes | Where-Object FileSystem -eq CSVFS )
    $VolsHealthy = NCount($Volumes  | Where-Object FileSystem -eq CSVFS | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) })
    "Cluster Shared Volumes Healthy: $VolsHealthy / $VolsTotal "

    # Deduplicated volume health

    if ($DedupEnabled)
    {
        if ($Read) {
            $DedupVolumes = Import-Clixml ($Path + "GetDedupVolume.XML")
        } else {
            try { $DedupVolumes = Invoke-Command -ComputerName $AccessNode { Get-DedupStatus }}
            catch { Show-Error("Unable to get Dedup Volumes. `nError="+$_.Exception.Message) }
            $DedupVolumes | Export-Clixml ($Path + "GetDedupVolume.XML")
        }

        $DedupTotal = NCount($DedupVolumes)
        $DedupHealthy = NCount($DedupVolumes | Where-Object LastOptimizationResult -eq 0 )
        "Dedup Volumes Healthy         : $DedupHealthy / $DedupTotal "

        if ($DedupTotal -lt $ExpectedDedupVolumes) { Show-Warning "Fewer Dedup volumes than the $ExpectedDedupVolumes expected" }
        if ($DedupHealthy -lt $DedupTotal) { Show-Warning "Unhealthy Dedup volumes detected" }
    } else {
        $DedupVolumes = @()
        $DedupTotal = 0
        $DedupHealthy = 0
        if (-not $Read) { $DedupVolumes | Export-Clixml ($Path + "GetDedupVolume.XML") }
    }

    # Virtual disk health

    if ($Read) {
        $VirtualDisks = Import-Clixml ($Path + "GetVirtualDisk.XML")
    } else {
        try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $VirtualDisks = Get-VirtualDisk -CimSession $AccessNode -StorageSubSystem $SubSystem }
        catch { Show-Error("Unable to get Virtual Disks. `nError="+$_.Exception.Message) }
        $VirtualDisks | Export-Clixml ($Path + "GetVirtualDisk.XML")
    }

    $VDsTotal = NCount($VirtualDisks)
    $VDsHealthy = NCount($VirtualDisks | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    "Virtual Disks Healthy         : $VDsHealthy / $VDsTotal"

    if ($VDsHealthy -lt $VDsTotal) { Show-Warning "Unhealthy virtual disks detected" }

    # Storage tier information
    if ($Read) {
        $StorageTiers = Import-Clixml ($Path + "GetStorageTier.XML")
    } else {
        try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $StorageTiers = Get-StorageTier -CimSession $AccessNode }
        catch { Show-Error("Unable to get Storage Tiers. `nError="+$_.Exception.Message) }
        $StorageTiers | Export-Clixml ($Path + "GetStorageTier.XML")
    }
    # Storage pool health

    if ($Read) {
        $StoragePools = Import-Clixml ($Path + "GetStoragePool.XML")
    } else {
        try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $StoragePools =Get-StoragePool -IsPrimordial $False -CimSession $AccessNode -StorageSubSystem $SubSystem -ErrorAction SilentlyContinue }
        catch { Show-Error("Unable to get Storage Pools. `nError="+$_.Exception.Message) }
        $StoragePools | Export-Clixml ($Path + "GetStoragePool.XML")
    }

    $PoolsTotal = NCount($StoragePools)
    $PoolsHealthy = NCount($StoragePools | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    "Storage Pools Healthy         : $PoolsHealthy / $PoolsTotal "

    if ($PoolsTotal -lt $ExpectedPools) { Show-Warning "Fewer storage pools than the $ExpectedPools expected" }
    if ($PoolsHealthy -lt $PoolsTotal) { Show-Warning "Unhealthy storage pools detected" }

    # Physical disk health

    if ($Read) {
        $PhysicalDisks = Import-Clixml ($Path + "GetPhysicalDisk.XML")
    } else {
        try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $PhysicalDisks = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $SubSystem }
        catch { Show-Error("Unable to get Physical Disks. `nError="+$_.Exception.Message) }
        $PhysicalDisks | Export-Clixml ($Path + "GetPhysicalDisk.XML")
    }

    $PDsTotal = NCount($PhysicalDisks)
    $PDsHealthy = NCount($PhysicalDisks | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    "Physical Disks Healthy        : $PDsHealthy / $PDsTotal"

    if ($PDsTotal -lt $ExpectedPhysicalDisks) { Show-Warning "Fewer physical disks than the $ExpectedPhysicalDisks expected" }
    if ($PDsHealthy -lt $PDsTotal) { Show-Warning "Unhealthy physical disks detected" }
    if ($Read) {
        $PhysicalDiskSNV = Import-Clixml ($Path + "GetPhysicalDiskSNV.XML")
    } else {
        try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $PhysicalDiskSNV = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $SubSystem | Get-PhysicalDiskSNV }
        catch { Show-Error("Unable to get Physical Disk Storage Node View. `nError="+$_.Exception.Message) }
        $PhysicalDiskSNV | Export-Clixml ($Path + "GetPhysicalDiskSNV.XML")
    }

    # Reliability counters

    if ($Read) {
        if (Test-Path ($Path + "GetReliabilityCounter.XML")) {
            $ReliabilityCounters = Import-Clixml ($Path + "GetReliabilityCounter.XML")
        } else {
            Show-Warning "Reliability Counters not gathered for this capture"
        }
    } else {
        if ($IncludeReliabilityCounters -eq $true) {
            try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
                  $ReliabilityCounters = $PhysicalDisks | Get-StorageReliabilityCounter -CimSession $AccessNode }
            catch { Show-Error("Unable to get Storage Reliability Counters. `nError="+$_.Exception.Message) }
            $ReliabilityCounters | Export-Clixml ($Path + "GetReliabilityCounter.XML")
        }
    }

    # Storage enclosure health - only performed if the required KB is present

    if (-not (Get-Command *StorageEnclosure*)) {
        Show-Warning "Storage Enclosure commands not available. See http://support.microsoft.com/kb/2913766/en-us"
    } else {
        if ($Read) {
            if (Test-Path ($Path + "GetStorageEnclosure.XML") -ErrorAction SilentlyContinue ) {
               $StorageEnclosures = Import-Clixml ($Path + "GetStorageEnclosure.XML")
            } else {
               $StorageEnclosures = ""
            }
        } else {
            try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
                  $StorageEnclosures = Get-StorageEnclosure -CimSession $AccessNode -StorageSubSystem $SubSystem }
            catch { Show-Error("Unable to get Enclosures. `nError="+$_.Exception.Message) }
            $StorageEnclosures | Export-Clixml ($Path + "GetStorageEnclosure.XML")
        }

        $EncsTotal = NCount($StorageEnclosures)
        $EncsHealthy = NCount($StorageEnclosures | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
        "Storage Enclosures Healthy    : $EncsHealthy / $EncsTotal "

        if ($EncsTotal -lt $ExpectedEnclosures) { Show-Warning "Fewer storage enclosures than the $ExpectedEnclosures expected" }
        if ($EncsHealthy -lt $EncsTotal) { Show-Warning "Unhealthy storage enclosures detected" }
    }   

    #
    # Phase 2
    #
    Show-Update "<<< Phase 2 - details on unhealthy components >>>`n" -ForegroundColor Cyan

    $Failed = $False

    if ($NodesTotal -ne $NodesHealthy) { 
        $Failed = $true; 
        "Cluster Nodes:"; 
        $ClusterNodes | Where-Object State -ne "Up" | Format-Table -AutoSize 
    }

    if ($NetsTotal -ne $NetsHealthy) { 
        $Failed = $true; 
        "Cluster Networks:"; 
        $ClusterNetworks | Where-Object State -ne "Up" | Format-Table -AutoSize 
    }

    if ($ResTotal -ne $ResHealthy) { 
        $Failed = $true; 
        "Cluster Resources:"; 
        $ClusterResources | Where-Object State -notlike "Online" | Format-Table -AutoSize 
    }

    if ($CSVTotal -ne $CSVHealthy) { 
        $Failed = $true; 
        "Cluster Shared Volumes:"; 
        $CSV | Where-Object State -ne "Online" | Format-Table -AutoSize 
    }

    if ($VolsTotal -ne $VolsHealthy) { 
        $Failed = $true; 
        "Volumes:"; 
        $Volumes | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) }  | 
        Format-Table Path, HealthStatus  -AutoSize
    }

    if ($DedupTotal -ne $DedupHealthy) { 
        $Failed = $true; 
        "Volumes:"; 
        $DedupVolumes | Where-Object LastOptimizationResult -eq 0 | 
        Format-Table Volume, Capacity, SavingsRate, LastOptimizationResultMessage -AutoSize
    }

    if ($VDsTotal -ne $VDsHealthy) { 
        $Failed = $true; 
        "Virtual Disks:"; 
        $VirtualDisks | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName, HealthStatus, OperationalStatus, ResiliencySettingName, IsManualAttach  -AutoSize 
    }

    if ($PoolsTotal -ne $PoolsHealthy) { 
        $Failed = $true; 
        "Storage Pools:"; 
        $StoragePools | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName, HealthStatus, OperationalStatus, IsReadOnly -AutoSize 
    }

    if ($PDsTotal -ne $PDsHealthy) { 
        $Failed = $true; 
        "Physical Disks:"; 
        $PhysicalDisks | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName, EnclosureNumber, SlotNumber, HealthStatus, OperationalStatus, Usage -AutoSize
    }

    if (Get-Command *StorageEnclosure*)
    {
        if ($EncsTotal -ne $EncsHealthy) { 
            $Failed = $true; "Enclosures:";
            $StorageEnclosures | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
            Format-Table FriendlyName, HealthStatus, ElementTypesInError -AutoSize 
        }
    }

    if ($ShTotal -ne $ShHealthy) { 
        $Failed = $true; 
        "CA Shares:";
        $ShareStatus | Where-Object Health -notlike "Healthy" | Format-Table -AutoSize
    }

    if (-not $Failed) { 
        "`nNo unhealthy components" 
    }

    #
    # Phase 3
    #
    Show-Update "<<< Phase 3 - Firmware and drivers >>>`n" -ForegroundColor Cyan

    Show-Update "Devices and drivers by Model and Driver Version per cluster node" 

    if (-not $Read) {

        $j = @()
        foreach ($node in $ClusterNodes.Name) {
            try {
                $j += Start-Job -Name $node {
                        Get-CimInstance -ClassName Win32_PnPSignedDriver -ComputerName $using:node |
                            Export-Clixml ($using:Path + $using:node + "_GetDrivers.XML")
                        }
            } catch {
                Show-Error("Unable to get Drivers on node $node. `nError="+$_.Exception.Message)
            }
        }

        $null = $j | Wait-Job
        $j | Receive-Job
        $j | Remove-Job
    }

    foreach ($node in $ClusterNodes) {
        "`nCluster Node: $node"
        Import-Clixml ($Path + $node + "_GetDrivers.XML") |? {
            ($_.DeviceCLass -eq 'SCSIADAPTER') -or ($_.DeviceCLass -eq 'NET') } |
            Group-Object DeviceName,DriverVersion |
            Sort Name |
            ft -AutoSize Count,
                @{ Expression = { $_.Group[0].DeviceName }; Label = "DeviceName" },
                @{ Expression = { $_.Group[0].DriverVersion }; Label = "DriverVersion" },
                @{ Expression = { $_.Group[0].DriverDate }; Label = "DriverDate" }
    }

    "`nPhysical disks by Media Type, Model and Firmware Version" 
    $PhysicalDisks | Group-Object MediaType,Model,FirmwareVersion |
        ft -AutoSize Count,
            @{ Expression = { $_.Group[0].Model }; Label="Model" },
            @{ Expression = { $_.Group[0].FirmwareVersion }; Label="FirmwareVersion" },
            @{ Expression = { $_.Group[0].MediaType }; Label="MediaType" }

 
    if ( -not (Get-Command *StorageEnclosure*) ) {
        Show-Warning "Storage Enclosure commands not available. See http://support.microsoft.com/kb/2913766/en-us"
    } else {
        "Storage Enclosures by Model and Firmware Version"
        $StorageEnclosures | Group-Object Model,FirmwareVersion |
            ft -AutoSize Count,
                @{ Expression = { $_.Group[0].Model }; Label="Model" },
                @{ Expression = { $_.Group[0].FirmwareVersion }; Label="FirmwareVersion" }
    }
    
    #
    # Phase 4 Prep
    #
    Show-Update "<<< Phase 4 - Pool, Physical Disk and Volume Details >>>" -ForegroundColor Cyan

	if ($IncludeAssociations) {
	
		if ($Read) {
			$Associations = Import-Clixml ($Path + "GetAssociations.XML")
			$SNVView = Import-Clixml ($Path + "GetStorageNodeView.XML")
		} else {
			"`nCollecting device associations..."
			try {
				$Associations = $AssocJob | Wait-Job | Receive-Job
				$AssocJob | Remove-Job
				if ($null -eq $Associations) {
					Show-Warning "Unable to get object associations"
				}
				$Associations | Export-Clixml ($Path + "GetAssociations.XML")

				"`nCollecting storage view associations..."
				$SNVView = $SNVJob | Wait-Job | Receive-Job
				$SNVJob | Remove-Job
				if ($null -eq $SNVView) {
					Show-Warning "Unable to get nodes storage view associations"
				}
				$SNVView | Export-Clixml ($Path + "GetStorageNodeView.XML")        
			} catch {
				Show-Warning "Not able to query associations.."
			}
		}
	}

    #
    # Phase 4
    #

	if ($IncludeHealthReport) {
		"`n[Health Report]" 
		"`nVolumes with status, total size and available size, sorted by Available Size" 
		"Notes: Sizes shown in gigabytes (GB). * means multiple shares on that volume"

		$Volumes | Where-Object FileSystem -eq CSVFS | Sort-Object SizeRemaining | 
		Format-Table -AutoSize @{Expression={$poolName = VolumeToPool($_.Path); "[$(PoolOperationalStatus($_.Path))/$(PoolHealthStatus($_.Path))] " + $poolName};Label="[OpStatus/Health] Pool"}, 
		@{Expression={(PoolHealthyPDs(VolumeToPool($_.Path)))};Label="HealthyPhysicalDisks"; Align="Center"}, 
		@{Expression={$vd = VolumeToVD($_.Path);  "[$(VDOperationalStatus($_.Path))/$(VDHealthStatus($_.Path))] "+$vd};Label="[OpStatus/Health] VirtualDisk"}, 
		@{Expression={$csvVolume = VolumeToCSV($_.Path); "[" + $_.HealthStatus + "] " + $csvVolume};Label="[Health] CSV Volume"},
		@{Expression={$csvName = VolumeToCSVName($_.Path); $csvStatus = CSVStatus($_.Path);  " [$csvStatus] " + $csvName};Label="[Status] CSV Name"}, 
		@{Expression={CSVToNode(VolumeToCSV($_.Path))};Label="Volume Owner"},   
		@{Expression={VolumeToShare($_.Path)};Label="Share Name"}, 
		@{Expression={$VolResiliency = VolumeToResiliency($_.Path); $volColumns = VolumeToColumns($_.Path); "$VolResiliency,$volColumns" +"Col" };Label="Volume Configuration"},        
		@{Expression={"{0:N2}" -f ($_.Size/1GB)};Label="Total Size";Width=11;Align="Right"},  
		@{Expression={"{0:N2}" -f ($_.SizeRemaining/$_.Size*100)};Label="Avail%";Width=11;Align="Right"} 

		if ($DedupEnabled -and ($DedupTotal -gt 0))
		{
			"Dedup Volumes with status, total size and available size, sorted by Savings %" 
			"Notes: Sizes shown in gigabytes (GB). * means multiple shares on that volume"

			$DedupVolumes | Sort-Object SavingsRate -Descending | 
			Format-Table -AutoSize @{Expression={$poolName = VolumeToPool($_.VolumeId); "[$(PoolOperationalStatus($_.VolumeId))/$(PoolHealthStatus($_.VolumeId))] " + $poolName};Label="[OpStatus/Health] Pool"},  
			@{Expression={(PoolHealthyPDs(VolumeToPool($_.VolumeId)))};Label="HealthyPhysicalDisks"; Align="Center"}, 
			@{Expression={$vd = VolumeToVD($_.VolumeId);  "[$(VDOperationalStatus($_.VolumeId))/$(VDHealthStatus($_.VolumeId))] "+$vd};Label="[OpStatus/Health] VirtualDisk"},  
			@{Expression={VolumeToCSV($_.VolumeId)};Label="Volume "},
			@{Expression={VolumeToShare($_.VolumeId)};Label="Share"},
			@{Expression={"{0:N2}" -f ($_.Capacity/1GB)};Label="Capacity";Width=11;Align="Left"}, 
			@{Expression={"{0:N2}" -f ($_.UnoptimizedSize/1GB)};Label="Before";Width=11;Align="Right"}, 
			@{Expression={"{0:N2}" -f ($_.UsedSpace/1GB)};Label="After";Width=11;Align="Right"}, 
			@{Expression={"{0:N2}" -f ($_.SavingsRate)};Label="Savings%";Width=11;Align="Right"}, 
			@{Expression={"{0:N2}" -f ($_.FreeSpace/1GB)};Label="Free";Width=11;Align="Right"}, 
			@{Expression={"{0:N2}" -f ($_.FreeSpace/$_.Capacity*100)};Label="Free%";Width=11;Align="Right"},
			@{Expression={"{0:N0}" -f ($_.InPolicyFilesCount)};Label="Files";Width=11;Align="Right"}
		}
    
		if ($SNVView) {
			"`n[Storage Node view]"
			$SNVView | sort StorageNode,StorageEnclosure | Format-Table -AutoSize @{Expression = {$_.StorageNode}; Label = "StorageNode"; Align = "Left"},
			@{Expression = {$_.StoragePool}; Label = "StoragePool"; Align = "Left"},
			@{Expression = {$_.MPIOPolicy}; Label = "MPIOPolicy"; Align = "Left"},
			@{Expression = {$_.MPIOState}; Label = "MPIOState"; Align = "Left"},
			@{Expression = {$_.PathID}; Label = "PathID"; Align = "Left"},
			@{Expression = {$_.PathState}; Label = "PathState"; Align = "Left"},
			@{Expression = {$_.PhysicalDiskUID}; Label = "PhysicalDiskUID"; Align = "Left"},
			@{Expression = {$_.StorageEnclosure}; Label = "StorageEnclosureLocation"; Align = "Left"} 
		}

		"`n[Capacity Report]"
		"Physical disks by Enclosure, Media Type and Health Status, with total and unallocated space" 
		"Note: Sizes shown in gigabytes (GB)"

		$PDStatus = $PhysicalDisks | Where-Object EnclosureNumber -ne $null | 
		Sort-Object EnclosureNumber, MediaType, HealthStatus |  
		Group-Object EnclosureNumber, MediaType, HealthStatus | 
		Select-Object Count, TotalSize, Unalloc, 
		@{Expression={$_.Name.Split(",")[0].Trim().TrimEnd()}; Label="Enc"},
		@{Expression={$_.Name.Split(",")[1].Trim().TrimEnd()}; Label="Media"},
		@{Expression={$_.Name.Split(",")[2].Trim().TrimEnd()}; Label="Health"}

		$PDStatus |% {
			$Current = $_
			$TotalSize = 0
			$Unalloc = 0
			$PDCurrent = $PhysicalDisks | Where-Object { ($_.EnclosureNumber -eq $Current.Enc) -and ($_.MediaType -eq $Current.Media) -and ($_.HealthStatus -eq $Current.Health) }
			$PDCurrent |% {
				$Unalloc += $_.Size - $_.AllocatedSize
				$TotalSize +=$_.Size
			}
        
			$Current.Unalloc = $Unalloc
			$Current.TotalSize = $TotalSize
		}

		$PDStatus | Format-Table -AutoSize Enc, Media, Health, Count, 
		@{Expression={"{0:N2}" -f ($_.TotalSize/$_.Count/1GB)};Label="Avg Size";Width=11;Align="Right"}, 
		@{Expression={"{0:N2}" -f ($_.TotalSize/1GB)};Label="Total Size";Width=11;Align="Right"}, 
		@{Expression={"{0:N2}" -f ($_.Unalloc/1GB)};Label="Unallocated";Width=11;Align="Right"},
		@{Expression={"{0:N2}" -f ($_.Unalloc/$_.TotalSize*100)};Label="Unalloc %";Width=11;Align="Right"} 

		"Pools with health, total size and unallocated space" 
		"Note: Sizes shown in gigabytes (GB)"

		$StoragePools | Sort-Object FriendlyName | 
		Format-Table -AutoSize @{Expression={$_.FriendlyName};Label="Name"}, 
		@{Expression={$_.HealthStatus};Label="Health"}, 
		@{Expression={"{0:N2}" -f ($_.Size/1GB)};Label="Total Size";Width=11;Align="Right"}, 
		@{Expression={"{0:N2}" -f (($_.Size-$_.AllocatedSize)/1GB)};Label="Unallocated";Width=11;Align="Right"}, 
		@{Expression={"{0:N2}" -f (($_.Size-$_.AllocatedSize)/$_.Size*100)};Label="Unalloc%";Width=11;Align="Right"} 

	}

    #
    # Phase 5
    #
    Show-Update "<<< Phase 5 - Storage Performance >>>`n" -ForegroundColor Cyan

    if ((-not $Read) -and (-not $IncludePerformance)) {
       "Performance was excluded by a parameter`n"
    }

    if ((-not $Read) -and $IncludePerformance) {

        "Please wait for $PerfSamples seconds while performance samples are collected."
		Write-Progress -Activity "Gathering counters" -CurrentOperation "Start monitoring"

        $PerfNodes = $ClusterNodes |% {$_.Name}
		$set=Get-Counter -ListSet *"virtual disk"*, *"hybrid"*, *"cluster storage"*, *"cluster csv"*,*"storage spaces"* -ComputerName $PerfNodes

        #$PerfCounters = "reads/sec","writes/sec","read latency","write latency"
        #$PerfItems = $PerfNodes |% { $Node=$_; $PerfCounters |% { ("\\"+$Node+"\Cluster CSV File System(*)\"+$_) } }
        #$PerfRaw = Get-Counter -Counter $PerfItems -SampleInterval 1 -MaxSamples $PerfSamples

		$PerfRaw=Get-Counter -Counter $set.Paths -SampleInterval 1 -MaxSamples $PerfSamples -ErrorAction Ignore -WarningAction Ignore
		Write-Progress -Activity "Gathering counters" -CurrentOperation "Exporting counters"
		$PerfRaw | Export-counter -Path ($Path + "GetCounters.blg") -Force -FileFormat BLG
		Write-Progress -Activity "Gathering counters" -Completed

		if ($ProcessCounter) {
			"Collected $PerfSamples seconds of raw performance counters. Processing...`n"
			$Count1 = 0
			$Total1 = $PerfRaw.Count

			if ($Total1 -gt 0) {

				$PerfDetail = $PerfRaw |% { 
					$TimeStamp = $_.TimeStamp
        
					$Progress = $Count1 / $Total1 * 45
					$Count1++
					Write-Progress -Activity "Processing performance samples" -PercentComplete $Progress

					$_.CounterSamples |% { 
						$DetailRow = "" | Select-Object Time, Pool, Owner, Node, Volume, Share, Counter, Value
						$Split = $_.Path.Split("\")
						$DetailRow.Time = $TimeStamp
						$DetailRow.Node = $Split[2]
						$DetailRow.Volume = $_.InstanceName
						$DetailRow.Counter = $Split[4]
						$DetailRow.Value = $_.CookedValue
						$DetailRow
					} 
				}

				Write-Progress -Activity "Processing performance samples" -PercentComplete 50
				$PerfDetail = $PerfDetail | Sort-Object Volume

				$Last = $PerfDetail.Count - 1
				$Volume = ""
    
				$PerfVolume = 0 .. $Last |% {

					if ($Volume -ne $PerfDetail[$_].Volume) {
						$Volume = $PerfDetail[$_].Volume
						$Pool = CSVToPool ($Volume)
						$Owner = CSVToNode ($Volume)
						$Share = CSVToShare ($Volume)
						$ReadIOPS = 0
						$WriteIOPS = 0
						$ReadLatency = 0
						$WriteLatency = 0
						$NonZeroRL = 0
						$NonZeroWL = 0

						$Progress = 55 + ($_ / $Last * 45 )
						Write-Progress -Activity "Processing performance samples" -PercentComplete $Progress
					}

					$PerfDetail[$_].Pool = $Pool
					$PerfDetail[$_].Owner = $Owner
					$PerfDetail[$_].Share = $Share

					$Value = $PerfDetail[$_].Value

					Switch ($PerfDetail[$_].Counter) {
						"reads/sec" { $ReadIOPS += $Value }
						"writes/sec" { $WriteIOPS += $Value }
						"read latency" { $ReadLatency += $Value; if ($Value -gt 0) {$NonZeroRL++} }
						"write latency" { $WriteLatency += $Value; if ($Value -gt 0) {$NonZeroWL++} }
						default { Write-Warning ?Invalid counter? }
					}

					if ($_ -eq $Last) { 
						$EndofVolume = $true 
					} else { 
						if ($Volume -ne $PerfDetail[$_+1].Volume) { 
							$EndofVolume = $true 
						} else { 
							$EndofVolume = $false 
						}
					}

					if ($EndofVolume) {
						$VolumeRow = "" | Select-Object Pool, Volume, Share, ReadIOPS, WriteIOPS, TotalIOPS, ReadLatency, WriteLatency, TotalLatency
						$VolumeRow.Pool = $Pool
						$VolumeRow.Volume = $Volume
						$VolumeRow.Share = $Share
						$VolumeRow.ReadIOPS = [int] ($ReadIOPS / $PerfSamples *  10) / 10
						$VolumeRow.WriteIOPS = [int] ($WriteIOPS / $PerfSamples * 10) / 10
						$VolumeRow.TotalIOPS = $VolumeRow.ReadIOPS + $VolumeRow.WriteIOPS
						if ($NonZeroRL -eq 0) {$NonZeroRL = 1}
						$VolumeRow.ReadLatency = [int] ($ReadLatency / $NonZeroRL * 1000000 ) / 1000 
						if ($NonZeroWL -eq 0) {$NonZeroWL = 1}
						$VolumeRow.WriteLatency = [int] ($WriteLatency / $NonZeroWL * 1000000 ) / 1000
						$VolumeRow.TotalLatency = [int] (($ReadLatency + $WriteLatency) / ($NonZeroRL + $NonZeroWL) * 1000000) / 1000
						$VolumeRow
					 }
				}
    
			} else {
				Show-Warning "Unable to collect performance information"
				$PerfVolume = @()
				$PerfDetail = @()
			}

			$PerfVolume | Export-Clixml ($Path + "GetVolumePerf.XML")
			$PerfDetail | Export-Csv ($Path + "VolumePerformanceDetails.TXT")
		}
    }

    #
    # Phase 6
    #
    Show-Update "<<< Phase 6 - Events and Logs >>>`n" -ForegroundColor Cyan

    if ((-not $Read) -and (-not $IncludeEvents)) {
       "Events were excluded by a parameter`n"
    }

    if ((-not $Read) -and $IncludeEvents) {

        Show-Update "Starting Export of Cluster Logs..." 

        # Cluster log collection will take some time. 
        # Using Start-Job to run them in the background, while we collect events and other diagnostic information

        $ClusterLogJob = Start-Job -ArgumentList $ClusterName,$Path { 
            param($c,$p)
            Get-ClusterLog -Cluster $c -Destination $p -UseLocalTime
            if ($using:S2DEnabled -eq $true) {
                Get-ClusterLog -Cluster $c -Destination $p -Health -UseLocalTime
            }
        }

        Show-Update "Exporting Event Logs..." 

        $AllErrors = @();

        $j = Invoke-Command -ArgumentList $HoursOfEvents -ComputerName $($ClusterNodes).Name -AsJob {

            Param([int] $Hours)

            # import common functions
            iex $using:CommonFunc

            # Calculate number of milliseconds and prepare the WEvtUtil parameter to filter based on date/time
            if ($Hours -ne -1) {
                $MSecs = $Hours * 60 * 60 * 1000
            } else {
                $MSecs = -1
            }               

            $QTime = "*[System[TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"

            $Node = $env:COMPUTERNAME
            $NodePath = [System.IO.Path]::GetTempPath()

            # Log prefixes to gather. Note that this is a simple pattern match; for instance, there are a number of
            # different providers that match *Microsoft-Windows-Storage*: Storage, StorageManagement, StorageSpaces, etc.
            $LogPatterns = 'Microsoft-Windows-Storage',
                           'Microsoft-Windows-SMB',
                           'Microsoft-Windows-FailoverClustering',
                           'Microsoft-Windows-VHDMP',
                           'Microsoft-Windows-Hyper-V',
                           'Microsoft-Windows-ResumeKeyFilter',
                           'Microsoft-Windows-REFS',
                           'Microsoft-Windows-WMI-Activity',
                           'Microsoft-Windows-NTFS',
                           'Microsoft-Windows-NDIS',
                           'Microsoft-Windows-Network',
                           'Microsoft-Windows-TCPIP',
                           'Microsoft-Windows-ClusterAwareUpdating',
                           'Microsoft-Windows-HostGuardian',
                           'Microsoft-Windows-Kernel',
						   'Microsoft-Windows-StorageSpaces',
                           'Microsoft-Windows-DataIntegrityScan',
						   'Microsoft-Windows-SMB' |% { "$_*" }

            # Exclude verbose/lower value channels
            # The FailoverClustering Diagnostics are reflected in the cluster logs, already gathered (and large)
            # StorageSpaces Performance is very expensive to export and not usually needed
            $LogPatternsToExclude = 'Microsoft-Windows-FailoverClustering/Diagnostic',
                                    'Microsoft-Windows-FailoverClustering-Client/Diagnostic',
                                    'Microsoft-Windows-StorageSpaces-Driver/Performance' |% { "$_*" }

            # Core logs to gather, by explicit names.
            $LogPatterns += 'System','Application'

            $Logs = Get-WinEvent -ListLog $LogPatterns -Force -ErrorAction Ignore -WarningAction Ignore

            # now apply exclusions
            $Logs = $Logs |? {
                $Log = $_.LogName
                $m = ($LogPatternsToExclude |% { $Log -like $_ } | measure -sum).sum
                -not $m
            }

            $Logs |% {
        
                $NodeFile = $NodePath+$Node+"_UnfilteredEvent_"+$_.LogName.Replace("/","-")+".EVTX"

                # Export unfiltered log file using the WEvtUtil command-line tool
            
                if ($_.LogName -like "Microsoft-Windows-FailoverClustering-ClusBflt/Management"  -Or ($MSecs -eq -1)) {
                    WEvtUtil.exe epl $_.LogName $NodeFile /ow:true
                } else {
                    WEvtUtil.exe epl $_.LogName $NodeFile /q:$QTime /ow:true
                }
                Write-Output (Get-AdminSharePathFromLocal $Node $NodeFile)
            }
        }

        $null = Wait-Job $j
        Show-JobRuntime $j.childjobs

        Show-Update "Copying Event Logs...."

        # keep parallelizing on receive at the individual node/child job level
        $copyjobs = @()
        $j.ChildJobs |% {
            $logs = Receive-Job $_

            $copyjobs += start-job -Name "Copy $($_.Location)" {

                $using:logs |% {
                    Copy-Item $_ $using:Path -Force -ErrorAction SilentlyContinue -Verbose
                    Remove-Item $_ -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $null = Wait-Job $copyjobs
        Remove-Job $j
        Remove-Job $copyjobs

        Show-Update "Gathering System Info, Reports and Minidump files ..." 

        $j = $ClusterNodes |% {

            Start-Job -Name $_.Name -ArgumentList $_.Name,$Cluster.Domain {

                param($NodeName,$DomainName)

                $Node = "$NodeName.$DomainName"

                # Gather SYSTEMINFO.EXE output for a given node

                $LocalFile = $using:Path+$Node+"_SystemInfo.TXT"
                SystemInfo.exe /S $Node >$LocalFile

                # cmd is of the form "cmd arbitraryConstantArgs -argForComputerOrSessionSpecification"
                # will be trimmed to "cmd" for logging
                # _C_ token will be replaced with node for cimsession/computername callouts
			    $CmdsToLog = "Get-NetAdapter -CimSession _C_",
                                "Get-NetAdapterAdvancedProperty -CimSession _C_",
                                "Get-NetIpAddress -CimSession _C_",
                                "Get-NetRoute -CimSession _C_",
                                "Get-NetQosPolicy -CimSession _C_",
                                "Get-NetIPv4Protocol -CimSession _C_",
                                "Get-NetIPv6Protocol -CimSession _C_",
                                "Get-NetOffloadGlobalSetting -CimSession _C_",
                                "Get-NetPrefixPolicy -CimSession _C_",
                                "Get-NetTCPConnection -CimSession _C_",
                                "Get-NetTcpSetting -CimSession _C_",
                                "Get-NetAdapterBinding -CimSession _C_",
                                "Get-NetAdapterChecksumOffload -CimSession _C_",
                                "Get-NetAdapterLso -CimSession _C_",
                                "Get-NetAdapterRss -CimSession _C_",
                                "Get-NetAdapterRdma -CimSession _C_",
                                "Get-NetAdapterIPsecOffload -CimSession _C_",
                                "Get-NetAdapterPacketDirect -CimSession _C_", 
                                "Get-NetAdapterRsc -CimSession _C_",
                                "Get-NetLbfoTeam -CimSession _C_",
                                "Get-NetLbfoTeamNic -CimSession _C_",
                                "Get-NetLbfoTeamMember -CimSession _C_",
                                "Get-SmbServerNetworkInterface -CimSession _C_",
                                "Get-HotFix -ComputerName _C_",
                                "Get-ScheduledTask -CimSession _C_ | Get-ScheduledTaskInfo -CimSession _C_"

			    foreach ($cmd in $CmdsToLog)
			    {
                    # truncate cmd string to the cmd itself
				    $LocalFile = $using:Path + (($cmd.split(' '))[0] -replace "-","") + "-$($Node)"
				    try {

                        $out = iex ($cmd -replace '_C_',$Node)

                        # capture as txt and xml for quick analysis according to taste
                        $out | Out-File -Width 9999 -Encoding ascii -FilePath "$LocalFile.txt"
                        $out | Export-Clixml -Path "$LocalFile.xml"

                    } catch {
                        Show-Warning "'$cmd $node' failed for node $Node"
                    }
			    }

                $NodePath = Invoke-Command -ComputerName $Node { $env:SystemRoot }

                if ($using:IncludeDumps -eq $true) {
                    # Enumerate minidump files for a given node

                    try {
                        $RPath = (Get-AdminSharePathFromLocal $Node (Join-Path $NodePath "Minidump\*.dmp"))
                        $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }                       
                    catch { $DmpFiles = ""; Show-Warning "Unable to get minidump files for node $Node" }

                    # Copy minidump files from the node

                    $DmpFiles |% {
                        $LocalFile = $using:Path + $Node + "_" + $_.Name 
                        try { Copy-Item $_.FullName $LocalFile } 
                        catch { Show-Warning("Could not copy minidump file $_.FullName") }
                    }        

                    try { 
                        $RPath = (Get-AdminSharePathFromLocal $Node (Join-Path $NodePath "LiveKernelReports\*.dmp"))
                        $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }                       
                    catch { $DmpFiles = ""; Show-Warning "Unable to get LiveKernelReports files for node $Node" }

                    # Copy LiveKernelReports files from the node

                    $DmpFiles |% {
                        $LocalFile = $using:Path + $Node + "_" + $_.Name 
                        try { Copy-Item $_.FullName $LocalFile } 
                        catch { Show-Warning "Could not copy LiveKernelReports file $_.FullName" }
                    }        
                }

                try {
                    $RPath = (Get-AdminSharePathFromLocal $Node (Join-Path $NodePath "Cluster\Reports\*.*"))
                    $RepFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }
                catch { $RepFiles = ""; Show-Warning "Unable to get reports for node $Node" }

                # Copy logs from the Report directory; exclude cluster/health logs which we're getting seperately
                $RepFiles |% {
                    if (($_.Name -notlike "Cluster.log") -and ($_.Name -notlike "ClusterHealth.log")) {
                        $LocalFile = $using:Path + $Node + "_" + $_.Name
                        try { Copy-Item $_.FullName $LocalFile }
                        catch { Show-Warning "Could not copy report file $_.FullName" }
                    }
                }
            }
        }

        $null = Wait-Job $j
        Show-JobRuntime $j
        Remove-Job $j

        Write-Progress -Activity "Gathering System Info and Minidump files" -Completed

        Show-Update "Receiving Cluster Logs..."
        $ClusterLogJob | Wait-Job | Receive-Job | ft -AutoSize
        $ClusterLogJob | Remove-Job

        Show-Update "All Logs Received`n"
    }

    if ($Read) { 
        try { $ErrorSummary = Import-Clixml ($Path + "GetAllErrors.XML") }
        catch { $ErrorSummary = @() }
    }

    if ($S2DEnabled -ne $true) { 
        if ((([System.Environment]::OSVersion.Version).Major) -ge 10) {
            Show-Update "Gathering the storage diagnostic information"
            $deleteStorageSubsystem = $false
            if (-not (Get-StorageSubsystem -FriendlyName Clustered*)) {
                $storageProviderName = (Get-StorageProvider -CimSession $ClusterName | ? Manufacturer -match 'Microsoft').Name
                $registeredSubSystem = Register-StorageSubsystem -ProviderName $storageProviderName -ComputerName $ClusterName -ErrorAction SilentlyContinue
                $deleteStorageSubsystem = $true
                $storagesubsystemToDelete = Get-StorageSubsystem -FriendlyName Clustered*
            }
            $destinationPath = Join-Path -Path $Path -ChildPath 'StorageDiagnosticInfo'
            if (Test-Path -Path $destinationPath) {
                Remove-Item -Path $destinationPath -Recurse -Force
            }
            New-Item -Path $destinationPath -ItemType Directory
            $clusterSubsystem = (Get-StorageSubSystem | Where-Object Model -eq 'Clustered Windows Storage').FriendlyName
            Stop-StorageDiagnosticLog -StorageSubSystemFriendlyName $clusterSubsystem -ErrorAction SilentlyContinue
            if ($IncludeLiveDump) {
                Get-StorageDiagnosticInfo -StorageSubSystemFriendlyName $clusterSubsystem -IncludeLiveDump -DestinationPath $destinationPath
            } else {
                Get-StorageDiagnosticInfo -StorageSubSystemFriendlyName $clusterSubsystem -DestinationPath $destinationPath
            }
            
            if ($deleteStorageSubsystem) {
                Unregister-StorageSubsystem -StorageSubSystemUniqueId $storagesubsystemToDelete.UniqueId -ProviderName Windows*
            }
        }
    }    

    #
    # Phase 7
    #

    #
    # Force GC so that any pending file references are
    # torn down. If they live, they will block removal
    # of content.
    #

    [System.GC]::Collect()

    if (-not $read) {
        Show-Update "<<< Phase 7 - Compacting files for transport >>>`n" -ForegroundColor Cyan

        $ZipSuffix = '-{0}{1:00}{2:00}-{3:00}{4:00}' -f $TodayDate.Year,$TodayDate.Month,$TodayDate.Day,$TodayDate.Hour,$TodayDate.Minute
        $ZipSuffix = "-" + $Cluster.Name + $ZipSuffix
        $ZipPath = $ZipPrefix+$ZipSuffix+".ZIP"

        # Stop Transcript
        Stop-Transcript
        
        try {
            Show-Update "Creating Zip file ..."

            Add-Type -Assembly System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Path, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
            Show-Update "Zip File Name : $ZipPath"

            Show-Update "Cleaning up temporary directory $Path"
            Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse

        } catch {
            Show-Error("Error creating the ZIP file!`nContent remains available at $Path") 
        }

        Show-Update "Cleaning up CimSessions"
        Get-CimSession | Remove-CimSession
    }

    Show-Update "COMPLETE"
}

##
# PCStorageDiagnosticInfo Reporting
##

enum ReportLevelType
{
    Summary = 0
    Standard
    Full
}

# Report Types. Ordering here is reflects output ordering when multiple reports are specified.

enum ReportType
{
    All = 0
    StorageBusCache
    StorageBusConnectivity
    StorageLatency
    StorageFirmware
    LSIEvent
}

# helper function to parse the csv-demarcated sections of the cluster log
# return value is a hashtable indexed by section name

function Get-ClusterLogDataSources(
    [string] $logname
    )
{

    BEGIN {
        $csvf = New-TemporaryFile
        $sr = [System.IO.StreamReader](gi $logname).FullName
        $datasource = @{}
    }

    PROCESS {

        ##
        # Parse cluster log for all csv datasources. Recognize by a heuristic of >4 comma-seperated values
        #   immediately after the block header [=== name ===]
        #
        # Final line to parse is the System block, which is after all potential datasources.
        ## 

        $firstline = $false
        $in = $false
        $section = $null

        do {

            $l = $sr.ReadLine()
        
            # Heuristic ...
            # SBL Disks comes before System

            if ($in) {

                # if first line of section, detect if CSV
                if ($firstline) {

                    $firstline = $false

                    #if not csv, go back to looking for blocks
                    if (($l -split ',').count -lt 4) {
                        $in = $false
                    } else {
                        
                        # bug workaround
                        # the Resources section has a duplicate _embeddedFailureAction
                        # rename the first to an ignore per DaUpton
                        # using the non-greedy match gives us the guarantee of picking out the first instance

                        if ($section -eq 'Resources' -and $l -match '^(.*?)(_embeddedFailureAction)(.*)$') {
                            $l = $matches[1]+"ignore"+$matches[3]
                        }

                        # number all ignore fields s.t. duplicates become unique (Networks section)
                        $n = 0
                        while ($l -match '^(.*?)(,ignore,)(.*)$') {
                            $l = $matches[1]+",ignore$n,"+$matches[3]
                            $n += 1
                        }
                                                                        
                        # place in csv temporary file
                        $l | out-file -Encoding ascii -Width 9999 $csvf
                    }

                } else {

                    # parsing
                    # in section, blank line terminates
                    if ($l -notmatch '^\s*$') {
                        $l | out-file -Append -Encoding ascii -Width 9999 $csvf
                    } else {
                        # at end; parse was good
                        # import the csv and insert into the datasource table
                        $datasource[$section] = import-csv $csvf

                        # reset parser
                        $in = $false
                        $section = $null
                    }
                }

            } elseif ($l -match '^\[===\s(.*)\s===\]') {

                # done at the start of the System block
                if ($matches[1] -eq 'System') { break }
                
                # otherwise prepare to parse
                $section = $matches[1]
                $in = $true
                $firstline = $true
            }
        
        } while (-not $sr.EndOfStream)
    }

    END {
        $datasource        
        $sr.Close()
        del $csvf
    }
}

# helper function which trims the full-length disk state
function Format-StorageBusCacheDiskState(
    [string] $DiskState
    )
{
    $DiskState -replace 'CacheDiskState',''
}

function Get-StorageBusCacheReport
{
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$true)]
        [ReportLevelType]
        $ReportLevel
    )

    <#
    These are the possible DiskStates

    typedef enum
    {
        CacheDiskStateUnknown                   = 0,
        CacheDiskStateConfiguring               = 1,
        CacheDiskStateInitialized               = 2,
        CacheDiskStateInitializedAndBound       = 3,     <- expected normal operational
        CacheDiskStateDraining                  = 4,     <- expected during RW->RO change (waiting for dirty pages -> 0)
        CacheDiskStateDisabling                 = 5,
        CacheDiskStateDisabled                  = 6,     <- expected post-disable of S2D
        CacheDiskStateMissing                   = 7,
        CacheDiskStateOrphanedWaiting           = 8,
        CacheDiskStateOrphanedRecovering        = 9,
        CacheDiskStateFailedMediaError          = 10,
        CacheDiskStateFailedProvisioning        = 11,
        CacheDiskStateReset                     = 12,
        CacheDiskStateRepairing                 = 13,
        CacheDiskStateIneligibleDataPartition   = 2000,
        CacheDiskStateIneligibleNotGPT          = 2001,
        CacheDiskStateIneligibleNotEnoughSpace  = 2002,
        CacheDiskStateIneligibleUnsupportedSystem = 2003,
        CacheDiskStateIneligibleExcludedFromS2D = 2004,
        CacheDiskStateIneligibleForS2D          = 2999,
        CacheDiskStateSkippedBindingNoFlash     = 3000,
        CacheDiskStateIgnored                   = 3001,
        CacheDiskStateNonHybrid                 = 3002,
        CacheDiskStateInternalErrorConfiguring  = 9000,
        CacheDiskStateMarkedBad                 = 9001,
        CacheDiskStateMarkedMissing             = 9002,
        CacheDiskStateInStorageMaintenance      = 9003   <- expected during FRU/maint
    }
    CacheDiskState;
    #>

    dir $Path\*cluster.log | sort -Property BaseName |% {

        $node = "<unknown>"
        if ($_.BaseName -match "^(.*)_cluster$") {
            $node = $matches[1]
        }

        Write-Output ("-"*40) "Node: $node"


        ##
        # Parse cluster log for the SBL Disk section
        ## 

        $data = Get-ClusterLogDataSources $_.FullName

        ##
        # With a an SBL Disks section, provide commentary
        ##

        $d = $data['SBL Disks']

        if ($d) {

            ##
            # Table of raw data, friendly cache device numbering
            ##

            $idmap = @{}
            $d |% {
                $idmap[$_.DiskId] = $_.DeviceNumber
            }

            if ($ReportLevel -eq [ReportLevelType]::Full) {
                $d | sort IsSblCacheDevice,CacheDeviceId,DiskState | ft -AutoSize @{ Label = 'DiskState'; Expression = { Format-StorageBusCacheDiskState $_.DiskState }},
                    DiskId,ProductId,Serial,@{
                        Label = 'Device#'; Expression = {$_.DeviceNumber}
                    },
                    @{
                        Label = 'CacheDevice#'; Expression = {
                            if ($_.IsSblCacheDevice -eq 'true') {
                                '= cache'
                            } elseif ($idmap.ContainsKey($_.CacheDeviceId)) {
                                $idmap[$_.CacheDeviceId]
                            } elseif ($_.CacheDeviceId -eq '{00000000-0000-0000-0000-000000000000}') {
                                "= unbound"
                            } else {
                                # should be DiskStateMissing or OrphanedWaiting? Check live.
                                "= not present $($_.CacheDeviceId)"
                            }
                        }
                    },@{
                        Label = 'SeekPenalty'; Expression = {$_.HasSeekPenalty}
                    },
                    PathId,BindingAttributes,DirtyPages
            }

            ##
            # Now do basic testing of device counts
            ##

            $dcache = $d |? IsSblCacheDevice -eq 'true'
            $dcap = $d |? IsSblCacheDevice -ne 'true'

            Write-Output "Device counts: cache $($dcache.count) capacity $($dcap.count)"
        
            ##
            # Test cache bindings if we do have cache present
            ##

            if ($dcache) {

                # first uneven check, the basic count case
                $uneven = $false
                if ($dcap.count % $dcache.count) {
                    $uneven = $true
                    Write-Warning "Capacity device count does not evenly distribute to cache devices"
                }

                # now look for unbound devices
                $unbound = $dcap |? CacheDeviceId -eq '{00000000-0000-0000-0000-000000000000}'
                if ($unbound) {
                    Write-Warning "There are $(@($unbound).count) unbound capacity device(s)"
                }

                # unbound devices give us the second uneven case
                if (-not $uneven -and ($dcap.count - @($unbound).count) % $dcache.count) {
                    $uneven = $true
                }

                $gdev = $dcap |? DiskState -eq 'CacheDiskStateInitializedAndBound' | group -property CacheDeviceId

                if (@($gdev).count -ne $dcache.count) {
                    Write-Warning "Not all cache devices in use"
                }

                $gdist = $gdev |% { $_.count } | group

                # in any given round robin binding of devices, there should be at most two counts; n and n-1

                # single ratio
                if (@($gdist).count -eq 1) {
                    Write-Output "Binding ratio is even: 1:$($gdist.name)"
                } else {
                    # group names are n in the 1:n binding ratios
                    $delta = [math]::Abs([int]$gdist[0].name - [int]$gdist[1].name)

                    if ($delta -eq 1 -and $uneven) {
                        Write-Output "Binding ratios are as expected for uneven device ratios"
                    } else {
                        Write-Warning "Binding ratios are uneven"
                    }

                    # form list of group sizes
                    $s = $($gdist |% {
                        "1:$($_.name) ($($_.count) total)"
                    }) -join ", "

                    Write-Output "Groups: $s"
                }
            }

            ##
            # Provide summary of diskstate if more than one is present in the results
            ##

            $g = $d | group -property DiskState

            if (@($g).count -ne 1) {
                write-output "Disk State Summary:"
                $g | sort -property Name | ft @{ Label = 'DiskState'; Expression = { Format-StorageBusCacheDiskState $_.Name}},@{ Label = "Number of Disks"; Expression = { $_.Count }}
            } else {
                write-output "All disks are in $(Format-StorageBusCacheDiskState $g.name)"
            }
        }
    }
}

function Get-StorageBusConnectivityReport
{
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$true)]
        [ReportLevelType]
        $ReportLevel
    )

    function Show-SSBConnectivity($node)
    {
        BEGIN {
            $disks = 0
            $enc = 0
            $ssu = 0
        }
        PROCESS {
            switch ($_.DeviceType) {
                0 { $disks += 1 }
                1 { $enc += 1 }
                2 { $ssu += 1 }
            }
        }
        END {
            "$node has $disks disks, $enc enclosures, and $ssu scaleunit"
        }
    }

    dir $path\*_ClusPort.xml | sort -Property BaseName |% {

        if ($_.BaseName -match "^(.*)_ClusPort$") {
            $node = $matches[1]
        }

        Import-Clixml $_ | Show-SSBConnectivity $node
    }
}

function Get-StorageLatencyReport
{
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$true)]
        [ReportLevelType]
        $ReportLevel
    )

    $j = @()

    dir $Path\*_UnfilteredEvent_Microsoft-Windows-Storage-Storport-Operational.EVTX | sort -Property BaseName |% {

        $file = $_.FullName
        $node = "<unknown>"
        if ($_.BaseName -match "^(.*)_UnfilteredEvent_Microsoft-Windows-Storage-Storport-Operational$") {
            $node = $matches[1]
        }

        # parallelize processing of per-node event logs

        $j += start-job -Name $node -ArgumentList $($ReportLevel -eq [ReportLevelType]::Full) {

            param($dofull)

            # hash for devices, label schema, and whether values are absolute counts or split success/faul
            $buckhash = @{}
            $bucklabels = $null
            $buckvalueschema = $null

            $evs = @()

            # get all storport 505 events; there is a label field at position 6 which names
            # the integer fields in the following positions. these fields countain counts
            # of IOs in the given latency buckets. we assume all events have the same labelling
            # scheme.
            #
            # 1. count the number of sample periods in which a given bucket had any io.
            # 2. emit onto the pipeline the hash of counted periods and events which have
            #    io in the last bucket
            #
            # note: getting fields by position is not ideal, but getting them by name would
            # appear to require pushing through an XML rendering and hashing. this would be
            # less efficient and this is already somewhat time consuming.
        
            # the erroraction handles (potentially) disabled logs, which have no events
            Get-WinEvent -Path $using:file -ErrorAction SilentlyContinue |? Id -eq 505 |% {

                # must cast through the XML representation of the event to get named properties
                # hash them
                $x = ([xml]$_.ToXml()).Event.EventData.Data
                $xh = @{}
                $x |% {
                    $xh[$_.Name] = $_.'#text'
                }

                # physical disk device id - string the curly to normalize later matching
                $dev = [string] $xh['ClassDeviceGuid']
                if ($dev -match '{(.*)}') {
                    $dev = $matches[1]
                }

                # only need to get the bucket label schema once
                # the number of labels and the number of bucket counts should be equal
                # determine the count schema at the same time
                if ($bucklabels -eq $null) {
                    $bucklabels = $xh['IoLatencyBuckets'] -split ',\s+'

                    # is the count scheme split (RS5) or combined (RS1)?
                    # match 1 is the bucket type
                    # match 2 is the value bucket number (1 .. n)
                    if ($xh.ContainsKey("BucketIoSuccess1")) {
                        $buckvalueschema = "^BucketIo(Success|Failed)(\d+)$"
                    } else {
                        $buckvalueschema = "^BucketIo(Count)(\d+)$"
                    }
                }

                # counting array for each bucket
                $buckvalues = @($null) * $bucklabels.length

                $xh.Keys |% {
                    if ($_ -match $buckvalueschema) {

                        # the schema parses the bucket number into match 2
                        # number is 1-based
                        $buckvalues[([int] $matches[2]) - 1] += [int] $xh[$_]
                    }
                }

                # if the counting array contains null entries, we got confused matching
                # counts to the label schema
                if ($buckvalues -contains $null) {
                    throw "misparsed 505 event latency buckets: labels $($bucklabels.count) values $(($buckvalues | measure).count)"
                }

                if (-not $buckhash.ContainsKey($dev)) {
                    # new device
                    $buckhash[$dev] = $buckvalues |% { if ($_) { 1 } else { 0 }}
                } else {
                    # increment device bucket hit counts
                    foreach ($i in 0..($buckvalues.count - 1)) {
                        if ($buckvalues[$i]) { $buckhash[$dev][$i] += 1}
                    }
                }

                if ($dofull -and $buckvalues[-1] -ne 0) {
                    $evs += $(

                        # events must be cracked into plain objects to survive deserialization through the session

                        # base object with time/device
                        $o = New-Object psobject -Property @{
                            'Time' = $_.TimeCreated
                            'Device' = [string] $_.Properties[4].Value
                        }

                        # add on the named latency buckets
                        foreach ($i in 0..($bucklabels.count -1)) {
                            $o | Add-Member -NotePropertyName $bucklabels[$i] -NotePropertyValue $buckvalues[$i]
                        }

                        # and emit
                        $o
                    )
                }
            }

            # return label schema, counting hash, and events
            # labels must be en-listed to pass the pipeline as a list as opposed to individual values
            ,$bucklabels
            $buckhash
            $evs 
        }
    }

    # acquire the physicaldisks datasource
    $PhysicalDisks = Import-Clixml (Join-Path $Path "GetPhysicalDisk.XML")

    # hash by object id
    # this is an example where a formal datasource class/api could be useful
    $PhysicalDisksTable = @{}
    $PhysicalDisks |% {
        if ($_.ObjectId -match 'PD:{(.*)}') {
            $PhysicalDisksTable[$matches[1]] = $_
        }
    }

    # we will join the latency information with this set of physicaldisk attributes
    $pdattr = 'FriendlyName','SerialNumber','MediaType','OperationalStatus','HealthStatus','Usage'

    $pdattrs_tab = @{ Label = 'FriendlyName'; Expression = { $PhysicalDisksTable[$_.Device].FriendlyName }},
                @{ Label = 'SerialNumber'; Expression = { $PhysicalDisksTable[$_.Device].SerialNumber }},
                @{ Label = 'Firmware'; Expression = { $PhysicalDisksTable[$_.Device].FirmwareVersion }},
                @{ Label = 'Media'; Expression = { $PhysicalDisksTable[$_.Device].MediaType }},
                @{ Label = 'Usage'; Expression = { $PhysicalDisksTable[$_.Device].Usage }},
                @{ Label = 'OpStat'; Expression = { $PhysicalDisksTable[$_.Device].OperationalStatus }},
                @{ Label = 'HealthStat'; Expression = { $PhysicalDisksTable[$_.Device].HealthStatus }}

    # joined physicaldisk attributes for the event view
    # since status' are not known at the time of the event, omit for brevity/accuracy
    $pdattrs_ev = @{ Label = 'FriendlyName'; Expression = { $PhysicalDisksTable[$_.Device].FriendlyName }},
                @{ Label = 'SerialNumber'; Expression = { $PhysicalDisksTable[$_.Device].SerialNumber }},
                @{ Label = 'Media'; Expression = { $PhysicalDisksTable[$_.Device].MediaType }},
                @{ Label = 'Usage'; Expression = { $PhysicalDisksTable[$_.Device].Usage }}
            
    # now wait for the event processing jobs and emit the per-node reports
    $j | wait-job| sort name |% {

        ($bucklabels, $buckhash, $evs) = receive-job $_
        $node = $_.Name
        remove-job $_

        Write-Output ("-"*40) "Node: $node" "`nSample Period Count Report"

        if ($buckhash.Count -eq 0) {

            #
            # If there was nothing reported, that may indicate the storport channel was disabled. In any case
            # we can't produce the report.
            #

            Write-Warning "Node $node is not reporting latency information. Please verify the following event channel is enabled on it: Microsoft-Windows-Storage-Storport/Operational"

        } else {

            # note: these reports are filtered to only show devices in the pd table
            # this leaves boot device and others unreported until we have a datasource
            # to inject them.
    
            # output the table of device latency bucket counts
            $buckhash.Keys |? { $PhysicalDisksTable.ContainsKey($_) } |% {

                $dev = $_

                # the bucket labels are in the hash in the same order as the values
                # and use to make an object for table rendering
                $vprop = @{}
                $weight = 0
                foreach ($i in 0..($bucklabels.count - 1)) { 
                    $v = $buckhash[$_][$i]
                    if ($v) {
                        $weight = $i
                        $weightval = $v
                        $vprop[$bucklabels[$i]] = $v
                    }
                }

                $vprop['Device'] = $dev
                $vprop['Weight'] = $weight
                $vprop['WeightVal'] = $weightval

                new-object psobject -Property $vprop

            } | sort Weight,@{ Expression = {$PhysicalDisksTable[$_.Device].Usage}},WeightVal | ft -AutoSize (,'Device' + $pdattrs_tab  + $bucklabels)

            # for the full report, output the high bucket events
            # note: enumerations do not appear to be available in job sessions, otherwise it would clearly be more efficient
            #  to avoid geneating the events in the first place.
            if ($ReportLevel -eq [ReportLevelType]::Full) {

                Write-Output "`nHighest Bucket ($($bucklabels[-1])) Latency Events"

                $n = 0
                if ($evs -ne $null) {
                    $evs |? { $PhysicalDisksTable.ContainsKey($_.Device) } |% { $n += 1; $_ } | sort Time -Descending | ft -AutoSize ('Time','Device' + $pdattrs_ev + $bucklabels)
                }

                if ($n -eq 0) {
                    Write-Output "-> No Events"
                }
            }
        }
    }
}

function Get-StorageFirmwareReport
{
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$true)]
        [ReportLevelType]
        $ReportLevel
    )
    
    # acquire the physicaldisks datasource for non-retired disks
    # retired disks may not show fw and in any case are not of interest for live operation
    $PhysicalDisks = Import-Clixml (Join-Path $Path "GetPhysicalDisk.XML") |? Usage -ne Retired

    # basic report
    Write-Output "Total Firmware Report"
    $PhysicalDisks | group -Property Manufacturer,Model,FirmwareVersion | sort Name |
        ft @{ Label = 'Number'; Expression = { $_.Count }},
           @{ Label = 'Manufacturer'; Expression = { $_.Group[0].Manufacturer }},
           @{ Label = 'Model'; Expression = { $_.Group[0].Model }},
           @{ Label = 'Firmware'; Expression = { $_.Group[0].FirmwareVersion }},
           @{ Label = 'Media'; Expression = { $_.Group[0].MediaType }},
           @{ Label = 'Usage'; Expression = { $_.Group[0].Usage }}

    # group by manu/model and for each, group by fw
    # report out minority fw devices by serial number
    Write-Output "Per Unit Firmware Report`n"
    $PhysicalDisks | group -Property Manufacturer,Model | sort Name |% {

        $total = $_.Count
        $fwg = $_.Group | group -Property FirmwareVersion | sort -Property Count

        # if there is any variation, report
        if (($fwg | measure).Count -ne 1) {
            Write-Output "$($_.Group[0].Manufacturer) $($_.Group[0].Model): varying firmware found - $($fwg.Name -join ' ')"
            Write-Output "Majority Devices: $($fwg[-1].Count) are at firmware version $($fwg[-1].Group[0].FirmwareVersion)"
            Write-Output "Minority Devices:"

            # skip group with the highest count; likely correct/not relevant to report
            $fwg | select -SkipLast 1 |% {

                Write-Output "Firmware Version $($_.Name) - Total $($_.Count)"

                $_.Group |
                    ft @{ Label = 'SerialNumber'; Expression = { if ($_.BusType -eq 'NVME') { $_.AdapterSerialNumber } else { $_.SerialNumber}}},
                       @{ Label = "Media"; Expression = { $_.MediaType }},
                       Usage

            }


        } else {

            # good case
            Write-Output "$($_.Group[0].Manufacturer) $($_.Group[0].Model): all devices are on firmware version $($_.Group[0].FirmwareVersion)`n"
        }
    }
}

function Get-LsiEventReport
{
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$true)]
        [ReportLevelType]
        $ReportLevel
    )

    # process the system event logs
    # produce the time-series for full report, error code summary-only for lower levels

    dir $path\*_UnfilteredEvent_System.EVTX | sort -Property BaseName |% {

        if ($_.BaseName -match "^(.*)_UnfilteredEvent_.*") {
            $node = $matches[1]
        }
         
        $ev = Get-WinEvent -Path $_ |? { $_.ProviderName -match "lsi" -and $_.Id -eq 11 } |% {

            new-object psobject -Property @{
                'Time' = $_.TimeCreated;
                'Provider Name' = $_.ProviderName;
                'LSI Error'= (($_.Properties[1].Value[19..16] |% { '{0:X2}' -f $_ }) -join '');
            }
        }

        Write-Output ("-"*40) "Node: $node"

        if (-not $ev) {
            Write-Output "No LSI events present"
        } else {
            Write-Output "Summary of LSI Event 11 error codes"
        
            $ev | group -Property 'LSI Error' -NoElement | sort -Property Name | ft -AutoSize Count,@{ Label = 'LSI Error'; Expression = { $_.Name }}

            if ($ReportLevel -eq [ReportLevelType]::Full) {

                Write-Output "LSI Event 11 errors by time"

                $ev | ft Time,'LSI Error'
            }
        }
    }
}

<#
.SYNOPSIS
    Show diagnostic reports based on information collected from Get-SddcDiagnosticInfo.

.DESCRIPTION
    Show diagnostic reports based on information collected from Get-SddcDiagnosticInfo.

.PARAMETER Path
    Path to the the logs produced by Get-SddcDiagnosticInfo. This must be the un-zipped report (Expand-Archive).

.PARAMETER ReportLevel
    Controls the level of detail in the report. By default standard reports are shown. Full detail may be extensive.

.PARAMETER Report
    Specifies individual reports to produce. By default all reports will be shown.

.EXAMPLE
    Show-SddcReport -Path C:\log -Report Full

#>

function Show-SddcDiagnosticReport
{
    [CmdletBinding()]
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$false)]
        [ReportLevelType]
        $ReportLevel = [ReportLevelType]::Standard,

        [parameter(Mandatory=$false)]
        [ReportType[]]
        $Report = [ReportType]::All
    )

    $Path = (gi $Path).FullName

    if (-not (Test-Path $Path)) {
        Write-Error "Path is not accessible. Please check and try again: $Path"
        return
    }

    # Produce all reports?
    if ($Report.Count -eq 1 -and $Report[0] -eq [ReportType]::All) {
        $Report = [ReportType].GetEnumValues() |? { $_ -ne [ReportType]::All } | sort
    }

    foreach ($r in $Report) {

        Write-Output ("*"*80)
        Write-Output "Report: $r"

        $t0 = Get-Date

        switch ($r) {
            { $_ -eq [ReportType]::StorageBusCache } {
                Get-StorageBusCacheReport $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::StorageBusConnectivity } {
                Get-StorageBusConnectivityReport $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::StorageLatency } {
                Get-StorageLatencyReport $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::StorageFirmware } {
                Get-StorageFirmwareReport $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::LsiEvent } {
                Get-LsiEventReport $Path -ReportLevel:$ReportLevel
            }
            default {
                throw "Internal Error: unknown report type $r"
            }
        }

        $td = (Get-Date) - $t0
        Write-Output ("Report $r took {0:N2} seconds" -f $td.TotalSeconds)
    }
}

# DEPRECATED New-Alias -Value Get-SddcDiagnosticInfo -Name Test-StorageHealth # Original name when Jose started (CPSv1)
New-Alias -Value Get-SddcDiagnosticInfo -Name Get-PCStorageDiagnosticInfo # Name until 02/2018, changed for inclusiveness
New-Alias -Value Get-SddcDiagnosticInfo -Name getpcsdi # Shorthand for Get-PCStorageDiagnosticInfo
New-Alias -Value Get-SddcDiagnosticInfo -Name gsddcdi # New alias

New-Alias -Value Show-SddcDiagnosticReport -name Get-PCStorageReport

Export-ModuleMember -Alias * -Function Get-SddcDiagnosticInfo,Show-SddcDiagnosticReport