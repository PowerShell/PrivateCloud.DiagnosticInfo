<###################################################
 #                                                 #
 #  Copyright (c) Microsoft. All rights reserved.  #
 #                                                 #
 ##################################################>

$Module = 'PrivateCloud.DiagnosticInfo'

<############################################################
#  Common helper functions/modules for main/child sessions  #
############################################################>

$CommonFuncBlock = {

    # FailoverClusters is Server-only. We allow the module to run (Show) on client.
    #
    # Handling of import failures in Start-Job initialization blocks is special - we
    # cannot control failure to load errors there, and need to use GM to check; neither
    # -ErrorAction nor try/catch control propagation of the errors.

    if (Get-Module -ListAvailable FailoverClusters) {
        Import-Module FailoverClusters
    }

    Import-Module CimCmdlets
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

    function Get-SddcCapturedEvents (
        [string] $Path,
        [int] $Hours
    )
    {
        # Calculate number of milliseconds and prepare the WEvtUtil parameter to filter based on date/time
        $QTime = $null
        if ($Hours -ne -1) {
            $MSecs = $Hours * 60 * 60 * 1000
            $QTime = "*[System[TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"
        }

        # Log prefixes to gather. Note that this is a simple pattern match; for instance, there are a number of
        # different providers that match *Microsoft-Windows-Storage*: Storage, StorageManagement, StorageSpaces, etc.
        # NOTE: please keep this list sorted to avoid accidental dups.
        $LogPatterns = 'Microsoft-Windows-ClusterAwareUpdating',
                        'Microsoft-Windows-DataIntegrityScan',
                        'Microsoft-Windows-FailoverClustering',
                        'Microsoft-Windows-HostGuardian',
                        'Microsoft-Windows-Hyper-V',
                        'Microsoft-Windows-Kernel',
                        'Microsoft-Windows-NDIS',
                        'Microsoft-Windows-Network',
                        'Microsoft-Windows-NTFS',
                        'Microsoft-Windows-REFS',
                        'Microsoft-Windows-ResumeKeyFilter',
                        'Microsoft-Windows-SMB',
                        'Microsoft-Windows-Storage',
                        'Microsoft-Windows-TCPIP',
                        'Microsoft-Windows-VHDMP',
                        'Microsoft-Windows-WMI-Activity' |% { "$_*" }

        # Exclude verbose/lower value channels
        # The FailoverClustering Diagnostics are reflected in the cluster logs, already gathered (and large)
        # StorageSpaces Performance is very expensive to export and not usually needed
        $LogToExclude = 'Microsoft-Windows-FailoverClustering/Diagnostic',
                        'Microsoft-Windows-FailoverClustering/DiagnosticVerbose',
                        'Microsoft-Windows-FailoverClustering-Client/Diagnostic',
                        'Microsoft-Windows-StorageSpaces-Driver/Performance'

        # Core logs to gather, by explicit names.
        $LogPatterns += 'System','Application'

        Get-WinEvent -ListLog $LogPatterns -Force -ErrorAction Ignore -WarningAction Ignore |? { $LogToExclude -notcontains $_.LogName } |% {

            $EventFile = Join-Path $Path ($_.LogName.Replace("/","-")+".EVTX")

            # analytical/debug channels can not be captured live
            # if any are encountered (not normal), disable them temporarily for export
            $directChannel = $false
            if ($_.LogType -in @('Analytical','Debug') -and $_.IsEnabled) {
                $directChannel = $true
                wevtutil sl /e:false $_.LogName
            }

            # Export log file using, filtered to given history limit if specified
            if ($QTime) {
                wevtutil epl $_.LogName $EventFile /q:$QTime /ow:true
            } else {
                wevtutil epl $_.LogName $EventFile /ow:true
            }

            if ($directChannel -eq $true) {
                echo y | wevtutil sl /e:true $_.LogName | out-null
            }

            # Create locale metadata for off-system rendering
            wevtutil al $EventFile /l:$PSCulture

            # Emit filename for capture
            Write-Output $EventFile
        }
    }

    # wrapper for common date format for file naming
    function Format-SddcDateTime(
        [datetime] $d
        )
    {
        $d.ToString('yyyyMMdd-HHmm')
    }

    # helper for testing/emitting feedback on module presence
    # use this on icm to remote nodes
    # this will be obsolete if/when we can integrate with add-node
    function Test-SddcModulePresence
    {
        # note that we can't pull from the global
        $Module = 'PrivateCloud.DiagnosticInfo'
        $m = Get-Module $Module

        if (-not $m) {
            Write-Warning "Node $($env:COMPUTERNAME) does not have the $Module module installed for Sddc Diagnostic Archive. Please 'Install-SddcDiagnosticModule -Node $($env:COMPUTERNAME)' to address."
            $false
        } else {
            $true
        }
    }

    # function for constructing filter xpath queries for event channels
    # event: list of event ids
    # timebase: time base for timedelta query (default: current system time)
    # timedeltams: time in ms relatve to base to filter event timestamps to (older than base)
    # data: table of k=v the event(s) must match
    #
    # events are OR'd
    # time is AND'd
    # dataand is AND'd
    # dataor is dataand AND dataor OR'd (e.g. (a and b and c) and (d or e or f)
    function Get-FilterXpath
    {
        [CmdletBinding(PositionalBinding=$false)]
        param (
            [int[]] $Event = @(),

            [datetime] $TimeBase,

            [ValidateScript({$_ -gt 0})]
            [int] $TimeDeltaMs = -1,

            [hashtable] $DataAnd = @{},
            [hashtable] $DataOr = @{}
            )

        # first build out the system property clauses
        $systemclauses = @()

        # build the event id clause
        if ($Event.Count) {
            $c = $Event |% { "EventID = $_" }
            # bracket eventids iff there are multiple
            if ($Event.Count -gt 1) {
                $systemclauses += "(" + ($c -join " or ") + ")"
            } else {
                $systemclauses += $c
            }
        }

        # build the time delta clause
        # based - two argument, relative to $TimeBase
        # unbase - one argument, relative to instantaneous system time
        if ($TimeDeltaMs -gt 0) {
            if ($TimeBase) {
                $t = $TimeBase.ToUniversalTime().ToString('s')
                $systemclauses += "(TimeCreated[timediff(@SystemTime,'$($t)') <= $($TimeDeltaMs)])"
            } else {
                $systemclauses += "(TimeCreated[timediff(@SystemTime) <= $($TimeDeltaMs)])"
            }
        }

        # system property clauses and together
        $systemclause = "System[" + ($systemclauses -join " and ") + "]"

        # now build data clauses
        $cAnd = @($DataAnd.Keys | sort |% {
            "Data[@Name = '" + $_ + "'] " + $DataAnd[$_]
        }) -join " and "

        $cOr = @($DataOr.Keys | sort |% {
            "Data[@Name = '" + $_ + "'] " + $DataOr[$_]
        }) -join " or "

        # both and'd, one or the other, or neither
        if ($cAnd.Length -and $cOr.Length) {
            $dataclause = "EventData[$cAnd and ($cOr)]"
        } elseif ($cAnd.Length -or $cOr.Length) {
            $dataclause = "EventData[$($cAnd + $cOr)]"
        } else {
            $dataclause = $null
        }

        # and join system+data with and
        if ($dataclause) {
            $xpath = "*[$systemclause and $dataclause]"
        } else {
            $xpath = "*[$systemclause]"
        }

        $xpath
    }

    # Makes a custom object out of an input stream of colon seperated k/v data
    # ex:
    #    creationTime: 2018-06-25T20:07:47.030Z
    #    lastAccessTime: 2018-06-25T20:07:47.030Z
    #    lastWriteTime: 2018-06-25T19:53:58.000Z
    #    fileSize: 1118208
    #    attributes: 32
    #    numberOfLogRecords: 523
    #    oldestRecordNumber: 1
    #
    # -> object with named members. Any member name ending in Time is pre-cast to [datetime].
    function Parse-SemicolonKVData
    {
        BEGIN { $o = new-object psobject }
        PROCESS {
            # split at the first semi
            $null = $_ -match '^([^:]+)\s*:\s*(.*)$'
            $k = $matches[1]
            $v = $matches[2]
            if ($k -like '*time') {
                $o | Add-Member -NotePropertyName $matches[1] -NotePropertyValue ([datetime]$matches[2])
            } else {
                $o | Add-Member -NotePropertyName $matches[1] -NotePropertyValue $matches[2]
            }

        }
        END { $o }
    }

    # count the number of events in a given event log which match a given xpath query
    #
    # powershell's event pipeline is very slow for bulk counting when there may be many
    # events (or simply many event channels that our caller needs to sift through)
    # use wevtutil queries to a temporary file and then count it using its gli facility
    function Count-EventLog
    {
        param(
            [string] $path,
            [string] $xpath
            )

        $f = New-TemporaryFile

        try {

            wevtutil epl /lf:true $path $f /q:$xpath /ow:true
            $gli = wevtutil gli /lf:true $f | Parse-SemicolonKVData
            $gli.numberOfLogRecords

        } finally {
            del -Force $f
        }
    }

    function Get-EventDataHash
    {

        param(
            [System.Diagnostics.Eventing.Reader.EventLogRecord] $event
        )

        # must cast through the XML representation of the event to get named properties
        # insert text into hash and return
        $xh = @{}
        $x = ([xml]$event.ToXml()).Event.EventData.Data
        $x |% {
            $xh[$_.Name] = $_.'#text'
        }
        $xh
    }
}

# do a basic compression on the common function block, removing
#    comment-only lines
#    whitespace-only lines
#    leading whitespace
# this is observed to reduce it by about 50% in character count
# the string transform of the block is used in session passing (job -InitializationScript) and
# cannot exceed about 14KiB in size
$CommonFunc = [scriptblock]::Create($(
    ((([string]$CommonFuncBlock) -split "`n") |? { $_ -notmatch '^\s*#' } |? { $_ -notmatch '^\s*$' }) -replace '^\s+','' -join "`n"
))

# evaluate into the main session
# without a direct assist like start-job -initialization script, passing into
# other contexts converts to string, which we must undo with [scriptblock]::Create()
. $CommonFunc

