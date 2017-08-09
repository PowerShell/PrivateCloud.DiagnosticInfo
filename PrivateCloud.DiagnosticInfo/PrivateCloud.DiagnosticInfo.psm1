<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>


<##################################################
#  Helper functions                               #
##################################################>

#
# Shows error, cancels script
#
Function ShowError { 
Param ([string] $Message)
    $Message = $Message + “ – cmdlet was cancelled”
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
    [bool] $IncludePerformance = $false,

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

    [parameter(ParameterSetName="Read", Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string] $ReadFromPath = "",

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
                        $o.CSVVolume = $o.CSVPath.Split(“\”)[2]
                    }     
                    $AssocLike = $o.CSVPath+”\*”
                    $AssocShares = $SmbShares | Where-Object Path –like $AssocLike 
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
                Get-StoragePool -CimSession $AccessNode –FriendlyName $AssocPName | 
                Get-VirtualDisk -CimSession $AccessNode | Foreach-Object {
                    $AssocVD = $_
                    $Associations | Foreach-Object {
                        If ($_.FriendlyName –eq $AssocVD.FriendlyName) { 
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

    if ($S2DEnabled -ne $true) {
        if ((Test-NetConnection -ComputerName 'www.microsoft.com' -Hops 1 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).PingSucceeded) {
            Compare-ModuleVersion
        }
    }

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

    if ($S2DEnabled -eq $true) {
        Try {
            $NonHealthyVDs=Get-VirtualDisk | where {$_.HealthStatus -ne "Healthy" -OR $_.OperationalStatus -ne "OK"}
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
            ShowWarning("Not able to query faulty disksa nd SSU for faulted pools")
        } 
    }

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
                        $o.CSVVolume = $o.CSVPath.Split(“\”)[2]
                    }     
                    $AssocLike = $o.CSVPath+”\*”
                    $AssocShares = $SmbShares | Where-Object Path –like $AssocLike 
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
                Get-StoragePool -CimSession $AccessNode –FriendlyName $AssocPName | 
                Get-VirtualDisk -CimSession $AccessNode | Foreach-Object {
                    $AssocVD = $_
                    $Associations | Foreach-Object {
                        If ($_.FriendlyName –eq $AssocVD.FriendlyName) { 
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
    "sers with a Witness           : $WitTotal"
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
        $ReliabilityCounters = Import-Clixml ($Path + "GetReliabilityCounter.XML")
    } else {
        Try { $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
              $ReliabilityCounters = $PhysicalDisks | Get-StorageReliabilityCounter -CimSession $AccessNode }
        Catch { ShowError("Unable to get Storage Reliability Counters. `nError="+$_.Exception.Message) }
        $ReliabilityCounters | Export-Clixml ($Path + "GetReliabilityCounter.XML")
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
            Catch { ShowError("Unable to get Drivers on node $nod. `nError="+$_.Exception.Message) }
            $Drivers | Export-Clixml ($Path + $node + "_GetDrivers.XML")
            $RelevantDrivers = $Drivers | Where-Object { ($_.DeviceName -like "LSI*") -or ($_.DeviceName -like "Mellanox*") -or ($_.DeviceName -like "Chelsio*") } | 
            Group-Object DeviceName, DriverVersion | 
            Select-Object @{Expression={$_.Name};Label="Device Name, Driver Version"}
            $RelevantDrivers
        }
    }

    "`nPhysical disks by Media Type, Model and Firmware Version" 
    $PhysicalDisks | Group-Object MediaType, Model, FirmwareVersion | Format-Table Count, @{Expression={$_.Name};Label="Media Type, Model, Firmware Version"} –AutoSize

 
    If ( -not (Get-Command *StorageEnclosure*) ) {
        ShowWarning("Storage Enclosure commands not available. See http://support.microsoft.com/kb/2913766/en-us")
    } else {
        "Storage Enclosures by Model and Firmware Version"
        $StorageEnclosures | Group-Object Model, FirmwareVersion | Format-Table Count, @{Expression={$_.Name};Label="Model, Firmware Version"} –AutoSize
    }
    
    #
    # Phase 4 Prep
    #

    "`n<<< Phase 4 - Pool, Physical Disk and Volume Details >>>"

    if ($Read) {
        $Associations = Import-Clixml ($Path + "GetAssociations.XML")
        $SNVView = Import-Clixml ($Path + "GetStorageNodeView.XML")
    } else {
        "`nCollecting device associations..."
        $Associations = $AssocJob | Wait-Job | Receive-Job
        $AssocJob | Remove-Job
        if ($null -eq $Associations) {
            ShowError("Unable to get object associations")
        }
        $Associations | Export-Clixml ($Path + "GetAssociations.XML")

        "`nCollecting storage view associations..."
        $SNVView = $SNVJob | Wait-Job | Receive-Job
        $SNVJob | Remove-Job
        if ($null -eq $SNVView) {
            ShowError("Unable to get nodes storage view associations")
        }
        $SNVView | Export-Clixml ($Path + "GetStorageNodeView.XML")        
    }

    #
    # Phase 4
    #

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
        $SNVView | Format-Table -AutoSize @{Expression = {$_.StorageNode}; Label = "StorageNode"; Align = "Left"},
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

    $PDStatus = $PhysicalDisks | Where-Object EnclosureNumber –ne $null | 
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

    #
    # Phase 5
    #

    "<<< Phase 5 - Storage Performance >>>`n"

    If ((-not $Read) -and (-not $IncludePerformance)) {
       "Performance was excluded by a parameter`n"
    }

    If ((-not $Read) -and $IncludePerformance) {

        $PerfSamples = 60 
        "Please wait for $PerfSamples seconds while performance samples are collected."

        $PerfNodes = $ClusterNodes | Where-Object State -like "Up" | Foreach-Object {$_.Name}
        $PerfCounters = “reads/sec”, “writes/sec” , “read latency”, “write latency” 
        $PerfItems = $PerfNodes | Foreach-Object { $Node=$_; $PerfCounters | Foreach-Object { (”\\”+$Node+”\Cluster CSV File System(*)\”+$_) } }
        $PerfRaw = Get-Counter -Counter $PerfItems -SampleInterval 1 -MaxSamples $PerfSamples

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
                    $DetailRow = “” | Select-Object Time, Pool, Owner, Node, Volume, Share, Counter, Value
                    $Split = $_.Path.Split(“\”)
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
            $Volume = “”
    
            $PerfVolume = 0 .. $Last | Foreach-Object {

                If ($Volume –ne $PerfDetail[$_].Volume) {
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
                    “reads/sec” { $ReadIOPS += $Value }
                    “writes/sec” { $WriteIOPS += $Value }
                    “read latency” { $ReadLatency += $Value; If ($Value -gt 0) {$NonZeroRL++} }
                    “write latency” { $WriteLatency += $Value; If ($Value -gt 0) {$NonZeroWL++} }
                    default { Write-Warning “Invalid counter” }
                }

                If ($_ -eq $Last) { 
                    $EndofVolume = $true 
                } else { 
                    If ($Volume –ne $PerfDetail[$_+1].Volume) { 
                        $EndofVolume = $true 
                    } else { 
                        $EndofVolume = $false 
                    }
                }

                If ($EndofVolume) {
                    $VolumeRow = “” | Select-Object Pool, Volume, Share, ReadIOPS, WriteIOPS, TotalIOPS, ReadLatency, WriteLatency, TotalLatency
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

    If ($Read) { 
        Try { $PerfVolume = Import-Clixml ($Path + "GetVolumePerf.XML") }
        Catch { $PerfVolume = @() }
    }

    If ($Read -or $IncludePerformance) {

        If (-not $PerfVolume) {
            "No storage performance information found" 
        } Else { 
        
            "Storage Performance per Volume, sorted by Latency"
            "Notes: Latencies in milliseconds (ms). * means multiple shares on that volume`n"

            $PerfVolume | Sort-Object TotalLatency -Descending | Select-Object * -ExcludeProperty TotalL* | Format-Table –AutoSize 
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
            param($c,$p) Get-ClusterLog -Cluster $c -Destination $p 
            if ($S2DEnabled -eq $true) {
                param($c,$p) Get-ClusterLog -Cluster $c -Destination $p -Health
            }
        }
    
        if ($S2DEnabled -eq $true) {
            "Starting Export of Cluster Health Logs..." 
            $ClusterHealthLogJob = Start-Job -ArgumentList $ClusterName,$Path { 
                param($c,$p) Get-ClusterLog -Cluster $c -Destination $p -Health
            }
        }

        "Exporting Event Logs..." 

        $AllErrors = @();
        $Logs = Invoke-Command -ArgumentList $HoursOfEvents -ComputerName $($ClusterNodes | Where-Object State -like "Up") {

            Param([int] $Hours)
            # Calculate number of milliseconds and prepare the WEvtUtil parameter to filter based on date/time
            $MSecs = $Hours * 60 * 60 * 1000
            $QParameter = "*[System[(Level=2) and TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"
            $QParameterUnfiltered = "*[System[TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"

            $Node = $env:COMPUTERNAME
            $NodePath = [System.IO.Path]::GetTempPath()
            $RPath = "\\"+$Node+"\"+$NodePath.Substring(0,1)+"$\"+$NodePath.Substring(3,$NodePath.Length-3)

            $LogPatterns = 'Storage','SMB','Failover','VHDMP','Hyper-V','ResumeKeyFilter','Witness','PnP','Space','NTFS','storport','disk','Kernel' | Foreach-Object { "*$_*" }
            $LogPatterns += 'System','Application'

            #$Logs = Get-WinEvent -ListLog $LogPatterns -ComputerName $Node | Where-Object LogName -NotLike "*Diag*" 
            $Logs = Get-WinEvent -ListLog $LogPatterns -ComputerName $Node  
            $Logs | Foreach-Object {
        
                $FileSuffix = $Node+"_Event_"+$_.LogName.Replace("/","-")+".EVTX"
                $NodeFile = $NodePath+$FileSuffix
                $RFile = $RPath+$FileSuffix

                # Export filtered log file using the WEvtUtil command-line tool
                # This includes filtering the events to errors (Level=2) that happened in recent hours.

                WEvtUtil.exe epl $_.LogName $NodeFile /q:$QParameter /ow:true
                Write-Output $RFile
            }

            $Logs | Foreach-Object {
        
                $UnfilteredFileSuffix = $Node+"_UnfilteredEvent_"+$_.LogName.Replace("/","-")+".EVTX"
                $UnfilteredNodeFile = $NodePath+$UnfilteredFileSuffix
                $UnfilteredRFile = $RPath+$UnfilteredFileSuffix

                # Export unfiltered log file using the WEvtUtil command-line tool
            
                WEvtUtil.exe epl $_.LogName $UnfilteredNodeFile /q:$QParameterUnfiltered /ow:true
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

        $NodeCount = $ClusterNodes.Count
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

        "Gathering System Info and Minidump files ..." 

        $Count1 = 0
        $Total1 = NCount($ClusterNodes | Where-Object State -like "Up")
    
        If ($Total1 -gt 0) {
    
            $ClusterNodes | Where-Object State -like "Up" | Foreach-Object {

                $Progress = ( $Count1 / $Total1 ) * 100
                Write-Progress -Activity "Gathering System Info and Minidump files" -PercentComplete $Progress
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

                $Count1++
            }
        }

        Write-Progress -Activity "Gathering System Info and Minidump files" -Completed

        "Receiving Cluster Logs..."
        $ClusterLogJob | Wait-Job | Receive-Job
        $ClusterLogJob | Remove-Job        
    
        if ($S2DEnabled) {
            "Receiving Cluster Health Logs..."
            $ClusterHealthLogJob | Wait-Job | Receive-Job
            $ClusterHealthLogJob | Remove-Job        
        }

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

<#
.SYNOPSIS
    Collect All WOSS related logs/events/... for Diagonistic

.DESCRIPTION

.PARAMETER StartTime
    The start time for collected logs, default value is two hours before current time

.PARAMETER  EndTime
    The end time for collected logs, default value is current time

.PARAMETER  TragetFolderPath
    The targetPosition unc path, default value is $env:temp

.PARAMETER  Credential
    The PSCredential object to run this script

.PARAMETER  SettingsStoreLiteralPath
    The Woss Settings Store location

.PARAMETER  $LogPrefix
    The Prefix for all the logs stored in public Azure blob
    
.EXAMPLE
    $secpasswd = ConvertTo-SecureString "Password!" -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($UserName, $secpasswd)
    $start = Get-Date -Date "2015-08-17 08:00:00"
    $end=Get-Date -Date "2015-08-17 09:00:00"

    Get-PCAzureStackACSDiagnosticInfo -StartTime $start -EndTime $end -Credential $credential -TargetFolderPath \\shared\SMB\LogCollect -Verbose
#>

function Get-PCAzureStackACSDiagnosticInfo
{
    param(
        [Parameter(Mandatory = $false)]
        [System.DateTime] $StartTime = (Get-Date).AddHours(-2),
        [Parameter(Mandatory = $false)]
        [System.DateTime] $EndTime = (Get-Date),
        [Parameter(Mandatory = $true)]
        [PSCredential] $Credential, 
        [Parameter(Mandatory = $false)]
        [System.String] $TargetFolderPath = $env:temp,
        [Parameter(Mandatory = $false)]
        [System.String] $SettingsStoreLiteralPath,
        [Parameter(Mandatory = $false)]
        [System.String] $LogPrefix
    )

    Write-Verbose "Set error action to Stop."
    $ErrorActionPreference = "Stop"
    
    if($StartTime -gt $EndTime)
    {
        Write-Error "Parameter StartTime is greater than EndTime, pls check your input and run the command again."
        exit
    }

    function global:EstablishSmbConnection
    {
    Param(
        [Parameter(
            Mandatory = $True,
            ParameterSetName = '',
            Position = 0)]
            [string[]]$remoteUNC,
        [Parameter(
            Mandatory = $True,
            ParameterSetName = '',
            Position = 1)]
            [PSCredential] $Credential
        )
        $ret = $True

        Write-Verbose('Check SMB connection on computers')

    # Inline C# helper class to connect/disconnect an SMB share using the specified credential

        $Assemblies = (
        'mscorlib'
        )

        $source = @'
        using System;
        using System.Runtime.InteropServices;

        public class WossDeploymentNetUseHelper
        {
            [DllImport("Mpr.dll", CallingConvention = CallingConvention.Winapi)]
            private static extern int WNetUseConnection
             (
                 IntPtr hwndOwner,
                 NETRESOURCE lpNetResource,
                 string lpPassword,
                 string lpUserID,
                 Connect dwFlags,
                 string lpAccessName,
                 string lpBufferSize,
                 string lpResult
             );

            [DllImport("Mpr.dll", CallingConvention = CallingConvention.Winapi)]
            public static extern int WNetCancelConnection(string Name, bool Force);

            public enum ResourceScope
            {
                CONNECTED = 0x00000001,
                GLOBALNET = 0x00000002,
                REMEMBERED = 0x00000003,
            }

            public enum ResourceType
            {
                ANY = 0x00000000,
                DISK = 0x00000001,
                PRINT = 0x00000002,
            }

            public enum ResourceDisplayType
            {
                GENERIC = 0x00000000,
                DOMAIN = 0x00000001,
                SERVER = 0x00000002,
                SHARE = 0x00000003,
                FILE = 0x00000004,
                GROUP = 0x00000005,
                NETWORK = 0x00000006,
                ROOT = 0x00000007,
                SHAREADMIN = 0x00000008,
                DIRECTORY = 0x00000009,
                TREE = 0x0000000A,
                NDSCONTAINER = 0x0000000A,
            }

            [Flags]
            public enum ResourceUsage
            {
                CONNECTABLE = 0x00000001,
                CONTAINER = 0x00000002,
                NOLOCALDEVICE = 0x00000004,
                SIBLING = 0x00000008,
                ATTACHED = 0x00000010,
            }

            [Flags]
            public enum Connect
            {
                UPDATE_PROFILE = 0x00000001,
                INTERACTIVE = 0x00000008,
                PROMPT = 0x00000010,
                REDIRECT = 0x00000080,
                LOCALDRIVE = 0x00000100,
                COMMANDLINE = 0x00000800,
                CMD_SAVECRED = 0x00001000,
            }

            [StructLayout(LayoutKind.Sequential)]
            private class NETRESOURCE
            {
                public ResourceScope dwScope = 0;
                public ResourceType dwType = 0;
                public ResourceDisplayType dwDisplayType = 0;
                public ResourceUsage dwUsage = 0;

                public string lpLocalName = null;
                public string lpRemoteName = null;
                public string lpComment = null;
                public string lpProvider = null;
            }

            public static int NetUseSmbShare(string UncPath, string username, string password)
            {
                NETRESOURCE nr = new NETRESOURCE();
                nr.dwType = ResourceType.DISK;
                nr.lpRemoteName = UncPath;
                int ret = WNetUseConnection(IntPtr.Zero, nr, password, username, 0, null, null, null);
                return ret;
            }
        }
'@
        Add-Type  -TypeDefinition $source -ReferencedAssemblies $Assemblies
        
        Foreach($path in $remoteUNC){
            $err = [WossDeploymentNetUseHelper]::NetUseSmbShare($path, $Credential.GetNetworkCredential().UserName, $Credential.GetNetworkCredential().Password)
            # The share has an existing connection from another user and WNetUseConnection returns ERROR_SESSION_CREDENTIAL_CONFLICT
            if(($err -eq 0) -or ($err -eq 1219))
            {
                 Write-Verbose('SMB {0} connection successfully established.' -f $path) 
            }
            else{
                Write-Error('{0} cannot be accessed, error: {1}' -f $path, $err) 
                $ret = $false
            }
        }
        return $ret
    }   
        
    function Upload-WossLogs
    {
        param(
            [Parameter(Mandatory = $true)]
            [System.String[]] $LogPaths,
        
            [Parameter(Mandatory = $true)]
            [System.String] $TargetFolderPath,
        
            [Parameter(Mandatory = $false)]
            [System.String] $LogPrefix
        )

        if(![string]::IsNullOrEmpty($TargetFolderPath))
        {
            foreach ($path in $LogPaths)
            {        
                if(Test-Path $path -pathtype Leaf)
                {
                    $parentPath = (get-item $path).Directory.Name
                }
                $TargetPath = Join-Path (Join-Path $TargetFolderPath $LogPrefix) $parentPath
                if(!(Test-Path -Path $TargetPath )){
                    New-Item -ItemType directory -Path $TargetPath
                }
                Write-Verbose "Upload log $path to share folder $TargetPath"
                Copy-Item $path $TargetPath -Recurse -Force
            }
            Write-Output "logs have been uploaded to share folder"
        }
    }   
    
    function Get-AcsNodeLog
    {
    [CmdletBinding()]
    param(
            [Parameter(Mandatory = $true)]
            [System.String[]] $RoleList,
            
            [Parameter(Mandatory = $false)]
            [System.String[]] $BinLogRoot,
            
            [Parameter(Mandatory = $true)]
            [System.DateTime] $StartTime,
            
            [Parameter(Mandatory = $true)]
            [System.DateTime] $EndTime,
            
            [Parameter(Mandatory = $true)]
            [System.String] $ComputerName,

            [Parameter(Mandatory = $false)]
            [PSCredential] $Credential,
            
            [Parameter(Mandatory = $true)]
            [System.String] $TargetFolderPath,
            
            [Parameter(Mandatory = $false)]
            [System.String] $LogPrefix
        )

        Write-Verbose "Create temp folder..."
        $tempLogFolder = Join-Path $env:TEMP ([System.Guid]::NewGuid())
        New-Item -ItemType directory -Path $tempLogFolder
        Write-Verbose "Temp foler is $tempLogFolder"
        
        $LogPrefix = "$LogPrefix$ComputerName"
        
        Write-Verbose "Set firewall rule to enable remote log collect."
        $sc = {
            $isEventLogInEnabled = (Get-NetFirewallRule -Name "RemoteEventLogSvc-In-TCP").Enabled
            if($isEventLogInEnabled -eq "False")
            {
                Enable-NetFirewallRule -Name "RemoteEventLogSvc-In-TCP"
            }
            $isEventLogInEnabled
        }

        if($Credential -ne $null)
        {
            $isEventLogInEnabled = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $sc
        }
        else
        {
            $isEventLogInEnabled = Invoke-Command -ComputerName $ComputerName -ScriptBlock $sc
        }

        $sc = {
            $isFPSEnabled = (Get-NetFirewallRule -Name "FPS-SMB-In-TCP").Enabled
            if($isFPSEnabled -eq "False")
            {
                Enable-NetFirewallRule -Name "FPS-SMB-In-TCP"
            }
            $isFPSEnabled
        }
        
        if($Credential -ne $null)
        {
            $isFPSEnabled = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $sc
        }
        else
        {
            $isFPSEnabled = Invoke-Command -ComputerName $ComputerName -ScriptBlock $sc
        }

        Write-Verbose "Get Cosmos Log file List"

        if($null -ne $BinLogRoot)
        {
            foreach ($root in $BinLogRoot) {

                $rawFiles = Get-ChildItem $root | Where-Object {$_.Extension -eq ".bin"}
                if($null -eq $rawFiles)
                {
                    continue
                }
                $firstFile = $rawFiles | Where-Object {$_.LastWriteTime -ge $StartTime} | Select-Object -First 1
                if($null -eq $firstFile)
                {
                    $firstFile = $rawFiles[-2]
                }

                $CosmosLogList = @()
                $getFile = $false
                foreach($file in $rawFiles)
                {
                    if($file.FullName -eq $firstFile.FullName)
                    {
                        $getFile = $true
                    }
                    if(($getFile -eq $true) -and ((Get-Content $file.FullName -Raw) -ne "")){
                        $CosmosLogList += $file.FullName
                    }
                    if($file.LastWriteTime -ge $EndTime)
                    {
                        break
                    }
                }

                if(($null -ne $CosmosLogList) -and ($CosmosLogList.count -gt 0)){
                    Upload-WossLogs -LogPaths $CosmosLogList -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
                }
                else
                {
                    Write-Verbose "$root has no log to copy."
                }
            }
            Write-Verbose "Cosmos logs copy complete."
        }

        if($RoleList.Contains("TableServer") -or $RoleList.Contains("TableMaster") -or $RoleList.Contains("AccountAndContainer") -or $RoleList.Contains("Metrics"))
        {
            Write-Verbose "Collect Events."
            $eventRootFolder = "\\$ComputerName\" + $env:SystemRoot.replace(":","$")+"\System32\Winevt\Logs\"
            $applicationEventFile = $eventRootFolder + "Application.evtx"
            $smbClientConnectivityEventFile = $eventRootFolder + "Microsoft-Windows-SmbClient%4Connectivity.evtx"
            $smbClientOperationalEventFile = $eventRootFolder + "Microsoft-Windows-SmbClient%4Operational.evtx"
            $smbClientSecurityEventFile = $eventRootFolder + "Microsoft-Windows-SmbClient%4Security.evtx"
            $wossEventAdminFile = $eventRootFolder + "Microsoft-AzureStack-ACS%4Admin.evtx"
            $wossEventOperationalFile = $eventRootFolder + "Microsoft-AzureStack-ACS%4Operational.evtx"
            $wossEventStorageAccountFile = $eventRootFolder + "Microsoft-AzureStack-ACS%4StorageAccount.evtx"
            
            Upload-WossLogs -LogPaths $applicationEventFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix

            Upload-WossLogs -LogPaths $smbClientConnectivityEventFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
            Upload-WossLogs -LogPaths $smbClientOperationalEventFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
            Upload-WossLogs -LogPaths $smbClientSecurityEventFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix

            Upload-WossLogs -LogPaths $wossEventAdminFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
            Upload-WossLogs -LogPaths $wossEventOperationalFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
            Upload-WossLogs -LogPaths $wossEventStorageAccountFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix

            Write-Verbose "Finish collecting Application, ACS and SMBClient events"
        }
        
        Write-Verbose "Collect Dump files"
        if($Credential -ne $null)
        {
            $dumpkeys = Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {Get-ChildItem "hklm:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" -ErrorAction SilentlyContinue}
        }
        else
        {
            $dumpkeys = Invoke-Command -ComputerName $ComputerName -ScriptBlock {Get-ChildItem "hklm:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" -ErrorAction SilentlyContinue}
        }
        $collectDumpExeNameList = ("blobsvc.exe","Fabric.exe","FabricDCA.exe","FabricGateway.exe","FabricHost.exe","FabricIS.exe","FabricMdsAgentSvc.exe","FabricMonSvc.exe","FabricMonSvc.exe","FabricRM.exe","FabricRS.exe","FrontEnd.Table.exe","FrontEnd.Blob.exe","FrontEnd.Queue.exe","Metrics.exe","TableMaster.exe","TableServer.exe","MonAgentHost.exe","AgentCore.exe")

        foreach ($dumpkey in $dumpkeys)
        {
            $isExeContained = $collectDumpExeNameList.Contains($dumpkey.Name)
            if($isExeContained)
            {
                $dumpFolder = ($dumpkey| Get-ItemProperty).DumpFolder
                
                $dumpFolder = "\\$ComputerName\" + $dumpFolder.replace(":","$")
                
                $dumpfiles = Get-ChildItem $dumpFolder | Where-Object {$_.CreationTime -ge $StartTime -and $_.CreationTime -le $EndTime}
                foreach ($dumpfilePath in $dumpfiles) {
                    if(!(Test-Path -Path $dumpDestinationPath )){
                        New-Item -ItemType directory -Path $dumpDestinationPath
                    }

                    Upload-WossLogs -LogPaths $dumpfilePath -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
                }
            }
        }
        Write-Verbose "Finish collecting Dump files" 
        
        Write-Verbose "Cleanup temp folder" 
        Remove-Item $tempLogFolder -Recurse -Force
        
        Write-Verbose "Reset firewall status back."
        
        if($isEventLogInEnabled -eq "False"){
            if($Credential -ne $null)
            {
                Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {Disable-NetFirewallRule -Name "RemoteEventLogSvc-In-TCP"}
            }
            else
            {
                Invoke-Command -ComputerName $ComputerName -ScriptBlock {Disable-NetFirewallRule -Name "RemoteEventLogSvc-In-TCP"}
            }
        }

        if($isFPSEnabled -eq "False"){
            if($Credential -ne $null)
            {
                Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock {Disable-NetFirewallRule -Name "FPS-SMB-In-TCP"}
            }
            else
            {
                Invoke-Command -ComputerName $ComputerName -ScriptBlock {Disable-NetFirewallRule -Name "FPS-SMB-In-TCP"}
            }        
        }

        Write-Verbose "Node $ComputerName Log Collector completed."
    }

    if($LogPrefix -eq $null){
        $LogPrefix = get-date -Format yyyyMMddHHmmss
    }
    $LogPrefix += "\"
    
    if([string]::IsNullOrEmpty($SettingsStoreLiteralPath))
    {
        $settingskey = Get-ItemProperty "hklm:\SOFTWARE\Microsoft\WOSS\Deployment"
        $SettingsStoreLiteralPath = $settingskey.SettingsStore
    }

    $tempLogFolder = Join-Path $env:TEMP ([System.Guid]::NewGuid())
    New-Item -ItemType directory -Path $tempLogFolder
    Write-Verbose "Temp foler is $tempLogFolder"
    
    if(![string]::IsNullOrEmpty($TargetFolderPath))
    {
        if(-not (Test-Path $TargetFolderPath))
        {
            Write-Verbose "Establish SMB connection to TargetFolder"
            if($Credential -ne $null)
            {
                EstablishSmbConnection -remoteUNC $TargetFolderPath -Credential $Credential
            }
            else
            {
                net use $TargetFolderPath
            }
        }
        $OriTargetFolderPath = $TargetFolderPath
        $TargetFolderPath = Join-Path $TargetFolderPath (get-date -Format yyyyMMddHHmmss)
        if(!(Test-Path -Path $TargetFolderPath)){
            New-Item -ItemType directory -Path $TargetFolderPath
        }
    }

    Write-Verbose "Copy Settings Store..."

    $settingsPrefix = $LogPrefix + "Settings\"
    Upload-WossLogs -LogPaths $SettingsStoreLiteralPath.TrimStart("file:") -TargetFolderPath $TargetFolderPath -LogPrefix $settingsPrefix

    Write-Verbose "Get Deploy Settings..."

    $SettingsFile = Get-ChildItem $SettingsStoreLiteralPath.TrimStart("file:") | Where-Object {$_.Extension -eq ".xml"} | Select-Object -Last 1

    [xml]$xmlDoc = Get-Content $SettingsFile.FullName

    $Settings = $xmlDoc.Settings

    $clusterStatusFile = Join-Path $tempLogFolder "WossDeploymentStatus.txt"
    $Settings["Deployment"] > $clusterStatusFile
    
    Upload-WossLogs -LogPaths $clusterStatusFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix

    Write-Verbose "Get Woss Node List"
    $NodeListDefinationDict = @{}
    $NodeListDefinationDict.Add("MetricsMasterNodeList", "Metrics")
    $NodeListDefinationDict.Add("MetricsRunnerNodeList", "Metrics")
    $NodeListDefinationDict.Add("BlobFENodeList", "BlobFrontEnd")
    $NodeListDefinationDict.Add("TableFENodeList", "TableFrontEnd")
    $NodeListDefinationDict.Add("QueueFENodeList", "QueueFrontEnd")
    $NodeListDefinationDict.Add("TMNodeList", "TableMaster")
    $NodeListDefinationDict.Add("TSNodeList", "TableServer")
    $NodeListDefinationDict.Add("MonitoringServiceNodeList", "MonitoringService")
    $NodeListDefinationDict.Add("ACNodeList", "AccountAndContainer")
    $NodeListDefinationDict.Add("BlobBackEndNodeList", "BlobSvc")

    $WossNodeList = @{}
    foreach($defination in $NodeListDefinationDict.Keys)
    {
        foreach($node in $Settings.Deployment[$defination].'#text'.split('|'))
        {
            if($WossNodeList.ContainsKey($node) -eq $false)
            {
                $WossNodeList.Add($node, @())
            }
            $WossNodeList[$node]+=$NodeListDefinationDict[$defination]
        }
    }
    
    Write-Verbose "Perparation Completed"

    Write-Verbose "Set error action to Continue."
    $ErrorActionPreference = "Continue"

    $blobServiceStatusFile = Join-Path $tempLogFolder "BlobServiceStatus.txt"
    sc.exe query blobsvc >> $blobServiceStatusFile
    
    Upload-WossLogs -LogPaths $blobServiceStatusFile -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix

    Write-Output "Get Service Fabric Health Status Completed"

    Write-Verbose "Trigger Log collect on Each Woss Node"
    # temp solution, hardcode SRP node as MAS-XRP01

    $WossNodeList.Add("MAS-XRP01",("SRP"))
    
    $domain = $env:UserDNSDOMAIN
    $WossNodeList.Add($domain.split('.')[0].replace("-","") + "-XRP01" , ("SRP"))
    
    Write-Verbose "Check if AD module is installed"
    $adModule = (Get-Module -Name ActiveDirectory)
    if($null -eq $adModule)
    {
        Import-Module ServerManager
        Add-WindowsFeature RSAT-AD-PowerShell
        Import-Module ActiveDirectory
    }

    foreach ($node in $WossNodeList.GetEnumerator())
    {
        $LogFolders = @()
        $roleList = @()
        foreach ($role in $node.Value)
        {
            if($role -eq "BlobSvc") {
                $logpath = $Settings.BlobSvc.CosmosLogDirectory
            }
            else {
                # temp solution, hardcode SRP path 
                if($role -eq "SRP") {
                    try {
                        Get-ADComputer $($node.Key) -ErrorAction Stop
                    }
                    catch {
                        Write-Verbose "Cannot find node: $($node.Key)"
                        continue
                    }

                    $logpath = "%programdata%\Microsoft\AzureStack\Logs\StorageResourceProvider"
                }
                else {
                    $logpath = $Settings[$role]["LogPath"].'#text'
                }
            }
            if($null -ne $logpath) {
                $logpath = [System.Environment]::ExpandEnvironmentVariables($logpath)
                $logpath = "\\$($node.Key)\" + $logpath.replace(":","$")
                $LogFolders += $logpath
            }
            $roleList += $role
        }
        if($LogFolders.Count -gt 0)
        {
            $uniLogFolders = $LogFolders | Select-Object -uniq
        }
        else
        {
            continue
        }

        Write-Verbose "Start collect on Node: $($node.Key) from $uniLogFolders"

        if($uniLogFolders.Count -gt 0)
        {
            if(-not (Test-Path $TargetFolderPath))
            {
                Write-Verbose "Establish SMB connection to source Folder"
                if($Credential -ne $null)
                {
                    EstablishSmbConnection -remoteUNC $uniLogFolders[0] -Credential $Credential
                }
                else
                {
                    net use -remoteUNC $uniLogFolders[0]
                }
            }
        }

        Get-AcsNodeLog -RoleList $roleList -BinLogRoot $uniLogFolders -StartTime $StartTime -EndTime $EndTime -TargetFolderPath $TargetFolderPath -Credential $Credential -ComputerName $($node.Key) -LogPrefix $LogPrefix
        Write-Verbose "Get log on Node: $($node.Key) Completed"
    }

    Write-Verbose "Get Cosmos log from all nodes Completed"
    
    Write-Verbose "Get Failover Cluster log"
    foreach ($node in $WossNodeList.GetEnumerator())
    {
        if($node.Value -contains "BlobBackEndNodeList")
        {
            if($Credential -ne $null)
            {
                Invoke-Command -ComputerName $($node.Key) -Credential $Credential -ScriptBlock {Get-ClusterLog}
            }
            else
            {
                Invoke-Command -ComputerName $($node.Key) -ScriptBlock {Get-ClusterLog}
            }
            $clusterlogpath = [System.Environment]::ExpandEnvironmentVariables("%windir%\Cluster\Reports\Cluster.log")
            $clusterlogpath = "\\$($node.Key)\" + $clusterlogpath.replace(":","$")
            Upload-WossLogs -LogPaths $clusterlogpath -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix
            break
        }
    }
    Write-Verbose "Get Failover Cluster log complete"

    Write-Verbose "Get Service Fabric Log List"
    $DCARoot = $Settings.Deployment.FabricDiagnosticStore.TrimStart("file:") 
    $winFabLogList = Get-ChildItem $DCARoot | Where-Object {$_.LastWriteTime -ge $StartTime -and $_.CreationTime -le $EndTime}

    $winFabLogFolder = Join-Path $tempLogFolder "WinFabLogs"
    New-Item -ItemType directory -Path $winFabLogFolder

    Write-Verbose "Start copying Logs in folder $winFabLogFolder start at $StartTime and End at $EndTime"
    foreach ($filepath in $winFabLogList) {
        $fileName = Split-Path -Path $filepath.FullName -Leaf
        $parentFolder = Split-Path -Path (Split-Path -Path $filepath.FullName -Parent) -Leaf
        $destinationPath = Join-Path $winFabLogFolder $parentFolder
        
        if(!(Test-Path -Path $destinationPath )){
            New-Item -ItemType directory -Path $destinationPath
        }

        $destinationFile = Join-Path $destinationPath $fileName
        Copy-Item $filepath.FullName -Destination $destinationFile -Force -Recurse
    }
    Write-Verbose "Compact winfabric log folder"

    Add-Type -Assembly System.IO.Compression.FileSystem
    $compressionLevel = [System.IO.Compression.CompressionLevel]::Optimal
    $zipfilename = Join-Path $env:TEMP "ServiceFabricLogs.zip"
    if(Test-Path -Path $zipfilename)
    {
        Remove-Item -Path $zipfilename
    }

    $fileSystemDllPath = [System.IO.Path]::Combine([System.IO.Path]::Combine($env:Windir,"Microsoft.NET\Framework64\v4.0.30319"), "System.IO.Compression.FileSystem.dll")

    Add-Type -Path $fileSystemDllPath
    [System.IO.Compression.ZipFile]::CreateFromDirectory($winFabLogFolder, $zipfilename, $compressionLevel, $false) 
    
    Upload-WossLogs -LogPaths $zipfilename -TargetFolderPath $TargetFolderPath -LogPrefix $LogPrefix

    Write-Verbose "Log Files was compacted into $zipfilename"

    Write-Verbose "Remove win fabric temp log folder"
    Remove-Item $winFabLogFolder -Recurse -Force

    Write-Output "Get Service Fabric Log Completed"

    if(![string]::IsNullOrEmpty($OriTargetFolderPath))
    {
        Write-Verbose "Compact log folder"
        $logName = get-date -Format yyyyMMddHHmmss
        $zipfilename = Join-Path $OriTargetFolderPath "ACSLogs_$logName.zip" 
        $compressionLevel = [System.IO.Compression.CompressionLevel]::Fastest

        [System.IO.Compression.ZipFile]::CreateFromDirectory($TargetFolderPath, $zipfilename, $compressionLevel, $false)
        Write-Verbose "Your log files was compacted into $zipfilename"

        Write-Verbose "Cleanup share folder" 
        Remove-Item $TargetFolderPath -Recurse -Force
    }

    Write-Verbose "Cleanup temp folder" 
    Remove-Item $tempLogFolder -Recurse -Force
    
    Write-Verbose "Log Collector completed."
}


New-Alias -Name getpcsdi -Value Get-PCStorageDiagnosticInfo -Description "Collects & reports the Storage Cluster state & diagnostic information"
New-Alias -Name Test-StorageHealth -Value Get-PCStorageDiagnosticInfo -Description "Collects & reports the Storage Cluster state & diagnostic information"
New-Alias -Name getacslog -Value Get-PCAzureStackACSDiagnosticInfo -Description "Collects diagnostic information of Azure Stack Storage"

Export-ModuleMember -Alias * -Function Get-PCStorageDiagnosticInfo, Get-PCAzureStackACSDiagnosticInfo

