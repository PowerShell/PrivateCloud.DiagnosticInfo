<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>

<############################################################
#  Common helper functions/modules for main/child sessions  #
############################################################>

$CommonFunc = {

    # FailoverClusters is Server-only. We allow the module to run (Show) on client.

    Import-Module CimCmdlets
    Import-Module FailoverClusters -ErrorAction SilentlyContinue
    Import-Module NetAdapter
    Import-Module NetQos
    Import-Module SmbShare
    Import-Module SmbWitness
    Import-Module Storage

    Add-Type -Assembly System.IO.Compression.FileSystem

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
        [object[]] $jobs,
        [hashtable] $namehash,
        [switch] $IncludeDone = $true,
        [switch] $IncludeRunning = $true
        )
    {
        # accumulate status lines as we go
        $job_running = @()
        $job_done = @()

        $jobs | sort Name,Location |% {

            $this = $_

            # crack parents to children
            # map children to names through the input namehash
            switch ($_.GetType().Name) {

                'PSRemotingJob' {
                    $jobname = $this.Name
                    $j = $this.ChildJobs | sort Location
                }

                'PSRemotingChildJob' {
                    if ($namehash.ContainsKey($this.Id)) {
                        $jobname = $namehash[$this.Id]
                    } else {
                        $jobname = "<n/a>"
                    }
                    $j = $this
                }

                default { throw "unexpected job type $_" }
            }

            if ($IncludeDone) {
                $j |? State -ne Running |% {
                    $job_done += "$($_.State): $($jobname) [$($_.Name) $($_.Location)]: $(($_.PSEndTime - $_.PSBeginTime).ToString("m'm's\.f's'")) : Start $($_.PSBeginTime.ToString('s')) - Stop $($_.PSEndTime.ToString('s'))"
                }
            }

            if ($IncludeRunning) {
                $t = get-date
                $j |? State -eq Running |% {
                    $job_running += "Running: $($jobname) [$($_.Name) $($_.Location)]: $(($t - $_.PSBeginTime).ToString("m'm's\.f's'")) : Start $($_.PSBeginTime.ToString('s'))"
                }
            }
        }

        if ($job_running.Count) {
            $job_running |% { Show-Update $_ }
        }

        if ($job_done.Count) {
            $job_done |% { Show-Update $_ }
        }
    }

    function Show-WaitChildJob(
        [object[]] $jobs,
        [int] $tick = 5
        )
    {
        # remember parent job names of all children for output
        # ids are session global, monotonically increasing integers
        $jhash = @{}
        $jobs |% {
            $j = $_
            $j.ChildJobs |% {
                $jhash[$_.Id] = $j.Name
            }
        }

        $tout_c = $tick
        $ttick = get-date

        # set up trackers. Note that jwait will slice to all child jobs on all input jobs.
        $jdone = @()
        $jwait = $jobs.ChildJobs
        $jtimeout = $false

        do {

            $jdone_c = $jwait | wait-job -any -timeout $tout_c
            $td = (get-date) - $ttick

            if ($jdone_c) {

                # write-host -ForegroundColor Red "done"
                Show-JobRuntime $jdone_c $jhash
                $tout_c = [int] ($tick - $td.TotalSeconds)
                if ($tout_c -lt 1) { $tout_c = 1 }
                # write-host -ForegroundColor Yellow "waiting additional $tout_c s (tout $tout and so-far $($td.TotalSeconds))"

                $jdone += $jdone_c
                $jwait = $jwait |? { $_ -notin $jdone_c }

            } else {

                $jtimeout = $true

                # write-host -ForegroundColor Yellow "timeout tick"
                write-host ("-"*20)
                $ttick = get-date
                $tout_c = $tick

                # exclude jobs which may be racing to done, we'll get them in the next tick
                Show-JobRuntime $jwait $jhash -IncludeDone:$false
            }

        } while ($jwait)

        # consume parent waits, which should be complete (all children complete)
        $null = Wait-Job $jobs

        # only do a total summary if we hit a timeout and did a running summary

        if ($jtimeout) {
            write-host "Job Summary" -ForegroundColor Green
            Show-JobRuntime $jobs
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

    #
    #  Common function to construct path to per-node data directory
    #

    function Get-NodePath(
        [string] $Path,
        [string] $node
        )
    {
        Join-Path $Path "Node_$node"
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
}

# evaluate into the main session
# without a direct assist like start-job -initialization script, passing into
# other contexts converts to string, which we must undo with [scriptblock]::Create()
. $CommonFunc

<####################################################
#  Common helper functions for main session only    #
####################################################>

function Check-ExtractZip(
    [string] $Path
    )
{
    if ($Path.ToUpper().EndsWith(".ZIP")) {

        $ExtractToPath = $Path.Substring(0, $Path.Length - 4)

        # Already done?
        $f = gi $ExtractToPath -ErrorAction SilentlyContinue
        if ($f) {
            return $f.FullName
        }

        Show-Update "Extracting $Path -> $ExtractToPath"

        try { [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $ExtractToPath) }
        catch { Show-Error("Can't extract results as Zip file from '$Path' to '$ExtractToPath'") }

        return $ExtractToPath
    }

    return $Path
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
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 

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
        [bool] $IncludePerformance = $true,

        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeReliabilityCounters = $false,
        
        [parameter(ParameterSetName="Write", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [bool] $IncludeGetNetView = $false,

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
            $healthyPDs = (Get-StoragePool -FriendlyName $PoolName -CimSession $ClusterName -ErrorAction SilentlyContinue | Get-PhysicalDisk |? HealthStatus -eq "Healthy" ).Count
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

    if ([uint64]$OS.BuildNumber -lt 14393) { 
        Show-Error("Wrong OS Version - Need at least Windows Server 2016. You are running - $($OS.Name) BuildNumber $($OS.BuildNumber)")
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
                    $AssocShares = $SmbShares |? Path -like $AssocLike 
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

        $Volumes |? FileSystem -eq CSVFS | Sort-Object SizeRemaining | 
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

    if ($Read) {
        $Path = Check-ExtractZip $Path
    } else {
        Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse | Out-Null
        md -ErrorAction SilentlyContinue $Path | Out-Null
    }

    $PathObject = Get-Item $Path
    if ($null -eq $PathObject) { Show-Error ("Path not found: $Path") }
    $Path = $PathObject.FullName

    # Note: this should be unnecessary as soon as we have the discipline of Join-Path flushed through
    if (-not $Path.EndsWith("\")) { $Path = $Path + "\" }

    ###
    # Now handle read case
    #
    # Generate Summary report based on content. Note this may be an update beyond the version
    # at the time of the gather stored in 0_CloudHealthSummary.log.
    ###

    if ($Read) {
        Show-SddcDiagnosticReport -Report Summary -ReportLevel Full $Path
        return
    }

    ###
    # From here on, this is ONLY the gather/write case (once extraction complete)
    ###

    # Start Transcript
    $transcriptFile = Join-Path $Path "0_CloudHealthGatherTranscript.log"
    try {
        Stop-Transcript | Out-Null
    }
    catch [System.InvalidOperationException]{}
    Start-Transcript -Path $transcriptFile -Force

    Show-Update "Writing to path : $Path"

    #
    # Handle parameters to archive/pass into the summary report generator.
    # XXX note expectedpools with S2D -> 1. Should we force/set?
    #

    $Parameters = "" | Select-Object TodayDate, ExpectedNodes, ExpectedNetworks, ExpectedVolumes, 
    ExpectedPhysicalDisks, ExpectedPools, ExpectedEnclosures, ExpectedDedupVolumes, HoursOfEvents, Version
    $TodayDate = Get-Date
    $Parameters.TodayDate = $TodayDate
    $Parameters.ExpectedNodes = $ExpectedNodes
    $Parameters.ExpectedNetworks = $ExpectedNetworks 
    $Parameters.ExpectedVolumes = $ExpectedVolumes 
    $Parameters.ExpectedDedupVolumes = $ExpectedDedupVolumes
    $Parameters.ExpectedPhysicalDisks = $ExpectedPhysicalDisks
    $Parameters.ExpectedPools = $ExpectedPools
    $Parameters.ExpectedEnclosures = $ExpectedEnclosures
    $Parameters.HoursOfEvents = $HoursOfEvents
    $Parameters.Version = (Get-Module PrivateCloud.DiagnosticInfo).Version.ToString()
    $Parameters | Export-Clixml ($Path + "GetParameters.XML")

    Show-Update "PrivateCloud.DiagnosticInfo v $($Parameters.Version)"

    #
    # Phase 1
    #

    Show-Update "<<< Phase 1 - Data Gather >>>`n" -ForegroundColor Cyan

    #
    # Cluster Nodes
    #

    try { $ClusterNodes = GetFilteredNodeList }
    catch { Show-Error "Unable to get Cluster Nodes" $_ }
    $ClusterNodes | Export-Clixml ($Path + "GetClusterNode.XML")

    #
    # Get-Cluster
    #

    try { 
        if ($ClusterName -eq ".")
        {
            foreach ($cn in $ClusterNodes)
            {
                $Cluster = Get-Cluster -Name $cn[0].Name -ErrorAction SilentlyContinue
                
                # if we cannot connect to cluster service will still have an access node this way
                $AccessNode = $cn[0].Name
                
                if ($Cluster -eq $null)
                {
                    continue;
                }				
                $ClusterName = $Cluster.Name
                break;
            }
        }
        else
        {
            $Cluster = Get-Cluster -Name $ClusterName
            $AccessNode = $ClusterNodes[0].Name
        }
    }
    catch { Show-Error("Cluster could not be contacted. `nError="+$_.Exception.Message) }

    if ($Cluster -ne $null)
    {
        $Cluster | Export-Clixml ($Path + "GetCluster.XML")
        $ClusterName = $Cluster.Name + "." + $Cluster.Domain
        $S2DEnabled = $Cluster.S2DEnabled
        $ClusterDomain = $Cluster.Domain 

        Write-Host "Cluster name               : $ClusterName"
    }
    else
    {
        # We can only get here if -Nodelist was used, but cluster service isn't running
        Write-Error "Cluster service was not running on any node, some information will be unavailable"
        $ClusterName = $null;
        $ClusterDomain = "";
        
        Write-Host "Cluster name               : Unavailable, Cluster is not online on any node"
    }
    Write-Host "Access node                : $AccessNode`n"

    # Create node-specific directories for content

    $ClusterNodes.Name |% {
        md (Get-NodePath $Path $_) | Out-Null
    }

    #
    # Verify deduplication prerequisites on access node.
    #

    $DedupEnabled = $true
    if ($(Invoke-Command -ComputerName $AccessNode {(-not (Get-Command -Module Deduplication))} )) { 
        $DedupEnabled = $false
        if ($S2DEnabled -ne $true) {
            Show-Warning "Deduplication PowerShell not installed on cluster node."
        }
    }

    ####
    # Start accumulating static jobs which self-contain their gather.
    # These are pulled in close to the end. Consider how to regularize this down the line.
    ####
    $JobStatic = @()
    $JobCopyOut = @()

    Show-Update "Start gather of cluster configuration ..."

    $JobStatic += Start-Job -InitializationScript $CommonFunc -Name ClusterGroup {
        try { 
            $o = Get-ClusterGroup -Cluster $using:AccessNode 
            $o | Export-Clixml ($using:Path + "GetClusterGroup.XML")
        }
        catch { Show-Warning("Unable to get Cluster Groups. `nError="+$_.Exception.Message) }
    }

    $JobStatic += Start-Job -InitializationScript $CommonFunc -Name ClusterNetwork {
        try { 
            $o = Get-ClusterNetwork -Cluster $using:AccessNode
            $o | Export-Clixml ($using:Path + "GetClusterNetwork.XML")
        }
        catch { Show-Warning("Could not get Cluster Nodes. `nError="+$_.Exception.Message) }
    }

    $JobStatic += Start-Job -InitializationScript $CommonFunc -Name ClusterResource {
        try {  
            $o = Get-ClusterResource -Cluster $using:AccessNode
            $o | Export-Clixml ($using:Path + "GetClusterResource.XML")
        }
        catch { Show-Warning("Unable to get Cluster Resources.  `nError="+$_.Exception.Message) }

    }

    $JobStatic += Start-Job -InitializationScript $CommonFunc -Name ClusterResourceParameter {
        try {  
            $o = Get-ClusterResource -Cluster $using:AccessNode | Get-ClusterParameter
            $o | Export-Clixml ($using:Path + "GetClusterResourceParameters.XML")
        }
        catch { Show-Warning("Unable to get Cluster Resource Parameters.  `nError="+$_.Exception.Message) }

    }

    $JobStatic += Start-Job -InitializationScript $CommonFunc -Name ClusterSharedVolume {
        try {  
            $o = Get-ClusterSharedVolume -Cluster $using:AccessNode
            $o | Export-Clixml ($using:Path + "GetClusterSharedVolume.XML")
        }
        catch { Show-Warning("Unable to get Cluster Shared Volumes.  `nError="+$_.Exception.Message) }

    }

    Show-Update "Start gather of driver information ..."

    $ClusterNodes.Name |% {
        
        $node = $_

        $JobStatic += Start-Job -InitializationScript $CommonFunc -Name "Driver Information: $node" {
            try { $o = Get-CimInstance -ClassName Win32_PnPSignedDriver -ComputerName $using:node }       
            catch { Show-Error("Unable to get Drivers on $using:node. `nError="+$_.Exception.Message) }
            $o | Export-Clixml (Join-Path (Get-NodePath $using:Path $using:node) "GetDrivers.XML")
        }
    }

    # consider using this as the generic copyout job set
    # these are gathers which are not remotable, which we run remote and copy back results for
    # keep control of which gathers are fast and therefore for which serialization is not a major issue
    
    Show-Update "Start gather of verifier ..."
        
    $JobCopyOut += Invoke-Command -ComputerName $($ClusterNodes).Name -AsJob -JobName Verifier {

        # import common functions
        . ([scriptblock]::Create($using:CommonFunc)) 

        # Verifier

        $LocalFile = Join-Path $env:temp "verifier-query.txt"
        verifier /query > $LocalFile
        Write-Output (Get-AdminSharePathFromLocal $env:COMPUTERNAME $LocalFile)

        $LocalFile = Join-Path $env:temp "verifier-querysettings.txt"
        verifier /querysettings > $LocalFile
        Write-Output (Get-AdminSharePathFromLocal $env:COMPUTERNAME $LocalFile)
    }

    if ($IncludeGetNetView) {

        Show-Update "Start gather of Get-NetView ..."

        $ClusterNodes.Name |% {

            $JobCopyOut += Invoke-Command -ComputerName $_ -AsJob -JobName GetNetView {

                # import common functions
                . ([scriptblock]::Create($using:CommonFunc)) 

                $NodePath = [System.IO.Path]::GetTempPath()

                # create a directory to capture GNV

                $gnvDir = Join-Path $NodePath 'GetNetView'
                Remove-Item -Recurse -Force $gnvDir -ErrorAction SilentlyContinue
                md $gnvDir -Force -ErrorAction SilentlyContinue

                # run inside a child session so we can sink output to the transcript
                # we must pass the GNV dir since $using is statically evaluated in the
                # outermost scope and $gnvDir is inside the Invoke call.

                $j = Start-Job -ArgumentList $gnvDir {

                    param($gnvDir)

                    # start gather transcript to the GNV directory

                    $transcriptFile = Join-Path $gnvDir "0_GetNetViewGatherTranscript.log"
                    Start-Transcript -Path $transcriptFile -Force

                    if (Get-Command Get-NetView -ErrorAction SilentlyContinue) {
                        Get-NetView -OutputDirectory $gnvDir
                    } else {
                        Write-Host "Get-NetView command not available"
                    }

                    Stop-Transcript
                }

                # do not receive job - sunk to transcript for offline analysis
                # gnv produces a very large quantity of host output
                $null = $j | Wait-Job
                $j | Remove-Job

                # wipe all non-file content (gnv produces zip + uncompressed dir, don't need the dir)
                dir $gnvDir -Directory |% {
                    Remove-Item -Recurse -Force $_.FullName
                }

                # gather all remaining content (will be the zip + transcript) in GNV directory
                Write-Output (Get-AdminSharePathFromLocal $env:COMPUTERNAME $gnvDir)
            }
        }
    }

    # Events, cmd, reports, et.al.
    Show-Update "Start gather of system info, cluster/health logs, reports and dump files ..." 

    $JobStatic += Start-Job -Name ClusterLogs { 
        $null = Get-ClusterLog -Node $using:ClusterNodes.Name -Destination $using:Path -UseLocalTime
    }

    if ($S2DEnabled) {
        $JobStatic += Start-Job -Name ClusterHealthLogs { 
            $null = Get-ClusterLog -Node $using:ClusterNodes.Name -Destination $using:Path -Health -UseLocalTime
        }
    }

    $JobStatic += $($ClusterNodes).Name |% {

        Start-Job -Name "System Info: $_" -ArgumentList $_,$ClusterDomain -InitializationScript $CommonFunc {

            param($NodeName,$DomainName)

            $Node = "$NodeName.$DomainName"
            $LocalNodeDir = Get-NodePath $using:Path $NodeName

            # Text-only conventional commands
            #
            # Gather SYSTEMINFO.EXE output for a given node
            SystemInfo.exe /S $Node > (Join-Path (Get-NodePath $using:Path $NodeName) "SystemInfo.TXT")

            # Cmdlets to drop in TXT and XML forms
            #
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
                $LocalFile = (Join-Path $LocalNodeDir (($cmd.split(' '))[0] -replace "-",""))
                try {

                    $out = iex ($cmd -replace '_C_',$Node)

                    # capture as txt and xml for quick analysis according to taste
                    $out | Out-File -Width 9999 -Encoding ascii -FilePath "$LocalFile.txt"
                    $out | Export-Clixml -Path "$LocalFile.xml"

                } catch {
                    Show-Warning "'$cmd $node' failed for node $Node"
                }
            }

            $NodeSystemRootPath = Invoke-Command -ComputerName $Node { $env:SystemRoot }

            if ($using:IncludeDumps -eq $true) {

                ##
                # Minidumps
                ##

                try {
                    $RPath = (Get-AdminSharePathFromLocal $Node (Join-Path $NodeSystemRootPath "Minidump\*.dmp"))
                    $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }                       
                catch { $DmpFiles = ""; Show-Warning "Unable to get minidump files for node $Node" }

                $DmpFiles |% {
                    try { Copy-Item $_.FullName $LocalNodeDir } 
                    catch { Show-Warning("Could not copy minidump file $_.FullName") }
                }

                ##
                # Live Kernel Reports
                ##

                try { 
                    $RPath = (Get-AdminSharePathFromLocal $Node (Join-Path $NodeSystemRootPath "LiveKernelReports\*.dmp"))
                    $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }                       
                catch { $DmpFiles = ""; Show-Warning "Unable to get LiveKernelReports files for node $Node" }

                $DmpFiles |% {
                    try { Copy-Item $_.FullName $LocalNodeDir } 
                    catch { Show-Warning "Could not copy LiveKernelReports file $($_.FullName)" }
                }
            }

            try {
                $RPath = (Get-AdminSharePathFromLocal $Node (Join-Path $NodeSystemRootPath "Cluster\Reports\*.*"))
                $RepFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }
            catch { $RepFiles = ""; Show-Warning "Unable to get reports for node $Node" }
                
            $LocalReportDir = Join-Path $LocalNodeDir "ClusterReports"
            md $LocalReportDir | Out-Null

            # Copy logs from the Report directory; exclude cluster/health logs which we're getting seperately
            $RepFiles |% {
                if (($_.Name -notlike "Cluster.log") -and ($_.Name -notlike "ClusterHealth.log")) {
                    try { Copy-Item $_.FullName $LocalReportDir }
                    catch { Show-Warning "Could not copy report file $($_.FullName)" }
                }
            }
        }
    }

    Show-Update "Starting export of events ..." 

    $JobCopyOut += Invoke-Command -ArgumentList $HoursOfEvents -ComputerName $($ClusterNodes).Name -AsJob -JobName Events {

        Param([int] $Hours)

        # import common functions
        . ([scriptblock]::Create($using:CommonFunc)) 

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
        
            $NodeFile = $NodePath+$_.LogName.Replace("/","-")+".EVTX"

            # analytical/debug channels can not be captured live
            # if any are encountered (not normal), disable them temporarily for export
            $directChannel = $false
            if ($_.LogType -in @('Analytical','Debug') -and $_.IsEnabled) {
                $directChannel = $true
                wevtutil sl /e:false $_.LogName
            }

            # Export unfiltered log file using the WEvtUtil command-line tool
            if ($_.LogName -like "Microsoft-Windows-FailoverClustering-ClusBflt/Management"  -Or ($MSecs -eq -1)) {
                wevtutil epl $_.LogName $NodeFile /ow:true
            } else {
                wevtutil epl $_.LogName $NodeFile /q:$QTime /ow:true
            }

            if ($directChannel -eq $true) {
                echo y | wevtutil sl /e:true $_.LogName | out-null
            }

            # Create locale metadata for off-system rendering
            wevtutil al $NodeFile /l:$PSCulture

            Write-Output (Get-AdminSharePathFromLocal $Node $NodeFile)
        }

        # Also export locale metadata for off-system rendering (one-shot, we'll recursively copy)
        Write-Output (Get-AdminSharePathFromLocal $Node (Join-Path $NodePath "LocaleMetaData"))
    }

    if ($IncludeAssociations -and $ClusterName -ne $null) {

        # This is used at Phase 2 and is run asynchronously since
        # it can take some time to gather for large numbers of devices.

        # Gather nodes view of storage and build all the associations

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
                $PDUID = ($allPhysicalDisks |? ObjectID -Match $pdID).UniqueID
                $pd = $allPhysicalDisks |? UniqueID -eq $PDUID
                $nodeIndex = $phyDisk.StorageNodeObjectId.IndexOf("SN:")
                $nodeLength = $phyDisk.StorageNodeObjectId.Length
                $storageNodeName = $phyDisk.StorageNodeObjectId.Substring($nodeIndex+3, $nodeLength-($nodeIndex+4))  
                $poolName = ($pd | Get-StoragePool -CimSession $clusterCimSession -ErrorAction SilentlyContinue |? IsPrimordial -eq $false).FriendlyName
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

        # Gather association between pool, virtualdisk, volume, share.

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
                    $AssocShares = $SmbShares |? Path -like $AssocLike 
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

    #
    # Generate SBL Connectivity report based on input clusport information
    #
    
    if ($S2DEnabled) {

        Show-Update "Unhealthy VD"

        try {
            $NonHealthyVDs = Get-VirtualDisk |? {$_.HealthStatus -ne "Healthy" -OR $_.OperationalStatus -ne "OK"}
            $NonHealthyVDs | Export-Clixml ($Path + "NonHealthyVDs.XML")

            foreach ($NonHealthyVD in $NonHealthyVDs) {
                $NonHealthyExtents = $NonHealthyVD | Get-PhysicalExtent |? OperationalStatus -ne Active | sort-object VirtualDiskOffset, CopyNumber
                $NonHealthyExtents | Export-Clixml($Path + $NonHealthyVD.FriendlyName + "_Extents.xml")
            }
        } catch {
            Show-Warning "Not able to query extents for faulted virtual disks"
        } 

        Show-Update "SSB Disks and SSU"

        try {
            Get-StoragePool -ErrorAction SilentlyContinue |? IsPrimordial -eq $false |% {
                $Disks = $_ | Get-PhysicalDisk 
                $Disks | Export-Clixml($Path + $_.FriendlyName + "_Disks.xml")
                    
                $SSU = $Disks | Get-StorageFaultDomain -type StorageScaleUnit | group FriendlyName |% { $_.Group[0] }
                $SSU | Export-Clixml($Path + $_.FriendlyName + "_SSU.xml")
            }
        } catch {
            Show-Warning "Not able to query faulty disks and SSU for faulted pools"
        }

        Show-Update "S2D Connectivity"

        try {
            $j = $ClusterNodes |? { $_.State.ToString() -eq 'Up' } |% {
                $node = $_.Name
                Start-Job -Name $node -InitializationScript $CommonFunc {
                    Get-CimInstance -Namespace root\wmi -ClassName ClusPortDeviceInformation -ComputerName $using:node |
                        Export-Clixml (Join-Path (Get-NodePath $using:Path $using:node) "ClusPort.xml")
                    Get-CimInstance -Namespace root\wmi -ClassName ClusBfltDeviceInformation -ComputerName $using:node |
                        Export-Clixml (Join-Path (Get-NodePath $using:Path $using:node) "ClusBflt.xml")
                }
            }

            $null = $j | Wait-Job
            $j | Receive-Job
            $j | Remove-Job

        } catch {
            Show-Warning "Gathering SBL connectivity failed"
        }
    }

    #
    # SMB share health/status
    #

    Show-Update "SMB Shares"

    try { $SmbShares = Get-SmbShare -CimSession $AccessNode }
    catch { Show-Error("Unable to get SMB Shares. `nError="+$_.Exception.Message) }

    # XXX only sharepath and health are added in, why are we selecting down to just these four as opposed to add-member?
    $ShareStatus = $SmbShares |? ContinuouslyAvailable | Select-Object ScopeName, Name, SharePath, Health
    $Count1 = 0
    $Total1 = NCount($ShareStatus)

    if ($Total1 -gt 0)
    {
        $ShareStatus |% {
            $Progress = $Count1 / $Total1 * 100
            $Count1++
            Write-Progress -Activity "Testing file share access" -PercentComplete $Progress

            if ($ClusterDomain -ne "")
            {
                $_.SharePath = "\\" + $_.ScopeName + "." + $ClusterDomain + "\" + $_.Name
            }
            else
            {
                $_.SharePath = "\\" + $_.ScopeName + "\" + $_.Name
            }
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

    $ShareStatus | Export-Clixml ($Path + "ShareStatus.XML")

    try {
        $o = Get-SmbOpenFile -CimSession $AccessNode
        $o | Export-Clixml ($Path + "GetSmbOpenFile.XML") }
    catch { Show-Error("Unable to get Open Files. `nError="+$_.Exception.Message) }
    

    try {
        $o = Get-SmbWitnessClient -CimSession $AccessNode
        $o | Export-Clixml ($Path + "GetSmbWitness.XML") }
    catch { Show-Error("Unable to get Open Files. `nError="+$_.Exception.Message) }
    
    Show-Update "Clustered Subsystem"

    # NOTE: $SubSystem is reused several times below
    try {
        $SubSystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
        $SubSystem | Export-Clixml ($Path + "GetStorageSubsystem.XML")
    }
    catch { Show-Warning("Unable to get Clustered Subsystem. `nError="+$_.Exception.Message) }

    Show-Update "Volumes & Virtual Disks"

    # Volume status

    try { 
        $Volumes = Get-Volume -CimSession $AccessNode -StorageSubSystem $SubSystem 
        $Volumes | Export-Clixml ($Path + "GetVolume.XML") }
    catch { Show-Error("Unable to get Volumes. `nError="+$_.Exception.Message) }
    

    # Virtual disk health

    try { 
        $o = Get-VirtualDisk -CimSession $AccessNode -StorageSubSystem $SubSystem 
        $o | Export-Clixml ($Path + "GetVirtualDisk.XML")
    }
    catch { Show-Warning("Unable to get Virtual Disks. `nError="+$_.Exception.Message) }
    
    # Deduplicated volume health
    # XXX the counts/healthy likely not needed once phase 2 shifted into summary report

    if ($DedupEnabled)
    {
        Show-Update "Dedup Volume Status"

        try {
            $DedupVolumes = Invoke-Command -ComputerName $AccessNode { Get-DedupStatus }
            $DedupVolumes | Export-Clixml ($Path + "GetDedupVolume.XML") }
        catch { Show-Error("Unable to get Dedup Volumes. `nError="+$_.Exception.Message) }

        $DedupTotal = NCount($DedupVolumes)
        $DedupHealthy = NCount($DedupVolumes |? LastOptimizationResult -eq 0 )

    } else {

        $DedupVolumes = @()
        $DedupTotal = 0
        $DedupHealthy = 0
    }

    Show-Update "Storage Pool & Tiers"

    # Storage tier information

    try {
        $o = Get-StorageTier -CimSession $AccessNode
        $o | Export-Clixml ($Path + "GetStorageTier.XML") }
    catch { Show-Warning("Unable to get Storage Tiers. `nError="+$_.Exception.Message) }
    
    # Storage pool health

    try { 
        $StoragePools = Get-StoragePool -IsPrimordial $False -CimSession $AccessNode -StorageSubSystem $SubSystem -ErrorAction SilentlyContinue
        $StoragePools | Export-Clixml ($Path + "GetStoragePool.XML") }
    catch { Show-Error("Unable to get Storage Pools. `nError="+$_.Exception.Message) }

    Show-Update "Storage Jobs"

    try {
        # cannot subsystem scope Get-StorageJob at this time
        $o = icm $AccessNode { Get-StorageJob }
        $o | Export-Clixml ($Path + "GetStorageJob.XML") }
    catch { Show-Warning("Unable to get Storage Jobs. `nError="+$_.Exception.Message) }

    Show-Update "Clustered PhysicalDisks and SNV"

    # Physical disk health

    try {
        $PhysicalDisks = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $SubSystem
        $PhysicalDisks | Export-Clixml ($Path + "GetPhysicalDisk.XML") }
    catch { Show-Error("Unable to get Physical Disks. `nError="+$_.Exception.Message) }

    try {
        $PhysicalDiskSNV = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $SubSystem | Get-PhysicalDiskSNV -CimSession $AccessNode
        $PhysicalDiskSNV | Export-Clixml ($Path + "GetPhysicalDiskSNV.XML") }
    catch { Show-Error("Unable to get Physical Disk Storage Node View. `nError="+$_.Exception.Message) }

    # Reliability counters
    # These may cause a latency burst on some devices due to device-specific requirements for lifting/generating
    # the SMART data which underlies them. Decline to do this by default.

    if ($IncludeReliabilityCounters -eq $true) {

        Show-Update "Storage Reliability Counters"

        try {
            $o = $PhysicalDisks | Get-StorageReliabilityCounter -CimSession $AccessNode
            $o | Export-Clixml ($Path + "GetReliabilityCounter.XML") }
        catch { Show-Error("Unable to get Storage Reliability Counters. `nError="+$_.Exception.Message) }

    }

    # Storage enclosure health

    Show-Update "Storage Enclosures"

    try {
        $o = Get-StorageEnclosure -CimSession $AccessNode -StorageSubSystem $SubSystem
        $o | Export-Clixml ($Path + "GetStorageEnclosure.XML") }
    catch { Show-Error("Unable to get Enclosures. `nError="+$_.Exception.Message) }


    ####
    # Now receive the jobs requiring remote copyout
    ####

    if ($JobCopyOut.Count) {
        Show-Update "Completing jobs with remote copyout ..." -ForegroundColor Green
        Show-WaitChildJob $JobCopyOut 120
        Show-Update "Starting remote copyout ..."

        # keep parallelizing on receive at the individual node/child job level
        $JobCopy = @()
        $JobCopyOut.ChildJobs |% {
            $logs = Receive-Job $_

            $JobCopy += start-job -Name "Copy $($_.Location)" -InitializationScript $CommonFunc {

                $using:logs |% {
                    Copy-Item -Recurse $_  (Get-NodePath $using:Path $_.PsComputerName) -Force -ErrorAction SilentlyContinue -Verbose
                    Remove-Item -Recurse $_ -Force -ErrorAction SilentlyContinue
                }
            }
        }

        Show-WaitChildJob $JobCopy 30
        Remove-Job $JobCopyOut
        Remove-Job $JobCopy

        Show-Update "All remote copyout complete" -ForegroundColor Green
    }

    ####
    # Now receive the static jobs
    ####

    Show-Update "Completing background gathers ..." -ForegroundColor Green
    Show-WaitChildJob $JobStatic 30
    Receive-Job $JobStatic
    Remove-Job $JobStatic

    # wipe variables to catch reuse
    Remove-Variable JobCopyOut
    Remove-Variable JobStatic

    #
    # Phase 2 Prep
    #
    Show-Update "<<< Phase 2 - Pool, Physical Disk and Volume Details >>>" -ForegroundColor Cyan

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
    # Phase 2
    #

    if ($IncludeHealthReport) {
        "`n[Health Report]" 
        "`nVolumes with status, total size and available size, sorted by Available Size" 
        "Notes: Sizes shown in gigabytes (GB). * means multiple shares on that volume"

        $Volumes |? FileSystem -eq CSVFS | Sort-Object SizeRemaining | 
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

        $PDStatus = $PhysicalDisks |? EnclosureNumber -ne $null | 
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
            $PDCurrent = $PhysicalDisks |? { ($_.EnclosureNumber -eq $Current.Enc) -and ($_.MediaType -eq $Current.Media) -and ($_.HealthStatus -eq $Current.Health) }
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
    # Phase 3
    #
    Show-Update "<<< Phase 3 - Storage Performance >>>" -ForegroundColor Cyan

    if (-not $IncludePerformance) {

       "Performance was excluded by a parameter`n"

    } else {

        Show-Update "Get counter sets"
        $set = Get-Counter -ListSet *"virtual disk"*, *"hybrid"*, *"cluster storage"*, *"cluster csv"*,*"storage spaces"* -ComputerName $ClusterNodes.Name
        Show-Update "Start monitoring ($($PerfSamples)s)"		
        $PerfRaw = Get-Counter -Counter $set.Paths -SampleInterval 1 -MaxSamples $PerfSamples -ErrorAction Ignore -WarningAction Ignore

        #$PerfCounters = "reads/sec","writes/sec","read latency","write latency"
        #$PerfItems = $PerfNodes |% { $Node=$_; $PerfCounters |% { ("\\"+$Node+"\Cluster CSV File System(*)\"+$_) } }
        #$PerfRaw = Get-Counter -Counter $PerfItems -SampleInterval 1 -MaxSamples $PerfSamples

        Show-Update "Exporting counters"
        $PerfRaw | Export-counter -Path ($Path + "GetCounters.blg") -Force -FileFormat BLG

        Show-Update "Completed"

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
                        default { Write-Warning "Invalid counter $_" }
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
  
    if ($S2DEnabled -ne $true) { 
        if ((([System.Environment]::OSVersion.Version).Major) -ge 10) {
            Show-Update "Gathering the storage diagnostic information"
            $deleteStorageSubsystem = $false
            if (-not (Get-StorageSubsystem -FriendlyName Clustered*)) {
                $storageProviderName = (Get-StorageProvider -CimSession $ClusterName |? Manufacturer -match 'Microsoft').Name
                $null = Register-StorageSubsystem -ProviderName $storageProviderName -ComputerName $ClusterName -ErrorAction SilentlyContinue
                $deleteStorageSubsystem = $true
                $storagesubsystemToDelete = Get-StorageSubsystem -FriendlyName Clustered*
            }
            $destinationPath = Join-Path -Path $Path -ChildPath 'StorageDiagnosticInfo'
            if (Test-Path -Path $destinationPath) {
                Remove-Item -Path $destinationPath -Recurse -Force
            }
            New-Item -Path $destinationPath -ItemType Directory
            $clusterSubsystem = (Get-StorageSubSystem |? Model -eq 'Clustered Windows Storage').FriendlyName
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

    Show-Update "GATHERS COMPLETE ($([int]((Get-Date) - $TodayDate).TotalSeconds)s)" -ForegroundColor Green

    # Stop Transcript
    Stop-Transcript

    # Generate Summary report for rapid consumption at analysis time
    Show-Update "<<< Generating Summary Report >>>" -ForegroundColor Cyan
    $transcriptFile = $Path + "0_CloudHealthSummary.log"
    Start-Transcript -Path $transcriptFile -Force
    Show-SddcDiagnosticReport -Report Summary -ReportLevel Full $Path
    Stop-Transcript

    #
    # Phase 4
    #

    Show-Update "<<< Phase 4 - Compacting files for transport >>>" -ForegroundColor Cyan

    #
    # Force GC so that any pending file references are
    # torn down. If they live, they will block removal
    # of content.
    #

    [System.GC]::Collect()

    $ZipSuffix = '-{0}{1:00}{2:00}-{3:00}{4:00}' -f $TodayDate.Year,$TodayDate.Month,$TodayDate.Day,$TodayDate.Hour,$TodayDate.Minute
    $ZipSuffix = "-" + $Cluster.Name + $ZipSuffix
    $ZipPath = $ZipPrefix+$ZipSuffix+".ZIP"
    
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($Path, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        Show-Update "Zip File Name : $ZipPath"

        Show-Update "Cleaning up temporary directory $Path"
        Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse

    } catch {
        Show-Error("Error creating the ZIP file!`nContent remains available at $Path") 
    }

    Show-Update "Cleaning up CimSessions"
    Get-CimSession | Remove-CimSession

    Show-Update "COMPLETE ($([int]((Get-Date) - $TodayDate).TotalSeconds)s)" -ForegroundColor Green
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
    Summary
    StorageBusCache
    StorageBusConnectivity
    StorageLatency
    StorageFirmware
    LSIEvent
}

# helper function to parse the csv-demarcated sections of the cluster log
# return value is a hashtable indexed by section name

function Get-ClusterLogDataSource
{
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
    param(
        [string] $logname
    )

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
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
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

        $data = Get-ClusterLogDataSource $_.FullName

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
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
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

    dir $path\Node_*\ClusPort.xml | sort -Property FullName |% {

        $file = $_.FullName
        $node = "<unknown>"
        if ($file -match "Node_([^\\]+)\\") {
            $node = $matches[1]
        }

        Import-Clixml $_ | Show-SSBConnectivity $node
    }
}

function Get-StorageLatencyReport
{
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
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

    dir $Path\Node_*\Microsoft-Windows-Storage-Storport-Operational.EVTX | sort -Property FullName |% {

        $file = $_.FullName
        $node = "<unknown>"
        if ($file -match "Node_([^\\]+)\\") {
            $node = $matches[1]
        }

        # parallelize processing of per-node event logs

        $j += Start-Job -Name $node -ArgumentList $($ReportLevel -eq [ReportLevelType]::Full) {

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
                if ($null -eq $bucklabels) {
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

        Write-Output ("-"*40),"Node: $node","`nSample Period Count Report"

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
                if ($null -ne $evs) {
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
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
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

    $good = @()
    $PhysicalDisks | group -Property Manufacturer,Model | sort Name |% {

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
            $good += "$($_.Group[0].Manufacturer) $($_.Group[0].Model): all devices are on firmware version $($_.Group[0].FirmwareVersion)"
        }
    }

    Write-Output $good
}

function Get-LsiEventReport
{
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
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

    dir $Path\Node_*\System.EVTX | sort -Property FullName |% {

        $node = "<unknown>"
        if ($_.FullName -match "Node_([^\\]+)\\") {
            $node = $matches[1]
        }

        Write-Output ("-"*40) "Node: $node"

        # can we get an authoratative list of lsi providers? otherwise, this
        # deep filter may serve well enough to make it performant
        $ev = Get-WinEvent -Path $_ -FilterXPath '*[System[(EventID=11)]]' -ErrorAction SilentlyContinue |? ProviderName -match "lsi" |% {

            new-object psobject -Property @{
                'Time' = $_.TimeCreated;
                'Provider Name' = $_.ProviderName;
                'LSI Error'= (($_.Properties[1].Value[19..16] |% { '{0:X2}' -f $_ }) -join '');
            }
        }

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

function Get-SummaryReport
{
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 
    param(
        [parameter(Position=0, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [parameter(Mandatory=$true)]
        [ReportLevelType]
        $ReportLevel
    )

    $Parameters = Import-Clixml (Join-Path $Path "GetParameters.XML")
    $TodayDate = $Parameters.TodayDate
    $ExpectedNodes = $Parameters.ExpectedNodes
    $ExpectedNetworks = $Parameters.ExpectedNetworks
    $ExpectedVolumes = $Parameters.ExpectedVolumes
    $ExpectedDedupVolumes = $Parameters.ExpectedDedupVolumes
    $ExpectedPhysicalDisks = $Parameters.ExpectedPhysicalDisks
    $ExpectedPools = $Parameters.ExpectedPools
    $ExpectedEnclosures = $Parameters.ExpectedEnclosures
    $HoursOfEvents = $Parameters.HoursOfEvents

    Show-Update "Gathered with       : PrivateCloud.DiagnosticInfo v $($Parameters.Version)"
    Show-Update "Report created with : PrivateCloud.DiagnosticInfo v $((Get-Module PrivateCloud.DiagnosticInfo).Version.ToString())"

    #####
    ##### Phase 1 Summary
    #####

    Show-Update "<<< Phase 1 - Storage Health Overview >>>`n" -ForegroundColor Cyan

    Write-Host ("Date of capture : " + $TodayDate)
    $ClusterNodes = Import-Clixml (Join-Path $Path "GetClusterNode.XML")

    try
    {
        $Cluster = Import-Clixml (Join-Path $Path "GetCluster.XML")
    
        $ClusterName = $Cluster.Name + "." + $Cluster.Domain
        $S2DEnabled = $Cluster.S2DEnabled
        $ClusterDomain = $Cluster.Domain;

        Write-Host "Cluster Name                  : $ClusterName"
        Write-Host "S2D Enabled                   : $S2DEnabled"
    }
    catch 
    {
        Write-Host "Cluster Name                  : Cluster was unavailable"
        Write-Host "S2D Enabled                   : Cluster was unavailable"
    }

    $ClusterGroups = Import-Clixml (Join-Path $Path "GetClusterGroup.XML")

    $ScaleOutServers = $ClusterGroups |? GroupType -like "ScaleOut*"
    if ($null -eq $ScaleOutServers) { 
        if ($S2DEnabled -ne $true) {
            Show-Warning "No Scale-Out File Server cluster roles found"
        }
    } else {
        $ScaleOutName = $ScaleOutServers[0].Name + "." + $ClusterDomain
        Write-Host "Scale-Out File Server Name : $ScaleOutName"
    }

    # Cluster node health

    $NodesTotal = NCount($ClusterNodes)
    $NodesHealthy = NCount($ClusterNodes |? {$_.State -like "Paused" -or $_.State -like "Up"})
    Write-Host "Cluster Nodes up              : $NodesHealthy / $NodesTotal"

    if ($NodesTotal -lt $ExpectedNodes) { Show-Warning "Fewer nodes than the $ExpectedNodes expected" }
    if ($NodesHealthy -lt $NodesTotal) { Show-Warning "Unhealthy nodes detected" }

    # Cluster network health

    $ClusterNetworks = Import-Clixml (Join-Path $Path "GetClusterNetwork.XML")

    $NetsTotal = NCount($ClusterNetworks)
    $NetsHealthy = NCount($ClusterNetworks |? {$_.State -like "Up"})
    Write-Host "Cluster Networks up           : $NetsHealthy / $NetsTotal"

    if ($NetsTotal -lt $ExpectedNetworks) { Show-Warning "Fewer cluster networks than the $ExpectedNetworks expected" }
    if ($NetsHealthy -lt $NetsTotal) { Show-Warning "Unhealthy cluster networks detected" }

    # Cluster resource health

    $ClusterResources = Import-Clixml (Join-Path $Path "GetClusterResource.XML")
    $ClusterResourceParameters = Import-Clixml (Join-Path $Path "GetClusterResourceParameters.XML")

    $ResTotal = NCount($ClusterResources)
    $ResHealthy = NCount($ClusterResources |? State -like "Online")
    Write-Host "Cluster Resources Online      : $ResHealthy / $ResTotal "
    if ($ResHealthy -lt $ResTotal) { Show-Warning "Unhealthy cluster resources detected" }

    if ($S2DEnabled) {
        $HealthProviders = $ClusterResourceParameters |? { $_.ClusterObject -like 'Health' -and $_.Name -eq 'Providers' }
        $HealthProviderCount = $HealthProviders.Value.Count
        if ($HealthProviderCount) {
            Write-Host "Health Resource               : $HealthProviderCount health providers registered"
        } else {
            Show-Warning "Health Resource providers not registered"
        }
    }

    # Cluster shared volume health

    $CSV = Import-Clixml (Join-Path $Path "GetClusterSharedVolume.XML")

    $CSVTotal = NCount($CSV)
    $CSVHealthy = NCount($CSV |? State -like "Online")
    Write-Host "Cluster Shared Volumes Online : $CSVHealthy / $CSVTotal"
    if ($CSVHealthy -lt $CSVTotal) { Show-Warning "Unhealthy cluster shared volumes detected" }

    # Storage subsystem health
    $Subsystem = Import-Clixml (Join-Path $Path "GetStorageSubsystem.XML")

    if ($Subsystem -eq $null) {
        Show-Warning "No clustered storage subsystem present"
    } elseif ($Subsystem.HealthStatus -notlike "Healthy") {
        Show-Warning "Clustered storage subsystem '$($Subsystem.FriendlyName)' is in health state $($Subsystem.HealthStatus)"
    } else {
        Write-Host "Clustered storage subsystem '$($Subsystem.FriendlyName)' is healthy"
    }

    # Verifier

    $VerifiedNodes = @()
    foreach ($node in $ClusterNodes.Name) {
        $f = Join-Path (Get-NodePath $Path $node) "verifier-query.txt"
        $o = @(gc $f)

        # single line 
        if (-not ($o.Count -eq 1 -and $o[0] -eq 'No drivers are currently verified.')) {
            $VerifiedNodes += $node
        }
    }
    
    if ($VerifiedNodes.Count -ne 0) {
        Show-Warning "The following $($VerifiedNodes.Count) node(s) have system verification (verifier.exe) active. This may carry significant performance cost.`nEnsure this is expected, for instance during Microsoft-directed triage."
        $VerifiedNodes |% { Write-Host "`t$_" }
    } else {
        Write-Host "No nodes currently under the system verifier."
    }
    
    # Storage jobs
    $StorageJobs = Import-Clixml (Join-Path $Path "GetStorageJob.XML")

    if ($StorageJobs -eq $null) {
        Write-Host "No storage jobs were present at the time of the gather"
    } else {
        Show-Warning "The following storage jobs were present; this includes ones executing along with those recently completed"
        $StorageJobs | ft -AutoSize
    }

    Write-Host "`nHealthy Components count: [SMBShare -> CSV -> VirtualDisk -> StoragePool -> PhysicalDisk -> StorageEnclosure]"

    # Scale-out share health
    $ShareStatus = Import-Clixml (Join-Path $Path "ShareStatus.XML")

    $ShTotal = NCount($ShareStatus)
    $ShHealthy = NCount($ShareStatus |? Health -like "Accessible")
    "SMB CA Shares Accessible      : $ShHealthy / $ShTotal"
    if ($ShHealthy -lt $ShTotal) { Show-Warning "Inaccessible CA shares detected" }
    
    # SMB Open Files

    $SmbOpenFiles = Import-Clixml (Join-Path $Path "GetSmbOpenFile.XML")

    $FileTotal = NCount( $SmbOpenFiles | Group-Object ClientComputerName)
    Write-Host "Users with Open Files         : $FileTotal"
    if ($FileTotal -eq 0) { Show-Warning "No users with open files" }

    # SMB witness

    $SmbWitness = Import-Clixml (Join-Path $Path "GetSmbWitness.XML")

    $WitTotal = NCount($SmbWitness |? State -eq RequestedNotifications | Group-Object ClientName)
    Write-Host "Users with a Witness          : $WitTotal"
    if ($FileTotal -ne 0 -and $WitTotal -eq 0) { Show-Warning "No users with a Witness" }

    # Volume status

    $Volumes = Import-Clixml (Join-Path $Path "GetVolume.XML")

    $VolsTotal = NCount($Volumes |? FileSystem -eq CSVFS )
    $VolsHealthy = NCount($Volumes  |? FileSystem -eq CSVFS |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) })
    Write-Host "Cluster Shared Volumes Healthy: $VolsHealthy / $VolsTotal "

    #
    # Deduplicated volume health - if the volume XML exists, it was present (may still be empty)
    #
    
    $DedupEnabled = $false

    if (Test-Path (Join-Path $Path "GetDedupVolume.XML")) {
        $DedupEnabled = $true

        $DedupVolumes = Import-Clixml (Join-Path $Path "GetDedupVolume.XML")
        $DedupTotal = NCount($DedupVolumes)
        $DedupHealthy = NCount($DedupVolumes |? LastOptimizationResult -eq 0)

        if ($DedupTotal) {
            Write-Host "Dedup Volumes Healthy         : $DedupHealthy / $DedupTotal "

            if ($DedupHealthy -lt $DedupTotal) { Show-Warning "Unhealthy Dedup volumes detected" }

        } else {

            $DedupHealthy = 0
        }

        if ($DedupTotal -lt $ExpectedDedupVolumes) { Show-Warning "Fewer Dedup volumes than the $ExpectedDedupVolumes expected" }
    }

    # Virtual disk health

    $VirtualDisks = Import-Clixml (Join-Path $Path "GetVirtualDisk.XML")

    $VDsTotal = NCount($VirtualDisks)
    $VDsHealthy = NCount($VirtualDisks |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Virtual Disks Healthy         : $VDsHealthy / $VDsTotal"

    if ($VDsHealthy -lt $VDsTotal) { Show-Warning "Unhealthy virtual disks detected" }

    # Storage pool health

    $StoragePools = Import-Clixml (Join-Path $Path "GetStoragePool.XML")

    $PoolsTotal = NCount($StoragePools)
    $PoolsHealthy = NCount($StoragePools |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Storage Pools Healthy         : $PoolsHealthy / $PoolsTotal "

    if ($PoolsTotal -lt $ExpectedPools) { Show-Warning "Fewer storage pools than the $ExpectedPools expected" }
    if ($PoolsHealthy -lt $PoolsTotal) { Show-Warning "Unhealthy storage pools detected" }

    # Physical disk health

    $PhysicalDisks = Import-Clixml (Join-Path $Path "GetPhysicalDisk.XML")
    $PhysicalDiskSNV = Import-Clixml (Join-Path $Path "GetPhysicalDiskSNV.XML")

    $PDsTotal = NCount($PhysicalDisks)
    $PDsHealthy = NCount($PhysicalDisks |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Physical Disks Healthy        : $PDsHealthy / $PDsTotal"

    if ($PDsTotal -lt $ExpectedPhysicalDisks) { Show-Warning "Fewer physical disks than the $ExpectedPhysicalDisks expected" }
    if ($PDsHealthy -lt $PDsTotal) { Show-Warning "$($PDsTotal - $PDsHealthy) unhealthy physical disks detected" }

    # Storage enclosure health

    $StorageEnclosures = Import-Clixml (Join-Path $Path "GetStorageEnclosure.XML")

    $EncsTotal = NCount($StorageEnclosures)
    $EncsHealthy = NCount($StorageEnclosures |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Storage Enclosures Healthy    : $EncsHealthy / $EncsTotal "

    if ($EncsTotal -lt $ExpectedEnclosures) { Show-Warning "Fewer storage enclosures than the $ExpectedEnclosures expected" }
    if ($EncsHealthy -lt $EncsTotal) { Show-Warning "Unhealthy storage enclosures detected" }

    # Reliability counters
    # Not currently evaluated in summary report, TBD

    if (-not (Test-Path (Join-Path $Path "GetReliabilityCounter.XML"))) {
        Write-Host "`nNOTE: storage device reliability counters not gathered for this capture.`nThis is default, avoiding a storage latency burst which`nmay occur at the device when returning these statistics.`nUse -IncludeReliabilityCounters to get this information, if required.`n"
    }

    #####
    ##### Phase 2 Unhealthy Detail
    #####

    #
    # Careful: export/import renders complex data type members into Deserialized.XXX objects which
    # take a second layer of indirection ($_.foo.value) to render.
    #

    Show-Update "<<< Phase 2 - Unhealthy Component Detail >>>`n" -ForegroundColor Cyan

    $Failed = $False

    if ($NodesTotal -ne $NodesHealthy) { 
        $Failed = $true
        Write-Host "Cluster Nodes:"
        $ClusterNodes |? State -ne "Up" | Format-Table -AutoSize 
    }

    if ($NetsTotal -ne $NetsHealthy) { 
        $Failed = $true
        Write-Host "Cluster Networks:"
        $ClusterNetworks |? State -ne "Up" | Format-Table -AutoSize 
    }

    if ($ResTotal -ne $ResHealthy) { 
        $Failed = $true
        Write-Host "Cluster Resources:"
        $ClusterResources |? State -notlike "Online" |
            Format-Table Name,
                @{ Label = 'State'; Expression = { $_.State.Value }},
                OwnerGroup,
                ResourceType
    }

    if ($CSVTotal -ne $CSVHealthy) { 
        $Failed = $true
        Write-Host "Cluster Shared Volumes:"
        $CSV |? State -ne "Online" | Format-Table -AutoSize 
    }

    if ($VolsTotal -ne $VolsHealthy) { 
        $Failed = $true
        Write-Host "Volumes:"
        $Volumes |? { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) }  | 
        Format-Table Path,HealthStatus  -AutoSize
    }

    if ($DedupEnabled -and $DedupTotal -ne $DedupHealthy) { 
        $Failed = $true
        Write-Host "Volumes:"
        $DedupVolumes |? LastOptimizationResult -eq 0 | 
        Format-Table Volume,Capacity,SavingsRate,LastOptimizationResultMessage -AutoSize
    }

    if ($VDsTotal -ne $VDsHealthy) { 
        $Failed = $true
        Write-Host "Virtual Disks:"
        $VirtualDisks |? { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName,HealthStatus,OperationalStatus,ResiliencySettingName,IsManualAttach  -AutoSize 
    }

    if ($PoolsTotal -ne $PoolsHealthy) { 
        $Failed = $true
        Write-Host "Storage Pools:"
        $StoragePools |? { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName,HealthStatus,OperationalStatus,IsReadOnly -AutoSize 
    }

    if ($PDsTotal -ne $PDsHealthy) { 
        $Failed = $true
        Write-Host "Physical Disks:"
        $PhysicalDisks |? { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName,EnclosureNumber,SlotNumber,HealthStatus,OperationalStatus,Usage -AutoSize
    }

    if ($EncsTotal -ne $EncsHealthy) { 
        $Failed = $true;
        Write-Host "Enclosures:"
        $StorageEnclosures |? { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table FriendlyName,HealthStatus,ElementTypesInError -AutoSize 
    }

    if ($ShTotal -ne $ShHealthy) { 
        $Failed = $true
        Write-Host "CA Shares:"
        $ShareStatus |? Health -notlike "Healthy" | Format-Table -AutoSize
    }

    if (-not $Failed) { 
        "No unhealthy components`n" 
    }

    #####
    ##### Phase 3 Devices/drivers information
    #####

    Show-Update "<<< Phase 3 - Firmware and drivers >>>`n" -ForegroundColor Cyan

    foreach ($node in $ClusterNodes.Name) {
        "`nCluster Node: $node"
        Import-Clixml (Join-Path (Get-NodePath $Path $node) "GetDrivers.XML") |? {
            ($_.DeviceCLass -eq 'SCSIADAPTER') -or ($_.DeviceCLass -eq 'NET') } |
            Group-Object DeviceName,DriverVersion |
            Sort Name |
            ft -AutoSize Count,
                @{ Expression = { $_.Group[0].DeviceName }; Label = "DeviceName" },
                @{ Expression = { $_.Group[0].DriverVersion }; Label = "DriverVersion" },
                @{ Expression = { $_.Group[0].DriverDate }; Label = "DriverDate" }
    }

    Write-Host "`nPhysical disks by Media Type, Model and Firmware Version" 
    $PhysicalDisks | Group-Object MediaType,Model,FirmwareVersion |
        ft -AutoSize Count,
            @{ Expression = { $_.Group[0].Model }; Label="Model" },
            @{ Expression = { $_.Group[0].FirmwareVersion }; Label="FirmwareVersion" },
            @{ Expression = { $_.Group[0].MediaType }; Label="MediaType" }

 
    Write-Host "Storage Enclosures by Model and Firmware Version"
    $StorageEnclosures | Group-Object Model,FirmwareVersion |
        ft -AutoSize Count,
            @{ Expression = { $_.Group[0].Model }; Label="Model" },
            @{ Expression = { $_.Group[0].FirmwareVersion }; Label="FirmwareVersion" }
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
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 

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

    # Extract ZIP if neccesary
    $Path = Check-ExtractZip $Path

    # Produce all reports?
    if ($Report.Count -eq 1 -and $Report[0] -eq [ReportType]::All) {
        $Report = [ReportType].GetEnumValues() |? { $_ -ne [ReportType]::All } | sort
    }

    foreach ($r in $Report) {

        Write-Output ("*"*80)
        Write-Output "Report: $r"

        $t0 = Get-Date

        switch ($r) {
            { $_ -eq [ReportType]::Summary } {
                Get-SummaryReport $Path -ReportLevel:$ReportLevel
            }
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
# SIG # Begin signature block
# MIIkAQYJKoZIhvcNAQcCoIIj8jCCI+4CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAmo8dnqd8Z88pT
# Z3UDYNBfhcpWlPRhW3Txk24yuxfdPqCCDYMwggYBMIID6aADAgECAhMzAAAAxOmJ
# +HqBUOn/AAAAAADEMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMTcwODExMjAyMDI0WhcNMTgwODExMjAyMDI0WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQCIirgkwwePmoB5FfwmYPxyiCz69KOXiJZGt6PLX4kvOjMuHpF4+nypH4IBtXrL
# GrwDykbrxZn3+wQd8oUK/yJuofJnPcUnGOUoH/UElEFj7OO6FYztE5o13jhwVG87
# 7K1FCTBJwb6PMJkMy3bJ93OVFnfRi7uUxwiFIO0eqDXxccLgdABLitLckevWeP6N
# +q1giD29uR+uYpe/xYSxkK7WryvTVPs12s1xkuYe/+xxa8t/CHZ04BBRSNTxAMhI
# TKMHNeVZDf18nMjmWuOF9daaDx+OpuSEF8HWyp8dAcf9SKcTkjOXIUgy+MIkogCy
# vlPKg24pW4HvOG6A87vsEwvrAgMBAAGjggGAMIIBfDAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUy9ZihM9gOer/Z8Jc0si7q7fDE5gw
# UgYDVR0RBEswSaRHMEUxDTALBgNVBAsTBE1PUFIxNDAyBgNVBAUTKzIzMDAxMitj
# ODA0YjVlYS00OWI0LTQyMzgtODM2Mi1kODUxZmEyMjU0ZmMwHwYDVR0jBBgwFoAU
# SG5k5VAF04KqFzc3IrVtqMp1ApUwVAYDVR0fBE0wSzBJoEegRYZDaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljQ29kU2lnUENBMjAxMV8yMDEx
# LTA3LTA4LmNybDBhBggrBgEFBQcBAQRVMFMwUQYIKwYBBQUHMAKGRWh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljQ29kU2lnUENBMjAxMV8y
# MDExLTA3LTA4LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQAG
# Fh/bV8JQyCNPolF41+34/c291cDx+RtW7VPIaUcF1cTL7OL8mVuVXxE4KMAFRRPg
# mnmIvGar27vrAlUjtz0jeEFtrvjxAFqUmYoczAmV0JocRDCppRbHukdb9Ss0i5+P
# WDfDThyvIsoQzdiCEKk18K4iyI8kpoGL3ycc5GYdiT4u/1cDTcFug6Ay67SzL1BW
# XQaxFYzIHWO3cwzj1nomDyqWRacygz6WPldJdyOJ/rEQx4rlCBVRxStaMVs5apao
# pIhrlihv8cSu6r1FF8xiToG1VBpHjpilbcBuJ8b4Jx/I7SCpC7HxzgualOJqnWmD
# oTbXbSD+hdX/w7iXNgn+PRTBmBSpwIbM74LBq1UkQxi1SIV4htD50p0/GdkUieeN
# n2gkiGg7qceATibnCCFMY/2ckxVNM7VWYE/XSrk4jv8u3bFfpENryXjPsbtrj4Ns
# h3Kq6qX7n90a1jn8ZMltPgjlfIOxrbyjunvPllakeljLEkdi0iHv/DzEMQv3Lz5k
# pTdvYFA/t0SQT6ALi75+WPbHZ4dh256YxMiMy29H4cAulO2x9rAwbexqSajplnbI
# vQjE/jv1rnM3BrJWzxnUu/WUyocc8oBqAU+2G4Fzs9NbIj86WBjfiO5nxEmnL9wl
# iz1e0Ow0RJEdvJEMdoI+78TYLaEEAo5I+e/dAs8DojCCB3owggVioAMCAQICCmEO
# kNIAAAAAAAMwDQYJKoZIhvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmlj
# YXRlIEF1dGhvcml0eSAyMDExMB4XDTExMDcwODIwNTkwOVoXDTI2MDcwODIxMDkw
# OVowfjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UE
# AxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBAKvw+nIQHC6t2G6qghBNNLrytlghn0IbKmvpWlCq
# uAY4GgRJun/DDB7dN2vGEtgL8DjCmQawyDnVARQxQtOJDXlkh36UYCRsr55JnOlo
# XtLfm1OyCizDr9mpK656Ca/XllnKYBoF6WZ26DJSJhIv56sIUM+zRLdd2MQuA3Wr
# aPPLbfM6XKEW9Ea64DhkrG5kNXimoGMPLdNAk/jj3gcN1Vx5pUkp5w2+oBN3vpQ9
# 7/vjK1oQH01WKKJ6cuASOrdJXtjt7UORg9l7snuGG9k+sYxd6IlPhBryoS9Z5JA7
# La4zWMW3Pv4y07MDPbGyr5I4ftKdgCz1TlaRITUlwzluZH9TupwPrRkjhMv0ugOG
# jfdf8NBSv4yUh7zAIXQlXxgotswnKDglmDlKNs98sZKuHCOnqWbsYR9q4ShJnV+I
# 4iVd0yFLPlLEtVc/JAPw0XpbL9Uj43BdD1FGd7P4AOG8rAKCX9vAFbO9G9RVS+c5
# oQ/pI0m8GLhEfEXkwcNyeuBy5yTfv0aZxe/CHFfbg43sTUkwp6uO3+xbn6/83bBm
# 4sGXgXvt1u1L50kppxMopqd9Z4DmimJ4X7IvhNdXnFy/dygo8e1twyiPLI9AN0/B
# 4YVEicQJTMXUpUMvdJX3bvh4IFgsE11glZo+TzOE2rCIF96eTvSWsLxGoGyY0uDW
# iIwLAgMBAAGjggHtMIIB6TAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUSG5k
# 5VAF04KqFzc3IrVtqMp1ApUwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYD
# VR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUci06AjGQQ7kU
# BU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBPoE2gS4ZJaHR0cDovL2NybC5taWNyb3Nv
# ZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0MjAxMV8yMDExXzAz
# XzIyLmNybDBeBggrBgEFBQcBAQRSMFAwTgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0MjAxMV8yMDExXzAz
# XzIyLmNydDCBnwYDVR0gBIGXMIGUMIGRBgkrBgEEAYI3LgMwgYMwPwYIKwYBBQUH
# AgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvZG9jcy9wcmltYXJ5
# Y3BzLmh0bTBABggrBgEFBQcCAjA0HjIgHQBMAGUAZwBhAGwAXwBwAG8AbABpAGMA
# eQBfAHMAdABhAHQAZQBtAGUAbgB0AC4gHTANBgkqhkiG9w0BAQsFAAOCAgEAZ/KG
# pZjgVHkaLtPYdGcimwuWEeFjkplCln3SeQyQwWVfLiw++MNy0W2D/r4/6ArKO79H
# qaPzadtjvyI1pZddZYSQfYtGUFXYDJJ80hpLHPM8QotS0LD9a+M+By4pm+Y9G6XU
# tR13lDni6WTJRD14eiPzE32mkHSDjfTLJgJGKsKKELukqQUMm+1o+mgulaAqPypr
# WEljHwlpblqYluSD9MCP80Yr3vw70L01724lruWvJ+3Q3fMOr5kol5hNDj0L8giJ
# 1h/DMhji8MUtzluetEk5CsYKwsatruWy2dsViFFFWDgycScaf7H0J/jeLDogaZiy
# WYlobm+nt3TDQAUGpgEqKD6CPxNNZgvAs0314Y9/HG8VfUWnduVAKmWjw11SYobD
# HWM2l4bf2vP48hahmifhzaWX0O5dY0HjWwechz4GdwbRBrF1HxS+YWG18NzGGwS+
# 30HHDiju3mUv7Jf2oVyW2ADWoUa9WfOXpQlLSBCZgB/QACnFsZulP0V3HjXG0qKi
# n3p6IvpIlR+r+0cjgPWe+L9rt0uX4ut1eBrs6jeZeRhL/9azI2h15q/6/IvrC4Dq
# aTuv/DDtBEyO3991bWORPdGdVk5Pv4BXIqF4ETIheu9BCrE/+6jMpF3BoYibV3FW
# TkhFwELJm3ZbCoBIa/15n8G9bW1qyVJzEw16UM0xghXUMIIV0AIBATCBlTB+MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNy
# b3NvZnQgQ29kZSBTaWduaW5nIFBDQSAyMDExAhMzAAAAxOmJ+HqBUOn/AAAAAADE
# MA0GCWCGSAFlAwQCAQUAoIHGMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwG
# CisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAWTWEQ
# OxCwaMlRVeEDeMKHFpirOC/DW4XhbAVPfRjUDTBaBgorBgEEAYI3AgEMMUwwSqAk
# gCIATQBpAGMAcgBvAHMAbwBmAHQAIABXAGkAbgBkAG8AdwBzoSKAIGh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS93aW5kb3dzMA0GCSqGSIb3DQEBAQUABIIBAC5B3J4f
# XPANXTZMKdzXKpmZwkLm6/z8N9p+mZWxQKNB0SfrsQbBDOWZoZFm0CIvTBfJc/sb
# IdPA3/XzfUvmhMYJIlqU1zvNm7giykj5EK9zoOGMk57kw0/ywqD+Kolk4V7OA6nn
# XqAJqUQ6irTy4TLc6ElipqmQP4v688qbgr4xf30pvkVg14yyxRBppR6bPUm/1ePb
# YDK/wlMu8Bl4SwP0c3Kb1VoitIr8X0f+V0lK0IY5ZLT5GUDBGAdhstji35GR1VQQ
# bm6roJSKIb2j+V4fFDfiqn0ZtFuhbTXTl1BkHIetqsG3aIYTVRojbVOJ/Yo5xxpw
# /3SSKBQmsHMDIy+hghNGMIITQgYKKwYBBAGCNwMDATGCEzIwghMuBgkqhkiG9w0B
# BwKgghMfMIITGwIBAzEPMA0GCWCGSAFlAwQCAQUAMIIBOwYLKoZIhvcNAQkQAQSg
# ggEqBIIBJjCCASICAQEGCisGAQQBhFkKAwEwMTANBglghkgBZQMEAgEFAAQgTwFf
# C6Rrh/x0i0nIcqvvbXUktQKceyW2xccQZOdVje8CBlsC+zCN5hgTMjAxODA1MjQy
# MDMzMTQuODM4WjAHAgEBgAIB9KCBt6SBtDCBsTELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEMMAoGA1UECxMDQU9DMSYwJAYDVQQLEx1UaGFsZXMg
# VFNTIEVTTjo3MERELTRCNUItNDU2ODElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZaCCDsswggZxMIIEWaADAgECAgphCYEqAAAAAAACMA0GCSqG
# SIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkg
# MjAxMDAeFw0xMDA3MDEyMTM2NTVaFw0yNTA3MDEyMTQ2NTVaMHwxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFBDQSAyMDEwMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
# AQEAqR0NvHcRijog7PwTl/X6f2mUa3RUENWlCgCChfvtfGhLLF/Fw+Vhwna3PmYr
# W/AVUycEMR9BGxqVHc4JE458YTBZsTBED/FgiIRUQwzXTbg4CLNC3ZOs1nMwVyaC
# o0UN0Or1R4HNvyRgMlhgRvJYR4YyhB50YWeRX4FUsc+TTJLBxKZd0WETbijGGvmG
# gLvfYfxGwScdJGcSchohiq9LZIlQYrFd/XcfPfBXday9ikJNQFHRD5wGPmd/9WbA
# A5ZEfu/QS/1u5ZrKsajyeioKMfDaTgaRtogINeh4HLDpmc085y9Euqf03GS9pAHB
# IAmTeM38vMDJRF1eFpwBBU8iTQIDAQABo4IB5jCCAeIwEAYJKwYBBAGCNxUBBAMC
# AQAwHQYDVR0OBBYEFNVjOlyKMZDzQ3t8RhvFM2hahW1VMBkGCSsGAQQBgjcUAgQM
# HgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1Ud
# IwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRPME0wS6BJoEeGRWh0
# dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0Nl
# ckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKG
# Pmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljUm9vQ2VyQXV0
# XzIwMTAtMDYtMjMuY3J0MIGgBgNVHSABAf8EgZUwgZIwgY8GCSsGAQQBgjcuAzCB
# gTA9BggrBgEFBQcCARYxaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL1BLSS9kb2Nz
# L0NQUy9kZWZhdWx0Lmh0bTBABggrBgEFBQcCAjA0HjIgHQBMAGUAZwBhAGwAXwBQ
# AG8AbABpAGMAeQBfAFMAdABhAHQAZQBtAGUAbgB0AC4gHTANBgkqhkiG9w0BAQsF
# AAOCAgEAB+aIUQ3ixuCYP4FxAz2do6Ehb7Prpsz1Mb7PBeKp/vpXbRkws8LFZslq
# 3/Xn8Hi9x6ieJeP5vO1rVFcIK1GCRBL7uVOMzPRgEop2zEBAQZvcXBf/XPleFzWY
# JFZLdO9CEMivv3/Gf/I3fVo/HPKZeUqRUgCvOA8X9S95gWXZqbVr5MfO9sp6AG9L
# MEQkIjzP7QOllo9ZKby2/QThcJ8ySif9Va8v/rbljjO7Yl+a21dA6fHOmWaQjP9q
# Yn/dxUoLkSbiOewZSnFjnXshbcOco6I8+n99lmqQeKZt0uGc+R38ONiU9MalCpaG
# pL2eGq4EQoO4tYCbIjggtSXlZOz39L9+Y1klD3ouOVd2onGqBooPiRa6YacRy5rY
# DkeagMXQzafQ732D8OE7cQnfXXSYIghh2rBQHm+98eEA3+cxB6STOvdlR3jo+KhI
# q/fecn5ha293qYHLpwmsObvsxsvYgrRyzR30uIUBHoD7G4kqVDmyW9rIDVWZeodz
# OwjmmC3qjeAzLhIp9cAvVCch98isTtoouLGp25ayp0Kiyc8ZQU3ghvkqmqMRZjDT
# u3QyS99je/WZii8bxyGvWbWu3EQ8l1Bx16HSxVXjad5XwdHeMMD9zOZN+w2/XU/p
# nR4ZOC+8z1gFLu8NoFA12u8JJxzVs341Hgi62jbb01+P3nSISRIwggTYMIIDwKAD
# AgECAhMzAAAAt/giFH0DIv76AAAAAAC3MA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTE3MTAwMjIzMDA1MloXDTE5MDEwMjIz
# MDA1MlowgbExCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xDDAK
# BgNVBAsTA0FPQzEmMCQGA1UECxMdVGhhbGVzIFRTUyBFU046NzBERC00QjVCLTQ1
# NjgxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC0hXZnLn7NAl1QCxJ8ZBM3LvZXoNoT
# NaHigy1WSNDcr8jKPsVrrb5krZElwM+di1G43efi5k3O2ESPG18E+nrdaMJrnOof
# +fCwXRLiF4XdTOXQI2gztw9EwVlYndf0dzdJZ4771xtmJJjBNA2GkAE7mJQPXAt+
# SULHh8fIHrwP3xVwT8Ly4NNwJWqzln11U3Jm1NSsUM68ZdCqhxBuRH0E4rMvmcDw
# xjnanzik7zq71oQ2eIu4HF/Cpv/he7RG2RKZ2uBwkom8YBEdiuUBoEubkXJSBzRL
# 0QZRbLWaYDs9fYMzVV59kjNYkS83ffjOOms77ZsjDxAnajpcvuba2J47AgMBAAGj
# ggEbMIIBFzAdBgNVHQ4EFgQUbWKvg3tEhnVxd9JNW4/uRC5gNWkwHwYDVR0jBBgw
# FoAU1WM6XIoxkPNDe3xGG8UzaFqFbVUwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDov
# L2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljVGltU3RhUENB
# XzIwMTAtMDctMDEuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0
# cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAx
# MC0wNy0wMS5jcnQwDAYDVR0TAQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDCDAN
# BgkqhkiG9w0BAQsFAAOCAQEAaaSp0uuxop+K5nske7Qn7t56ojZWiDVVHIfZvNv7
# ARlMxECedM+O/zhwRwjhD/jfPHwwWsgg7052h1JaKDxnB6rxIWJkNvU3+Uobspja
# SDaZFdRUpTTW3EDpzWhGs/+SIamgg+UUZC+JVYF5mMAd7b6YdMxUA+YAd823NNHe
# wpUlEb3ok6QlafT9JZeOqu9TTzCOcL+p2WeOZ097deqx9beMd46h9KUypgf28Ppj
# dSOcgWZRmviWVu6b4v445460NOIDGQDwBhoYOu1XMT/KxjnRP3ry5Tq++s4RI0Qe
# gwpxKJ6jpYGQ/XaNhjhkch2wrLWC84eIjOqrU4KV2OH4aaGCA3YwggJeAgEBMIHh
# oYG3pIG0MIGxMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMQww
# CgYDVQQLEwNBT0MxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjcwREQtNEI1Qi00
# NTY4MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiUKAQEw
# CQYFKw4DAhoFAAMVANXj0P5ZNuTCZFlJB+nXIozHReoNoIHBMIG+pIG7MIG4MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMQwwCgYDVQQLEwNBT0Mx
# JzAlBgNVBAsTHm5DaXBoZXIgTlRTIEVTTjoyNjY1LTRDM0YtQzVERTErMCkGA1UE
# AxMiTWljcm9zb2Z0IFRpbWUgU291cmNlIE1hc3RlciBDbG9jazANBgkqhkiG9w0B
# AQUFAAIFAN6xGp0wIhgPMjAxODA1MjQxMTAzNTdaGA8yMDE4MDUyNTExMDM1N1ow
# dzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA3rEanQIBADAKAgEAAgICeAIB/zAHAgEA
# AgIWEjAKAgUA3rJsHQIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMB
# oAowCAIBAAIDFuNgoQowCAIBAAIDHoSAMA0GCSqGSIb3DQEBBQUAA4IBAQAY5N3m
# NnBC3h+HzySA1oOCdhbKJP/c70f0ffxYyJ2YRaOS6ohi4gTyiV9ixE7W3BHHeMpN
# d5hWCkhQpT4GuE+Lgh/aNOwFwecI2P6JDk2HVnbQmYwP3QDAWKy9G5YtgzjUWbT0
# hWhGXmcRYTsPx+GOgjBuJjZPZjL+v9seoVJkv6Xuz82hIw49+B5pwLHJhV89m5Rv
# Pt8Y6vvg/JukmTdZjV+E/Hxz+aknj1UKCKg9CtGR2inn6UtLTXTR5KPVCJC5zPuq
# MJiVyag0sLo1lzfLSnw1lWLRZK0CntBqERUKllywKVwW01jNWWjGCQDevolSZO2m
# bdlU5UG6FHAMULwtMYIC9TCCAvECAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNV
# BAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# UENBIDIwMTACEzMAAAC3+CIUfQMi/voAAAAAALcwDQYJYIZIAWUDBAIBBQCgggEy
# MBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgpwL3
# 0vAoBPjDH6EOOzknIlO9CBzZb8wolVTjW3Hu/kMwgeIGCyqGSIb3DQEJEAIMMYHS
# MIHPMIHMMIGxBBTV49D+WTbkwmRZSQfp1yKMx0XqDTCBmDCBgKR+MHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAAt/giFH0DIv76AAAAAAC3MBYEFEt9
# dnJ92sjBLqqBgKx2kxgspv+SMA0GCSqGSIb3DQEBCwUABIIBAFm1fC/n4uYgUjQF
# H6w51iEdWAlGCRBYqz8ubdlfifLenwKjeYAWrwSf/ydnfDomS6fUcNSgkZ4fUBpE
# T1TCGeKx1C6gBADZYmXBs25z0yOSVAieeDOqS5SX9K3lSapy/8uT51dmHvnWjo3o
# fNlxy3OVwjijfrg5GxXHzU7U+rLSrcS3giC+qYkuI+xxnPjcKoIHgNnU0MiXeesV
# NBSmdZ9kDR8bzwQJx047/82YKxKiQeWwPuFk+QsjzOZTaDYMjCeDCI7Ef4pSSGKB
# DLkZt9oj6AtG7lXUanb2PDEKD4BC6zwWzYeJieX9rrS4r6fg3+kthflqyTdJPIoo
# IqY0lRY=
# SIG # End signature block