<####################################################
#  Common helper functions for main session only    #
####################################################>

#
# This tests whether a path is a valid prefix name for a new file (e.g., $path + .ZIP)
#

function Test-PrefixFilePath(
    $path
    )
{
    $elements = @($path -split '\\')

    # we need to tear off the last element and test the parent. before doing that,
    # need to check that we have enough path to use in the first place.
    # also check to see if we have simple cases of a usable single name

    # the last split element cannot be empty (e.g., bad: some\path\, good: some\path)
    # a single element is OK as long as it isn't a driveletter (e.g., bad: C:, good: foo)
    # unc is OK as long as we see at least 5 post-split elements (e.g., bad: \\foo, \\foo\bar, good: \\foo\bar\baz)

    $lastempty = $elements[-1] -notmatch '\S'
    $islocabs = $elements[0][1] -eq ':'
    $isunc = $path -like '\\*'

    if ($lastempty -or
        ($islocabs -and $elements.Count -eq 1) -or
        ($isunc -and $elements.Count -lt 5)) {
        return $false
    }

    # simple single names: relative path "foo" or "\foo"
    if ($elements.Count -eq 1 -or
        ($elements.Count -eq 2 -and
         $elements[0].Length -eq 0)) {
        return $true
    }

    # rejoin without the tail and test
    $p = $elements[0..($elements.Count-2)] -join '\'

    Test-Path $p
}

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

#
# Utility wrapper for copyout jobs which allows seperating ones which
# delete temporary/gathered content and ones which gather persistent
# content (like archive logs)
#

function Start-CopyJob(
    [string] $Path,
    [switch] $Delete,
    [object[]] $j
    )
{
    $j |% {

        $parent = $_
        $parent.ChildJobs |% {

            $logs = Receive-Job $_

            # avoid the job if not needed, no content
            if (@($logs).Count) {

                # create/use a specific job destination if present
                # ex: "foo" -> \node_xxx\foo\<rest> v. the default \node_xxx\<rest>
                $Destination = (Get-NodePath $Path $_.Location)
                if (Get-Member -InputObject $_ -Name Destination) {
                    $Destination = Join-Path $Destination $_.Destination
                    if (-not (Test-Path $Destination)) {
                        $null = md $Destination -Force -ErrorAction Continue
                    }
                }

                start-job -Name "Copy $($parent.Name) $($_.Location)" -InitializationScript $CommonFunc {

                    $using:logs |% {
                        # allow errors to propagte for triage
                        Copy-Item -Recurse $_ $using:Destination -Force -ErrorAction Continue
                        if ($using:Delete) {
                            Remove-Item -Recurse $_ -Force -ErrorAction Continue
                        }
                    }
                }
            }
        }
    }
}

#
# Makes a list of cluster nodes or equivalent property-containing objects (Name/State)
# Optionally filtered for if they are physically responding v. cluster visible state.
#	

function Get-NodeList(
    [string] $Cluster,
    [string[]] $Nodes = @(),
    [switch] $Filter
)
{
    $FilteredNodes = @()
    $NodesToPing = @()
            
    if ($Nodes.Count) {
        $NodesToPing += $Nodes |% { New-Object -TypeName PSObject -Property @{ "Name" = $_; "State" = "Up" }}
    } else {

        foreach ($node in (Get-ClusterNode -Cluster $Cluster)) {

            if ($node.State -ne "Down") {
                $FilteredNodes += $node
            } else {
                $NodesToPing += $node
            }
        }
    }

    if ($Filter) {

        if ($NodesToPing.Count) {

            # Test-NetConnection is ~3s. Parallelize for the sake of larger clusters/lists of nodes.
            $j = $NodesToPing |% {

                Start-Job -ArgumentList $_ {
                    param( $Node )
                    if (Test-Connection -ComputerName $Node.Name -Quiet) {
                        $Node
                    }
                }
            }

            $null = Wait-Job $j
            $FilteredNodes += $j | Receive-Job 
            $j | Remove-Job
        }
    } else {

        # unfiltered, return all
        $FilteredNodes += $NodesToPing
    }

    return $FilteredNodes
}

<##################################################
#  End Helper functions                           #
##################################################>

<# 
.SYNOPSIS 
    Get state and diagnostic information for all Software-Defined DataCenter (SDDC) features in a Windows Server 2016 cluster.

.DESCRIPTION 
    Get state and diagnostic information for all Software-Defined DataCenter (SDDC) features in a Windows Server 2016 cluster.
    Run from one of the nodes of the cluster or specify a cluster name, or specify a set of nodes directly. Results are saved
    to a ZIP archive for later review and analysis.

.LINK 
    To provide feedback and contribute visit https://github.com/PowerShell/PrivateCloud.Health

.EXAMPLE 
    Get-SddcDiagnosticInfo
 
    Targets the cluster the local computer is a member of.
    Uses the default temporary working folder at $env:USERPROFILE\HealthTest
    Saves the zipped results at $env:USERPROFILE\HealthTest-<cluster>-<date>.ZIP

.EXAMPLE 
    Get-SddcDiagnosticInfo -WriteToPath C:\Test
 
    Uses the specified folder as the temporary working folder. This does not change the location of
    the zipped results.

.EXAMPLE 
    Get-SddcDiagnosticInfo -ClusterName Cluster1
 
    Targets the specified cluster, Cluster1.

.EXAMPLE 
    Get-SddcDiagnosticInfo -ReadFromPath C:\Test.ZIP
 
    Display the summary health report from the capture located in the given ZIP. The content is
    unzipped to a directory (minus the .ZIP extension) and remains after the summary health report
    is shown.

    In this example, C:\Test would be created from C:\Test.ZIP. If the .ZIP path is specified and
    the unzipped directory is present, the directory will be reused without re-unzipping the
    content.

    EQUIVALENT: Show-SddcDiagnosticReport -Report Summary -Path <ZIP or Directory>

    The file 0_CloudHealthSummary.log in the capture contains the summary report at the time the
    capture was taken. Running the report again is a re-analysis of the content, which may reflect
    new triage if PrivateCloud.DiagnosticInfo has been updated in the interim.

.EXAMPLE
    Get-SddcDiagnosticInfo -ReadFromPath C:\Test

    Display the summary health report from the capture located in the given directory, which should
    be an unzipped capture.

.PARAMETER ReadFromPath
Path to read content from for summary health report generation.

.PARAMETER TemporaryPath
Temporary path to stage capture content to, prior to ZIP creation.

.PARAMETER ClusterName
Cluster to capture content from.

.PARAMETER Nodelist
List of nodes to capture content from.

.PARAMETER HoursOfEvents
For sources which support it, limit log and event data to the prior number of hours. By default
all available data is captured (-1).

.PARAMETER DaysOfArchive
Limit the number of days of Sddc Diagnostic Archive captured. Only applicable if Sddc Diagnostic
Archive is active in the target cluster. By default 8 days are captured.

Specify -1 to capture the complete archive - NOTE: this may be very large.
Specify 0 to disable capture of the archive.

.PARAMETER ZipPrefix
Path for the resulting ZIP file: -<cluster>-<timestamp>.ZIP will be appended.

.PARAMETER MonitoringMode
Run in a limited monitoring mode (deprecated)

.PARAMETER ExpectedNodes
Specify the expected number of nodes. A summary warning will be issued if a different number is
present.

.PARAMETER ExpectedNetworks
Specify the expected number of networks. A summary warning will be issued if a different number is
present.

.PARAMETER ExpectedVolumes
Specify the expected number of volumes. A summary warning will be issued if a different number is
present.

.PARAMETER ExpectedDedupVolumes
Specify the expected number of dedeuplicated volumes. A summary warning will be issued if a
different number is present.

.PARAMETER ExpectedPhysicalDisks
Specify the expected number of physical disks. A summary warning will be issued if a different
number is present.

.PARAMETER ExpectedPools
Specify the expected number of storage pools. A summary warning will be issued if a different
number is present.

.PARAMETER ExpectedEnclosures
Specify the expected number of storage enclosures. A summary warning will be issued if a different
number is present.

.PARAMETER ProcessCounter
Process the performance counters into a summary report (deprecated)

.PARAMETER PerfSamples
Specify the number of performance counter samples to capture (in seconds, 1/s).

.PARAMETER IncludeAssociations
Include additional object association information (deprecated)

.PARAMETER IncludeDumps
Include minidumps and live kernel report dumps.

.PARAMETER IncludeGetNetView
Include content from the Get-NetView (NetDiagnosticInfo module) command, if present.

.PARAMETER IncludeHealthReport
Include an additional health report (deprecated)

.PARAMETER IncludeLiveDump
Include a live dump of the target systems (not valid in S2D clusters)

.PARAMETER IncludePerformance
Include a performance counter capture.

.PARAMETER IncludeReliabilityCounters
Include Storage Reliability counters. This may incur a short but observable latency cost on the
physical disks due to varying overhead in their internal handling of SMART queries.

#> 

