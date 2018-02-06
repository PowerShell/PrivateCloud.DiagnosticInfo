<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>

 Import-Module Storage

<##################################################
#  Helper functions                               #
##################################################>

#
# Shows error, cancels script
#
Function ShowError { 
Param ([string] $Message)
    $Message = $Message + " - cmdlet was cancelled"
    Write-Error $Message -ErrorAction Stop
}
 
#
# Shows warning, script continues
#
Function ShowWarning { 
Param ([string] $Message) 
    Write-Warning $Message 
}

#
# Checks if the current version of module is the latest version
#
Function Compare-ModuleVersion {
    If ($PSVersionTable.PSVersion -lt [System.Version]"5.0.0") {
        ShowWarning("Current PS Version does not support this operation. `nPlease check for updated module from PS Gallery and update using: Update-Module PrivateCloud.DiagnosticInfo")
    }
    Else {        
        If ((Find-Module -Name PrivateCloud.DiagnosticInfo).Version -gt (Get-Module PrivateCloud.DiagnosticInfo).Version) {        
            ShowWarning ("There is an updated module available on PowerShell Gallery. Please update the module using: Update-Module PrivateCloud.DiagnosticInfo")
        }
    }
}
<##################################################
#  End Helper functions                           #
##################################################>

<# 
    .SYNOPSIS 
       Report on Storage Cluster Health

    .DESCRIPTION 
       Show Storage Cluster Health information for major cluster and storage objects.
       Run from one of the nodes of the Storage Cluster or specify a cluster name.
       Results are saved to a folder (default C:\Users\<user>\HealthTest) for later review and replay.

    .LINK 
        To provide feedback and contribute visit https://github.com/PowerShell/PrivateCloud.Health

    .EXAMPLE 
       Get-PCStorageDiagnosticInfo
 
       Reports on overall storage cluster health, capacity, performance and events.
       Uses the default temporary working folder at C:\Users\<user>\HealthTest
       Saves the zipped results at C:\Users\<user>\HealthTest-<cluster>-<date>.ZIP

    .EXAMPLE 
       Get-PCStorageDiagnosticInfo -WriteToPath C:\Test
 
       Reports on overall storage cluster health, capacity, performance and events.
       Uses the specified folder as the temporary working folder

    .EXAMPLE 
       Get-PCStorageDiagnosticInfo -ClusterName Cluster1
 
       Reports on overall storage cluster health, capacity, performance and events.
       Targets the storage cluster specified.

    .EXAMPLE 
       Get-PCStorageDiagnosticInfo -ReadFromPath C:\Test
 
       Reports on overall storage cluster health, capacity, performance and events.
       Results are obtained from the specified folder, not from a live cluster.

#> 