function Get-SddcDiagnosticInfo
{
    # aliases usage in this module is idiomatic, only using defaults
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")] 

    #
    # Parameter sets:
    #    Read - backcompat alias for Show Summary report
    #    Write(C|N) - capture with -Cluster or -Nodelist
    #    M - monitoring mode
    #

    [CmdletBinding(DefaultParameterSetName="WriteC")]
    [OutputType([String])]

    param(
        [parameter(ParameterSetName="WriteC", Position=0, Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Position=0, Mandatory=$false)]
        [alias("WriteToPath")]
        [ValidateNotNullOrEmpty()]
        [string] $TemporaryPath = $($env:userprofile + "\HealthTest\"),

        [parameter(ParameterSetName="M", Position=1, Mandatory=$false)]
        [parameter(ParameterSetName="WriteC", Position=1, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $ClusterName = ".",
        
        [parameter(ParameterSetName="WriteN", Position=1, Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Nodelist = @(),

        [parameter(ParameterSetName="Read", Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ReadFromPath = "",
        
        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [switch] $IncludePerformance = $true,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,3600)]
        [int] $PerfSamples = 10,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $ProcessCounter,
        
        [parameter(ParameterSetName="M", Mandatory=$true)]
        [switch] $MonitoringMode,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [int] $HoursOfEvents = -1,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(-1,365)]
        [int] $DaysOfArchive = 8,

        [parameter(ParameterSetName="WriteC", Position=2, Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Position=2, Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $ZipPrefix = $($env:userprofile + "\HealthTest"),

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,1000)]
        [int] $ExpectedNodes,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,1000)]
        [int] $ExpectedNetworks,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(0,1000)]
        [int] $ExpectedVolumes,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(0,1000)]
        [int] $ExpectedDedupVolumes,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,10000)]
        [int] $ExpectedPhysicalDisks,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,1000)]
        [int] $ExpectedPools,
    
        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,10000)]
        [int] $ExpectedEnclosures,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeAssociations,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeDumps,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeGetNetView,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeHealthReport,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeLiveDump,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeReliabilityCounters
        )

    #
    # Set strict mode to check typos on variable and property names
    #

    Set-StrictMode -Version Latest

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

        $NodeList = Get-NodeList -Cluster $ClusterName -Filter
        
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
    # Verify zip location
    #

    if (-not (Test-PrefixFilePath $ZipPrefix)) {
        Write-Error "$ZipPrefix is not a valid prefix for ZIP: $ZipPrefix.ZIP must be creatable"
        return
    }

    #
    # Veriyfing path
    #

    if ($ReadFromPath -ne "") {
        $Path = $ReadFromPath
        $Read = $true
    } else {
        $Path = $TemporaryPath
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

    Show-Update "Temporary write path : $Path"

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
    $Parameters.Version = (Get-Module $Module).Version.ToString()
    $Parameters | Export-Clixml ($Path + "GetParameters.XML")

    Show-Update "$Module v $($Parameters.Version)"

    #
    # Phase 1
    #

    Show-Update "<<< Phase 1 - Data Gather >>>`n" -ForegroundColor Cyan

    #
    # Cluster Nodes
    # Note: get unfiltered list for reporting, then filter for continued use during gather
    # (i.e., only contact responsive nodes)
    #

    try { $ClusterNodes = Get-NodeList -Cluster $ClusterName -Nodes $Nodelist }
    catch { Show-Error "Unable to get Cluster Nodes for reporting" $_ }
    $ClusterNodes | Export-Clixml ($Path + "GetClusterNode.XML")

    try { $ClusterNodes = Get-NodeList -Cluster $ClusterName -Nodes $Nodelist -Filter }
    catch { Show-Error "Unable to get filtered Cluster Nodes for gathering" $_ }

    # use a filtered node as the access node
    $AccessNode = $ClusterNodes[0].Name

    #
    # Get-Cluster
    #

    try { 
        # discover name if called with default dot form and/or node list
        if ($ClusterName -eq ".") {
            foreach ($cn in $ClusterNodes)
            {
                $Cluster = Get-Cluster -Name $cn.Name -ErrorAction SilentlyContinue
                if ($Cluster -ne $null) { break }
            }
        } else {
            $Cluster = Get-Cluster -Name $ClusterName
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
    # Begin paralellized captures.
    # Start accumulating static jobs which self-contain their gather.
    # These are pulled in close to the end. Consider how to regularize this down the line.
    ####
    $JobStatic = @()
    $JobCopyOut = @()
    $JobCopyOutNoDelete = @()

    # capture Sddc Diagnostic Archive if requested and active on the target cluster
    if ($Cluster -and
        (Get-ClusteredScheduledTask -Cluster $Cluster -TaskName SddcDiagnosticArchive)) {

        if ($DaysOfArchive -gt 0) {

            Show-Update "Start gather of Sddc Diagnostic Archives ..."

            $JobStatic += Start-Job -Name 'Sddc Diagnostic Archive Report' {

                Import-Module $using:Module -ErrorAction SilentlyContinue

                # capture state of the job regardless of archive capture
                $o = (Join-Path $using:Path SddcDiagnosticArchiveJob.txt)
                Show-SddcDiagnosticArchiveJob -Cluster $using:Cluster > $o

                # use confirm to capture the version validation warnings for replay - note that
                # we self-document the version producing the report, so we only need to look for/capture
                # warnings to highlight variance
                $o = (Join-Path $using:Path SddcDiagnosticArchiveJobWarn.txt)
                $null = Confirm-SddcDiagnosticModule -Cluster $using:Cluster 3> $o
            }

            $j = icm $ClusterNodes.Name -AsJob -JobName SddcDiagnosticArchive {

                Import-Module $using:Module -ErrorAction SilentlyContinue

                # note we only receive module exports from the import, must ...
                # import common functions
                . ([scriptblock]::Create($using:CommonFunc))

                if (Test-SddcModulePresence) {

                    $Path = $null
                    Get-SddcDiagnosticArchiveJobParameters -Path ([ref] $Path)

                    # emit 
                    & {
                        # filter archive?
                        if ($using:DaysOfArchive -ne -1) {

                            # get archive in increasing order of time (our timestamp is lexically sortable)
                            $Archive = dir $Path\*.ZIP | sort -Descending
                            if ($Archive.Count -gt $using:DaysOfArchive) {
                                $Archive = $Archive[0..$($using:DaysOfArchive - 1)]
                            }

                            $Archive.FullName
                            (dir $Path\*.log).FullName

                        } else {

                            # get entire archive
                            # note: we use the wildcard so that we copy the content of the directory
                            # to the appropriate destination. the path itself is configurable.
                            # see comment below.
                            Join-Path (gi $Path).FullName "*"
                        }
                    } |% {

                        Get-AdminSharePathFromLocal $env:COMPUTERNAME $_
                    }
                }
            }
        
            # since the archive directory is configurable, we always need to specify the
            # destination within the capture - it may be \some\dir\foo, but we want it to be 
            # node_xxx\SddcDiagnosticArchive in the capture.
            #
            # we add a member to the jobs to indicate this. also rename them to indicate the
            # activity in these jobs, so we report runtime in a more useful way.
            $j.ChildJobs |% {
                $_ | Add-Member -NotePropertyName Destination -NotePropertyValue SddcDiagnosticArchive   
            }

            # and add to the copyout-nodelete set
            # we do not want to scrub away the archive, unlike content we generate on the target node
            # and then do want to delete after capture.
            $JobCopyOutNoDelete += $j
        }
    }

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

        Start-Job -Name "System Info: $_" -ArgumentList $_,$ClusterDomain,$AccessNode -InitializationScript $CommonFunc {

            param($NodeName,$DomainName,$AccessNode)

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
            # _A_ token will be replaced with the chosen cluster access node
            # _C_ token will be replaced with node fqdn for cimsession/computername callouts
            # _N_ token will be replaced with node non-fqdn
            $CmdsToLog = "Get-NetAdapter -CimSession _C_",
                            "Get-NetAdapterAdvancedProperty -CimSession _C_",
                            "Get-NetIpAddress -CimSession _C_",
                            "Get-NetRoute -CimSession _C_",
                            "Get-NetQosPolicy -CimSession _C_",
                            "Get-NetIPv4Protocol -CimSession _C_",
                            "Get-NetIPv6Protocol -CimSession _C_",
                            "Get-NetOffloadGlobalSetting -CimSession _C_",
                            "Get-NetPrefixPolicy -CimSession _C_",
                            "Get-NetTcpConnection -CimSession _C_",
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
                            "Get-ScheduledTask -CimSession _C_ | Get-ScheduledTaskInfo -CimSession _C_",
                            "Get-StorageFaultDomain -CimSession _A_ -Type StorageScaleUnit |? FriendlyName -eq _N_ | Get-StorageFaultDomain -CimSession _A_"

            foreach ($cmd in $CmdsToLog)
            {
                # truncate cmd string to the cmd itself
                $LocalFile = (Join-Path $LocalNodeDir (($cmd.split(' '))[0] -replace "-",""))
                try {

                    $out = iex ($cmd -replace '_C_',$Node -replace '_N_',$NodeName -replace '_A_',$AccessNode)

                    # capture as txt and xml for quick analysis according to taste
                    $out | ft -AutoSize | Out-File -Width 9999 -Encoding ascii -FilePath "$LocalFile.txt"
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

        $Node = $env:COMPUTERNAME
        $NodePath = [System.IO.Path]::GetTempPath()

        Get-SddcCapturedEvents $NodePath $Hours |% {

            Write-Output (Get-AdminSharePathFromLocal $Node $_)
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

    # NOTE: $Subsystem is reused several times below
    try {
        $Subsystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
        $Subsystem | Export-Clixml ($Path + "GetStorageSubsystem.XML")
    }
    catch { Show-Warning("Unable to get Clustered Subsystem.`nError="+$_.Exception.Message) }

    if ($Subsystem.HealthStatus -notlike "Healthy") {
        try {
            $Subsystem | Debug-StorageSubsystem -CimSession $AccessNode |
                Export-Clixml (Join-Path $Path "DebugStorageSubsystem.XML")
        }
        catch { Show-Error "Unable to get Debug-StorageSubsystem for unhealthy StorageSubsystem.`nError=" $_ }
    }

    Show-Update "Volumes & Virtual Disks"

    # Volume status

    try { 
        $Volumes = Get-Volume -CimSession $AccessNode -StorageSubSystem $Subsystem 
        $Volumes | Export-Clixml ($Path + "GetVolume.XML") }
    catch { Show-Error("Unable to get Volumes. `nError="+$_.Exception.Message) }
    

    # Virtual disk health
    # Used in S2D-specific gather below

    try { 
        $VirtualDisk = Get-VirtualDisk -CimSession $AccessNode -StorageSubSystem $Subsystem 
        $VirtualDisk | Export-Clixml ($Path + "GetVirtualDisk.XML")
    }
    catch { Show-Warning("Unable to get Virtual Disks.`nError="+$_.Exception.Message) }
    
    # Deduplicated volume health
    # XXX the counts/healthy likely not needed once phase 2 shifted into summary report

    if ($DedupEnabled)
    {
        Show-Update "Dedup Volume Status"

        try {
            $DedupVolumes = Invoke-Command -ComputerName $AccessNode { Get-DedupStatus }
            $DedupVolumes | Export-Clixml ($Path + "GetDedupVolume.XML") }
        catch { Show-Error("Unable to get Dedup Volumes.`nError="+$_.Exception.Message) }

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
        Get-StorageTier -CimSession $AccessNode |
            Export-Clixml ($Path + "GetStorageTier.XML") }
    catch { Show-Warning("Unable to get Storage Tiers. `nError="+$_.Exception.Message) }
    
    # Storage pool health

    try { 
        $StoragePools = @(Get-StoragePool -IsPrimordial $False -CimSession $AccessNode -StorageSubSystem $Subsystem -ErrorAction SilentlyContinue)
        $StoragePools | Export-Clixml ($Path + "GetStoragePool.XML") }
    catch { Show-Error("Unable to get Storage Pools. `nError="+$_.Exception.Message) }

    Show-Update "Storage Jobs"

    try {
        # cannot subsystem scope Get-StorageJob at this time
        icm $AccessNode { Get-StorageJob } |
            Export-Clixml ($Path + "GetStorageJob.XML") }
    catch { Show-Warning("Unable to get Storage Jobs. `nError="+$_.Exception.Message) }

    Show-Update "Clustered PhysicalDisks and SNV"

    # Physical disk health

    try {
        $PhysicalDisks = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $Subsystem
        $PhysicalDisks | Export-Clixml ($Path + "GetPhysicalDisk.XML") }
    catch { Show-Error("Unable to get Physical Disks. `nError="+$_.Exception.Message) }

    try {
        $PhysicalDiskSNV = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $Subsystem | Get-PhysicalDiskSNV -CimSession $AccessNode |
            Export-Clixml ($Path + "GetPhysicalDiskSNV.XML") }
    catch { Show-Error("Unable to get Physical Disk Storage Node View. `nError="+$_.Exception.Message) }

    # Reliability counters
    # These may cause a latency burst on some devices due to device-specific requirements for lifting/generating
    # the SMART data which underlies them. Decline to do this by default.

    if ($IncludeReliabilityCounters -eq $true) {

        Show-Update "Storage Reliability Counters"

        try {
            $PhysicalDisks | Get-StorageReliabilityCounter -CimSession $AccessNode |
                Export-Clixml ($Path + "GetReliabilityCounter.XML") }
        catch { Show-Error("Unable to get Storage Reliability Counters. `nError="+$_.Exception.Message) }

    }

    # Storage enclosure health

    Show-Update "Storage Enclosures"

    try {
        Get-StorageEnclosure -CimSession $AccessNode -StorageSubSystem $Subsystem |
            Export-Clixml ($Path + "GetStorageEnclosure.XML") }
    catch { Show-Error("Unable to get Enclosures. `nError="+$_.Exception.Message) }

    #
    # Generate SBL Connectivity report based on input clusport information
    #
    
    if ($S2DEnabled) {

        Show-Update "Pooled Disks"

        try {
            if ($StoragePools.Count -eq 1) {
                $StoragePools | Get-PhysicalDisk -CimSession $AccessNode |
                    Export-Clixml (Join-Path $Path ("GetPhysicalDisk_Pool.xml"))
            }
        } catch {
            Show-Error "Not able to query pooled disks" $_
        }

        Show-Update "Storage Scale Units"

        try {
            $Subsystem | Get-StorageFaultDomain -CimSession $AccessNode -Type StorageScaleUnit |
                Export-Clixml (Join-Path $Path ("GetStorageFaultDomain_SSU.xml"))
        } catch {
            Show-Error "Not able to query Storage Scale Units" $_
        }

        Show-Update "S2D Connectivity"

        try {
            $JobStatic += $ClusterNodes |% {
                $node = $_.Name
                Start-Job -Name "S2D Connectivity: $node" -InitializationScript $CommonFunc {
                    Get-CimInstance -Namespace root\wmi -ClassName ClusPortDeviceInformation -ComputerName $using:node |
                        Export-Clixml (Join-Path (Get-NodePath $using:Path $using:node) "ClusPort.xml")
                    Get-CimInstance -Namespace root\wmi -ClassName ClusBfltDeviceInformation -ComputerName $using:node |
                        Export-Clixml (Join-Path (Get-NodePath $using:Path $using:node) "ClusBflt.xml")
                }
            }
        } catch {
            Show-Warning "Gathering SBL connectivity failed"
        }
    }

    ####
    # Now receive the jobs requiring remote copyout
    ####

    if ($JobCopyOut.Count -or $JobCopyOutNoDelete.Count) {
        Show-Update "Completing jobs with remote copyout ..." -ForegroundColor Green
        Show-WaitChildJob ($JobCopyOut + $JobCopyOutNoDelete) 120
        Show-Update "Starting remote copyout ..."

        # keep parallelizing on receive at the individual node/child job level
        $JobCopy = @()
        if ($JobCopyOut.Count) { $JobCopy += Start-CopyJob $Path -Delete $JobCopyOut }
        if ($JobCopyOutNoDelete.Count) { $JobCopy += Start-CopyJob $Path $JobCopyOutNoDelete }
        Show-WaitChildJob $JobCopy 30

        # receive any copyout errors for logging/triage
        Receive-Job $JobCopy
        Remove-Job ($JobCopyOut + $JobCopyOutNoDelete)
        Remove-Job $JobCopy
    }

    Show-Update "All remote copyout complete" -ForegroundColor Green

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
        $set = Get-Counter -ListSet "Cluster Storage*","Cluster CSV*","Storage Spaces*" -ComputerName $ClusterNodes.Name
        Show-Update "Start monitoring ($($PerfSamples)s)"		
        $PerfRaw = Get-Counter -Counter $set.Paths -SampleInterval 1 -MaxSamples $PerfSamples -ErrorAction Ignore -WarningAction Ignore
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

    Show-Update "GATHERS COMPLETE ($(((Get-Date) - $TodayDate).ToString("m'm's\.f's'")))" -ForegroundColor Green

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

    $ZipSuffix = '-' + $Cluster.Name + '-' + (Format-SddcDateTime $TodayDate) + '.ZIP'
    $ZipPath = $ZipPrefix + $ZipSuffix
    
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

    Show-Update "COMPLETE ($(((Get-Date) - $TodayDate).ToString("m'm's\.f's'")))" -ForegroundColor Green
}

#######
#######
#######
##
# Archive Job Management
##
#######
#######
#######

<#
.SYNOPSIS
    Install the Sddc Diagnostic Module (PrivateCloud.DiagnosticInfo) on the target nodes.

.DESCRIPTION
    Install the Sddc Diagnostic Module (PrivateCloud.DiagnosticInfo) on the target nodes.

    This is done by pushing the current version of the module from the local system to the targets,
    not by downloading from a remote location.

.PARAMETER Cluster
    Specifies the cluster to push to. All nodes will receive the module.

.PARAMETER Node
    Specifies the nodes to push to, directly.

.PARAMETER Force
    Forces (re)installation even if the target nodes have the same version as the source.

.EXAMPLE
    Install-SddcDiagnosticModule

    Install the module to all nodes of the current system's cluster.

.EXAMPLE
    Install-SddcDiagnosticModule -Cluster Cluster1

    Install the module to all nodes of the Cluster1 cluster.

.EXAMPLE
    Install-SddcDiagnosticModule -Node Node1,Node2

    Install the module to the specified nodes.
#>

function Install-SddcDiagnosticModule
{
    [CmdletBinding( DefaultParameterSetName = "Cluster" )]
    param(
        [parameter(ParameterSetName="Cluster", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.',

        [parameter(ParameterSetName="Node", Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Node,

        [parameter(ParameterSetName="Cluster", Mandatory=$false)]
        [parameter(ParameterSetName="Node", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [switch] $Force
    )

    switch ($psCmdlet.ParameterSetName) {
        "Cluster" {
            $Nodes = Get-NodeList -Cluster $Cluster -Filter
        }
        "Node" {
            $Nodes = Get-NodeList -Nodes $Node -Filter
        }
    }

    # remove the local node if present (self-update)
    $Nodes = $Nodes |? { $_ -ne $env:COMPUTERNAME }

    $thisModule = Get-Module $Module -ErrorAction Stop

    $clusterModules = icm $Nodes.Name {
        $null = Import-Module -Force $using:Module -ErrorAction SilentlyContinue
        Get-Module $using:Module
    }

    # build list of nodes which need installation/refresh
    $installNodes = @()
    $updateNodes = @()

    # start with nodes which lack the module
    $Nodes.Name |? { $_ -notin $clusterModules.PsComputerName } |% { $installNodes += $_ }
    # now add nodes which are downlevel (or, forced, the same apparent version)
    $clusterModules |? { $thisModule.Version -gt $_.Version -or ($Force -and $thisModule.Version -eq $_.Version) } |% { $updateNodes += $_.PsComputerName }

    # warn nodes which are uplevel
    $clusterModules |? { $thisModule.Version -lt $_.Version } |% {
        Write-Warning "Node $($_.PsComputerName) has an newer version of the $Module module ($($_.Version) > $($thisModule.Version)). Consider installing the updated module on the local system ($env:COMPUTERNAME) and updating the cluster."
    }

    if ($installNodes.Count) { Write-Host "New Install to Nodes: $(($installNodes | sort) -join ',')" }
    if ($updateNodes.Count) { Write-Host "Update for Nodes    : $(($updateNodes | sort) -join ',')" }

    # begin gathering remote install locations
    # clean outdated installations if present

    $installPaths = @()

    if ($installNodes.Count -gt 0) {
        $installPaths += icm $installNodes {

            # import common functions
            . ([scriptblock]::Create($using:CommonFunc))

            # place in the Install-Module default location
            # note we must specify all the way to final destination since we know it does not exist
            Write-Output (Get-AdminSharePathFromLocal $env:COMPUTERNAME (Join-Path "$env:ProgramFiles\WindowsPowerShell\Modules\$using:Module" $using:thisModule.Version))
        }
    }

    if ($updateNodes.Count -gt 0) {
        $installPaths += icm $updateNodes {

            # import common functions
            . ([scriptblock]::Create($using:CommonFunc))

            # wipe outdated install location - Install-Module does not place here, prefer its location
            if (Test-Path $env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\$using:Module) {

                rm -Recurse $env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\$using:Module -ErrorAction Stop

                # place in the Install-Module default location
                Write-Output (Get-AdminSharePathFromLocal $env:COMPUTERNAME (Join-Path "$env:ProgramFiles\WindowsPowerShell\Modules\$using:Module" $using:thisModule.Version))

            } else { 
        
                $null = Import-Module $using:Module -Force
                $m = Get-Module $using:module -ErrorAction Stop

                # unload current and return its location for update
                $md = (gi (gi $m.ModuleBase -ErrorAction SilentlyContinue).PsParentPath).FullName
                Remove-Module $using:module -ErrorAction SilentlyContinue

                # note we return the parent path - the copy will place the versioned module directory within it
                Write-Output (Get-AdminSharePathFromLocal $env:COMPUTERNAME $md)
            }
        }
    }

    # and propagate to the given locations
    $installPaths |% {
        cp -Recurse $thisModule.ModuleBase $_ -Force -ErrorAction Stop
    }
}

<#
.SYNOPSIS
    Confirm versioning of the Sddc Diagnostic module (PrivateCloud.DiagnosticInfo) on the target
    nodes.

.DESCRIPTION
    Confirm versioning of the Sddc Diagnostic module (PrivateCloud.DiagnosticInfo) on the target
    nodes.

    Warnings will be generated for nodes which do not have the module or have versions different
    from the one on the local system. Use Install-SddcDiagnosticModule to push updates.

.PARAMETER Cluster
    Specifies the cluster. All nodes will be validated.

.PARAMETER Node
    Specifies the nodes to validate directly.

.EXAMPLE
    Confirm-SddcDiagnosticModule

    Validate versions installed across the cluster the local system is a member of.

.EXAMPLE
    Confirm-SddcDiagnosticModule -Cluster Cluster1

    Validate versions installed across the Cluster1 cluster.
#>

function Confirm-SddcDiagnosticModule
{
    [CmdletBinding()]
    param(
        [parameter(ParameterSetName="Cluster", Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.',

        [parameter(ParameterSetName="Node", Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Node
    )

    switch ($psCmdlet.ParameterSetName) {
        "Cluster" {
            $Nodes = Get-NodeList -Cluster $Cluster -Filter
        }
        "Node" {
            $Nodes = Get-NodeList -Nodes $Node -Filter
        }
    }

    $thisModule = Get-Module $Module -ErrorAction Stop

    $clusterModules = icm $Nodes.Name {
        $null = Import-Module -Force $using:Module -ErrorAction SilentlyContinue
        Get-Module $using:Module
    }

    $Nodes.Name |? { $_ -notin $clusterModules.PsComputerName } |% {
        Write-Warning "Node $_ does not have the $Module module. Please 'Install-SddcDiagnosticModule -Node $_' to address."
    }
    $clusterModules |? { $thisModule.Version -gt $_.Version } |% {
        Write-Warning "Node $($_.PsComputerName) has an older version of the $Module module ($($_.Version) < $($thisModule.Version)). Please 'Install-SddcDiagnosticModule -Node $_' to address."
    }
    $clusterModules |? { $thisModule.Version -lt $_.Version } |% {
        Write-Warning "Node $($_.PsComputerName) has an newer version of the $Module module ($($_.Version) > $($thisModule.Version)). Consider installing the updated module on the local system ($env:COMPUTERNAME) and updating the cluster."
    }

    $clusterModules
}

<#
.SYNOPSIS
    Perform garbage collection on the local node's Sddc Diagnostic Archive.

.DESCRIPTION
    Perform garbage collection on the local node's Sddc Diagnostic Archive.

    This is an INTERNAL utililty command, used by the clustered scheduled task which performs the
    Sddc Diagnostic Archive. It is not intended for direct use.

.PARAMETER ArchivePath
    Specifies the path to the archive to garbage collect.

.EXAMPLE
    Limit-SddcDiagnosticArchive -ArchivePath C:\Windows\SddcDiagnosticArchive

    Perform garbage collection on the content of the specified directory.
#>

function Limit-SddcDiagnosticArchive
{
    param(
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ArchivePath
    )

    $Days = $null
    $Size = $null
    Get-SddcDiagnosticArchiveJobParameters -Days ([ref] $Days) -Size ([ref] $Size)

    Show-Update "Applying limits to SDDC Archive @ $ArchivePath : $Days Days & $('{0:0.00} MiB' -f ($Size/1MB))"

    #
    # Comment/get current state
    #

    # note: default sort is ascending, so by our lexically sortable naming convention
    # the oldest ZIPs will come first
    $f = @(dir $ArchivePath\*.ZIP) | sort
    $m = $f | measure -Sum Length

    Show-Update "Begin: $($m.Count) ZIPs which are $('{0:0.00} MiB' -f ($m.Sum/1MB))"

    #
    # Day limit
    #

    if ($f.Count -gt $Days) {
        $ndelete = $f.Count - $Days
        Show-Update "Deleting $ndelete days of archive"

        $f[0..($ndelete - 1)] |% {
            Show-Update "`tDay limit: Deleting $($_.FullName)"
            $_
        } | del -Force

        # re-measure the remaining
        $f = $f[$ndelete..$($f.Count - 1)]
        $m = $f | measure -Sum Length
    }

    #
    # Size limit
    #

    if ($m.Sum -gt $Size) {

        Show-Update "Deleting $('{0:0.00} MiB' -f ($($m.Sum-$Size)/1MB)) MiB of archive"

        foreach ($file in $f) {

            Show-Update "`tSize limit: Deleting $($file.FullName)"
            $m.Sum -= $file.Length
            del $file.Fullname -Force

            if ($m.Sum -le $Size) {
                break
            }
        }
    }

    #
    # Comment final state
    #

    $f = @(dir $ArchivePath\*.ZIP) | sort
    $m = $f | measure -Sum Length

    Show-Update "End: $($m.Count) ZIPs which are $('{0:0.00} MiB' -f ($m.Sum/1MB))"
}

<#
.SYNOPSIS
    Perform a new capture to the local node's Sddc Diagnostic Archive.

.DESCRIPTION
    Perform a new capture to the local node's Sddc Diagnostic Archive.

    This is an INTERNAL utililty command, used by the clustered scheduled task which performs the
    Sddc Diagnostic Archive. It is not intended for direct use.

.PARAMETER ArchivePath
    Specifies the path to the archive.

.EXAMPLE
    Update-SddcDiagnosticArchive -ArchivePath C:\Windows\SddcDiagnosticArchive

    Capture content to the specified directory.
#>

function Update-SddcDiagnosticArchive
{
    param(
        [parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $ArchivePath
    )

    # get timestamp at the top, reflecting job launch time
    $TimeStamp = Get-Date

    # Scrub in just in case
    $CapturePath = (Join-Path $ArchivePath "Capture")
    rm -r $CapturePath -Force -ErrorAction SilentlyContinue
    $null = mkdir $CapturePath -Force -ErrorAction Stop

    #
    # Capture
    #

    # 25 hour capture of events
    Get-SddcCapturedEvents $CapturePath 25 |% {
        Show-Update "Captured: $_"
    }

    # 25 hour capture of cluster/health logs
    try {

        if ($c = Get-Cluster) {

            $f = Get-ClusterLog -Node $env:COMPUTERNAME -Destination $CapturePath -UseLocalTime -TimeSpan (25 * 60)
            Show-Update "Captured: $($f.FullName)"
            if ($c.S2DEnabled) {
                $f = Get-ClusterLog -Node $env:COMPUTERNAME -Destination $CapturePath -Health -UseLocalTime -TimeSpan (25 * 60)
                Show-Update "Captured: $($f.FullName)"
            }
        }
    } catch {

        Show-Update "Cluster/Health Logs not captured"
    }

    #
    # Compress
    #

    $ZipFile = 'SddcDiagnosticArchive-' + $env:COMPUTERNAME + '-' + (Format-SddcDateTime ($TimeStamp)) + '.ZIP'
    $ZipPath = (join-path $ArchivePath $ZipFile)
    
    try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($CapturePath, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        Show-Update "Zip File Name : $ZipPath"
    } catch {
        Show-Error "Error creating the ZIP file!" $_
    }

    # Scrub out
    rm -r $CapturePath -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Query for Sddc Diagnostic Archive job parameters.

.DESCRIPTION
    Query for Sddc Diagnostic Archive job parameters. [ref] parameters must be specified.

    This is an INTERNAL utililty command, used by the clustered scheduled task which performs the
    Sddc Diagnostic Archive. It is not intended for direct use.

    Use Show-SddcDiagnosticArchiveJob to query & show the state of the archive job on a target set
    of systems.

.PARAMETER Cluster
    Specifies the cluster from which parameters should be queried.

.PARAMETER Days
    Receives the days of archive to maintain.

.PARAMETER Path
    Receives the path to the archive (valid only on local system)

.PARAMETER Size
    Receives the maximum size of the archive to maintain (bytes)

.PARAMETER At
    Receives the time of day that the archive update job is configured to run.

.EXAMPLE
    Get-SddcDiagnosticArchiveJobParameters -Days ([ref] $d)

    Receives the days of archive configured for the cluster the local system is a member of.
#>

function Get-SddcDiagnosticArchiveJobParameters
{
    param(
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.',

        [parameter(Mandatory=$false)]
        [ref] $Days,

        [parameter(Mandatory=$false)]
        [ref] $Path,

        [parameter(Mandatory=$false)]
        [ref] $Size,

        [parameter(Mandatory=$false)]
        [ref] $At
    )

    $c = Get-Cluster -Name $Cluster -ErrorAction Stop

    if ($PSBoundParameters.ContainsKey('Days')) {
        try {
            $Days.Value = ($c | Get-ClusterParameter -Name SddcDiagnosticArchiveDays -ErrorAction Stop).Value
        } catch {
            $Days.Value = 60
        }
    }

    if ($PSBoundParameters.ContainsKey('Path')) {
        try {
            $Path.Value = ($c | Get-ClusterParameter -Name SddcDiagnosticArchivePath -ErrorAction Stop).Value
        } catch {
            $Path.Value = Join-Path $env:SystemRoot "SddcDiagnosticArchive"
        }
    }

    if ($PSBoundParameters.ContainsKey('Size')) {
        try {
            $Size.Value = ($c | Get-ClusterParameter -Name SddcDiagnosticArchiveSize -ErrorAction Stop).Value
        } catch {
            $Size.Value = 500MB
        }
    }

    if ($PSBoundParameters.ContainsKey('At')) {
        try {
            $Task = Get-ClusteredScheduledTask -Cluster $c.Name -TaskName SddcDiagnosticArchive -ErrorAction Stop

            # may be overaggresive, there should only be one trigger if we define it
            $At.Value = [datetime] ($Task.TaskDefinition.Triggers[0].StartBoundary)
        } catch {
            $At.Value = [datetime] '3AM'
        }
    }
}

<#
.SYNOPSIS
    Set Sddc Diagnostic Archive job parameters.

.DESCRIPTION
    Set Sddc Diagnostic Archive job parameters.

    Use this command to change the default archive location and garbage collection controls (days
    of archive and its maximum size).

    Use the Register-SddcDiagnosticArchiveJob to change the launch time.

.PARAMETER Cluster
    Specifies the cluster for which parameters will be set.

.PARAMETER Days
    Specifies the days of archive to maintain. This limit will be applied during the next archive
    job execution.

.PARAMETER Path
    Specifies the path to create the archive at. Ensure that this path is available on all systems.
    By default the archive will be placed at $env:SystemRoot\SddcDiagnosticArchive

.PARAMETER Size
    Specifies the maximum size of the archive (in bytes). This limit will be applied during the next
    archive job execution.

.EXAMPLE
    Set-SddcDiagnosticArchiveJobParameters -Days 14

    Sets the maximum days of archive to two weeks.
#>

function Set-SddcDiagnosticArchiveJobParameters
{
    param(
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.',
        
        [parameter(Mandatory=$false)]
        [ValidateRange(1,365)]
        [int] $Days,

        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,
        
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [uint64] $Size
    )

    $c = Get-Cluster -Name $Cluster -ErrorAction Stop

    # note: we could rewrite paths which are prefixed with recognizably $env:systemroot and other
    # canonical paths with macros that we can expand at the destination node. strictly speaking these are
    # not guaranteed to be identical though its extremely unlikely we'll find that condition in practice.


    if ($PSBoundParameters.ContainsKey('Days')) {
        $c | Set-ClusterParameter -Name SddcDiagnosticArchiveDays -Create -Value $Days -ErrorAction Stop
    }
    if ($PSBoundParameters.ContainsKey('Path')) {
        if ($Path[1] -ne ':') {
            Write-Error 'Path must be specified as an absolute path (<driveletter>:\some\path)'
        } else {
            $c | Set-ClusterParameter -Name SddcDiagnosticArchivePath -Create -Value $Path -ErrorAction Stop
        }
    }
    if ($PSBoundParameters.ContainsKey('Size')) {
        $c | Set-ClusterParameter -Name SddcDiagnosticArchiveSize -Create -Value $Size -ErrorAction Stop
    }

    # note, the scheduled start time is only modified at register time
}

<#
.SYNOPSIS
    Show the state of the Sddc Diagnostic Archive job.

.DESCRIPTION
    Show the state of the Sddc Diagnostic Archive job.

    Use this command to generate a report on the location and garbage collection parameters for the
    archive on the target cluster, along with space used on each node.

.PARAMETER Cluster
    Specifies the cluster to query.

.EXAMPLE
    Show-SddcDiagnosticArchiveJob -Cluster Cluster1

    Shows the state of the archive job on cluster Cluster1
#>

function Show-SddcDiagnosticArchiveJob
{
    param(
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.'
    )

    $c = Get-Cluster -Name $Cluster -ErrorAction Stop

    # continue if present, else error
    if (-not (Get-ClusteredScheduledTask -Cluster $c.Name |? TaskName -eq SddcDiagnosticArchive)) {
        Show-Error "SddcDiagnosticArchive job not currently registered"
    }

    $Days = $null
    $Path = $null
    $Size = $null
    $At = $null

    Get-SddcDiagnosticArchiveJobParameters -Cluster $c.Name -Days ([ref] $Days) -Path ([ref] $Path) -Size ([ref] $Size) -At ([ref] $At)

    Write-Output "Target archive size per node : $('{0:0.00} MiB' -f ($Size/1MB))"
    Write-Output "Target days of archive       : $Days"
    Write-Output "Capture to path              : $Path"
    Write-Output "Capture at                   : $($At.ToString("h:mm tt"))"

    $Nodes = Get-NodeList -Cluster $Cluster -Filter

    Write-Output "$('-'*20)`nPer Node Report"
    $j = $Nodes | sort Name |% {
        icm $_.Name -AsJob {

            Import-Module $using:Module -ErrorAction SilentlyContinue

            # import common functions
            . ([scriptblock]::Create($using:CommonFunc))

            if (Test-SddcModulePresence) {

                $Path = $null
                Get-SddcDiagnosticArchiveJobParameters -Path ([ref] $Path)

                dir $Path\*.ZIP -ErrorAction SilentlyContinue | measure -Sum Length
            }
        }   
    }

    $null = $j | Wait-Job
    $j | sort Location |% {

        $m = Receive-Job $_
        Remove-Job $_

        # note we will not have a measurement if the remote node lacks the module
        # a warning will have already been passed to the output in this case
        if ($m) {
            Write-Output "Node $($_.Location): $($m.Count) ZIPs which are $('{0:0.00} MiB' -f ($m.Sum/1MB))"
        }
    }
}

<#
.SYNOPSIS
    Unregister (remove) the Sddc Diagnostic Archive job.

.DESCRIPTION
    Unregister (remove) the Sddc Diagnostic Archive job.

    This removes all configured parameters and the Sddc Diagnostic Archive clustered scheduled task.
    It does not remove the Sddc Diagnostic Archives themselves.

.PARAMETER Cluster
    Specifies the target cluster.

.EXAMPLE
    Unregister-SddcDiagnosticArchiveJob -Cluster Cluster1

    Removes the Sddc Diagnostic Archive job from cluster Cluster1
#>

function Unregister-SddcDiagnosticArchiveJob
{
    param(
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.'
    )

    $c = Get-Cluster -Name $Cluster -ErrorAction Stop

    # silently delete parameters, if set away from defaults
    $c | Set-ClusterParameter -Name SddcDiagnosticArchiveDays -Delete -ErrorAction SilentlyContinue
    $c | Set-ClusterParameter -Name SddcDiagnosticArchivePath -Delete -ErrorAction SilentlyContinue
    $c | Set-ClusterParameter -Name SddcDiagnosticArchiveSize -Delete -ErrorAction SilentlyContinue

    # unregister if present, else error
    if (Get-ClusteredScheduledTask -Cluster $c.Name |? TaskName -eq SddcDiagnosticArchive) {
        Unregister-ClusteredScheduledTask -Cluster $c.Name -TaskName SddcDiagnosticArchive -ErrorAction Stop
    } else {
        Show-Error "SddcDiagnosticArchive job not currently registered"
    }
}

<#
.SYNOPSIS
    Register the Sddc Diagnostic Archive job.

.DESCRIPTION
    Register the Sddc Diagnostic Archive job.

    This creates the Sddc Diagnostic Archive clustered scheduled task on the target cluster. Use
    Set-SddcDiagnosticArchiveJobParameters to change the default location and garbage collection
    options. Use Show-SddcDiagnosticArchiveJob to verify the state of the job and its parameters.

    Re-registering can be used to change the start time for the job. This does not affect other
    configured parameters, and does not create an additional instance of the job.

.PARAMETER Cluster
    Specifies the target cluster.

.PARAMETER At
    Specifies the time to launch the job (1/day).

.EXAMPLE
    Register-SddcDiagnosticArchiveJob -Cluster Cluster1

    Creates the Sddc Diagnostic Archive job on cluster Cluster1 with default location and garbage
    collection parameters.

.EXAMPLE
    Register-SddcDiagnosticArchiveJob -At 4:30AM

    Creates the Sddc Diagnostic Archive job, launching at 4:30AM each morning.
#>

function Register-SddcDiagnosticArchiveJob
{
    param(
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [string] $Cluster = '.',
        
        [parameter(Mandatory=$false)]
        [ValidateNotNullOrEmpty()]
        [datetime] $At = '3AM'
    )

    $c = Get-Cluster -Name $Cluster -ErrorAction Stop

    # the scheduled task script itself
    $scr = {
        $Module = 'PrivateCloud.DiagnosticInfo'
        Import-Module $Module

        $Path = $null
        Get-SddcDiagnosticArchiveJobParameters -Path ([ref] $Path)
        $null = mkdir -Force $Path -ErrorAction SilentlyContinue

        $LogFile = Join-Path $Path "SddcDiagnosticArchive.log"

        # trim log
        $ntail = $null
        $limit = 10MB
        if (($l = gi $LogFile -ErrorAction SilentlyContinue) -and
            $l.Length -gt $limit) {

            $LogFileTmp = Join-Path $Path "SddcDiagnosticArchive.log.tmp"

            # note: transcripts are produced in plain ASCII
            # estimate the #lines in the tail of the file which ~10MB allows for
            $ntail = [int] ((gc $LogFile | measure).Count * ($limit/$l.length))
            gc $LogFile -Tail $ntail | Out-File -Encoding ascii -Width 9999 $LogFileTmp
            del $LogFile
            move $LogFileTmp $LogFile
        }

        Start-Transcript -Path $LogFile -Append

        if ($ntail) {
            Write-Output "Truncated $LogFile to $ntail lines ($('{0:0.00} MiB' -f ($limit/1MB)) limit)"
        }

        if (-not (Get-Module $Module)) {
            Write-Output "Module $Module not installed - exiting, cannot capture"
        } else {

            try {
                Update-SddcDiagnosticArchive $Path
                Limit-SddcDiagnosticArchive $Path
            } catch {
                Show-Error "SDDC Diagnostic Archive job failed.`nError=" $_
            }
        }

        Stop-Transcript
    }

    # use the encoded form to mitigate quoting complications that full scriptblock transfer exposes
    $encscr = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("& { $scr }"))
    $arg = "-NoProfile -NoLogo -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encscr"

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Daily -At $At

    Unregister-ClusteredScheduledTask -Cluster $c.Name -TaskName SddcDiagnosticArchive -ErrorAction SilentlyContinue
    Register-ClusteredScheduledTask -Cluster $c.Name -Action $action -Trigger $trigger -TaskName SddcDiagnosticArchive -TaskType ClusterWide -Description "Get-SddcDiagnosticInfo Periodic Diagnostic Archive Task"
}

#######
#######
#######
##
# Reporting
##
#######
#######
#######

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
    SmbConnectivity
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
        $ReportLevel,

        [int]
        $CutoffMs = 0,
        
        [datetime]
        $TimeBase,

        [int]
        $HoursOfEvents = -1
    )

    $j = @()

    dir $Path\Node_*\Microsoft-Windows-Storage-Storport-Operational.EVTX | sort -Property FullName |% {

        $file = $_.FullName
        $node = "<unknown>"
        if ($file -match "Node_([^\\]+)\\") {
            $node = $matches[1]
        }

        # parallelize processing of per-node event logs

        $j += Start-Job -InitializationScript $CommonFunc -Name $node -ArgumentList $($ReportLevel -eq [ReportLevelType]::Full) {

            param($dofull)

            # helper function for getting list of bucketnames from x->end
            function Get-Bucket
            {
                param(
                    [int] $i,
                    [int] $max,
                    [string[]] $s
                )

                $i .. $max |% {
                    $l = $_
                    $s |% { "BucketIo$_$l" }
                }
            }

            # hash for devices, label schema, and whether values are absolute counts or split success/faul
            $buckhash = @{}
            $bucklabels = $null
            $buckvalueschema = $null

            # note: cutoff bucket is 1-based, following the actual event schema labels (BucketIoCountNNN)
            $cutoffbuck = 1

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

            # get single event from the log (if present)
            $e = Get-WinEvent -Path $using:file -FilterXPath (Get-FilterXpath -Event 505) -ErrorAction SilentlyContinue -MaxEvents 1

            if ($e) {

                # use this event to determine schema and cutoff bucket (if specified)

                $xh = Get-EventDataHash $e

                # only need to get the bucket label schema once
                # the number of labels and the number of bucket counts should be equal
                # determine the count schema at the same time
                $bucklabels = $xh['IoLatencyBuckets'] -split ',\s+'

                # is the count scheme split (RS5) or combined (RS1)?
                # match 1 is the bucket type
                # match 2 is the value bucket number (1 .. n)
                if ($xh.ContainsKey("BucketIoSuccess1")) {
                    $schemasplit = $true
                    $buckvalueschema = "^BucketIo(Success|Failed)(\d+)$"
                } else {
                    $schemasplit = $false
                    $buckvalueschema = "^BucketIo(Count)(\d+)$"
                }

                # initialize empty data element test
                $DataOr = @{}

                if ($using:CutoffMs) {

                    $CutoffUs = $using:CutoffMs * 1000

                    # parse the buckets to determine where the cutoff is
                    $a = $xh['IoLatencyBuckets'] -split ',\s+' |% {

                        switch -Regex ($_) {

                            "^(\d+)us$" { [int] $matches[1] }
                            "^(\d+)ms$" { ([int] $matches[1]) * 1000 }
                            "^(\d+)\+ms$" { [int]::MaxValue }

                            default { throw "misparsed storport 505 event latency bucket label $_ " }
                        }
                    }

                    # determine which bucket contains the cutoff, and build the must-be-gtz kv
                    foreach ($i in 0..($a.Count - 1)) {
                        if ($CutoffUs -lt $a[$i]) {
                            # cutoff bucket matches the event schema, which is one-based, i.e. we're putting the cutoff
                            # at BucketIoCount3 if we found the cutoff in the 0-1-2nd array entry
                            $cutoffbuck = $i+1
                            break
                        }
                    }

                    # ... build the named buckets in the event which must-be-gtz
                    if ($schemasplit) {
                        $buck = Get-Bucket $cutoffbuck $a.Count 'Success','Failed'
                    } else {
                        $buck = Get-Bucket $cutoffbuck $a.Count 'Count'
                    }

                    # ... build out the DataOor as must-be-gtz tests
                    $DataOr = @{}
                    $buck |% {
                        $DataOr[$_] = "> 0"
                    }
                }

                # now do two things based on determining the cutoff (or lack thereof)
                # 1. relabel the cutoff bucket (the first we will return) to indicate the lower bound of latency
                #       - if there is no cutoff, we add 0- to indicate it contains 0-<label>
                #       - if there is a cutoff, we add <lower bucket>- to indicate  contains events
                #           from that latency upward, i.e. 64ms-2048ms
                # 2. trim off the cut labels from the front of bucklabels (the length of this drives the rest)

                if ($cutoffbuck -eq 1) {
                    # no cutoff, prepend 0- to first entry
                    $bucklabels[0] = "0-" + $bucklabels[0]
                } else {
                    # cutoff, prepend lower neighbor
                    $bucklabels[$cutoffbuck - 1] = $bucklabels[$cutoffbuck - 2] + "-" + $bucklabels[$cutoffbuck - 1]
                    # trim labels to the cutoff bucket and upward
                    $bucklabels = $bucklabels[($cutoffbuck - 1) .. ($bucklabels.Count - 1)]
                }

                # construct the xpath filter w/wo the time filter
                # if the data element test is empty, it will not be built into the xpath query
                if ($using:HoursOfEvents -ne -1) {
                    $xpath = Get-FilterXpath -Event 505 -TimeBase $using:TimeBase -TimeDeltaMs ($using:HoursOfEvents * 60 * 60 * 1000) -DataOr $DataOr
                } else {
                    $xpath = Get-FilterXpath -Event 505 -DataOr $DataOr
                }

                # now, with schema, process all events
                Get-WinEvent -Path $using:file -FilterXPath $xpath |% {

                    $xh = Get-EventDataHash $_

                    # physical disk device id - string the curly to normalize later matching
                    $dev = [string] $xh['ClassDeviceGuid']
                    if ($dev -match '{(.*)}') {
                        $dev = $matches[1]
                    }

                    # counting array for each bucket
                    $buckvalues = @($null) * $bucklabels.length

                    # place all data values into the counting array
                    $xh.Keys |% {
                        if ($_ -match $buckvalueschema) {

                            # the schema parses the bucket number into match 2
                            # number is 1-based, as is the cutoff
                            # this converts it to a 0-base
                            $thisbuck = [int] $matches[2]
                            if ($thisbuck -ge $cutoffbuck) {
                                $buckvalues[$thisbuck - $cutoffbuck] += [int] $xh[$_]
                            }
                        }
                    }

                    # the counting array should not contain null entries; all buckets should be represented in the event
                    if ($buckvalues -contains $null) {
                        throw "misparsed 505 event latency buckets: labels $($bucklabels.count) values $(($buckvalues | measure).count)"
                    }

                    # now place the counting array into the device hash; each nonzero bucket adds +1
                    if (-not $buckhash.ContainsKey($dev)) {
                        # new device
                        $buckhash[$dev] = $buckvalues |% { if ($_) { 1 } else { 0 }}
                    } else {
                        # increment device bucket hit counts
                        foreach ($i in 0..($buckvalues.count - 1)) {
                            if ($buckvalues[$i]) { $buckhash[$dev][$i] += 1}
                        }
                    }

                    # in the full report, show
                    # 1. all events above a cutoff, if applied
                    # 2. or events in the highest bucket
                    if ($dofull -and ($buckvalues[-1] -ne 0 -or $cutoffbuck -ne 1)) {
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
    $j | Wait-Job| sort name |% {

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

                Write-Output "`nHigh Latency Events"

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
        # note: we should put the provider test into the xpath query as well; extend Get-FilterXpath for this
        #    when we have another test log to work against
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

function Get-SmbConnectivityReport
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

    $ReportTableBlock = {
        param(
            [string[]] $paths,
            [int] $ev,
            [datetime] $timebase,
            [System.ConsoleColor] $warncol,
            [string] $warn
            )

        $r = $paths |% {
            
            $node = "<unknown>"
            if ($_ -match "Node_([^\\]+)\\") {
                $node = $matches[1]
            }

            # relative time deltas in milliseconds
            $last5 = (1000*60*5)
            $lasthour = (1000*60*60)
            $lastday = (1000*60*60*24)

            New-Object psobject -Property @{
                'ComputerName' = $node
                'RDMA Last5Min' = Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $last5    -DataAnd @{'ConnectionType'='=2'})
                'RDMA LastHour' = Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $lasthour -DataAnd @{'ConnectionType'='=2'})
                'RDMA LastDay' =  Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $lastday  -Data @{'ConnectionType'='=2'})

                'TCP Last5Min' =  Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $last5    -DataAnd @{'ConnectionType'='=1'})
                'TCP LastHour' =  Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $lasthour -DataAnd @{'ConnectionType'='=1'})
                'TCP LastDay' =   Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $lastday  -DataAnd @{'ConnectionType'='=1'}) 
            }
        }

        $hdr = 'ComputerName','RDMA Last5Min','RDMA LastHour','RDMA LastDay','TCP Last5Min','TCP LastHour','TCP LastDay'
        $rdmafail = ($r |% { $row = $_; $hdr |? {$_ -like 'RDMA*' } |% { $row.$_ }} | measure -sum).sum -ne 0

        if ($rdmafail) {
            Write-Host -ForegroundColor $warncol $warn
        }

        $r | sort -Property ComputerName | ft -Property $hdr
    }

    # get the timebase from the capture parameters
    $Parameters = Import-Clixml (Join-Path $Path "GetParameters.XML")
    $CaptureDate = $Parameters.TodayDate

    Write-Host "This report is relative to the time of data capture: $($CaptureDate)"

    $eventlogs = (dir $Path\Node_*\Microsoft-Windows-SmbClient-Connectivity.EVTX).FullName

    $j = @()

    $w = @"
WARNING: the SMB Client is receiving RDMA disconnects. This is an error whose root
`t cause may be PFC/CoS misconfiguration (if RoCE) on hosts or switches, physical
`t issues (ex: bad cable), switch or NIC firmware issues, and will lead to severely
`t degraded performance. Please inspect especially if in the Last5 bucket. Note that
`t cluster node reboots are a natural & expected source of disconnects.
"@

    $j += Start-Job -name 'SMB Connectivity Error Check - Disconnect Failures (Event 30804)' -InitializationScript $CommonFunc -ScriptBlock $ReportTableBlock -ArgumentList $eventlogs,30804,$CaptureDate,([ConsoleColor]'Red'),$w

    $w = @"
WARNING: the SMB Client is receiving RDMA connect errors. This is an error whose root
`t cause may be actual lack of connectivity or fundamental problems with the RDMA
`t network fabric. Please inspect especially if in the Last5 bucket.
"@

    $j += Start-Job -name 'SMB Connectivity Error Check - Connect Failures (Event 30803)' -InitializationScript $CommonFunc -ScriptBlock $ReportTableBlock -ArgumentList $eventlogs,30803,$CaptureDate,([ConsoleColor]'Yellow'),$w 

    $null = $j | Wait-Job
    $j | sort Name |% {

        Write-Host -ForegroundColor Cyan $_.Name
        Receive-Job $_
    }
    $j | Remove-Job
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

    Show-Update "<<< Phase 1 - Health Overview >>>`n" -ForegroundColor Cyan

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

    # Sddc Diagnostic Archive status
    # re-emit the warnings as such so they are well-distinguished
    $f = Join-Path $Path SddcDiagnosticArchiveJob.txt
    if (gi -ErrorAction SilentlyContinue $f) {
        Write-Host "$("-"*3)`nSddc Diagnostic Archive Status`n"
        gc $f
        $f = Join-Path $Path SddcDiagnosticArchiveJobWarn.txt
        if ((gi $f).Length) {
            gc $f |% { Show-Warning $_ }
        }
        Write-Host $("-"*3)
    }

    #
    # Cluster status
    #

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

    # Storage subsystem health
    $Subsystem = Import-Clixml (Join-Path $Path "GetStorageSubsystem.XML")

    $SubsystemUnhealthy = $false
    if ($Subsystem -eq $null) {
        Show-Warning "No clustered storage subsystem present"
    } elseif ($Subsystem.HealthStatus -notlike "Healthy") {
        $SubsystemUnhealthy = $true
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

    #
    # Start the component/object count-out.
    #

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

    # Cluster shared volume status

    $CSV = Import-Clixml (Join-Path $Path "GetClusterSharedVolume.XML")

    $CSVTotal = NCount($CSV)
    $CSVHealthy = NCount($CSV |? State -like "Online")
    Write-Host "Cluster Shared Volumes Online : $CSVHealthy / $CSVTotal"
    if ($CSVHealthy -lt $CSVTotal) { Show-Warning "Offline cluster shared volumes detected" }

    # Volume health

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

    $StoragePools = @(Import-Clixml (Join-Path $Path "GetStoragePool.XML"))

    $PoolsTotal = NCount($StoragePools)
    $PoolsHealthy = NCount($StoragePools |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Storage Pools Healthy         : $PoolsHealthy / $PoolsTotal "

    if ($S2DEnabled -and $StoragePools.Count -ne 1) {
        Show-Warning "S2D is enabled but the number of non-primordial pools $($StoragePools.Count) != 1"
    }

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

    if ($SubsystemUnhealthy) {
        Write-Host "Clustered storage subsystem '$($Subsystem.FriendlyName)' not healthy:"
        Import-Clixml (Join-Path $Path "DebugStorageSubsystem.XML") | ft -AutoSize
    }

    if ($CSVTotal -ne $CSVHealthy) { 
        $Failed = $true
        Write-Host "Cluster Shared Volumes not Online:"
        $CSV |? State -ne "Online" | Format-Table -AutoSize 
    }

    if ($VolsTotal -ne $VolsHealthy) { 
        $Failed = $true
        Write-Host "Cluster Shared Volumes not Healthy:"
        $Volumes |? { ($_.HealthStatus -notlike "Healthy") -and ($_.HealthStatus -ne 0) } | 
        Format-Table Path,HealthStatus -AutoSize
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
    Show extended reports based on storage latency information collected from Get-SddcDiagnosticInfo.

.DESCRIPTION
    Show extended reports based on storage latency information collected from Get-SddcDiagnosticInfo.

.PARAMETER Path
    Path to the the logs produced by Get-SddcDiagnosticInfo. This may be a ZIP or a directory
    containing previously unzipped content. If ZIP, it will be unzipped to the same location
    (minus .ZIP) and will remain after reporting.

.PARAMETER ReportLevel
    Controls the level of detail in the report. By default standard reports are shown. Full
    detail may be extensive and/or more time consuming to generate.

.PARAMETER Report
    Specifies individual reports to produce. By default all reports will be shown.

.EXAMPLE
    Show-SddcDiagnosticStorageLatencyReport -Path C:\Test.ZIP -Report Summary

    Display the summary health report from the capture located in the given ZIP. The content is
    unzipped to a directory (minus the .ZIP extension) and remains after the summary health report
    is shown.

    In this example, C:\Test would be created from C:\Test.ZIP. If the .ZIP path is specified and
    the unzipped directory is present, the directory will be reused without re-unzipping the
    content.

.EXAMPLE
    Show-SddcDiagnosticStorageLatencyReport -Path C:\Test.ZIP

    Show all available reports available from this version of PrivateCloud.DiagnosticInfo, at standard
    report level.

.EXAMPLE
    Show-SddcDiagnosticStorageLatencyReport -Path C:\Test.ZIP -ReportLevel Full

    Show all avaliable reports, at full report level.
#>

function Show-SddcDiagnosticStorageLatencyReport
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

        [parameter(ParameterSetName="Days",Mandatory=$false)]
        [ValidateRange(-1,365)]
        [int]
        $Days = 8,

        [parameter(ParameterSetName="Hours",Mandatory=$true)]
        [ValidateRange(-1,72)]
        [int]
        $Hours,

        [ValidateRange(0,100000)]
        [int]
        $CutoffMs = 200
    )

    # Common header for path validation

    $Path = (gi $Path).FullName

    if (-not (Test-Path $Path)) {
        Write-Error "Path is not accessible. Please check and try again: $Path"
        return
    }

    # Extract ZIP if neccesary
    $Path = Check-ExtractZip $Path

    # get the timebase from the capture parameters
    $Parameters = Import-Clixml (Join-Path $Path "GetParameters.XML")
    $CaptureDate = $Parameters.TodayDate

    if ($Hours -eq -1 -or $Days -eq -1) {
        $HoursOfEvents = -1
    } elseif ($Hours) {
        $HoursOfEvents = $Hours
    } else {
        $HoursOfEvents = $Days * 24
    }

    Get-StorageLatencyReport -Path $Path -ReportLevel $ReportLevel -CutoffMs $CutoffMs -TimeBase $CaptureDate -HoursOfEvents $HoursOfEvents
}

<#
.SYNOPSIS
    Show diagnostic reports based on information collected from Get-SddcDiagnosticInfo.

.DESCRIPTION
    Show diagnostic reports based on information collected from Get-SddcDiagnosticInfo.

.PARAMETER Path
    Path to the the logs produced by Get-SddcDiagnosticInfo. This may be a ZIP or a directory
    containing previously unzipped content. If ZIP, it will be unzipped to the same location
    (minus .ZIP) and will remain after reporting.

.PARAMETER ReportLevel
    Controls the level of detail in the report. By default standard reports are shown. Full
    detail may be extensive and/or more time consuming to generate.

.PARAMETER Report
    Specifies individual reports to produce. By default all reports will be shown.

.EXAMPLE
    Show-SddcDiagnosticReport -Path C:\Test.ZIP -Report Summary

    Display the summary health report from the capture located in the given ZIP. The content is
    unzipped to a directory (minus the .ZIP extension) and remains after the summary health report
    is shown.

    In this example, C:\Test would be created from C:\Test.ZIP. If the .ZIP path is specified and
    the unzipped directory is present, the directory will be reused without re-unzipping the
    content.

    EQUIVALENT: Get-SddcDiagnosticInfo -ReadFromPath <ZIP or Directory>

    The file 0_CloudHealthSummary.log in the capture contains the summary report at the time the
    capture was taken. Running the report again is a re-analysis of the content, which may reflect
    new triage if PrivateCloud.DiagnosticInfo has been updated in the interim.

.EXAMPLE
    Show-SddcDiagnosticReport -Path C:\Test.ZIP

    Show all available reports available from this version of PrivateCloud.DiagnosticInfo, at standard
    report level.

.EXAMPLE
    Show-SddcDiagnosticReport -Path C:\Test.ZIP -ReportLevel Full

    Show all avaliable reports, at full report level.

.EXAMPLE
    Show-SddcDiagnosticReport -Path C:\Test.ZIP -Report StorageBusCache -ReportLevel Full

    Only show the StorageBusCache report, at full report level.
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
            { $_ -eq [ReportType]::SmbConnectivity } {
                Get-SmbConnectivityReport $Path -ReportLevel:$ReportLevel
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

New-Alias -Value Show-SddcDiagnosticReport -Name Get-PCStorageReport

Export-ModuleMember -Alias * -Function 'Get-SddcDiagnosticInfo',
    'Show-SddcDiagnosticReport',
    'Show-SddcDiagnosticStorageLatencyReport',
    'Install-SddcDiagnosticModule',
    'Confirm-SddcDiagnosticModule',
    'Register-SddcDiagnosticArchiveJob',
    'Unregister-SddcDiagnosticArchiveJob',
    'Update-SddcDiagnosticArchive',
    'Limit-SddcDiagnosticArchive',
    'Show-SddcDiagnosticArchiveJob',
    'Set-SddcDiagnosticArchiveJobParameters',
    'Get-SddcDiagnosticArchiveJobParameters'