function Get-PCStorageDiagnosticInfo
{
    [CmdletBinding(DefaultParameterSetName="Write")]
    [OutputType([String])]

    param(
        [parameter(ParameterSetName="Write", Position=0, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $WriteToPath = $($env:userprofile + "\HealthTest\"),

        [parameter(ParameterSetName="Write", Position=1, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $ClusterName = ".",

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
        [int] $HoursOfEvents = 48,

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
    # Count number of elements in an array, including checks for $null or single object
    #

    Function NCount { 
        Param ([object] $Item) 
        If ($null -eq $Item) {
            $Result = 0
        } else {
            If ($Item.GetType().BaseType.Name -eq "Array") {
                $Result = ($Item).Count
            } Else { 
                $Result = 1
            }
        }
        Return $Result
    }

    Function VolumeToPath {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeID -eq $Volume) { $Result = $_.CSVPath }
             }
        Return $Result
    }

    Function VolumeToCSV {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeID -eq $Volume) { $Result = $_.CSVVolume }
        }
        Return $Result
    }
    
    Function VolumeToVD {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeID -eq $Volume) { $Result = $_.FriendlyName }
        }
        Return $Result
    }

    Function VolumeToShare {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeID -eq $Volume) { $Result = $_.ShareName }
        }
        Return $Result
    }

    Function VolumeToResiliency {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeID -eq $Volume) { 
                $Result = $_.VDResiliency+","+$_.VDCopies
                If ($_.VDEAware) { 
                    $Result += ",E"
                } else {
                    $Result += ",NE"
                }
            }
        }
        Return $Result
    }

    Function VolumeToColumns {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeID -eq $Volume) { $Result = $_.VDColumns }
        }
        Return $Result
    }

    Function CSVToShare {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.CSVVolume -eq $Volume) { $Result = $_.ShareName }
        }
        Return $Result
    }

    Function VolumeToPool {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.PoolName }
        }
        Return $Result
    }

    Function CSVToVD {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.CSVVolume -eq $Volume) { $Result = $_.FriendlyName }
        }
        Return $Result
    }

    Function CSVToPool {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.CSVVolume -eq $Volume) { $Result = $_.PoolName }
        }
        Return $Result
    }
    
    Function CSVToNode {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.CSVVolume -eq $Volume) { $Result = $_.CSVNode }
        }
        Return $Result
    }

    Function VolumeToCSVName {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.CSVName }
        }
        Return $Result
    }
    
    Function CSVStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.CSVStatus.Value }
        }
        Return $Result
    }
                
    Function PoolOperationalStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.PoolOpStatus }
        }
        Return $Result
    }

    Function PoolHealthStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.PoolHealthStatus }
        }
        Return $Result
    }

    Function PoolHealthyPDs {
        Param ([String] $PoolName)
        $healthyPDs = ""
        If ($PoolName) {
            $totalPDs = (Get-StoragePool -FriendlyName $PoolName -CimSession $ClusterName | Get-PhysicalDisk).Count
            $healthyPDs = (Get-StoragePool -FriendlyName $PoolName -CimSession $ClusterName | Get-PhysicalDisk | Where-Object HealthStatus -eq "Healthy" ).Count
        }
        else {
            ShowError("No storage pool specified")
        }
        return "$totalPDs/$healthyPDs"
    }

    Function VDOperationalStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.OperationalStatus }
        }
        Return $Result
    }

    Function VDHealthStatus {
        Param ([String] $Volume) 
        if ($null -eq $Associations) { ShowError("No device associations present.") }
        $Result = ""
        $Associations | Foreach-Object {
            If ($_.VolumeId -eq $Volume) { $Result = $_.HealthStatus }
        }
        Return $Result    
    }

    #
    # Veriyfing basic prerequisites on script node.
    #

    $OS = Get-CimInstance -ClassName Win32_OperatingSystem
    $S2DEnabled = $false

    If ([uint64]$OS.BuildNumber -lt 9600) { 
        ShowError("Wrong OS Version - Need at least Windows Server 2012 R2 or Windows 8.1. You are running - " + $OS.Name) 
    }
 
    If (-not (Get-Command -Module FailoverClusters)) { 
        ShowError("Cluster PowerShell not available. Download the Windows Failover Clustering RSAT tools.") 
    }

    Function StartMonitoring {
        Write-Output "Entered continuous monitoring mode. Storage Infrastucture information will be refreshed every 3-6 minutes" -ForegroundColor Yellow    
        Write-Output "Press Ctrl + C to stop monitoring" -ForegroundColor Yellow

        Try { $ClusterName = (Get-Cluster -Name $ClusterName).Name }
        Catch { ShowError("Cluster could not be contacted. `nError="+$_.Exception.Message) }

        $AccessNode = (Get-ClusterNode -Cluster $ClusterName | Where-Object State -like "Up")[0].Name + "." + (Get-Cluster -Name $ClusterName).Domain

        Try { $Volumes = Get-Volume -CimSession $AccessNode  }
        Catch { ShowError("Unable to get Volumes. `nError="+$_.Exception.Message) }

        $AssocJob = Start-Job -ArgumentList $AccessNode,$ClusterName {

            param($AccessNode,$ClusterName)

            $SmbShares = Get-SmbShare -CimSession $AccessNode
            $Associations = Get-VirtualDisk -CimSession $AccessNode |Foreach-Object {

                $o = $_ | Select-Object FriendlyName, CSVName, CSVNode, CSVPath, CSVVolume, 
                ShareName, SharePath, VolumeID, PoolName, VDResiliency, VDCopies, VDColumns, VDEAware

                $AssocCSV = $_ | Get-ClusterSharedVolume -Cluster $ClusterName

                If ($AssocCSV) {
                    $o.CSVName = $AssocCSV.Name
                    $o.CSVNode = $AssocCSV.OwnerNode.Name
                    $o.CSVPath = $AssocCSV.SharedVolumeInfo.FriendlyVolumeName
                    if ($o.CSVPath.Length -ne 0) {
                        $o.CSVVolume = $o.CSVPath.Split("\")[2]
                    }     
                    $AssocLike = $o.CSVPath+"\*"
                    $AssocShares = $SmbShares | Where-Object Path -like $AssocLike 
                    $AssocShare = $AssocShares | Select-Object -First 1
                    If ($AssocShare) {
                        $o.ShareName = $AssocShare.Name
                        $o.SharePath = $AssocShare.Path
                        $o.VolumeID = $AssocShare.Volume
                        If ($AssocShares.Count -gt 1) { $o.ShareName += "*" }
                    }
                }

                Write-Output $o
            }

            $AssocPool = Get-StoragePool -CimSession $AccessNode
            $AssocPool | Foreach-Object {
                $AssocPName = $_.FriendlyName
                Get-StoragePool -CimSession $AccessNode -FriendlyName $AssocPName | 
                Get-VirtualDisk -CimSession $AccessNode | Foreach-Object {
                    $AssocVD = $_
                    $Associations | Foreach-Object {
                        If ($_.FriendlyName -eq $AssocVD.FriendlyName) { 
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
    If ($MonitoringMode) {
        StartMonitoring 
    }

    #
    # Veriyfing path
    #

    If ($ReadFromPath -ne "") {
        $Path = $ReadFromPath
        $Read = $true
    } else {
        $Path = $WriteToPath
        $Read = $false
    }

    $PathOK = Test-Path $Path -ErrorAction SilentlyContinue
    If ($Read -and -not $PathOK) { ShowError ("Path not found: $Path") }
    If (-not $Read) {
        Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse | Out-Null
        MKDIR -ErrorAction SilentlyContinue $Path | Out-Null
    } 
    $PathObject = Get-Item $Path
    If ($null -eq $PathObject) { ShowError ("Invalid Path: $Path") }
    $Path = $PathObject.FullName

    If ($Path.ToUpper().EndsWith(".ZIP")) {
        [Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null
        $ExtractToPath = $Path.Substring(0, $Path.Length - 4)

        Try { [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $ExtractToPath) }
        Catch { ShowError("Can't extract results as Zip file from '$Path' to '$ExtractToPath'") }

        $Path = $ExtractToPath
    }

    If (-not $Path.EndsWith("\")) { $Path = $Path + "\" }

    # Start Transcript
    $transcriptFile = $Path + "0_CloudHealthSummary.log"
    try{
        Stop-Transcript | Out-Null
    }
    catch [System.InvalidOperationException]{}
    Start-Transcript -Path $transcriptFile -Force


    If ($Read) { 
        "Reading from path : $Path"
    } else { 
        "Writing to path : $Path"
    }

<#
    If ($Read) {
        Try { $SavedVersion = Import-Clixml ($Path + "GetVersion.XML") }
        Catch { $SavedVersion = 1.1 }

        If ($SavedVersion -ne $ScriptVersion) 
        {ShowError("Files are from script version $SavedVersion, but the script is version $ScriptVersion")};
    } else {
        $ScriptVersion | Export-Clixml ($Path + "GetVersion.XML")
    }
#>
    #
    # Handle parameters
    #

    If ($Read) {
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

    "`n<<< Phase 1 - Storage Health Overview >>>`n"

    #
    # Get-Cluster
    #

    If ($Read) {
        $Cluster = Import-Clixml ($Path + "GetCluster.XML")
    } else {
        Try { $Cluster = Get-Cluster -Name $ClusterName }
        Catch { ShowError("Cluster could not be contacted. `nError="+$_.Exception.Message) }
        If ($null -eq $Cluster) { ShowError("Server is not in a cluster") }
        $Cluster | Export-Clixml ($Path + "GetCluster.XML")
    }

    $ClusterName = $Cluster.Name + "." + $Cluster.Domain
    "Cluster Name               : $ClusterName"
    
    $S2DEnabled = $Cluster.S2DEnabled
    "S2D Enabled                : $S2DEnabled"

    if ($S2DEnabled -ne $true) {
        if ((Test-NetConnection -ComputerName 'www.microsoft.com' -Hops 1 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).PingSucceeded) {
            Compare-ModuleVersion
        }
    }

    #
    # Test if it's a scale-out file server
    #

    If ($Read) {
        $ClusterGroups = Import-Clixml ($Path + "GetClusterGroup.XML")
    } else {
        Try { $ClusterGroups = Get-ClusterGroup -Cluster $ClusterName }
        Catch { ShowError("Unable to get Cluster Groups. `nError="+$_.Exception.Message) }
        $ClusterGroups | Export-Clixml ($Path + "GetClusterGroup.XML")
    }

    $ScaleOutServers = $ClusterGroups | Where-Object GroupType -like "ScaleOut*"
    If ($null -eq $ScaleOutServers) { 
        if ($S2DEnabled -ne $true) {
            ShowWarning("No Scale-Out File Server cluster roles found") 
        }
    } else {
        $ScaleOutName = $ScaleOutServers[0].Name+"."+$Cluster.Domain
        "Scale-Out File Server Name : $ScaleOutName"
    }
    #
    # Show health
    #

    # Cluster Nodes

    If ($Read) {
        $ClusterNodes = Import-Clixml ($Path + "GetClusterNode.XML")
    } else {
        Try { $ClusterNodes = Get-ClusterNode -Cluster $ClusterName }
        Catch { ShowError("Unable to get Cluster Nodes. `nError="+$_.Exception.Message) }
        $ClusterNodes | Export-Clixml ($Path + "GetClusterNode.XML")
    }

    # Select an access node, which will be used to query the cluster

    $AccessNode = ($ClusterNodes | Where-Object State -like "Up")[0].Name + "." + $Cluster.Domain
    "Access node                : $AccessNode `n"
    
    #
    # Verify deduplication prerequisites on access node, if in Write mode.
    #

    $DedupEnabled = $true
    if (-not $Read) {
        if ($(Invoke-Command -ComputerName $AccessNode {(-not (Get-Command -Module Deduplication))} )) { 
            $DedupEnabled = $false
            if ($S2DEnabled -ne $true) {
                ShowWarning("Deduplication PowerShell not installed on cluster node.")
            }
        }
    }

	if ($IncludeAssociations) {

		# Gather nodes view of storage and build all the associations

		If (-not $Read) {                         
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
					$poolName = ($pd | Get-StoragePool -CimSession $clusterCimSession | Where-Object IsPrimordial -eq $false).FriendlyName
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

    function Show-SBLConnectivity($node)
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

    if ($S2DEnabled -eq $true) {

        #
        # Gather only
        #

        if (-not $Read) {
            Try {
                $NonHealthyVDs = Get-VirtualDisk | where {$_.HealthStatus -ne "Healthy" -OR $_.OperationalStatus -ne "OK"}
                $NonHealthyVDs | Export-Clixml ($Path + "NonHealthyVDs.XML")

                foreach ($NonHealthyVD in $NonHealthyVDs) {
                    $NonHealthyExtents = $NonHealthyVD | Get-PhysicalExtent | ? OperationalStatus -ne Active | sort-object VirtualDiskOffset, CopyNumber
                    $NonHealthyExtents | Export-Clixml($Path + $NonHealthyVD.FriendlyName + "_Extents.xml")
                }
            } Catch {
                ShowWarning("Not able to query extents for faulted virtual disks")
            } 

            Try {
                $NonHealthyPools = Get-StoragePool | ? IsPrimordial -eq $false
                foreach ($NonHealthyPool in $NonHealthyPools) {
                    $faultyDisks = $NonHealthyPool | Get-PhysicalDisk 
                    $faultySSU = $faultyDisks | Get-StorageFaultDomain -type StorageScaleUnit
                    $faultyDisks | Export-Clixml($Path + $NonHealthyPool.FriendlyName + "_Disks.xml")
                    $faultySSU | Export-Clixml($Path + $NonHealthyPool.FriendlyName + "_SSU.xml")
                }
            } Catch {
                ShowWarning("Not able to query faulty disks and SSU for faulted pools")
            } 
        }

        #
        # Gather and report
        #

        Try {
            Write-Progress -Activity "Gathering SBL connectivity"
            "SBL Connectivity"
            foreach($node in $ClusterNodes |? { $_.State.ToString() -eq 'Up' }) {

                Write-Progress -Activity "Gathering SBL connectivity" -currentOperation "collecting from $node"
                if ($Read) {
                    $endpoints = Import-Clixml ($Path + $node + "_ClusPort.xml")
                } else {
                    $endpoints = Get-CimInstance -Namespace root\wmi -ClassName ClusPortDeviceInformation -ComputerName $node
                    $endpoints | Export-Clixml ($Path + $node + "_ClusPort.xml")
                }

                $endpoints | Show-SBLConnectivity $node
            }
            Write-Progress -Activity "Gathering SBL connectivity" -Completed
        } Catch {
            Write-Progress -Activity "Gathering SBL connectivity" -Completed
            ShowWarning("Gathering SBL connectivity failed")
        }
    }

	if ($IncludeAssociations) {
		# Gather association between pool, virtualdisk, volume, share.
		# This is first used at Phase 4 and is run asynchronously since
		# it can take some time to gather for large numbers of devices.

		If (-not $Read) {

			$AssocJob = Start-Job -Name 'StorageComponentAssociations' -ArgumentList $AccessNode,$ClusterName {
				param($AccessNode,$ClusterName)

				$SmbShares = Get-SmbShare -CimSession $AccessNode
				$Associations = Get-VirtualDisk -CimSession $AccessNode | Foreach-Object {

					$o = $_ | Select-Object FriendlyName, OperationalStatus, HealthStatus, CSVName, CSVStatus, CSVNode, CSVPath, CSVVolume, 
					ShareName, SharePath, VolumeID, PoolName, PoolOpStatus, PoolHealthStatus, VDResiliency, VDCopies, VDColumns, VDEAware

					$AssocCSV = $_ | Get-ClusterSharedVolume -Cluster $ClusterName

					If ($AssocCSV) {
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
						If ($AssocShare) {
							$o.ShareName = $AssocShare.Name
							$o.SharePath = $AssocShare.Path
							$o.VolumeID = $AssocShare.Volume
							If ($AssocShares.Count -gt 1) { $o.ShareName += "*" }
						}
					}

					Write-Output $o
				}

				$AssocPool = Get-StoragePool -CimSession $AccessNode
				$AssocPool | Foreach-Object {
					$AssocPName = $_.FriendlyName
					$AssocPOpStatus = $_.OperationalStatus
					$AssocPHStatus = $_.HealthStatus
					Get-StoragePool -CimSession $AccessNode -FriendlyName $AssocPName | 
					Get-VirtualDisk -CimSession $AccessNode | Foreach-Object {
						$AssocVD = $_
						$Associations | Foreach-Object {
							If ($_.FriendlyName -eq $AssocVD.FriendlyName) { 
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
    $NodesHealthy = NCount($ClusterNodes | Where-Object State -like "Up")
    "Cluster Nodes up              : $NodesHealthy / $NodesTotal"

    If ($NodesTotal -lt $ExpectedNodes) { ShowWarning("Fewer nodes than the $ExpectedNodes expected") }
    If ($NodesHealthy -lt $NodesTotal) { ShowWarning("Unhealthy nodes detected") }

    If ($Read) {
        $ClusterNetworks = Import-Clixml ($Path + "GetClusterNetwork.XML")
    } else {
        Try { $ClusterNetworks = Get-ClusterNetwork -Cluster $ClusterName }
        Catch { ShowError("Could not get Cluster Nodes. `nError="+$_.Exception.Message) }
        $ClusterNetworks | Export-Clixml ($Path + "GetClusterNetwork.XML")
    }

    # Cluster network health

    $NetsTotal = NCount($ClusterNetworks)
    $NetsHealthy = NCount($ClusterNetworks | Where-Object State -like "Up")
    "Cluster Networks up           : $NetsHealthy / $NetsTotal"
    

    If ($NetsTotal -lt $ExpectedNetworks) { ShowWarning("Fewer cluster networks than the $ExpectedNetworks expected") }
    If ($NetsHealthy -lt $NetsTotal) { ShowWarning("Unhealthy cluster networks detected") }

    If ($Read) {
        $ClusterResources = Import-Clixml ($Path + "GetClusterResource.XML")
    } else {
        Try { $ClusterResources = Get-ClusterResource -Cluster $ClusterName }
        Catch { ShowError("Unable to get Cluster Resources.  `nError="+$_.Exception.Message) }
        $ClusterResources | Export-Clixml ($Path + "GetClusterResource.XML")
    }

    # Cluster resource health

    $ResTotal = NCount($ClusterResources)
    $ResHealthy = NCount($ClusterResources | Where-Object State -like "Online")
    "Cluster Resources Online      : $ResHealthy / $ResTotal "
    If ($ResHealthy -lt $ResTotal) { ShowWarning("Unhealthy cluster resources detected") }

    If ($Read) {
        $CSV = Import-Clixml ($Path + "GetClusterSharedVolume.XML")
    } else {
        Try { $CSV = Get-ClusterSharedVolume -Cluster $ClusterName }
        Catch { ShowError("Unable to get Cluster Shared Volumes.  `nError="+$_.Exception.Message) }
        $CSV | Export-Clixml ($Path + "GetClusterSharedVolume.XML")
    }

    # Cluster shared volume health

    $CSVTotal = NCount($CSV)
    $CSVHealthy = NCount($CSV | Where-Object State -like "Online")
    "Cluster Shared Volumes Online : $CSVHealthy / $CSVTotal"
    If ($CSVHealthy -lt $CSVTotal) { ShowWarning("Unhealthy cluster shared volumes detected") }

    "`nHealthy Components count: [SMBShare -> CSV -> VirtualDisk -> StoragePool -> PhysicalDisk -> StorageEnclosure]"

    # SMB share health

    If ($Read) {
        #$SmbShares = Import-Clixml ($Path + "GetSmbShare.XML")
        $ShareStatus = Import-Clixml ($Path + "ShareStatus.XML")
    } else {
        Try { $SmbShares = Get-SmbShare -CimSession $AccessNode }
        Catch { ShowError("Unable to get SMB Shares. `nError="+$_.Exception.Message) }

        $ShareStatus = $SmbShares | Where-Object ContinuouslyAvailable | Select-Object ScopeName, Name, SharePath, Health
        $Count1 = 0
        $Total1 = NCount($ShareStatus)

        If ($Total1 -gt 0)
        {
            $ShareStatus | Foreach-Object {
                $Progress = $Count1 / $Total1 * 100
                $Count1++
                Write-Progress -Activity "Testing file share access" -PercentComplete $Progress

                $_.SharePath = "\\"+$_.ScopeName+"."+$Cluster.Domain+"\"+$_.Name
                Try { If (Test-Path -Path $_.SharePath  -ErrorAction SilentlyContinue) {
                            $_.Health = "Accessible"
                        } else {
                            $_.Health = "Inaccessible" 
                    } 
                }
                Catch { $_.Health = "Accessible: "+$_.Exception.Message }
            }
            Write-Progress -Activity "Testing file share access" -Completed
        }

        #$SmbShares | Export-Clixml ($Path + "GetSmbShare.XML")
        $ShareStatus | Export-Clixml ($Path + "ShareStatus.XML")

    }

    $ShTotal = NCount($ShareStatus)
    $ShHealthy = NCount($ShareStatus | Where-Object Health -like "Accessible")
    "SMB CA Shares Accessible      : $ShHealthy / $ShTotal"
    If ($ShHealthy -lt $ShTotal) { ShowWarning("Inaccessible CA shares detected") }

    # Open files 

    If ($Read) {
        $SmbOpenFiles = Import-Clixml ($Path + "GetSmbOpenFile.XML")
    } else {
        Try { $SmbOpenFiles = Get-SmbOpenFile -CimSession $AccessNode }
        Catch { ShowError("Unable to get Open Files. `nError="+$_.Exception.Message) }
        $SmbOpenFiles | Export-Clixml ($Path + "GetSmbOpenFile.XML")
    }

    $FileTotal = NCount( $SmbOpenFiles | Group-Object ClientComputerName)
    "Users with Open Files         : $FileTotal"
    If ($FileTotal -eq 0) { ShowWarning("No users with open files") }

    # SMB witness

    If ($Read) {
        $SmbWitness = Import-Clixml ($Path + "GetSmbWitness.XML")
    } else {
        Try { $SmbWitness = Get-SmbWitnessClient -CimSession $AccessNode }
        Catch { ShowError("Unable to get Open Files. `nError="+$_.Exception.Message) }
        $SmbWitness | Export-Clixml ($Path + "GetSmbWitness.XML")
    }

    $WitTotal = NCount($SmbWitness | Where-Object State -eq RequestedNotifications | Group-Object ClientName)
    "Users with a Witness           : $WitTotal"
    If ($WitTotal -eq 0) { ShowWarning("No users with a Witness") }

    # Volume health

    If ($Read) {
        $Volumes = Import-Clixml ($Path + "GetVolume.XML")
    } else {
        Try { $Volumes = Get-Volume -CimSession $AccessNode  }
        Catch { ShowError("Unable to get Volumes. `nError="+$_.Exception.Message) }
        $Volumes | Export-Clixml ($Path + "GetVolume.XML")
    }

    $VolsTotal = NCount($Volumes | Where-Object FileSystem -eq CSVFS )
    $VolsHealthy = NCount($Volumes  | Where-Object FileSystem -eq CSVFS | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) })
    "Cluster Shared Volumes Healthy: $VolsHealthy / $VolsTotal "

    # Deduplicated volume health

    If ($DedupEnabled)
    {
        If ($Read) {
            $DedupVolumes = Import-Clixml ($Path + "GetDedupVolume.XML")
        } else {
            Try { $DedupVolumes = Invoke-Command -ComputerName $AccessNode { Get-DedupStatus }}
            Catch { ShowError("Unable to get Dedup Volumes. `nError="+$_.Exception.Message) }
            $DedupVolumes | Export-Clixml ($Path + "GetDedupVolume.XML")
        }

        $DedupTotal = NCount($DedupVolumes)
        $DedupHealthy = NCount($DedupVolumes | Where-Object LastOptimizationResult -eq 0 )
        "Dedup Volumes Healthy         : $DedupHealthy / $DedupTotal "

        If ($DedupTotal -lt $ExpectedDedupVolumes) { ShowWarning("Fewer Dedup volumes than the $ExpectedDedupVolumes expected") }
        If ($DedupHealthy -lt $DedupTotal) { ShowWarning("Unhealthy Dedup volumes detected") }
    } else {
        $DedupVolumes = @()
        $DedupTotal = 0
        $DedupHealthy = 0
        If (-not $Read) { $DedupVolumes | Export-Clixml ($Path + "GetDedupVolume.XML") }
    }

    # Virtual disk health

    If ($Read) {
        $VirtualDisks = Import-Clixml ($Path + "GetVirtualDisk.XML")
    } else {
        Try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $VirtualDisks = Get-VirtualDisk -CimSession $AccessNode -StorageSubSystem $SubSystem }
        Catch { ShowError("Unable to get Virtual Disks. `nError="+$_.Exception.Message) }
        $VirtualDisks | Export-Clixml ($Path + "GetVirtualDisk.XML")
    }

    $VDsTotal = NCount($VirtualDisks)
    $VDsHealthy = NCount($VirtualDisks | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    "Virtual Disks Healthy         : $VDsHealthy / $VDsTotal"

    If ($VDsHealthy -lt $VDsTotal) { ShowWarning("Unhealthy virtual disks detected") }

    # Storage pool health

    If ($Read) {
        $StoragePools = Import-Clixml ($Path + "GetStoragePool.XML")
    } else {
        Try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $StoragePools =Get-StoragePool -IsPrimordial $False -CimSession $AccessNode -StorageSubSystem $SubSystem }
        Catch { ShowError("Unable to get Storage Pools. `nError="+$_.Exception.Message) }
        $StoragePools | Export-Clixml ($Path + "GetStoragePool.XML")
    }

    $PoolsTotal = NCount($StoragePools)
    $PoolsHealthy = NCount($StoragePools | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    "Storage Pools Healthy         : $PoolsHealthy / $PoolsTotal "

    If ($PoolsTotal -lt $ExpectedPools) { ShowWarning("Fewer storage pools than the $ExpectedPools expected") }
    If ($PoolsHealthy -lt $PoolsTotal) { ShowWarning("Unhealthy storage pools detected") }

    # Physical disk health

    If ($Read) {
        $PhysicalDisks = Import-Clixml ($Path + "GetPhysicalDisk.XML")
    } else {
        Try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $PhysicalDisks = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $SubSystem }
        Catch { ShowError("Unable to get Physical Disks. `nError="+$_.Exception.Message) }
        $PhysicalDisks | Export-Clixml ($Path + "GetPhysicalDisk.XML")
    }

    $PDsTotal = NCount($PhysicalDisks)
    $PDsHealthy = NCount($PhysicalDisks | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    "Physical Disks Healthy        : $PDsHealthy / $PDsTotal"

    If ($PDsTotal -lt $ExpectedPhysicalDisks) { ShowWarning("Fewer physical disks than the $ExpectedPhysicalDisks expected") }
    If ($PDsHealthy -lt $PDsTotal) { ShowWarning("Unhealthy physical disks detected") }

    # Reliability counters

    If ($Read) {
        if (Test-Path ($Path + "GetReliabilityCounter.XML")) {
            $ReliabilityCounters = Import-Clixml ($Path + "GetReliabilityCounter.XML")
        } else {
            ShowWarning("Reliability Counters not gathered for this capture")
        }
    } else {
        if ($IncludeReliabilityCounters -eq $true) {
            Try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
                  $ReliabilityCounters = $PhysicalDisks | Get-StorageReliabilityCounter -CimSession $AccessNode }
            Catch { ShowError("Unable to get Storage Reliability Counters. `nError="+$_.Exception.Message) }
            $ReliabilityCounters | Export-Clixml ($Path + "GetReliabilityCounter.XML")
        }
    }

    # Storage enclosure health - only performed if the required KB is present

    If (-not (Get-Command *StorageEnclosure*)) {
        ShowWarning("Storage Enclosure commands not available. See http://support.microsoft.com/kb/2913766/en-us")
    } else {
        If ($Read) {
            If (Test-Path ($Path + "GetStorageEnclosure.XML") -ErrorAction SilentlyContinue ) {
               $StorageEnclosures = Import-Clixml ($Path + "GetStorageEnclosure.XML")
            } Else {
               $StorageEnclosures = ""
            }
        } else {
            Try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
                  $StorageEnclosures = Get-StorageEnclosure -CimSession $AccessNode -StorageSubSystem $SubSystem }
            Catch { ShowError("Unable to get Enclosures. `nError="+$_.Exception.Message) }
            $StorageEnclosures | Export-Clixml ($Path + "GetStorageEnclosure.XML")
        }

        $EncsTotal = NCount($StorageEnclosures)
        $EncsHealthy = NCount($StorageEnclosures | Where-Object { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
        "Storage Enclosures Healthy    : $EncsHealthy / $EncsTotal "

        If ($EncsTotal -lt $ExpectedEnclosures) { ShowWarning("Fewer storage enclosures than the $ExpectedEnclosures expected") }
        If ($EncsHealthy -lt $EncsTotal) { ShowWarning("Unhealthy storage enclosures detected") }
    }   

    #
    # Phase 2
    #

    "`n<<< Phase 2 - details on unhealthy components >>>`n"

    $Failed = $False

    If ($NodesTotal -ne $NodesHealthy) { 
        $Failed = $true; 
        "Cluster Nodes:"; 
        $ClusterNodes | Where-Object State -ne "Up" | Format-Table -AutoSize 
    }

    If ($NetsTotal -ne $NetsHealthy) { 
        $Failed = $true; 
        "Cluster Networks:"; 
        $ClusterNetworks | Where-Object State -ne "Up" | Format-Table -AutoSize 
    }

    If ($ResTotal -ne $ResHealthy) { 
        $Failed = $true; 
        "Cluster Resources:"; 
        $ClusterResources | Where-Object State -notlike "Online" | Format-Table -AutoSize 
    }

    If ($CSVTotal -ne $CSVHealthy) { 
        $Failed = $true; 
        "Cluster Shared Volumes:"; 
        $CSV | Where-Object State -ne "Online" | Format-Table -AutoSize 
    }

    If ($VolsTotal -ne $VolsHealthy) { 
        $Failed = $true; 
        "Volumes:"; 
        $Volumes | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) }  | 
        Format-Table Path, HealthStatus  -AutoSize
    }

    If ($DedupTotal -ne $DedupHealthy) { 
        $Failed = $true; 
        "Volumes:"; 
        $DedupVolumes | Where-Object LastOptimizationResult -eq 0 | 
        Format-Table Volume, Capacity, SavingsRate, LastOptimizationResultMessage -AutoSize
    }

    If ($VDsTotal -ne $VDsHealthy) { 
        $Failed = $true; 
        "Virtual Disks:"; 
        $VirtualDisks | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName, HealthStatus, OperationalStatus, ResiliencySettingName, IsManualAttach  -AutoSize 
    }

    If ($PoolsTotal -ne $PoolsHealthy) { 
        $Failed = $true; 
        "Storage Pools:"; 
        $StoragePools | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName, HealthStatus, OperationalStatus, IsReadOnly -AutoSize 
    }

    If ($PDsTotal -ne $PDsHealthy) { 
        $Failed = $true; 
        "Physical Disks:"; 
        $PhysicalDisks | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName, EnclosureNumber, SlotNumber, HealthStatus, OperationalStatus, Usage -AutoSize
    }

    If (Get-Command *StorageEnclosure*)
    {
        If ($EncsTotal -ne $EncsHealthy) { 
            $Failed = $true; "Enclosures:";
            $StorageEnclosures | Where-Object { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
            Format-Table FriendlyName, HealthStatus, ElementTypesInError -AutoSize 
        }
    }

    If ($ShTotal -ne $ShHealthy) { 
        $Failed = $true; 
        "CA Shares:";
        $ShareStatus | Where-Object Health -notlike "Healthy" | Format-Table -AutoSize
    }

    If (-not $Failed) { 
        "`nNo unhealthy components" 
    }

    #
    # Phase 3
    #

    "`n<<< Phase 3 - Firmware and drivers >>>`n"

    "Devices and drivers by Model and Driver Version per cluster node" 

    If ($Read) {
        $clusterNodeNames = (Get-ClusterNode -Cluster $ClusterName).Name
        foreach ($node in $clusterNodeNames) {
            "`nCluster Node: $node"
            $Drivers = Import-Clixml ($Path + $node + "_GetDrivers.XML")
            $RelevantDrivers = $Drivers | Where-Object { ($_.DeviceName -like "LSI*") -or ($_.DeviceName -like "Mellanox*") -or ($_.DeviceName -like "Chelsio*") } | 
            Group-Object DeviceName, DriverVersion | 
            Select-Object @{Expression={$_.Name};Label="Device Name, Driver Version"}
            $RelevantDrivers
        }         
    } else {
        $clusterNodeNames = (Get-ClusterNode -Cluster $ClusterName).Name
        foreach ($node in $clusterNodeNames) { 
            "`nCluster Node: $node"
            Try { $Drivers = Get-CimInstance -ClassName Win32_PnPSignedDriver -ComputerName $node }
            Catch { ShowError("Unable to get Drivers on node $node. `nError="+$_.Exception.Message) }
            $Drivers | Export-Clixml ($Path + $node + "_GetDrivers.XML")
            $RelevantDrivers = $Drivers | Where-Object { ($_.DeviceName -like "LSI*") -or ($_.DeviceName -like "Mellanox*") -or ($_.DeviceName -like "Chelsio*") } | 
            Group-Object DeviceName, DriverVersion | 
            Select-Object @{Expression={$_.Name};Label="Device Name, Driver Version"}
            $RelevantDrivers
        }
    }

    "`nPhysical disks by Media Type, Model and Firmware Version" 
    $PhysicalDisks | Group-Object MediaType, Model, FirmwareVersion | Format-Table Count, @{Expression={$_.Name};Label="Media Type, Model, Firmware Version"} -AutoSize

 
    If ( -not (Get-Command *StorageEnclosure*) ) {
        ShowWarning("Storage Enclosure commands not available. See http://support.microsoft.com/kb/2913766/en-us")
    } else {
        "Storage Enclosures by Model and Firmware Version"
        $StorageEnclosures | Group-Object Model, FirmwareVersion | Format-Table Count, @{Expression={$_.Name};Label="Model, Firmware Version"} -AutoSize
    }
    
    #
    # Phase 4 Prep
    #

	if ($IncludeAssociations) {
		"`n<<< Phase 4 - Pool, Physical Disk and Volume Details >>>"
	
		if ($Read) {
			$Associations = Import-Clixml ($Path + "GetAssociations.XML")
			$SNVView = Import-Clixml ($Path + "GetStorageNodeView.XML")
		} else {
			"`nCollecting device associations..."
			Try {
				$Associations = $AssocJob | Wait-Job | Receive-Job
				$AssocJob | Remove-Job
				if ($null -eq $Associations) {
					ShowWarning("Unable to get object associations")
				}
				$Associations | Export-Clixml ($Path + "GetAssociations.XML")

				"`nCollecting storage view associations..."
				$SNVView = $SNVJob | Wait-Job | Receive-Job
				$SNVJob | Remove-Job
				if ($null -eq $SNVView) {
					ShowWarning("Unable to get nodes storage view associations")
				}
				$SNVView | Export-Clixml ($Path + "GetStorageNodeView.XML")        
			} catch {
				ShowWarning("Not able to query associations..")
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

		If ($DedupEnabled -and ($DedupTotal -gt 0))
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
    
		If ($SNVView) {
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

		$PDStatus | Foreach-Object {
			$Current = $_
			$TotalSize = 0
			$Unalloc = 0
			$PDCurrent = $PhysicalDisks | Where-Object { ($_.EnclosureNumber -eq $Current.Enc) -and ($_.MediaType -eq $Current.Media) -and ($_.HealthStatus -eq $Current.Health) }
			$PDCurrent | Foreach-Object {
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

    "<<< Phase 5 - Storage Performance >>>`n"

    If ((-not $Read) -and (-not $IncludePerformance)) {
       "Performance was excluded by a parameter`n"
    }

    If ((-not $Read) -and $IncludePerformance) {

        "Please wait for $PerfSamples seconds while performance samples are collected."
		Write-Progress -Activity "Gathering counters" -CurrentOperation "Start monitoring"

        $PerfNodes = $ClusterNodes | Where-Object State -like "Up" | Foreach-Object {$_.Name}
		$set=Get-Counter -ListSet *"virtual disk"*, *"hybrid"*, *"cluster storage"*, *"cluster csv"*,*"storage spaces"* -ComputerName $PerfNodes

        #$PerfCounters = "reads/sec","writes/sec","read latency","write latency"
        #$PerfItems = $PerfNodes | Foreach-Object { $Node=$_; $PerfCounters | Foreach-Object { ("\\"+$Node+"\Cluster CSV File System(*)\"+$_) } }
        #$PerfRaw = Get-Counter -Counter $PerfItems -SampleInterval 1 -MaxSamples $PerfSamples

		$PerfRaw=Get-Counter -Counter $set.Paths -SampleInterval 1 -MaxSamples $PerfSamples -ErrorAction Ignore -WarningAction Ignore
		Write-Progress -Activity "Gathering counters" -CurrentOperation "Exporting counters"
		$PerfRaw | Export-counter -Path ($Path + "GetCounters.blg") -Force -FileFormat “BLG”
		Write-Progress -Activity "Gathering counters" -Completed

		if ($ProcessCounter) {
			"Collected $PerfSamples seconds of raw performance counters. Processing...`n"
			$Count1 = 0
			$Total1 = $PerfRaw.Count

			If ($Total1 -gt 0) {

				$PerfDetail = $PerfRaw | Foreach-Object { 
					$TimeStamp = $_.TimeStamp
        
					$Progress = $Count1 / $Total1 * 45
					$Count1++
					Write-Progress -Activity "Processing performance samples" -PercentComplete $Progress

					$_.CounterSamples | Foreach-Object { 
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
    
				$PerfVolume = 0 .. $Last | Foreach-Object {

					If ($Volume -ne $PerfDetail[$_].Volume) {
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
						"read latency" { $ReadLatency += $Value; If ($Value -gt 0) {$NonZeroRL++} }
						"write latency" { $WriteLatency += $Value; If ($Value -gt 0) {$NonZeroWL++} }
						default { Write-Warning ?Invalid counter? }
					}

					If ($_ -eq $Last) { 
						$EndofVolume = $true 
					} else { 
						If ($Volume -ne $PerfDetail[$_+1].Volume) { 
							$EndofVolume = $true 
						} else { 
							$EndofVolume = $false 
						}
					}

					If ($EndofVolume) {
						$VolumeRow = "" | Select-Object Pool, Volume, Share, ReadIOPS, WriteIOPS, TotalIOPS, ReadLatency, WriteLatency, TotalLatency
						$VolumeRow.Pool = $Pool
						$VolumeRow.Volume = $Volume
						$VolumeRow.Share = $Share
						$VolumeRow.ReadIOPS = [int] ($ReadIOPS / $PerfSamples *  10) / 10
						$VolumeRow.WriteIOPS = [int] ($WriteIOPS / $PerfSamples * 10) / 10
						$VolumeRow.TotalIOPS = $VolumeRow.ReadIOPS + $VolumeRow.WriteIOPS
						If ($NonZeroRL -eq 0) {$NonZeroRL = 1}
						$VolumeRow.ReadLatency = [int] ($ReadLatency / $NonZeroRL * 1000000 ) / 1000 
						If ($NonZeroWL -eq 0) {$NonZeroWL = 1}
						$VolumeRow.WriteLatency = [int] ($WriteLatency / $NonZeroWL * 1000000 ) / 1000
						$VolumeRow.TotalLatency = [int] (($ReadLatency + $WriteLatency) / ($NonZeroRL + $NonZeroWL) * 1000000) / 1000
						$VolumeRow
					 }
				}
    
			} else {
				ShowWarning("Unable to collect performance information")
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

    "<<< Phase 6 - Recent Error events >>>`n"

    If ((-not $Read) -and (-not $IncludeEvents)) {
       "Events were excluded by a parameter`n"
    }

    If ((-not $Read) -and $IncludeEvents) {

        "Starting Export of Cluster Logs..." 

        # Cluster log collection will take some time. 
        # Using Start-Job to run them in the background, while we collect events and other diagnostic information

        $ClusterLogJob = Start-Job -ArgumentList $ClusterName,$Path { 
            param($c,$p)
            Get-ClusterLog -Cluster $c -Destination $p -UseLocalTime
            if ($using:S2DEnabled -eq $true) {
                Get-ClusterLog -Cluster $c -Destination $p -Health -UseLocalTime
            }
        }

        "Exporting Event Logs..." 

        $AllErrors = @();
        $Logs = Invoke-Command -ArgumentList $HoursOfEvents -ComputerName $($ClusterNodes | Where-Object State -like "Up") {

            Param([int] $Hours)
            # Calculate number of milliseconds and prepare the WEvtUtil parameter to filter based on date/time
            $MSecs = $Hours * 60 * 60 * 1000
            
            $QLevel = "*[System[(Level=2)]]"
            $QTime = "*[System[TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"
            $QLevelAndTime = "*[System[(Level=2) and TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"

            $Node = $env:COMPUTERNAME
            $NodePath = [System.IO.Path]::GetTempPath()
            $RPath = "\\$Node\$($NodePath[0])$\"+$NodePath.Substring(3,$NodePath.Length-3)

            # Log prefixes to gather. Note that this is a simple pattern match; for instance, there are a number of
            # different providers that match *Microsoft-Windows-Storage*: Storage, StorageManagement, StorageSpaces, etc.
            #
            # TODO: make this a prefix match for self-documentatability. Confirm ClusterAware updating's prefix and do it.
            $LogPatterns = 'Microsoft-Windows-Storage',
                           'Microsoft-Windows-SMB',
                           'Microsoft-Windows-FailoverClustering',
                           'Microsoft-Windows-VHDMP',
                           'Microsoft-Windows-Hyper-V',
                           'Microsoft-Windows-ResumeKeyFilter',
                           'Microsoft-Windows-REFS',
                           'Microsoft-Windows-NTFS',
                           'Microsoft-Windows-NDIS',
                           'Microsoft-Windows-Network',
                           'Microsoft-Windows-TCPIP',
                           'ClusterAware',
                           'Microsoft-Windows-Kernel' | Foreach-Object { "*$_*" }

            # Core logs to gather, by explicit names.
            $LogPatterns += 'System','Application'

            $Logs = Get-WinEvent -ListLog $LogPatterns -ComputerName $Node -Force
            $Logs | Foreach-Object {
        
                $FileSuffix = $Node+"_Event_"+$_.LogName.Replace("/","-")+".EVTX"
                $NodeFile = $NodePath+$FileSuffix
                $RFile = $RPath+$FileSuffix

                # Export filtered log file using the WEvtUtil command-line tool
                # This includes filtering the events to errors (Level=2) that happened in recent hours.
                if ($_.LogName -like "Microsoft-Windows-FailoverClustering-ClusBflt/Management") {
                    WEvtUtil.exe epl $_.LogName $NodeFile /q:$QLevel /ow:true
                } else {
                    WEvtUtil.exe epl $_.LogName $NodeFile /q:$QLevelAndTime /ow:true
                }
                Write-Output $RFile
            }

            $Logs | Foreach-Object {
        
                $UnfilteredFileSuffix = $Node+"_UnfilteredEvent_"+$_.LogName.Replace("/","-")+".EVTX"
                $UnfilteredNodeFile = $NodePath+$UnfilteredFileSuffix
                $UnfilteredRFile = $RPath+$UnfilteredFileSuffix

                # Export unfiltered log file using the WEvtUtil command-line tool
            
                if ($_.LogName -like "Microsoft-Windows-FailoverClustering-ClusBflt/Management") {
                    WEvtUtil.exe epl $_.LogName $UnfilteredNodeFile /ow:true
                } else {
                    WEvtUtil.exe epl $_.LogName $UnfilteredNodeFile /q:$QTime /ow:true
                }
                Write-Output $UnfilteredRFile
            }
        }

        "Copying Event Logs...."

        $Logs |Foreach-Object {
            # Copy event log files and remove them from the source
            Copy-Item $_ $Path -Force -ErrorAction SilentlyContinue
            Remove-Item $_ -Force -ErrorAction SilentlyContinue
        }

        "Processing Event Logs..." 

        $Files = Get-ChildItem ($Path+"\*_Event_*.EVTX") | Sort-Object Name

        If ($Files) {

            $Total1 = $Files.Count
            #$E = "" | Select-Object MachineName, LogName, EventID, Count
            $ErrorFound = $false
            $Count1 = 0

            $Files | Foreach-Object {
                Write-Progress -Activity "Processing Event Logs - Reading in" -PercentComplete ($Count1 / $Total1 * 100)
                $Count1++

                $ErrorEvents = Get-WinEvent -Path $_ -ErrorAction SilentlyContinue | 
                Sort-Object MachineName, LogName, Id | Group-Object MachineName, LogName, Id 

                If ($ErrorEvents) {
                     $ErrorEvents | Foreach-Object { $AllErrors += $_ }
                     $ErrorFound = $true 
                }
            } 

            Write-Progress -Activity "Processing Event Logs - Reading in" -Completed
        }

        #
        # Find the node name prefix, so we can trim the node name if possible
        #

        $NodeCount = @($ClusterNodes).Count
        $NodeSame = 0
        If ($NodeCount -gt 1) { 
    
            # Find the length of the shortest node name
            $NodeShort = $ClusterNodes[0].Name.Length
            1..($NodeCount-1) | Foreach-Object {
                If ($NodeShort -gt $ClusterNodes[$_].Name.Length) {
                    $NodeShort = $ClusterNodes[$_].Name.Length
                }
            }

            # Find the first character that's different in a node name (end of prefix)
            $Current = 0
            $Done = $false
            While (-not $Done) {

                1..($NodeCount-1) | Foreach-Object {
                    If ($ClusterNodes[0].Name[$Current] -ne $ClusterNodes[$_].Name[$Current]) {
                        $Done = $true
                    }
                }
                $Current++
                If ($Current -eq $NodeShort) {
                    $Done = $true
                }
            }
            # The last character was the end of the prefix
            $NodeSame = $Current-1
        } 

        #
        # Trim the node name by removing the node name prefix
        #

        Function TrimNode {
            Param ([String] $Node) 
            $Result = $Node.Split(".")[0].Trim().TrimEnd()
            If ($NodeSame -gt 0) { $Result = $Result.Substring($NodeSame, $Result.Length-$NodeSame) }
            Return $Result
        }

        # 
        # Trim the log name by removing some common log name prefixes
        #

        Function TrimLogName {
            Param ([String] $LogName) 
            $Result = $LogName.Split(",")[1].Trim().TrimEnd()
            $Result = $Result.Replace("Microsoft-Windows-","")
            $Result = $Result.Replace("Hyper-V-Shared-VHDX","Shared-VHDX")
            $Result = $Result.Replace("Hyper-V-High-Availability","Hyper-V-HA")
            $Result = $Result.Replace("FailoverClustering","Clustering")
            Return $Result
        }

        #
        # Convert the grouped table into a table with the fields we need
        #

        $Errors = $AllErrors | Select-Object @{Expression={TrimLogName($_.Name)};Label="LogName"},
        @{Expression={[int] $_.Name.Split(",")[2].Trim().TrimEnd()};Label="EventId"},
        @{Expression={TrimNode($_.Name)};Label="Node"}, Count, 
        @{Expression={$_.Group[0].Message};Label="Message"} | 
        Sort-Object LogName, EventId, Node

        #
        # Prepare to summarize events by LogName/EventId
        #

        If ($Errors) {

            $Last = $Errors.Count -1
            $LogName = ""
            $EventID = 0

            $ErrorSummary = 0 .. $Last | Foreach-Object {

                #
                # Top of row, initialize the totals
                #

                If (($LogName -ne $Errors[$_].LogName) -or ($EventId -ne $Errors[$_].EventId)) {
                    Write-Progress -Activity "Processing Event Logs - Summary" -PercentComplete ($_ / ($Last+1) * 100)
                    $LogName = $Errors[$_].LogName
                    $EventId = $Errors[$_].EventId
                    $Message = $Errors[$_].Message

                    # Zero out the node hash table
                    $NodeData = @{}
                    $ClusterNodes | Foreach-Object { 
                        $Node = TrimNode($_.Name)
                        $NodeData.Add( $Node, 0) 
                    }
                }

                # Add the error count to the node hash table
                $Node = $Errors[$_].Node
                $NodeData[$Node] += $Errors[$_].Count

                #
                # Is it the end of row?
                #

                If ($_ -eq $Last) { 
                    $EndofRow = $true 
                } else { 
                    If (($LogName -ne $Errors[$_+1].LogName) -or ($EventId -ne $Errors[$_+1].EventId)) { 
                        $EndofRow = $true 
                    } else { 
                        $EndofRow = $false 
                    }
                }

                # 
                # End of row, generate the row with the totals per Logname, EventId
                #

                If ($EndofRow) {
                    $ErrorRow = "" | Select-Object LogName, EventId
                    $ErrorRow.LogName = $LogName
                    $ErrorRow.EventId = "<" + $EventId + ">"
                    $TotalErrors = 0
                    $ClusterNodes | Sort-Object Name | Foreach-Object { 
                        $Node = TrimNode($_.Name)
                        $NNode = "N"+$Node
                        $ErrorRow | Add-Member -NotePropertyName $NNode -NotePropertyValue $NodeData[$Node]
                        $TotalErrors += $NodeData[$Node]
                    }
                    $ErrorRow | Add-Member -NotePropertyName "Total" -NotePropertyValue $TotalErrors
                    $ErrorRow | Add-Member -NotePropertyName "Message" -NotePropertyValue $Message
                    $ErrorRow
                }
            }
        } else {
            $ErrorSummary = @()
        }

        $ErrorSummary | Export-Clixml ($Path + "GetAllErrors.XML")
        Write-Progress -Activity "Processing Event Logs - Summary" -Completed

        "Gathering System Info, Reports and Minidump files ..." 

        $Count1 = 0
        $Total1 = NCount($ClusterNodes | Where-Object State -like "Up")
    
        If ($Total1 -gt 0) {
    
            $ClusterNodes | Where-Object State -like "Up" | Foreach-Object {

                $Progress = ( $Count1 / $Total1 ) * 100
                Write-Progress -Activity "Gathering System Info, Reports and Minidump files" -PercentComplete $Progress
                $Node = $_.Name + "." + $Cluster.Domain

                # Gather SYSTEMINFO.EXE output for a given node

                $LocalFile = $Path+$Node+"_SystemInfo.TXT"
                SystemInfo.exe /S $Node >$LocalFile

                # Gather Network Adapter information for a given node

                $LocalFile = $Path+"GetNetAdapter_"+$Node+".XML"
                Try { Get-NetAdapter -CimSession $Node >$LocalFile }
                Catch { ShowWarning("Unable to get a list of network adapters for node $Node") }

                # Gather SMB Network information for a given node

                $LocalFile = $Path+"GetSmbServerNetworkInterface_"+$Node+".XML"
                Try { Get-SmbServerNetworkInterface -CimSession $Node >$LocalFile } 
                Catch { ShowWarning("Unable to get a list of SMB network interfaces for node $Node") }

                if ($IncludeDumps -eq $true) {
                    # Enumerate minidump files for a given node

                    Try { $NodePath = Invoke-Command -ComputerName $Node { Get-Content Env:\SystemRoot }
                          $RPath = "\\"+$Node+"\"+$NodePath.Substring(0,1)+"$\"+$NodePath.Substring(3,$NodePath.Length-3)+"\Minidump\*.dmp"
                          $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }                       
                    Catch { $DmpFiles = ""; ShowWarning("Unable to get minidump files for node $Node") }

                    # Copy minidump files from the node

                    $DmpFiles | Foreach-Object {
                        $LocalFile = $Path + $Node + "_" + $_.Name 
                        Try { Copy-Item $_.FullName $LocalFile } 
                        Catch { ShowWarning("Could not copy minidump file $_.FullName") }
                    }        

                    Try { $NodePath = Invoke-Command -ComputerName $Node { Get-Content Env:\SystemRoot }
                          $RPath = "\\"+$Node+"\"+$NodePath.Substring(0,1)+"$\"+$NodePath.Substring(3,$NodePath.Length-3)+"\LiveKernelReports\*.dmp"
                          $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }                       
                    Catch { $DmpFiles = ""; ShowWarning("Unable to get LiveKernelReports files for node $Node") }

                    # Copy LiveKernelReports files from the node

                    $DmpFiles | Foreach-Object {
                        $LocalFile = $Path + $Node + "_" + $_.Name 
                        Try { Copy-Item $_.FullName $LocalFile } 
                        Catch { ShowWarning("Could not copy LiveKernelReports file $_.FullName") }
                    }        
                }

                Try {$NodePath = Invoke-Command -ComputerName $Node { Get-Content Env:\SystemRoot }
                     $RPath = "\\"+$Node+"\"+$NodePath.Substring(0,1)+"$\"+$NodePath.Substring(3,$NodePath.Length-3)+"\Cluster\Reports\*.*"
                     $RepFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }
                Catch { $RepFiles = ""; ShowWarning("Unable to get reports for node $Node") }

                # Copy logs from the Report directory
                $RepFiles | Foreach-Object {
                    if (($_.Name -notlike "Cluster.log") -and ($_.Name -notlike "ClusterHealth.log")) {
                        $LocalFile = $Path + $Node + "_" + $_.Name
                        Try { Copy-Item $_.FullName $LocalFile }
                        Catch { ShowWarning("Could not copy report file $_.FullName") }
                    }
                }

                $Count1++
            }
        }

        Write-Progress -Activity "Gathering System Info and Minidump files" -Completed

        "Receiving Cluster Logs..."
        $ClusterLogJob | Wait-Job | Receive-Job
        $ClusterLogJob | Remove-Job        

        $errorFilePath = $Path + "\*"
        Remove-Item -Path $errorFilePath -Include "*_Event_*.EVTX" -Recurse -Force -ErrorAction SilentlyContinue

        "All Logs Received`n"
    }

    If ($Read) { 
        Try { $ErrorSummary = Import-Clixml ($Path + "GetAllErrors.XML") }
        Catch { $ErrorSummary = @() }
    }

    If ($Read -or $IncludeEvents) {
        If (-not $ErrorSummary) {
            "No errors found`n" 
        } Else { 

            #
            # Output the final error summary
            #
            "Summary of Error Events (in the last $HoursOfEvents hours) by LogName and EventId"
            $ErrorSummary | Sort-Object Total -Descending | Select-Object * -ExcludeProperty Group, Values | Format-Table  -AutoSize
        }
    }

    if ($S2DEnabled -ne $true) { 
        if ((([System.Environment]::OSVersion.Version).Major) -ge 10) {
            "Gathering the storage diagnostic information"
            $deleteStorageSubsystem = $false
            if (-not (Get-StorageSubsystem -FriendlyName Clustered*)) {
                $storageProviderName = (Get-StorageProvider -CimSession $ClusterName | ? Manufacturer -match 'Microsoft').Name
                $registeredSubSystem = Register-StorageSubsystem -ProviderName $storageProviderName -ComputerName $ClusterName -ErrorAction SilentlyContinue
                $deleteStorageSubsystem = $true
                $storagesubsystemToDelete = Get-StorageSubsystem -FriendlyName Clustered*
            }
            $destinationPath = Join-Path -Path $Path -ChildPath 'StorageDiagnosticInfo'
            If (Test-Path -Path $destinationPath) {
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

    If (-not $read) {

        "<<< Phase 7 - Compacting files for transport >>>`n"

        $ZipSuffix = '-{0}{1:00}{2:00}-{3:00}{4:00}' -f $TodayDate.Year,$TodayDate.Month,$TodayDate.Day,$TodayDate.Hour,$TodayDate.Minute
        $ZipSuffix = "-" + $Cluster.Name + $ZipSuffix
        $ZipPath = $ZipPrefix+$ZipSuffix+".ZIP"

        # Stop Transcript
        Stop-Transcript
        
        Try {
            "Creating zip file with objects, logs and events."

            [Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem") | Out-Null
            $ZipLevel = [System.IO.Compression.CompressionLevel]::Optimal
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Path, $ZipPath, $ZipLevel, $false)
            "Zip File Name : $ZipPath `n" 
        
            "Cleaning up temporary directory $Path"
            Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse
            "Removing all the cimsessions"
            Get-CimSession | Remove-cimSession 
        } Catch {
            ShowError("Error creating the ZIP file!`nContent remains available at $Path") 
        }
    }
}

##
# PCStorageDiagnosticInfo Reporting
##

enum ReportLevelType
{
    Summary
    Standard
    Full
}

# Report Types. Ordering here is reflects output ordering when multiple reports are specified.

enum ReportType
{
    All = 0
    SSBCache = 1
    StorageLatency = 2
    StorageFirmware = 3
    LSIEvent = 4
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
function Format-SSBCacheDiskState(
    [string] $DiskState
    )
{
    $DiskState -replace 'CacheDiskState',''
}

function Get-PCStorageReportSSBCache
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
                $d | sort IsSblCacheDevice,CacheDeviceId,DiskState | ft -AutoSize @{ Label = 'DiskState'; Expression = { Format-SSBCacheDiskState $_.DiskState }},
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
                $g | sort -property Name | ft @{ Label = 'DiskState'; Expression = { Format-SSBCacheDiskState $_.Name}},@{ Label = "Number of Disks"; Expression = { $_.Count }}
            } else {
                write-output "All disks are in $(Format-SSBCacheDiskState $g.name)"
            }
        }
    }
}

function Get-PCStorageReportStorageLatency
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

            $buckhash = @{}
            $bucklabels = $null

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
                if ($bucklabels -eq $null) { $bucklabels = $xh['IoLatencyBuckets'] -split ',\s+' }
                $buckvalues = $xh.Keys |? { $_ -like 'BucketIoCount*' } | sort |% { [int] $xh[$_] }
                if ($bucklabels.count -ne $buckvalues.count) { throw "misparsed 505 event latency buckets: labels $($bucklabels.count) values $($buckvalues.count)" }

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

function Get-PCStorageReportStorageFirmware
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

function Get-PCStorageReportLsiEvent
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
    Show diagnostic reports based on information collected from Get-PCStorageDiagnosticInfo.

.DESCRIPTION
    Show diagnostic reports based on information collected from Get-PCStorageDiagnosticInfo.    

.PARAMETER Path
    Path to the the logs produced by Get-PCStorageDiagnosticInfo. This must be the un-zipped report (Expand-Archive).

.PARAMETER ReportLevel
    Controls the level of detail in the report. By default standard reports are shown. Full detail may be extensive.

.PARAMETER Report
    Specifies individual reports to produce. By default all reports will be shown.

.EXAMPLE
    Get-PCStorageTriageReport -Path C:\log -Report Full

#>

function Get-PCStorageReport
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
            { $_ -eq [ReportType]::SSBCache } {
                Get-PCStorageReportSSBCache $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::StorageLatency } {
                Get-PCStorageReportStorageLatency $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::StorageFirmware } {
                Get-PCStorageReportStorageFirmware $Path -ReportLevel:$ReportLevel
            }
            { $_ -eq [ReportType]::LsiEvent } {
                Get-PCStorageReportLsiEvent $Path -ReportLevel:$ReportLevel
            }
            default {
                throw "Internal Error: unknown report type $r"
            }
        }

        $td = (Get-Date) - $t0
        Write-Output ("Report $r took {0:N2} seconds" -f $td.TotalSeconds)
    }
}

New-Alias -Name getpcsdi -Value Get-PCStorageDiagnosticInfo -Description "Collects & reports the Storage Cluster state & diagnostic information"
New-Alias -Name Test-StorageHealth -Value Get-PCStorageDiagnosticInfo -Description "Collects & reports the Storage Cluster state & diagnostic information"

Export-ModuleMember -Alias * -Function Get-PCStorageDiagnosticInfo,Get-PCStorageReport
