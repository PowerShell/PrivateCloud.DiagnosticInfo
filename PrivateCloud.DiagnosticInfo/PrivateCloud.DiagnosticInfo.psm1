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
    # DcbQos is only present if the Data-Center-Bridging feature is present (for RoCE)
    # Hyper-V may be ommitted in SOFS-only configurations
    #
    # Handling of import failures in Start-Job initialization blocks is special - we
    # cannot control failure to load errors there, and need to use GM to check; neither
    # -ErrorAction nor try/catch control propagation of the errors.

    if (Get-Module -ListAvailable FailoverClusters) {
        Import-Module FailoverClusters
    }

    if (Get-Module -ListAvailable DcbQos) {
        Import-Module DcbQos
    }

    if (Get-Module -ListAvailable Hyper-V) {
        Import-Module Hyper-V
    }

    Import-Module CimCmdlets
    Import-Module NetAdapter
    Import-Module NetQos
    Import-Module SmbShare
    Import-Module SmbWitness
    Import-Module Storage

    #
    # Shows error
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

    # Wrapper for Import-Clixml which provides for basic feedback on missing/not-gathered elements
    function Import-ClixmlIf(
        [string] $Path,
        [string] $MessageIf = $null
    )
    {
        if (Test-Path $path) {
            Import-Clixml $path
        } else {
            $m = "$Path not present"
            if ($MessageIf) {
                $m = "$MessageIf : " + $m
            }
            Show-Warning $m
            $null
        }
    }

    function TimespanToString
    {
        param(
            [timespan] $TimeSpan
        )

        # Autoranging output
        if ($TimeSpan.TotalDays -ge 1)
        {
            $TimeSpan.ToString("dd\d\.hh\h\:mm\m\:ss\.f\s")
        }
        elseif ($TimeSpan.TotalHours -ge 1)
        {
            $TimeSpan.ToString("hh\h\:mm\m\:ss\.f\s")
        }
        elseif ($TimeSpan.TotalMinutes -ge 1)
        {
            $TimeSpan.ToString("mm\m\:ss\.f\s")
        }
        else
        {
            $TimeSpan.ToString("ss\.f\s")
        }
    }

    function Show-JobRuntime(
        [object[]] $jobs,
        [hashtable] $namehash,
        [switch] $Running
        )
    {
        # accumulate status lines as we go
        $job_running = @()
        $job_done = @()

        $jobs | Sort-Object Name,Location |% {

            $this = $_

            # crack parents to children
            # map children to names through the input namehash
            switch ($_.GetType().Name) {

                'PSRemotingJob' {
                    $jobname = $this.Name
                    $j = $this.ChildJobs | Sort-Object Location
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

            # Only show running jobs? Skip non-running.
            if (-not $Running) {
                $j |? State -ne Running |% {
                    $job_done += "$($_.State): $($jobname) [$($_.Name) $($_.Location)]: $(TimespanToString ($_.PSEndTime - $_.PSBeginTime)) : Start $($_.PSBeginTime.ToString('s')) - Stop $($_.PSEndTime.ToString('s'))"
                }
            }

            # And now running jobs (always).
            $t = get-date
            $j |? State -eq Running |% {
                $job_running += "Running: $($jobname) [$($_.Name) $($_.Location)]: $(TimespanToString ($t - $_.PSBeginTime)) : Start $($_.PSBeginTime.ToString('s'))"
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
                Show-JobRuntime $jwait $jhash -Running
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
        # Build time-based event filter as needed
        $QTime = $null
        if ($Hours -ne -1) {
            $MSecs = $Hours * 60 * 60 * 1000
            $QTime = "*[System[TimeCreated[timediff(@SystemTime) <= "+$MSecs+"]]]"
        }

        # Exclude verbose/lower value channels and ones which are captured in different ways (e.g., cluster log)
        $LogToExclude = 'Microsoft-Windows-FailoverClustering/Diagnostic',          # cluster log
                        'Microsoft-Windows-FailoverClustering/DiagnosticVerbose',   # cluster log
                        'Microsoft-Windows-FailoverClustering-Client/Diagnostic',
                        'Microsoft-Windows-Health/Diagnostic',                      # cluster log -health
                        'Microsoft-Windows-Health/DiagnosticVerbose',               # cluster log -health
                        'Microsoft-Windows-PowerShell/Operational',                 # temporary 210930 (archive inflation)
                        'Microsoft-Windows-StorageReplica/Performance',             # large / not needed
                        'Microsoft-Windows-StorageSpaces-Driver/Performance',       # large / not needed
                        'Microsoft-Windows-SystemDataArchiver/Diagnostic',          # large / not needed
                        'Security'                                                  # potentially large/sensitive / not needed


        # Force adds in analytic/debug logs
        $providers = Get-WinEvent -Force -ListLog * -ErrorAction Ignore -WarningAction Ignore

        # Save off provider report
        $TxtPath = Join-Path $Path "GetWinEvent.txt"
        $XmlPath  = Join-Path $Path "GetWinEvent.xml"

        $providers > $TxtPath
        $providers | Export-Clixml $XmlPath

        Write-Output $TxtPath
        Write-Output $XmlPath

        # Autoscale to half of the available processors, minimum of 10
        $cs = Get-CimInstance win32_computersystem
        $jobsMax = 0
        if ($null -ne $cs) {
            $jobsMax = [int] ($cs.NumberOfLogicalProcessors / 2)
        }
        if ($jobsMax -lt 10) {
            $jobsMax = 10
        }

        # Private hash of outstanding jobs, list of job completion results
        $jobs = @{}
        $completions = @()

        function ConsumeJobs
        {
            param( [switch] $Any )

            if ($Any) {
                $jobsComplete = $jobs.Values | Wait-Job -Any
            } else {
                $jobsComplete = $jobs.Values | Wait-Job
            }
            $newCompletions = $jobsComplete | Receive-Job
            $jobsComplete | Remove-Job
            $jobsComplete |% { $jobs.Remove($_.Id) }

            return $newCompletions
        }

        foreach ($p in $providers) {

            # Analytical/Debug channels require special handling
            if ($p.LogType -in @('Analytical','Debug') -and $p.IsEnabled) {
                $directChannel = $true
            } else {
                $directChannel = $false
            }

            # Decline excluded and/or empty non-analytical/debug logs. Empty
            # can come in the form of 0 or an actual null.
            if ($LogToExclude -contains $p.LogName -or
                (($p.RecordCount -eq 0 -or $null -eq $p.RecordCount) -and
                 $directChannel -eq $false)) {
                continue
            }

            $EventFile = Join-Path $Path ($p.LogName.Replace("/","-")+".EVTX")

            if ($jobs.Count -ge $jobsMax)
            {
                # Wait for completions to free up execution slots
                $completions += ConsumeJobs -Any
            }

            $j = Start-Job -ArgumentList ($p, $EventFile, $QTime, $directChannel) {

                param( $p, $EventFile, $QTime, $directChannel )

                # analytical/debug channels can not be captured live
                # if any are encountered (not normal), disable them temporarily for export
                if ($directChannel) {
                    wevtutil sl /e:false $p.LogName
                }

                # Export log file filtered to given history limit, if specified
                $tepl = (Get-Date)
                if ($QTime) {
                    wevtutil epl $p.LogName $EventFile /q:$QTime /ow:true
                } else {
                    wevtutil epl $p.LogName $EventFile /ow:true
                }
                $tepl = (Get-Date) - $tepl

                if ($directChannel -eq $true) {
                    echo y | wevtutil sl /e:true $p.LogName | out-null
                }

                # Create locale metadata for off-system rendering
                $tal = (Get-Date)
                wevtutil al $EventFile /l:$PSCulture
                $tal = (Get-Date) - $tal

                # Emit results
                [ordered] @{
                    EventFile = $EventFile
                    LogName = $p.LogName
                    RecordCount = $p.RecordCount
                    Direct = $directChannel
                    Time = $tepl + $tal
                    TimeExport = $tepl
                    TimeArchive = $tal
                }
            }

            $jobs[$j.Id] = $j
        }

        $completions += ConsumeJobs

        # Emit event filenames to output for extraction
        if ($null -ne $completions)
        {
            $completions.EventFile
        }

        # Save event gather timings for triage/analysis
        $XmlPath = Join-Path $Path "GetWinEvent-Timing.xml"
        $completions | Export-Clixml -Path $XmlPath
        Write-Output $XmlPath

        # work around temp file leak re: archive-log/wevtsvc
        # conservatively estimate that any file older than <right now>
        # after sleeping a few seconds must be stale, so we do not stomp other
        # tools using the same functionality.
        $t = Get-Date
        Start-Sleep 5
        Get-ChildItem $env:WINDIR\ServiceProfiles\LocalService\AppData\Local\Temp |? {
            ($_.Name -like 'MSG*.tmp' -or
             $_.Name -like 'EVT*.tmp' -or
             $_.Name -like 'PUB*.tmp') -and
            $_.CreateTime -lt $t
        } | del -Force -ErrorAction SilentlyContinue
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
            Remove-Item -Force $f
        }
    }

    function Get-EventDataHash
    {
        param(
            $ev
        )

        # convert list of xmlelements into hash by element name
        $xh = @{}
        $ev.EventData.Data |% {
            $xh[$_.Name] = $_.'#text'
        }
        $xh
    }

    function NewCopyTask {
        param (
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [string]
            $Source,

            [Parameter(Mandatory = $true)]
            [switch]
            $Delete,

            [switch]
            $NoCopy
        )

        # Describe a single copy task. This is emitted by gather jobs to indicate results which
        # the gathering node should retrieve. Source paths must be UNC. NoCopy + Delete is used
        # to scrub away a capture directory.

        [Ordered] @{
            Source = $Source
            NoCopy = $NoCopy
            Delete = $Delete
        }
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
# The path is returned if valid, normalized to an absolute path if specified in
# relative form. If $null is returned it is not a valid prefix path.

function Test-PrefixFilePath
{
    param(
        [string]
        $Path
    )

    $p = $Path
    $elements = @($p -split '\\')

    # we need to tear off the last element and test the parent. before doing that,
    # need to check that we have enough path to use in the first place.
    # also check to see if we have simple cases of a usable single name

    # the last split element cannot be empty (e.g., bad: some\path\, good: some\path)
    # a single element is OK as long as it isn't a driveletter (e.g., bad: C:, good: foo)
    # unc is OK as long as we see at least 5 post-split elements (e.g., bad: \\foo, \\foo\bar, good: \\foo\bar\baz)

    $lastempty = $elements[-1] -notmatch '\S'
    $islocabs = $elements[0].Length -and $elements[0][1] -eq ':'
    $isunc = $p -like '\\*'

    if ($lastempty -or
        ($islocabs -and $elements.Count -eq 1) -or
        ($isunc -and $elements.Count -lt 5)) {
        return $null
    }

    # if not local absolute or unc, it is local relative
    # force this to local absolute by
    #    1. prepending the <driveletter>: component of the cwd if it is drive-relative absolute, starting with \
    #    2. prepending the entire cwd otherwise
    #
    # in these cases we must return the updated path to the caller

    if (-not ($islocabs -or $isunc)) {

        # local drive relative (test needed)
        if ($p[0] -eq '\') {

            # prepend the drive letter
            $p = Join-Path ((Get-Location).Path.SubString(0,2)) $p

            # drive relative single element (no test needed, return immediately) (e.g., \foo, NOT \foo\bar)
            if ($elements.Count -eq 2) {
                return $p
            }

            # ... must be multi-element (test needed)
        } else {

            # prepend cwd
            $p = Join-Path (Get-Location).Path $p

            # local single element (no test needed, return immediately)
            if ($elements.Count -eq 1) {
                return $p
            }

            # ... must be local relative multi-element (test needed)
        }

        $elements = @($p -split '\\')
    }

    # rejoin without the tail and test
    $tp = $elements[0..($elements.Count-2)] -join '\'

    # return potentially updated path, but only modify on success
    if (Test-Path $tp) {
        return $p
    }

    return $null
}

function Check-ExtractZip(
    [string] $Path
    )
{
    # If path is not a ZIP, assume it is a directory to use as-is
    if (-not $Path.ToUpper().EndsWith(".ZIP")) {
        return $Path
    }

    $ExtractToPath = $Path.Substring(0, $Path.Length - 4)

    # Already extracted?
    $f = gi $ExtractToPath -ErrorAction SilentlyContinue
    if ($f) {
        return $f.FullName
    }

    Show-Update "Extracting $Path -> $ExtractToPath"

    # Create - use compression to minimize temp footprint
    if (-not (New-Item -ItemType Directory -ErrorAction SilentlyContinue $ExtractToPath))
    {
        Show-Error("Can't create directory for extraction")
    }
    $null = compact /c $ExtractToPath

    try
    {
        Add-Type -Assembly System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $ExtractToPath)
    }
    catch
    {
        Show-Error("Can't extract results as Zip file from '$Path' to '$ExtractToPath'")
    }

    return $ExtractToPath
}

#
# Utility wrapper for copyout jobs which allows seperating ones which
# delete temporary/gathered content and ones which gather persistent
# content (like archive logs)
#

function Start-CopyJob
{
    [CmdletBinding()]
    param(
        [string]
        $Path,

        [Parameter(ValueFromPipeline = $true)]
        [object]
        $Job
    )

    process {

        foreach ($childJob in $Job.ChildJobs)
        {
            try
            {
                # Receive set of copy tasks from job - these are built by NewCopyTask
                $copy = @(Receive-Job $childJob)
                if ($copy.Count -eq 0) { continue }

                # create/use a specific job destination if present
                # ex: "foo" -> \node_xxx\foo\<rest> v. the default \node_xxx\<rest>
                $Destination = (Get-NodePath $Path $childJob.Location)
                if (Get-Member -InputObject $_ -Name Destination) {
                    $Destination = Join-Path $Destination $childJob.Destination
                    if (-not (Test-Path $Destination)) {
                        $null = mkdir $Destination -Force -ErrorAction Continue
                    }
                }

                $jobName = "Copy $($Job.Name) $($childjob.Location)"
                start-job -Name $jobName -ArgumentList $copy,$Destination {

                    param($copy,$Destination)

                    $copy |% {

                        # allow errors to propagte for triage
                        if (-not $_.NoCopy)
                        {
                            Copy-Item -Recurse $_.Source $Destination -Force -ErrorAction Continue
                        }
                        if ($_.Delete) {
                            Remove-Item -Recurse $_.Source -Force -ErrorAction Continue
                        }
                    }
                }
            }
            catch
            {
                Show-Warning("Exception in start-copyjob. `nError="+$_.Exception.Message)
            }
        }
    }
}

#
# Utility wrapper for invoking commands by opening sessions
# for each of the cluster nodes and preserving the session
# to be deleted after use.
#

function Invoke-CommonCommand (
    [string[]] $ClusterNodes = @(),
    [string] $JobName,
    [scriptblock] $InitBlock,
    [scriptblock] $ScriptBlock,
    # If session configuration name is $null, it connects to default powershell
    [string] $SessionConfigurationName,
    [Object[]] $ArgumentList
    )
{
    $Sessions = @()

    if ($ClusterNodes.Count -eq 0)
    {
        $Sessions = New-PSSession -Cn localhost -EnableNetworkAccess -ConfigurationName $SessionConfigurationName
    }
    else
    {
        $Sessions = New-PSSession -ComputerName $ClusterNodes -ConfigurationName $SessionConfigurationName
    }

    Invoke-Command -Session $Sessions $InitBlock
    Invoke-Command -Session $Sessions -AsJob -JobName $JobName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList |
        Add-Member -NotePropertyName ActiveSession -NotePropertyValue $Sessions.Id -PassThru
}

function RemoveCommonJobSession
{
    param (
        [Parameter(ValueFromPipeline = $true)]
        [object]
        $j
        )

    # Remove sessions from completed CommonCommand jobs

    process {
        if (Get-Member -InputObject $j ActiveSession)
        {
             Remove-PSSession -Id $j.ActiveSession
        }
    }
}

#
# Goes over a list of nodes and finds the first one that can access the cluster
# if none of them can access the cluster it returns nothing
#

function Get-ClusterAccessNode(
    $Nodes
)
{
    for ($i = 0; $i -lt $Nodes.count; $i++)
    {
        $Cluster = Get-Cluster $Nodes[$i].Name -ErrorAction SilentlyContinue
        if ($null -ne $Cluster)
        {
            return $Nodes[$i].Name
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
    $NodesToPing = @()
    $SuccesfullyPingedNodes = @()
    $NodesToReturn = @()

    if ($Nodes.Count) {
        $NodesToPing += $Nodes |% { New-Object -TypeName PSObject -Property @{ "Name" = $_; "State" = "Down"; "Type" = "ManuallySpecifiedMachine" }}
    }


    # Now try to contact the cluster - first via name then by every name from $Nodes.Count above if that fails, until we succesfully contact cluster
    # Add any nodes missing from $NodesToPing / Replace objects in the list with their real objects
    $ClusterNodes = $null

    if ($Cluster -ne "" -and $Cluster -ne $null)
    {
        $ClusterNodes = Get-ClusterNode -Cluster $Cluster -ErrorAction SilentlyContinue
    }

    $NodeIdx = 0;
    while ($null -eq $ClusterNodes -and $NodeIdx -lt $NodesToPing.Count)
    {
        # we failed to get it, iterate through the nodes
        $ClusterNodes = Get-ClusterNode -Cluster $NodesToPing[$NodeIdx].Name -ErrorAction SilentlyContinue

        $NodeIdx++
    }

    if ($null -ne $ClusterNodes)
    {
        if ($Nodes.Count)
        {
            # Replace their objects if found, add to list otherwise
            for ($i = 0; $i -lt $ClusterNodes.Count; $i++)
            {
                $found = $false

                for ($j = 0; $j -lt $NodesToPing.Count; $j++)
                {
                    if ($NodesToPing[$j].Name -eq $ClusterNodes[$i].Name)
                    {
                        $NodesToPing[$j] = $ClusterNodes[$i]
                        $found = $true
                        break
                    }
                }

                if ($found -ne $true)
                {
                    $NodesToPing += @($ClusterNodes[$i])
                }
            }
        }
        else
        {
            $NodesToPing = @($ClusterNodes)
        }
    }


    # Try to ping the nodes

    if ($NodesToPing.Count) {

        $PingResults = @()
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
        $PingResults += $j | Receive-Job
        $j | Remove-Job

        # For any notes that are "fake objects" (Type=Machine instead of Type=Node) mark them up
        # Copy from NodesToPing to SuccesfullyPingedNodes if they're contained in PingResults
        # Doing this because the job mutates the object
        for ($i = 0; $i -lt $PingResults.Count; $i++)
        {
            for ($j = 0; $j -lt $NodesToPing.Count; $j++)
            {
                if ($NodesToPing[$j].Name -eq $PingResults[$i].Name)
                {
                    $SuccesfullyPingedNodes += @($NodesToPing[$j])
                }
            }
        }

    }

    if ($Filter) {
        $NodesToReturn = $SuccesfullyPingedNodes
    } else {
        # unfiltered, return all
        $NodesToReturn = $NodesToPing
    }


    return $NodesToReturn
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
Temporary path to stage capture content to, prior to ZIP creation. Only use if you want output to be zipped.

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
Path for the resulting ZIP file: -<cluster>-<timestamp>.ZIP will be appended. Only use if you want output to be zipped.

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

.PARAMETER IncludeClusterPerformanceHistory
Include an Cluster Performance History report

.PARAMETER PerformanceHistoryTimeFrame
If Cluster Performance History is collected what is the time frame of collection.

.PARAMETER IncludeLiveDump
Include a live dump of the target systems

.PARAMETER IncludeStorDiag
Include a storage diagnostic log of the target systems

.PARAMETER IncludeProcessDump
Include the process dump of the default process and processlists, if present.

.PARAMETER ProcessLists
Include the process dump for these processlists (comma seperated), if present.

.PARAMETER IncludePerformance
Include a performance counter capture.

.PARAMETER IncludeReliabilityCounters
Include Storage Reliability counters. This may incur a short but observable latency cost on the
physical disks due to varying overhead in their internal handling of SMART queries.

.PARAMETER SessionConfigurationName
SessionConfigurationName to connect to other nodes in cluster.
Null if default configuration is to be used.

.PARAMETER DestPath
The destination path for output. Only use if you do not want output to be zipped.

.PARAMETER ZipFiles
Determine if output should be zipped. If false, will extract internal .cab files, as well.

.PARAMETER ExcludeLocaleMetadata
Determine if contents in "LocaleMetadata" should not be collected.

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
        [bool] $IncludePerformance = $true,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateRange(1,3600)]
        [int] $PerfSamples = 30,

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
        [switch] $SkipVM,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeHealthReport,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeClusterPerformanceHistory,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [ValidateSet('LastHour','LastDay','LastWeek','LastMonth','LastYear')]
        [string] $PerformanceHistoryTimeFrame = "LastDay",

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeLiveDump,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeStorDiag,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeProcessDump,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [string] $Processlists = "",

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [switch] $IncludeReliabilityCounters,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [string] $SessionConfigurationName = $null,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [string] $DestPath = $($env:userprofile + "\HealthTest"),

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [bool] $ZipFiles = $true,

        [parameter(ParameterSetName="WriteC", Mandatory=$false)]
        [parameter(ParameterSetName="WriteN", Mandatory=$false)]
        [bool] $ExcludeLocaleMetadata = $false
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

    if (-not (Get-Module -ListAvailable FailoverClusters)) {
        Show-Error("Cluster PowerShell not available. Download the Windows Failover Clustering RSAT tools.")
    }

    function StartMonitoring {
        Show-Update "Entered continuous monitoring mode. Storage Infrastucture information will be refreshed every 3-6 minutes" -ForegroundColor Yellow
        Show-Update "Press Ctrl + C to stop monitoring" -ForegroundColor Yellow

        try { $ClusterName = (Get-Cluster -Name $ClusterName).Name }
        catch { Show-Error("Cluster could not be contacted. `nError="+$_.Exception.Message) }

        $NodeList = Get-NodeList -Cluster $ClusterName -Filter

        $AccessNode = Get-ClusterAccessNode @($NodeList)

        if ($null -ne $AccessNode)
        {
            $AccessNode = $AccessNode + "." + (Get-Cluster -Name $AccessNode).Domain
        }

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
    if (-not (Test-PrefixFilePath ([ref] $ZipPrefix))) {
        Write-Error "$ZipPrefix is not a valid prefix for ZIP: $ZipPrefix.ZIP must be creatable"
        return
    }

    if ($ZipFiles)
    {
        if ($PSBoundParameters.ContainsKey("DestPath"))
        {
            Write-Error "Can't use DestPath parameter if ZipFiles parameter is true"
            return
        }
    }
    else
    {
        if ($PSBoundParameters.ContainsKey("TemporaryPath"))
        {
            Write-Error "Can't use TemporaryPath parameter if ZipFiles parameter is false"
            return
        }
        if ($PSBoundParameters.ContainsKey("ZipPrefix"))
        {
            Write-Error "Can't use ZipPrefix parameter if ZipFiles parameter is false"
            return
        }
    }

    #
    # Veriyfing path
    #

    if ($ReadFromPath -ne "") {
        $Path = $ReadFromPath
        $Read = $true
    } else {
        if ($ZipFiles)
        {
            $Path = $TemporaryPath
        }
        else
        {
            $Path = $DestPath
        }

        $Read = $false
    }

    if ($Read) {
        $Path = Check-ExtractZip $Path
    } else {
        # Scrub any existing and create new - use compression to minimize temp footprint
        Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse | Out-Null
        New-Item -ItemType Directory -ErrorAction SilentlyContinue $Path | Out-Null
        $null = compact /c $Path
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
        Start-Transcript -Path $transcriptFile -Force
    } catch {
        # show error and rethrow to terminate
        Show-Error "Unable to start transcript at $transcriptFile" $_
        throw $_
    }

    # Asynch gather job lists
    $JobStatic = @()
    $JobGather = @()

    try {

        Show-Update "Write path : $Path"

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
        $AccessNode = Get-ClusterAccessNode @($ClusterNodes)

        #
        # Get-Cluster
        #

        try {
            # discover name if called with default dot form and/or node list
            if ($ClusterName -eq ".") {
                foreach ($cn in $ClusterNodes)
                {
                    $Cluster = Get-Cluster -Name $cn.Name -ErrorAction SilentlyContinue
                    if ($null -ne $Cluster) { break }
                }
            } else {
                $Cluster = Get-Cluster -Name $ClusterName
            }
        }
        catch { Show-Error("Cluster could not be contacted. `nError="+$_.Exception.Message) }

        if ($null -ne $Cluster)
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
            Show-Warning "Cluster service was not running on any node, some information will be unavailable"
            $ClusterName = ''
            $ClusterDomain = ''

            Write-Host "Cluster name               : Unavailable, Cluster is not online on any node"
        }
        Write-Host ("Accessible Node List	   : " + [string]::Join(", ",$ClusterNodes.name))
        Write-Host "Access node                : $AccessNode`n"

        # Create node-specific directories for content

        $ClusterNodes.Name |% {
            md (Get-NodePath $Path $_) | Out-Null
        }

        #
        # Verify deduplication prerequisites on access node.
        #

        $DedupEnabled = $true
        if ($(Invoke-Command -ComputerName $AccessNode -ConfigurationName $SessionConfigurationName {(-not (Get-Command -Module Deduplication))} )) {
            $DedupEnabled = $false
        }

        ####
        # Begin paralellized captures.
        ####

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

                $j = Invoke-CommonCommand -ClusterNodes $ClusterNodes.Name -JobName SddcDiagnosticArchive -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc {

                    Import-Module $using:Module -ErrorAction SilentlyContinue

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

                            # Copy but do not scrub the archive!
                            NewCopyTask -Delete:$false (Get-AdminSharePathFromLocal $env:COMPUTERNAME $_)
                        }
                    }
                }

                # since the archive directory is configurable, we always need to specify the
                # destination within the capture - it may be \some\dir\foo, but we want it to be
                # node_xxx\SddcDiagnosticArchive in the capture.
                $j.ChildJobs |% {
                    $_ | Add-Member -NotePropertyName Destination -NotePropertyValue SddcDiagnosticArchive
                }

                $JobGather += $j
            }
        }

        if ($AccessNode) {

            Show-Update "Start gather of cluster configuration ..."

            $JobStatic += start-job -Name ClusterGroup {
                try {
                    Get-ClusterGroup -Cluster $using:AccessNode |
                    Export-Clixml ($using:Path + "GetClusterGroup.XML")
                }
                catch { Show-Warning("Unable to get Cluster Groups. `nError="+$_.Exception.Message) }
            }

            $JobStatic += start-job -Name ClusterNetwork {
                try {
                    Get-ClusterNetwork -Cluster $using:AccessNode |
                    Export-Clixml ($using:Path + "GetClusterNetwork.XML")
                }
                catch { Show-Warning("Could not get Cluster Nodes. `nError="+$_.Exception.Message) }
            }

            $JobStatic += start-job -Name ClusterResource {
                try {
                    Get-ClusterResource -Cluster $using:AccessNode |
                    Export-Clixml ($using:Path + "GetClusterResource.XML")
                }
                catch { Show-Warning("Unable to get Cluster Resources.  `nError="+$_.Exception.Message) }
            }

            $JobStatic += start-job -Name ClusterResourceParameter {
                try {
                    Get-ClusterResource -Cluster $using:AccessNode | Get-ClusterParameter |
                    Export-Clixml ($using:Path + "GetClusterResourceParameters.XML")
                }
                catch { Show-Warning("Unable to get Cluster Resource Parameters.  `nError="+$_.Exception.Message) }
            }

            $JobStatic += start-job -Name ClusterSharedVolume {
                try {
                    Get-ClusterSharedVolume -Cluster $using:AccessNode |
                    Export-Clixml ($using:Path + "GetClusterSharedVolume.XML")
                }
                catch { Show-Warning("Unable to get Cluster Shared Volumes.  `nError="+$_.Exception.Message) }
            }

            $JobStatic += start-job -Name ClusterQuorum {
                try {
                    Get-ClusterQuorum -Cluster $using:AccessNode |
                    Export-Clixml ($using:Path + "GetClusterQuorum.XML")
                }
                catch { Show-Warning("Unable to get Cluster Quorum.  `nError="+$_.Exception.Message) }
            }

            $JobStatic += start-job -Name CauDebugTrace {
                try {
                    if ($executionContext.SessionState.LanguageMode -eq "FullLanguage")
                    {
                        # SCDT returns a fileinfo object for the saved ZIP on the pipeline; discard (allow errors/warnings to flow as normal)
                        $parameters = (Get-Command Save-CauDebugTrace).Parameters.Keys
                        if ($parameters -contains "FeatureUpdateLogs") {
                            $null = Save-CauDebugTrace -Cluster $using:AccessNode -FeatureUpdateLogs All -FilePath $using:Path
                        }
                        else {
                            $null = Save-CauDebugTrace -Cluster $using:AccessNode -FilePath $using:Path
                        }
                    }
                    else
                    {
                        Write-Host "Skipping CauDebugTrace because cannot run Save-CAUDebugTrace in constrained language mode."
                    }
                }
                catch { Write-Warning("Unable to get CAU debug trace.  `nError="+$_.Exception.Message) }
            }

        } else {
            Show-Update "... Skip gather of cluster configuration since cluster is not available"
        }

        if ($IncludeClusterPerformanceHistory) {

            Show-Update "Starting ClusterPerformanceHistory log collection ..."

            $JobStatic += start-job -Name ClusterPerformanceHistory {
                try {
                    Get-Clusterlog -ExportClusterPerformanceHistory -Destination $using:Path -PerformanceHistoryTimeFrame $using:PerformanceHistoryTimeFrame -Node $using:ClusterNodes.Name
                }
                catch { Show-Warning("Could not get ClusterPerformanceHistory. `nError="+$_.Exception.Message) }
            }
        }

        Show-Update "Start gather of driver information ..."

        $ClusterNodes.Name |% {

            $node = $_

            $JobStatic += start-job -Name "Driver Information: $node" {
                try { $o = Get-CimInstance -ClassName Win32_PnPSignedDriver -ComputerName $using:node }
                catch { Show-Error("Unable to get Drivers on $using:node. `nError="+$_.Exception.Message) }
                $o | Export-Clixml (Join-Path (Join-Path $using:Path "Node_$using:node") "GetDrivers.XML")
            }
        }

        # consider using this as the generic copyout job set
        # these are gathers which are not remotable, which we run remote and copy back results for
        # keep control of which gathers are fast and therefore for which serialization is not a major issue
        # however, dividing these into distinct jobs helps when triaging hangs or sources of error - its a tradeoff

        Show-Update "Start gather of verifier ..."
        $JobGather += Invoke-CommonCommand -ClusterNodes $($ClusterNodes).Name -JobName Verifier -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc {

            # Verifier

            try
            {
                $LocalFile = Join-Path $env:temp "verifier-query.txt"
                verifier /query > $LocalFile
                NewCopyTask -Delete (Get-AdminSharePathFromLocal $env:COMPUTERNAME $LocalFile)

                $LocalFile = Join-Path $env:temp "verifier-querysettings.txt"
                verifier /querysettings > $LocalFile
                NewCopyTask -Delete  (Get-AdminSharePathFromLocal $env:COMPUTERNAME $LocalFile)
            }
            catch
            {
                Show-Warning("Exception in verifier script block.  `nError="+$_.Exception.Message)
            }

        }

        Show-Update "Start gather of filesystem filter status ..."

        $JobGather += Invoke-CommonCommand -ClusterNodes $($ClusterNodes).Name -JobName 'Filesystem Filter Manager' -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc {

            # Filter Manager
            try
            {
                $LocalFile = Join-Path $env:temp "fltmc.txt"
                fltmc > $LocalFile
                NewCopyTask -Delete  (Get-AdminSharePathFromLocal $env:COMPUTERNAME $LocalFile)

                $LocalFile = Join-Path $env:temp "fltmc-instances.txt"
                fltmc instances > $LocalFile
                NewCopyTask -Delete  (Get-AdminSharePathFromLocal $env:COMPUTERNAME $LocalFile)
            }
            catch
            {
                Show-Warning("Exception in filter manager script block.  `nError="+$_.Exception.Message)
            }

        }

        $JobGather += Invoke-CommonCommand -ClusterNodes $($ClusterNodes).Name -JobName 'Copy WER ReportArchive' -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc {

            try
            {
                # ReportArchive copy (one-shot, we'll recursively copy)

                NewCopyTask -Delete:$false (Get-AdminSharePathFromLocal $env:COMPUTERNAME $env:ProgramData\Microsoft\Windows\WER\ReportArchive)
            }
            catch
            {
                Show-Warning("Exception in Copy WER ReportArchive script block.  `nError="+$_.Exception.Message)
            }

        }

        if ($IncludeDumps -eq $true) {

            $JobGather += Invoke-CommonCommand -ClusterNodes $($ClusterNodes).Name -JobName 'Copy ReportQueue' -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc {

                # ReportQueue copy (one-shot, we'll recursively copy)

                NewCopyTask -Delete:$false (Get-AdminSharePathFromLocal $env:COMPUTERNAME $env:ProgramData\Microsoft\Windows\WER\ReportQueue)
            }
        }

        if ($IncludeProcessDump) {

            $JobGather += Invoke-CommonCommand -ClusterNodes $($ClusterNodes).Name -JobName ProcessDumps -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc -ArgumentList $ProcessLists {

                Param($ProcessLists)

                $NodePath = $env:Temp
                $Node = $env:COMPUTERNAME

                #Default dump processes.
                $DumpProcesses = @("vmms", "vmcompute", "vmwp", "rhs", "clussvc")

                #Appending user passed process lists.
                if ($null -ne $ProcessLists) {
                    $DumpProcesses += $ProcessLists.split(",")
                }

                $DumpFileFolder = Join-Path -Path $NodePath -ChildPath 'ProcessDumps'

                if (Test-Path -Path $DumpFileFolder) {
                    Remove-Item -Path $DumpFileFolder -Recurse -Force
                }

                $null = New-Item -Path $DumpFileFolder -ItemType Directory
                $WER = [PSObject].Assembly.GetType('System.Management.Automation.WindowsErrorReporting')
                $NativeMethods = $WER.GetNestedType('NativeMethods', 'NonPublic')
                $MiniDump = $NativeMethods.GetMethod('MiniDumpWriteDump', ([Reflection.BindingFlags]'NonPublic, Static'))
                $MiniDumpWithFullMemory = [UInt32] 2
                $ProcessList = @{}

                foreach ($ProcessName in $DumpProcesses) {

                    $ProcessIds = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id

                    if (-not $ProcessIds) {
                        Show-Warning "Could not generate minidump for process $ProcessName"
                        continue;
                    }

                    foreach ($ProcessId in $ProcessIds) {

                        #Already collected.
                        if ($ProcessList[$ProcessId]) {
                            continue;
                        }

                        $ProcessList.Add($ProcessId, $ProcessName)

                        $Process = Get-Process -Id $ProcessId
                        $ProcessId = $Process.Id
                        $ProcessHandle = $Process.Handle
                        $DumpFileName = "$($ProcessName)_$($ProcessId).dmp"

                        $DumpFilePath = Join-Path $DumpFileFolder $DumpFileName

                        $DumpFile = New-Object IO.FileStream($DumpFilePath, [IO.FileMode]::Create)

                        $Result = $MiniDump.Invoke($null, @($ProcessHandle,        #hProcess
                                                            $ProcessId,                #ProcessId
                                                            $DumpFile.SafeFileHandle,  #hFile
                                                            $MiniDumpWithFullMemory    #DumpType
                                                            [IntPtr]::Zero,            #ExceptionParam
                                                            [IntPtr]::Zero,            #UserStreamParam
                                                            [IntPtr]::Zero))           #CallbackParam

                        $DumpFile.Close()

                        if(-not $Result) {
                            Show-Warning "Failed to write dump file for process $psname with PID $ProcessId."
                            Remove-Item $DumpFilePath
                        } else {
                            NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node $DumpFilePath)
                        }
                    }
                }
            }
        }

        if ($IncludeGetNetView) {

            Show-Update "Start gather of Get-NetView ..."
            $GetNetViewArguments = @($SkipVM, $ZipFiles)

            $JobGather += Invoke-CommonCommand -ArgumentList $GetNetViewArguments -ClusterNodes $($ClusterNodes).Name -JobName 'GetNetView' -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc {

                Param($SkipVM,$ZipFiles)
                try
                {
                    $NodePath = $env:Temp

                    # create a directory to capture GNV

                    $gnvDir = Join-Path $NodePath 'GetNetView'
                    Remove-Item -Recurse -Force $gnvDir -ErrorAction SilentlyContinue
                    $null = md $gnvDir -Force -ErrorAction SilentlyContinue

                    # run inside a child session so we can sink output to the transcript
                    # we must pass the GNV dir since $using is statically evaluated in the
                    # outermost scope and $gnvDir is inside the Invoke call.

                    $j = Start-Job -ArgumentList $gnvDir,$SkipVM {

                        param($gnvDir,$SkipVM)

                        # start gather transcript to the GNV directory

                        $transcriptFile = Join-Path $gnvDir "0_GetNetViewGatherTranscript.log"
                        Start-Transcript -Path $transcriptFile -Force

                        if (Get-Command Get-NetView -ErrorAction SilentlyContinue) {
                            if ($SkipVM) {
                                Get-NetView -OutputDirectory $gnvDir -SkipLogs -SkipVM
                            } else {
                                Get-NetView -OutputDirectory $gnvDir -SkipLogs
                            }
                        } else {
                            Write-Host "Get-NetView command not available"
                        }

                        Stop-Transcript
                    }

                    # do not receive job - sunk to transcript for offline analysis
                    # gnv produces a very large quantity of host output
                    $null = $j | Wait-Job
                    $j | Remove-Job


                    # If chose to zip files, wipe all non-file content (gnv produces zip + uncompressed dir, don't need the dir)
                    if ($ZipFiles)
                    {
                       Write-Host "User selected to zip output. Remove uncompressed directory msdbg"
                        dir $gnvDir -Directory |% {
                            Remove-Item -Recurse -Force $_.FullName
                        }
                    }
                    else
                    {
                        # if not zipping content, keep the uncompressed dir to copy later, and remove the zipped directory
                        Write-Host "User selected not to zip output. Remove compressed directory msdbg*.zip"
                        Get-ChildItem -Path $gnvDir -Filter 'msdbg*.zip' | Remove-Item
                    }

                    # gather all remaining content (will be the zip + transcript) in GNV directory
                    NewCopyTask -Delete (Get-AdminSharePathFromLocal $env:COMPUTERNAME $gnvDir)
                }
                catch
                {
                    Show-Warning("Exception in GetNetView script block.  `nError="+$_.Exception.Message)
                }

            }
        }

        # Events, cmd, reports, et.al.
        Show-Update "Start gather of system info, cluster/netft/health logs, reports and dump files ..."

        $JobStatic += Start-Job -Name ClusterLogs {
            $null = Get-ClusterLog -Node $using:ClusterNodes.Name -Destination $using:Path -UseLocalTime
            $parameters = (Get-Command Get-ClusterLog).Parameters.Keys
            if ($parameters -contains "NetFt")
            {
                $null = Get-ClusterLog -Node $using:ClusterNodes.Name -Destination $using:Path -UseLocalTime -Netft
            }
        }

        if ($S2DEnabled) {
            $JobStatic += Start-Job -Name ClusterHealthLogs {
                $null = Get-ClusterLog -Node $using:ClusterNodes.Name -Destination $using:Path -Health -UseLocalTime
            }
        }

        $JobStatic += $ClusterNodes.Name |% {

            $NodeName = $_

            Invoke-CommonCommand -JobName "System Info: $NodeName" -InitBlock $CommonFunc -SessionConfigurationName $SessionConfigurationName -ScriptBlock {
                try
                {
                    $Node = "$using:NodeName"
                    if ($using:ClusterDomain.Length) {
                        $Node += ".$using:ClusterDomain"
                    }

                    $LocalNodeDir = Get-NodePath $using:Path $using:NodeName

                    # Text-only conventional commands
                    #
                    # Gather SYSTEMINFO.EXE output for a given node
                    SystemInfo.exe /S $using:NodeName > (Join-Path (Get-NodePath $using:Path $using:NodeName) "SystemInfo.TXT")

                # Cmdlets to drop in TXT and XML forms
                #
                # cmd is of the form "cmd arbitraryConstantArgs -argForComputerOrSessionSpecification"
                # will be trimmed to "cmd" for logging
                # _A_ token will be replaced with the chosen cluster access node
                # _C_ token will be replaced with node fqdn for cimsession/computername callouts
                # _N_ token will be replaced with node non-fqdn
                $CmdsToLog =
                            @{ C = 'Get-CimInstance -ComputerName _C_ Win32_Bios'; F = 'Win32_Bios' },
                            @{ C = 'Get-CimInstance -ComputerName _C_ Win32_ComputerSystem'; F = 'Win32_ComputerSystem' },
                            @{ C = 'Get-CimInstance -ComputerName _C_ Win32_OperatingSystem'; F = 'Win32_OperatingSystem' },
                            @{ C = 'Get-CimInstance -ComputerName _C_ Win32_PhysicalMemory'; F = 'Win32_PhysicalMemory' },
                            @{ C = 'Get-CimInstance -ComputerName _C_ Win32_Processor'; F = 'Win32_Processor' },
                            @{ C = 'Get-HotFix -ComputerName _C_'; F = $null },
                            @{ C = 'Get-NetAdapter -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterAdvancedProperty -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterBinding -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterChecksumOffload -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterIPsecOffload -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterLso -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterPacketDirect -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterRdma -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterRsc -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterRss -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetAdapterVmq -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetIPv4Protocol -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetIPv6Protocol -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetIpAddress -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetLbfoTeam -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetLbfoTeamMember -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetLbfoTeamNic -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetOffloadGlobalSetting -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetPrefixPolicy -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetQosPolicy -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetRoute -CimSession _C_'; F = $null },
                            @{ C = 'Get-Disk -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetTcpConnection -CimSession _C_'; F = $null },
                            @{ C = 'Get-NetTcpSetting -CimSession _C_'; F = $null },
                            @{ C = 'Get-ScheduledTask -CimSession _C_ | Get-ScheduledTaskInfo -CimSession _C_'; F = $null },
                            @{ C = 'Get-SmbClientConfiguration -CimSession _C_'; F = $null },
                            @{ C = 'Get-SmbClientNetworkInterface -CimSession _C_'; F = $null },
                            @{ C = 'Get-SmbMultichannelConnection -IncludeNotSelected -SmbInstance Default -CimSession _C_'; F = 'GetSmbMultichannelConnection-Default' },
                            @{ C = 'Get-SmbMultichannelConnection -IncludeNotSelected -SmbInstance CSV -CimSession _C_'; F = 'GetSmbMultichannelConnection-CSV' },
                            @{ C = 'Get-SmbMultichannelConnection -IncludeNotSelected -SmbInstance SBL -CimSession _C_'; F = 'GetSmbMultichannelConnection-SBL' },
                            @{ C = 'Get-SmbMultichannelConnection -IncludeNotSelected -SmbInstance SR -CimSession _C_'; F = 'GetSmbMultichannelConnection-SR' },
                            @{ C = 'Get-SmbServerConfiguration -CimSession _C_'; F = $null },
                            @{ C = 'Get-SmbServerNetworkInterface -CimSession _C_'; F = $null },
                            @{ C = 'Get-StorageFaultDomain -CimSession _A_ -Type StorageScaleUnit |? FriendlyName -eq _N_ | Get-StorageFaultDomain -CimSession _A_'; F = $null },
                            @{ C = 'Get-WindowsFeature -ComputerName _C_'; F = $null }

                    # These commands are specific to optional modules, add only if present
                    #   - DcbQos: RoCE environments primarily
                    #   - Hyper-V: may be ommitted in SOFS-only cases
                    if (Get-Module DcbQos -ErrorAction SilentlyContinue) {
                        $CmdsToLog +=
                                @{ C = 'Get-NetQosDcbxSetting -CimSession _C_'; F = $null },
                                @{ C = 'Get-NetQosFlowControl -CimSession _C_'; F = $null },
                                @{ C = 'Get-NetQosTrafficClass -CimSession _C_'; F = $null }
                    }

                    if (Get-Module Hyper-V -ErrorAction SilentlyContinue) {
                        $CmdsToLog +=
                                @{ C = 'Get-VM -CimSession _C_ -ErrorAction SilentlyContinue'; F = $null },
                                @{ C = 'Get-VMNetworkAdapter -All -CimSession _C_ -ErrorAction SilentlyContinue'; F = $null },
                                @{ C = 'Get-VMSwitch -CimSession _C_ -ErrorAction SilentlyContinue'; F = $null }
                    }

                    foreach ($cmd in $CmdsToLog) {

                        $cmdstr = $cmd.C
                        $file = $cmd.F

                        # Default rule: base cmdlet name no dash
                        if ($null -eq $file) {
                            $LocalFile = (Join-Path $LocalNodeDir (($cmdstr.split(' '))[0] -replace "-",""))
                        } else {
                            $LocalFile = (Join-Path $LocalNodeDir $file)
                        }

                        try {

                            $cmdex = $cmdstr -replace '_C_',$using:NodeName -replace '_N_',$using:NodeName -replace '_A_',$using:AccessNode
                            $out = iex $cmdex

                            # capture as txt and xml for quick analysis according to taste
                            $out | ft -AutoSize | Out-File -Width 9999 -Encoding ascii -FilePath "$LocalFile.txt"
                            $out | Export-Clixml -Path "$LocalFile.xml"

                        } catch {
                            Show-Warning "'$cmdex' failed for node $Node ($($_.Exception.Message))"
                        }
                    }

                    $NodeSystemRootPath = Invoke-Command -ComputerName $using:NodeName -ConfigurationName $using:SessionConfigurationName { $env:SystemRoot }

                    # Avoid to use 'Join-Path' because the drive of path may not exist on the local machine.
                    if ($using:IncludeDumps -eq $true) {

                        $NodeMinidumpsPath = Invoke-Command -ComputerName $using:NodeName -ConfigurationName $using:SessionConfigurationName { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl').MinidumpDir } -ErrorAction SilentlyContinue
                        $NodeLiveKernelReportsPath = Invoke-Command -ComputerName $using:NodeName -ConfigurationName $using:SessionConfigurationName { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl\LiveKernelReports').LiveKernelReportsPath } -ErrorAction SilentlyContinue
                        ##
                        # Minidumps
                        ##

                        try {
                            # Use the registry key value if it exists.
                            if ($NodeMinidumpsPath) {
                                $RPath = (Get-AdminSharePathFromLocal $using:NodeName "$NodeMinidumpsPath\*.dmp")
                            }
                            else {
                                $RPath = (Get-AdminSharePathFromLocal $using:NodeName "$NodeSystemRootPath\Minidump\*.dmp")
                            }

                            $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue
                        }
                        catch { $DmpFiles = ""; Show-Warning "Unable to get minidump files for node $using:NodeName" }

                        $DmpFiles |% {
                            try { Copy-Item $_.FullName $LocalNodeDir }
                            catch { Show-Warning("Could not copy minidump file $_.FullName") }
                        }

                        ##
                        # Live Kernel Reports
                        ##

                        try {
                            # Use the registry key value if it exists.
                            if ($NodeLiveKernelReportsPath) {
                                $RPath = (Get-AdminSharePathFromLocal $using:NodeName "$NodeLiveKernelReportsPath\*.dmp")
                            }
                            else {
                                $RPath = (Get-AdminSharePathFromLocal $using:NodeName "$NodeSystemRootPath\LiveKernelReports\*.dmp")
                            }

                            $DmpFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue
                        }
                        catch { $DmpFiles = ""; Show-Warning "Unable to get LiveKernelReports files for node $using:NodeName" }

                        $DmpFiles |% {
                            try { Copy-Item $_.FullName $LocalNodeDir }
                            catch { Show-Warning "Could not copy LiveKernelReports file $($_.FullName)" }
                        }
                    }

                    try {
                        $RPath = (Get-AdminSharePathFromLocal $using:NodeName "$NodeSystemRootPath\Cluster\Reports\*.*")
                        $RepFiles = Get-ChildItem -Path $RPath -Recurse -ErrorAction SilentlyContinue }
                    catch { $RepFiles = ""; Show-Warning "Unable to get reports for node $using:NodeName" }

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
                catch
                {
                    Show-Warning("Exception in System Info: NodeName $node  `nError="+$_.Exception.Message)
                }
            }
        }

        Show-Update "Starting export diagnostic log and live dump ..."

        $JobGather += Invoke-CommonCommand -ArgumentList $IncludeLiveDump,$IncludeStorDiag -ClusterNodes $AccessNode -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc -JobName StorageDiagnosticInfoAndLiveDump {

            Param($IncludeLiveDump,$IncludeStorDiag)
            try
            {
                $Node = $env:COMPUTERNAME
                $NodePath = $env:Temp

                $destinationPath = Join-Path -Path $NodePath -ChildPath 'StorageDiagnosticDump'

                if (Test-Path -Path $destinationPath) {
                    Remove-Item -Path $destinationPath -Recurse -Force
                }

                $clusterSubsystem = (Get-StorageSubSystem |? Model -eq 'Clustered Windows Storage').FriendlyName

                if ($IncludeLiveDump) {
                    Get-StorageDiagnosticInfo -StorageSubSystemFriendlyName $clusterSubsystem -IncludeLiveDump -DestinationPath $destinationPath

                    # Copy storage diagnostic and live dump information (one-shot, we'll recursively copy)
                    NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node $destinationPath)
                }
                elseif ($IncludeStorDiag) {
                    Get-StorageDiagnosticInfo -StorageSubSystemFriendlyName $clusterSubsystem -DestinationPath $destinationPath

                    # Copy storage diagnostic and live dump information (one-shot, we'll recursively copy)
                    NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node $destinationPath)
                }
            }
            catch
            {
                 Show-Warning("Exception in StorageDiagnosticInfoAndLiveDump  `nError="+$_.Exception.Message)
            }
        }

        Show-Update "Starting export of events ..."
        $EventsArguments = @($HoursOfEvents, $ExcludeLocaleMetadata)
        $JobGather += Invoke-CommonCommand -ArgumentList $EventsArguments -ClusterNodes $($ClusterNodes).Name -SessionConfigurationName $SessionConfigurationName -InitBlock $CommonFunc -JobName Events {

            Param([int] $Hours,[bool] $ExcludeLocaleMetadata)
            try
            {
                $Node = $env:COMPUTERNAME

                # use temporary directory with compression on to minimize capture footprint
                $NodePath = New-TemporaryFile
                Remove-Item $NodePath
                $null = New-Item -ItemType Directory $NodePath
                $null = compact /c $NodePath

                # Flatten the captured events + local metadata into the per-node directory on the gatherer
                Get-SddcCapturedEvents $NodePath $Hours |% {
                    NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node $_)
                }

                if ($ExcludeLocaleMetadata)
                {
                    NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node (Join-Path $NodePath "LocaleMetaData")) -NoCopy
                }
                else
                {
                    NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node (Join-Path $NodePath "LocaleMetaData"))
                }

                # And remove the capture directory at the end of copy
                NewCopyTask -Delete (Get-AdminSharePathFromLocal $Node $NodePath) -NoCopy
            }
            catch
            {
                Show-Warning("Exception in JobName Events  `nError="+$_.Exception.Message)
            }
        }

        if ($IncludeAssociations -and $ClusterName.Length) {

            # This is used at Phase 2 and is run asynchronously since
            # it can take some time to gather for large numbers of devices.

            # Gather nodes view of storage and build all the associations

            $SNVJob = Start-Job -Name 'StorageNodePhysicalDiskView' -ArgumentList $ClusterName {
            param ($ClusterName)
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

        Show-Update "SMB Share Open Files"

        try {
            $o = Get-SmbOpenFile -CimSession $AccessNode
            $o | Export-Clixml ($Path + "GetSmbOpenFile.XML") }
        catch { Show-Error("Unable to get SMB open files. `nError="+$_.Exception.Message) }

        Show-Update "SMB Share Witness"

        try {
            $o = Get-SmbWitnessClient -CimSession $AccessNode
            $o | Export-Clixml ($Path + "GetSmbWitness.XML") }
        catch { Show-Error("Unable to get SMB Witness state. `nError="+$_.Exception.Message) }

        Show-Update "Clustered Subsystem"

        # NOTE: $Subsystem is reused several times below
        try {
            $Subsystem = Get-StorageSubsystem Cluster* -CimSession $AccessNode
            $Subsystem | Export-Clixml ($Path + "GetStorageSubsystem.XML")
        }
        catch { Show-Warning("Unable to get Clustered Subsystem.`nError="+$_.Exception.Message) }

        # Automatic triage is dependent on the cluster (Health Resource), avoid spurious
        # errors if not available
        if ($Subsystem.HealthStatus -notlike "Healthy" -and $ClusterName.Length) {
            Show-Update "Triage for Clustered Subsystem (HealthStatus = $($Subsystem.HealthStatus))"
            try {
                $cmdlet = Get-Command Get-HealthFault -ErrorAction SilentlyContinue
                if ($null -ne $cmdlet -and $cmdlet.Source -eq 'FailoverClusters') {
                    Get-HealthFault  -CimSession $AccessNode |
                        Export-Clixml (Join-Path $Path "HeathFault.XML")
                } else {
                    $Subsystem | Debug-StorageSubsystem -CimSession $AccessNode |
                        Export-Clixml (Join-Path $Path "DebugStorageSubsystem.XML")
                }
            }
            catch { Show-Error "Unable to get Get-HealthFault or Debug-StorageSubsystem for unhealthy StorageSubsystem.`nError=" $_ }
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
                $DedupVolumes = Invoke-Command -ComputerName $AccessNode -ConfigurationName $SessionConfigurationName { Get-DedupStatus }
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
            icm $AccessNode -ConfigurationName $SessionConfigurationName { Get-StorageJob } |
                Export-Clixml ($Path + "GetStorageJob.XML") }
        catch { Show-Warning("Unable to get Storage Jobs. `nError="+$_.Exception.Message) }

        Show-Update "Clustered PhysicalDisks and SNV"

        # Physical disk health

        try {
            $PhysicalDisks = Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $Subsystem
            $PhysicalDisks | Export-Clixml ($Path + "GetPhysicalDisk.XML") }
        catch { Show-Error("Unable to get Physical Disks. `nError="+$_.Exception.Message) }

        try {
            Get-PhysicalDisk -CimSession $AccessNode -StorageSubSystem $Subsystem | Get-PhysicalDiskSNV -CimSession $AccessNode |
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

        # Undo changes as this is failing in AzureStack environment.
        # SDDC cim objects

        #Show-Update "SDDC Cim Objects"

        #foreach($objType in @("Drive","Server","Volume","Cluster","VirtualMachine","VirtualSwitch"))
        #{
        #    try {
        #        $className = "SDDC_"+$objType;
        #        Get-CimInstance -Namespace "root\SDDC\Management" -ClassName $className  | Export-Clixml ($Path + "GetSddc"+$objType+".XML");
        #    }
        #    catch { Show-Warning("Unable to get SDDC "+$objType+". `nError="+$_.Exception.Message) }
        #}

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
                    start-job -Name "S2D Connectivity: $node" {
                        Get-CimInstance -Namespace root\wmi -ClassName ClusPortDeviceInformation -ComputerName $using:node |
                            Export-Clixml (Join-Path (Join-Path $using:Path "Node_$using:node") "ClusPort.xml")
                        Get-CimInstance -Namespace root\wmi -ClassName ClusBfltDeviceInformation -ComputerName $using:node |
                            Export-Clixml (Join-Path (Join-Path $using:Path "Node_$using:node") "ClusBflt.xml")
                    }
                }
            } catch {
                Show-Warning "Gathering S2D connectivity failed"
            }
        }

        ####
        # Now receive the jobs requiring remote copyout
        ####

        if ($JobGather.Count) {

            Show-Update "Completing jobs with remote copyout ..." -ForegroundColor Green
            Show-WaitChildJob $JobGather 120
            Show-Update "Starting remote copyout ..."

            # keep parallelizing on receive at the individual node/child job level
            $JobCopy = $JobGather | Start-CopyJob $Path
            Remove-Job $JobGather
            $JobGather | RemoveCommonJobSession
            $JobGather = @()

            # receive any copyout errors for logging/triage
            Show-WaitChildJob $JobCopy 30
            Receive-Job $JobCopy
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
        $JobStatic | RemoveCommonJobSession
        $JobStatic = @()

        #
        # Phase 2 Prep
        #
        Show-Update "<<< Phase 2 - Pool, Physical Disk and Volume Details >>>" -ForegroundColor Cyan

        if ($IncludeAssociations) {

            if ($Read) {
                $Associations = Import-ClixmlIf ($Path + "GetAssociations.XML")
                $SNVView = Import-ClixmlIf ($Path + "GetStorageNodeView.XML")
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
            $set = Get-Counter -ListSet "Cluster Storage*","Cluster CSV*","Storage Spaces*","Refs","Cluster Disk Counters","PhysicalDisk" -ComputerName $ClusterNodes.Name
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

            try {
                if ((([System.Environment]::OSVersion.Version).Major) -ge 10) {
                    Show-Update "Gathering Get-StorageDiagnosticInfo"
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
                    $null = New-Item -Path $destinationPath -ItemType Directory
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
            catch {
                Show-Warning "Could not gather Get-StorageDiagnosticInfo (cluster down and/or shared storage)`nError = $($_)"
            }
        }

        Show-Update "GATHERS COMPLETE ($(((Get-Date) - $TodayDate).ToString("m'm's\.f's'")))" -ForegroundColor Green

    } finally {

        Stop-Transcript

        # Wipe down any pending jobs & associated sessions
        $JobGather | Stop-Job
        $JobGather | Remove-Job
        $JobGather | RemoveCommonJobSession

        $JobStatic | Stop-Job
        $JobStatic | Remove-Job
        $JobStatic | RemoveCommonJobSession
    }

    # Generate Summary report for rapid consumption at analysis time
    Show-Update "<<< Generating Summary Report >>>" -ForegroundColor Cyan
    $transcriptFile = $Path + "0_CloudHealthSummary.log"
    Start-Transcript -Path $transcriptFile -Force
    try {
        Show-SddcDiagnosticReport -Report Summary -ReportLevel Full $Path
    } finally {
        Stop-Transcript
    }

    #
    # Phase 4
    #

    if ($ZipFiles)
    {
        Show-Update "<<< Phase 4 - Compacting files for transport >>>" -ForegroundColor Cyan
    }
    else
    {
        Show-Update "<<< Phase 4 - Extract cab files + Final Cleanup >>>" -ForegroundColor Cyan
    }

    if (!$ZipFiles)
    {
         Show-Update "Rename msdbg.<node name> to msdbg. Do this to shorten overall filepath."
         $items = Get-ChildItem -Recurse -Path $Path -Filter "msdbg.*"
         foreach ($item in $items)
         {
             if ($item.FullName -Match "msdbg(.*)")
             {
                 $childFolder = Split-Path $item.FullName -Leaf
                 $parentFolder = Split-Path $item.FullName -Parent
                 $childFolder = $childFolder -Replace $matches[1], ""
                 $renamedFolder = Join-Path -Path $parentFolder -ChildPath $childFolder
                 Rename-Item $item.FullName $renamedFolder
             }
         }
    }

    #
    # Force GC so that any pending file references are
    # torn down. If they live, they will block removal
    # of content.
    #

    [System.GC]::Collect()

    if ($ZipFiles)
    {
        # time/extension suffix
        $ZipSuffix = '-' + (Format-SddcDateTime $TodayDate) + '.ZIP'

        # prepend clustername if live, domain name trimmed away
        # we could use $Cluster.Name since it will exist if $ClusterName was created from it,
        # but that may seem excessively mysterious)
        if ($ClusterName.Length) {
            $ZipSuffix = '-' + ($ClusterName.Split('.',2)[0]) + $ZipSuffix
        } else {
            $ZipSuffix = '-OFFLINECLUSTER' + $ZipSuffix
        }

        # ... and full path
        $ZipPath = $ZipPrefix + $ZipSuffix

        try {
            Add-Type -Assembly System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Path, $ZipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
            $ZipPath = Convert-Path $ZipPath
            Show-Update "Zip File Name : $ZipPath"

            Show-Update "Cleaning up temporary directory $Path"
            Remove-Item -Path $Path -ErrorAction SilentlyContinue -Recurse

        } catch {
            Show-Error("Error creating the ZIP file!`nContent remains available at $Path")
        }
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
        Add-Type -Assembly System.IO.Compression.FileSystem
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

    $psBoundParametersKeys = $PSBoundParameters.Keys
    if ($psBoundParametersKeys -contains 'Days') {
        try {
            $Days.Value = ($c | Get-ClusterParameter -Name SddcDiagnosticArchiveDays -ErrorAction Stop).Value
        } catch {
            $Days.Value = 60
        }
    }

    if ($psBoundParametersKeys -contains 'Path') {
        try {
            $Path.Value = ($c | Get-ClusterParameter -Name SddcDiagnosticArchivePath -ErrorAction Stop).Value
        } catch {
            $Path.Value = Join-Path $env:SystemRoot "SddcDiagnosticArchive"
        }
    }

    if ($psBoundParametersKeys -contains 'Size') {
        try {
            $Size.Value = ($c | Get-ClusterParameter -Name SddcDiagnosticArchiveSize -ErrorAction Stop).Value
        } catch {
            $Size.Value = 500MB
        }
    }

    if ($psBoundParametersKeys -contains 'At') {
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

        $Path = (Get-Cluster -Name . -ErrorAction Stop | Get-ClusterParameter -Name SddcDiagnosticArchivePath -ErrorAction Stop).Value
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
                Write-Error "$(Get-Date -format 's') : SDDC Diagnostic Archive job failed."
                throw $_
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

function Show-StorageCounters
{
    Param (
       [parameter(Position=0, Mandatory=$true)]
       [ValidateNotNullOrEmpty()]
       [string] $Path,
       [Parameter (Mandatory = $false)]
       [bool] $showerr = $false,
       [Parameter (Mandatory = $false)]
       [int] $delta = 0
       )

    if (-not (Test-Path $Path)) {
        Write-Error "Path is not accessible. Please check and try again: $Path"
        return
    }

    $d=import-counter -Path $path\"GetCounters.blg"

    $tabName="Cache Perf"
    $cachetable=new-object System.Data.DataTable "$tabName"

    #Define Columns
    $col1 = New-Object system.Data.DataColumn Node,([string])
    $col2 = New-Object system.Data.DataColumn CacheHits,([string])
    $col3 = New-Object system.Data.DataColumn CacheMiss,([string])
    $col4 = New-Object system.Data.DataColumn DiskReads,([string])
    $col5 = New-Object system.Data.DataColumn DirectReads,([string])

    $col6 = New-Object system.Data.DataColumn DiskWrites,([string])
    $col7 = New-Object system.Data.DataColumn DirectWrites,([string])
    $col8 = New-Object system.Data.DataColumn CacheWrites,([string])

    $tabName="Error Table"
    $errtable=new-object System.Data.DataTable "$tabName"

    $col9 = New-Object system.Data.DataColumn Node,([string])
    $col10 = New-Object system.Data.DataColumn WriteError,([string])
    $col11 = New-Object system.Data.DataColumn WriteMedia,([string])
    $col12 = New-Object system.Data.DataColumn ReadTimeout,([string])
    $col13 = New-Object system.Data.DataColumn ReadMedia,([string])

    #Add the Columns
    $cachetable.columns.add($col1)
    $cachetable.columns.add($col2)
    $cachetable.columns.add($col3)
    $cachetable.columns.add($col4)
    $cachetable.columns.add($col5)
    $cachetable.columns.add($col6)
    $cachetable.columns.add($col7)
    $cachetable.columns.add($col8)

    $errtable.columns.add($col9)
    $errtable.columns.add($col10)
    $errtable.columns.add($col11)
    $errtable.columns.add($col12)
    $errtable.columns.add($col13)


    $tabName="CSV Clusport Perf"
    $table=new-object System.Data.DataTable "$tabName"

    #Define Columns
    $col1 = New-Object system.Data.DataColumn Node,([string])
    $col2 = New-Object system.Data.DataColumn CSVReadIOPS,([string])
    $col3 = New-Object system.Data.DataColumn CSVReadLatency,([string])
    $col4 = New-Object system.Data.DataColumn CSVWriteIOPS,([string])
    $col5 = New-Object system.Data.DataColumn CSVWriteLatency,([string])

    $tabName="SBL Perf"
    $sbltable=new-object System.Data.DataTable "$tabName"
    $col6 = New-Object system.Data.DataColumn Node,([string])
    $col7 = New-Object system.Data.DataColumn SBLReadIOPS,([string])
    $col8 = New-Object system.Data.DataColumn SBLReadLatency,([string])
    $col9 = New-Object system.Data.DataColumn SBLWriteIOPS,([string])
    $col10 = New-Object system.Data.DataColumn SBLWriteLatency,([string])
    $col11 = New-Object system.Data.DataColumn SBLLocalRead,([string])
    $col12 = New-Object system.Data.DataColumn SBLLocalWrite,([string])
    $col13 = New-Object system.Data.DataColumn SBLRemoteRead,([string])
    $col14 = New-Object system.Data.DataColumn SBLRemoteWrite,([string])

    #Add the Columns
    $table.columns.add($col1)
    $table.columns.add($col2)
    $table.columns.add($col3)
    $table.columns.add($col4)
    $table.columns.add($col5)

    $sbltable.columns.add($col6)
    $sbltable.columns.add($col7)
    $sbltable.columns.add($col8)
    $sbltable.columns.add($col9)
    $sbltable.columns.add($col10)
    $sbltable.columns.add($col11)
    $sbltable.columns.add($col12)
    $sbltable.columns.add($col13)
    $sbltable.columns.add($col14)

    $tabName="Hybrid IO Profile"
    $ioprofiletable=new-object System.Data.DataTable "$tabName"

    #Define Columns
    $col1 = New-Object system.Data.DataColumn Node,([string])
    $col2 = New-Object system.Data.DataColumn IOProfileRead,([string])
    $col3 = New-Object system.Data.DataColumn IOProfileWrites,([string])

    $ioprofiletable.columns.add($col1)
    $ioprofiletable.columns.add($col2)
    $ioprofiletable.columns.add($col3)

    if ($delta -ne 0) {
        $sample = $delta
    } else {
        $sample=0
    }

    do {

        $csvreads=$d[$sample].CounterSamples | where { $_.path -Like "*cluster csvfs(_total)\reads/sec*"}
        $csvwrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster csvfs(_total)\writes/sec*"}
        $csvwritelat=$d[$sample].CounterSamples | where { $_.path -Like "*cluster csvfs(_total)\avg. sec/write"}
        $csvreadlat=$d[$sample].CounterSamples | where { $_.path -Like "*cluster csvfs(_total)\avg. sec/read"}
        $csvnodes=$csvreads.Path

        $sblreads=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\read/sec*"}
        $sblwrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\writes/sec*"}
        $sbllocalreads=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\Local: read/sec*"}
        $sbllocalwrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\Local: writes/sec*"}
        $sblremotereads=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\Remote: read/sec*"}
        $sblremotewrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\Remote: writes/sec*"}
        $sblwritelat=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\write latency"}
        $sblreadlat=$d[$sample].CounterSamples | where { $_.path -Like "*cluster disk counters(_total)\read latency"}
        $sblnodes=$sblreads.Path

        $cachehits=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\cache hit reads/sec*"}
        $cachemiss=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\cache miss reads/sec*"}
        $diskreads=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\disk reads/sec"}
        $directreads=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\direct reads/sec"}

        $diskwrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\disk writes/sec*"}
        $directwrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\direct writes/sec*"}
        $cachewrites=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\cache writes/sec"}

        $writeerror=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\write errors total*"}
        $writemedia=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\write errors media*"}
        $readtimeout=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\read errors timeout*"}
        $readmedia=$d[$sample].CounterSamples | where { $_.path -Like "*cluster storage hybrid disks(_total)\read errors media*"}
        $cachenodes=$cachehits.Path


        $diskioreads=$d[$sample].CounterSamples | where { $_.path -like "*cluster storage hybrid disks io profile(_total)\reads/sec total*" }
        $diskiowrites=$d[$sample].CounterSamples | where { $_.path -like "*cluster storage hybrid disks io profile(_total)\writes/sec total*" }
        $ioprofilenodes = $diskioreads.Path

        $csvreadtotal=0
        $csvwritetotal=0
        $sblreadtotal=0
        $sblwritetotal=0
        $ioprofilereadtotal=0
        $ioprofilewritetotal=0


        $cachehittotal =0
        $cachemisstotal=0
        $diskreadtotal=0
        $diskwritetotal=0
        $directreadtotal=0
        $directwritetotal=0
        $cachewritetotal=0

        $table.Clear()
        $cachetable.Clear()
        $errtable.Clear()
        $sbltable.Clear()
        $ioprofiletable.Clear()

        $index=0
        foreach($node in $csvnodes) {
            $row = $table.NewRow()

            $pos = $csvnodes[$index].IndexOf("\",2)
            #Enter data in the row
            $row.Node = $csvnodes[$index].Substring(2,$pos-2)
            $row.CSVReadIOPS = $([math]::Round($csvreads[$index].cookedValue,0))
            $row.CSVReadLatency = $([math]::Round($csvreadlat[$index].cookedValue*1000,2))
            $row.CSVWriteIOPS = $([math]::Round($csvwrites[$index].cookedValue,0))
            $row.CSVWriteLatency = $([math]::Round($csvwritelat[$index].cookedValue*1000,2))
            $csvreadtotal += $row.CSVReadIOPS
            $csvwritetotal+= $row.CSVWriteIOPS
            $table.Rows.Add($row)
            $index+=1
        }

        $index=0
        foreach($node in $sblnodes) {
            $row = $sbltable.NewRow()
            $pos = $sblnodes[$index].IndexOf("\",2)
            $row.Node = $sblnodes[$index].Substring(2,$pos-2)
            $row.SBLReadIOPS = $([math]::Round($sblreads[$index].cookedValue,0))
            $row.SBLReadLatency = $([math]::Round($sblreadlat[$index].cookedValue*1000,2))
            $row.SBLWriteIOPS = $([math]::Round($sblwrites[$index].cookedValue,0))
            $row.SBLWriteLatency = $([math]::Round($sblwritelat[$index].cookedValue*1000,2))
            $row.SBLLocalRead = $([math]::Round($sbllocalreads[$index].cookedValue,0))
            $row.SBLLocalWrite = $([math]::Round($sbllocalwrites[$index].cookedValue,0))
            $row.SBLRemoteRead = $([math]::Round($sblremotereads[$index].cookedValue,0))
            $row.SBLRemoteWrite = $([math]::Round($sblremotewrites[$index].cookedValue,0))

            $sblreadtotal+=$row.SBLReadIOPS
            $sblwritetotal+=$row.SBLWriteIOPS

            #Add the row to the table
            $sbltable.Rows.Add($row)
            $index+=1
        }

        $index=0
        foreach($node in $cachenodes) {
            $row = $cachetable.NewRow();
            $pos = $cachenodes[$index].IndexOf("\",2)
            $row.Node = $cachenodes[$index].Substring(2,$pos-2)

            $row.CacheHits = $([math]::Round($cachehits[$index].cookedValue,0))
            $row.CacheMiss = $([math]::Round($cachemiss[$index].cookedValue,0))
            $row.DiskReads = $([math]::Round($diskreads[$index].cookedValue,0))
            $row.DirectReads = $([math]::Round($directreads[$index].cookedValue,0))
            $row.DiskWrites = $([math]::Round($diskwrites[$index].cookedValue,0))
            $row.DirectWrites = $([math]::Round($directwrites[$index].cookedValue,0))
            $row.CacheWrites = $([math]::Round($cachewrites[$index].cookedValue,0))
            #Add the row to the table
            $cachetable.Rows.Add($row)

            $cachehittotal+=$row.CacheHits
            $cachemisstotal+=$row.CacheMiss
            $diskreadtotal+=$row.DiskReads
            $diskwritetotal+=$row.DiskWrites
            $directreadtotal+=$row.DirectReads
            $directwritetotal+=$row.DirectWrites
            $cachewritetotal+=$row.CacheWrites

            if ($showerr) {
                $row = $errtable.NewRow();
                $row.Node = $nodes[$index].Substring(2,$pos-2)
                $row.WriteError = $([math]::Round($writeerror[$index].cookedValue,0))
                $row.WriteMedia = $([math]::Round($writemedia[$index].cookedValue,0))
                $row.ReadTimeout = $([math]::Round($readtimeout[$index].cookedValue,0))
                $row.ReadMedia = $([math]::Round($readmedia[$index].cookedValue,0))

                #Add the row to the table
                $errtable.Rows.Add($row)
            }

            $index+=1
        }

        $index=0
        foreach($node in $ioprofilenodes) {
            $row = $ioprofiletable.NewRow()
            $pos = $ioprofilenodes[$index].IndexOf("\",2)
            $row.Node = $ioprofilenodes[$index].Substring(2,$pos-2)
            $row.IOProfileRead = $([math]::Round($diskioreads[$index].cookedValue,0))
            $row.IOProfileWrites = $([math]::Round($diskiowrites[$index].cookedValue,0))

            $ioprofilereadtotal+=$row.IOProfileRead
            $ioprofilewritetotal+=$row.IOProfileWrites

            #Add the row to the table
            $ioprofiletable.Rows.Add($row)
            $index+=1
        }

        # add Total row
        $row = $table.NewRow()
        $row.Node = "Total"
        $row.CSVReadIOPS = $csvreadtotal
        $row.CSVWriteIOPS = $csvwritetotal
        #Add the row to the table
        $table.Rows.Add($row)

        $row = $sbltable.NewRow()
        $row.Node = "Total"
        $row.SBLReadIOPS = $sblreadtotal
        $row.SBLWriteIOPS= $sblwritetotal

        #Add the row to the table
        $sbltable.Rows.Add($row)


        $row = $cachetable.NewRow()
        $row.Node = "Total"
        $row.CacheHits = $cachehittotal
        $row.CacheMiss = $cachemisstotal
        $row.DiskReads = $diskreadtotal
        $row.DirectReads = $directreadtotal
        $row.DiskWrites = $diskwritetotal
        $row.DirectWrites= $directwritetotal
        $row.CacheWrites = $cachewritetotal
        #Add the row to the table
        $cachetable.Rows.Add($row)

        $row = $ioprofiletable.NewRow()
        $row.Node = "Total"
        $row.IOProfileRead = $ioprofilereadtotal
        $row.IOProfileWrites= $ioprofilewritetotal

        #Add the row to the table
        $ioprofiletable.Rows.Add($row)

        cls

        #Display the table
        write-host "Sample interval " $sample
        $table | sort-object Node| format-table -AutoSize
        $sbltable | sort-object Node| format-table -AutoSize
        $cachetable | sort-object Node| format-table -AutoSize
        $ioprofiletable | sort-object Node| format-table -AutoSize

        if ($showerr) {
            $errtable | sort-object Node| format-table -AutoSize
        }

        $sample+=1
        if ($sample -eq $d.Count) {
            $sample=0
        }

        if ($delta -ne 0) {
            break
        }

        Start-Sleep -Seconds 1

    } while (1)
}

function Get-SpacesTimeline

{

    # aliases usage in this module is idiomatic, only using defaults

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingCmdletAliases", "")]

    param(

        [parameter(Position=0, Mandatory=$true)]

        [ValidateNotNullOrEmpty()]

        [string]

        $Path,

        [parameter(Mandatory=$true)]

        [ValidateNotNullOrEmpty()]

        [string]

        $VirtualDiskId

        )

        $VirtualDiskFilePath = Join-Path $Path "GetVirtualDisk.XML"
        $ClusterNodeFilePath = Join-Path $Path "GetClusterNode.XML"

        if ((-not (Test-Path $VirtualDiskFilePath)) -or (-not (Test-Path $ClusterNodeFilePath)))
        {
            Write-Error "Path is not valid or collection files are not present. Please check and try again: $Path"
            return
        }

        $VirtualDisks = Import-ClixmlIf ($VirtualDiskFilePath)
        $ClusterNodes = Import-ClixmlIf ($ClusterNodeFilePath)

        $OperationalLog = "Microsoft-Windows-StorageSpaces-Driver-Operational.EVTX"
        $DiagnosticLog  = "Microsoft-Windows-StorageSpaces-Driver-Diagnostic.EVTX"

        $eventshash  = @{}

        foreach ($node in $ClusterNodes)
        {
            $nodeName = $node.Name
            $OperationalLogPath = Join-Path (Get-NodePath $Path $nodeName) $OperationalLog
            $DiagnosticLogPath  = Join-Path (Get-NodePath $Path $nodeName) $DiagnosticLog

            foreach ($VirtualDisk in $VirtualDisks)
            {
                $id = $VirtualDisk.ObjectId.Split(":")[2].Split("}")[1] + "}"

                if ($VirtualDiskId -ne $id.Trim("{}"))
                {
                    continue;
                }

                $eventFilter = "EventID=1008 or EventID=1009 or EventID=1021 or EventID=1022"

                $query = "*[System[($eventFilter)]] and *[EventData[Data[@Name='Id'] and (Data='$id')]]"

                $events = Get-WinEvent -Path $DiagnosticLogPath -FilterXPath $query -ErrorAction SilentlyContinue
                $events | % { $_ | Add-Member NodeName $nodeName}

                if ($events)
                {
                    $eventshash[$id] += $events;
                }
            }
        }

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Windows.Forms.DataVisualization

        $Title = "Storage Spaces State Timeline"

        $chart = New-object Windows.Forms.DataVisualization.Charting.Chart
        $chart.Anchor = [Windows.Forms.AnchorStyles]::Bottom -bor
                        [Windows.Forms.AnchorStyles]::Right -bor
                        [Windows.Forms.AnchorStyles]::Top -bor
                        [Windows.Forms.AnchorStyles]::Left

        $chart.Width = 1000
        $chart.Height = 800
        $chart.Left = 40
        $chart.Top = 30
        $chart.BackColor = [Drawing.Color]::White
        [void]$chart.Titles.Add($Title)
        $chart.Titles[0].Font = "segoeuilight,12pt"

        #
        # Create a chart area to draw on
        #

        $chartArea = New-Object Windows.Forms.DataVisualization.Charting.ChartArea
        $chartarea.Name = "TimeSeries"
        $chartarea.AxisX.IntervalType = [Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
        $chartarea.AxisX.IntervalAutoMode = [Windows.Forms.DataVisualization.Charting.IntervalAutoMode]::VariableCount
        $chartarea.AxisX.MajorGrid.Enabled = $false
        $chartarea.AxisX.LabelStyle.Format = "yyyy/MM/dd h tt"
        $chartarea.AxisX.ScaleView.Zoomable = $true
        $chartarea.AxisX.ScrollBar.IsPositionedInside = $true
        $chartarea.AxisX.ScrollBar.ButtonStyle = [Windows.Forms.DataVisualization.Charting.ScrollBarButtonStyles]::All
        $chartarea.CursorX.IsUserEnabled = $true
        $chartarea.CursorX.IsUserSelectionEnabled = $true
        $chartarea.CursorX.IntervalType = [Windows.Forms.DataVisualization.Charting.DateTimeIntervalType]::Hours
        $chartarea.CursorX.AutoScroll = $true
        $chartArea.AxisY.Title = "State"
        $chartArea.AxisY.TitleFont = "segoeuilight,12pt"
        $chartarea.AxisY.LabelStyle.Format = "N0"
        $chartarea.AxisY.MinorGrid.Enabled = $true
        $chartarea.AxisY.MinorGrid.LineDashStyle = [Windows.Forms.DataVisualization.Charting.ChartDashStyle]::Dot

        $chart.ChartAreas.Add($chartArea)

        foreach ($key in $eventshash.Keys)
        {
            if ($key.Trim("{}") -ne $VirtualDiskId)
            {
                continue;
            }

            $eventsHashSortTime = $eventshash[$key] | sort TimeCreated

            foreach ($i in $eventsHashSortTime)
            {

                $point = New-Object Windows.Forms.DataVisualization.Charting.DataPoint
                $point.Color = [Drawing.Color]::Green

                if ($i.Id -eq 1008)
                {
                    $startTime = $i.TimeCreated
                    $seriesName = "State" + $startTime
                    [void]$chart.Series.Add($seriesName)
                    $endTime   = $null
                }
                if ($i.Id -eq 1009)
                {
                    $endTime = $i.TimeCreated
                    $startTime = $null
                }

                if ($i.Id -eq 1021)
                {
                    $value = 20
                    $seriesName = "Attach" + $i.TimeCreated
                    $point.SetValueXY($i.TimeCreated, $value)
                    $point.Tooltip = "Attached" +
                                    "At: #VALX{MM/dd/yyyy h:mm:ss tt}\n" +
                                    "NodeName: $($i.NodeName)"
                    $point.Color = [Drawing.Color]::Red
                    $chart.Series[$seriesName].Points.Add($point)
                }

                if ($i.Id -eq 1021)
                {
                    $value = 20
                    $seriesName = "Detached" + $i.TimeCreated
                    $point.SetValueXY($i.TimeCreated, $value)
                    $point.Tooltip = "Detached" +
                                    "At: #VALX{MM/dd/yyyy h:mm:ss tt}\n" +
                                    "NodeName: $($i.NodeName)"
                    $point.Color = [Drawing.Color]::Red
                    $chart.Series[$seriesName].Points.Add($point)
                }

                $chart.Series[$seriesName].ChartType = [Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
                $chart.Series[$seriesName].XValueType = [Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
                $chart.Series[$seriesName].MarkerStyle = [Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle

                if ($null -ne $startTime)
                {
                    $value = 10
                    $point.SetValueXY($i.TimeCreated, $value)
                    $point.Tooltip = "Regen progressing" +
                                    "At: #VALX{MM/dd/yyyy h:mm:ss tt}\n" +
                                    "NodeName: $($i.NodeName)"
                    $chart.Series[$seriesName].Points.Add($point)
                    $startTime = $null
                }
                if ($null -ne $endTime)
                {
                    $value = 20
                    $point.SetValueXY($i.TimeCreated, $value)
                    $point.Tooltip = "RegenCompleted " +
                                    "At: #VALX{MM/dd/yyyy h:mm:ss tt}\n" +
                                    "NodeName: $($i.NodeName)"
                    $chart.Series[$seriesName].Points.Add($point)
                    $startTime = $null
                    $endTime   = $null
                }
            }
        }

        $form = New-Object Windows.Forms.Form
        $form.Text = "Storage Chart plotting space timeline"
        $form.Width = 1100
        $form.Height = 900
        $form.controls.add($chart)
        $form.Add_Shown({$form.Activate()})

        [void]$form.ShowDialog()
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
                            } elseif ($idmap.Keys -contains $_.CacheDeviceId) {
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

        Import-ClixmlIf $_ | Show-SSBConnectivity $node
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
        $TimeBase = 0,

        [int]
        $HoursOfEvents = -1
    )

    # comment on limits/base
    if ($CutoffMs) {
        Write-Output "Latency Cutoff: report limited to IO of $($CutoffMs)ms and higher (as limited by distribution buckets)"
    } else {
        Write-Output "Latency Cutoff: none, report will show the complete IO latency distribution"
    }
    if ($HoursOfEvents -eq -1) {
        Write-Output "Time Cutoff   : none, report will show the full available IO history"
    } else {
        Write-Output "Time Cutoff   : report will show IO history from $($TimeBase.ToString()) for the prior $HoursOfEvents hours"
    }

    # comment if neither limit is being used
    if (-not $CutoffMs -and $HoursOfEvents -eq -1) {
        write-output "NOTE: Show-SddcDiagnosticStorageLatencyReport provides access to time/latency cutoff limits which may significantly speed up reporting when focused on recent high latency events"
    }

    $j = @()

    try
    {

        dir $Path\Node_*\Microsoft-Windows-Storage-Storport-Operational.EVTX | sort -Property FullName |% {

            $file = $_.FullName
            $node = "<unknown>"
            if ($file -match "Node_([^\\]+)\\") {
                $node = $matches[1]
            }

            # parallelize processing of per-node event logs

            $j += Invoke-CommonCommand -InitBlock $CommonFunc -JobName $node -SessionConfigurationName $null -ArgumentList $file,$ReportLevel,$CutoffMS,$TimeBase,$HoursOfEvents -ScriptBlock {

                param(
                    [string]
                    $file,

                    $ReportLevel,

                    [int]
                    $CutoffMS,

                    [datetime]
                    $TimeBase,

                    [int]
                    $HoursOfEvents )

                $dofull = $false

                if ($ReportLevel -eq "Full")
                {
                    $dofull = $true
                }

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
                $x = wevtutil qe /lf $file "/q:$(Get-FilterXpath -Event 505)" /c:1
                $evs = [xml]"<Events>$x</Events>"

                if ($null -ne $evs) {

                    # use this event to determine schema and cutoff bucket (if specified)

                    $xh = Get-EventDataHash $evs.Events.Event

                    # only need to get the bucket label schema once
                    # the number of labels and the number of bucket counts should be equal
                    # determine the count schema at the same time
                    $bucklabels = $xh['IoLatencyBuckets'] -split ',\s+'

                    # is the count scheme split (RS5) or combined (RS1)?
                    # match 1 is the bucket type
                    # match 2 is the value bucket number (1 .. n)
                     $xhKeys = $xh.Keys
                    if ($xhKeys -contains "BucketIoSuccess1") {
                        $schemasplit = $true
                        $buckvalueschema = "^BucketIo(Success|Failed)(\d+)$"
                    } else {
                        $schemasplit = $false
                        $buckvalueschema = "^BucketIo(Count)(\d+)$"
                    }

                    # initialize empty data element test
                    $DataOr = @{}

                    if ($CutoffMs) {

                        $CutoffUs = $CutoffMs * 1000

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

                    # now, with schema, process all events
                    # construct the xpath filter w/wo the time filter
                    # if the data element test is empty, it will not be built into the xpath query
                    if ($HoursOfEvents -ne -1) {
                        $xpath = Get-FilterXpath -Event 505 -TimeBase $TimeBase -TimeDeltaMs ($HoursOfEvents * 60 * 60 * 1000) -DataOr $DataOr
                    } else {
                        $xpath = Get-FilterXpath -Event 505 -DataOr $DataOr
                    }

                    $x = wevtutil qe /lf $file "/q:$xpath"
                    $evs = [xml]"<Events>$x</Events>"

                    foreach ($e in $evs.Events.Event)
                    {
                        $xh = Get-EventDataHash $e

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
                        if (-not ($buckhash.Keys -contains $dev)) {
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
                                    'Time' = $e.TimeCreated
                                    'Device' = [string] $e.Properties[4].Value
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
        $PhysicalDisks = Import-ClixmlIf (Join-Path $Path "GetPhysicalDisk.XML")

        # hash by object id
        # this is an example where a formal datasource class/api could be useful
        $PhysicalDisksTable = @{}
        $PhysicalDisks |% {
            if ($_.ObjectId -match 'PD:{(.*)}') {
                $PhysicalDisksTable[$matches[1]] = $_
            }
        }

        # we will join the latency information with this set of physicaldisk attributes
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
        $j | Wait-Job | Sort-Object Name |% {

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
                $buckhash.Keys |? { $PhysicalDisksTable.Keys -contains $_ } |% {

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
                        $evs |? { $PhysicalDisksTable.Keys -contains $_.Device } |% { $n += 1; $_ } | sort Time -Descending | ft -AutoSize ('Time','Device' + $pdattrs_ev + $bucklabels)
                    }

                    if ($n -eq 0) {
                        Write-Output "-> No Events"
                    }
                }
            }
        }
    }
    catch
    {
        Show-Warning("Exception in get-stroage latency report .  `nError="+$_.Exception.Message)
    }
    finally
    {
        # And remove sessions from jobs
        $j | RemoveCommonJobSession
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
    $PhysicalDisks = Import-ClixmlIf (Join-Path $Path "GetPhysicalDisk.XML") |? Usage -ne Retired

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
                'RDMA LastDay' =  Count-EventLog -path $_ -xpath $(Get-FilterXpath -Event $ev -TimeBase $timebase -TimeDeltaMs $lastday  -DataAnd @{'ConnectionType'='=2'})

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
    $Parameters = Import-ClixmlIf (Join-Path $Path "GetParameters.XML")
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

    $Parameters = Import-ClixmlIf (Join-Path $Path "GetParameters.XML")
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
    $ClusterNodes = Import-ClixmlIf (Join-Path $Path "GetClusterNode.XML")

    $Cluster = Import-ClixmlIf (Join-Path $Path "GetCluster.XML")

    if ($Cluster) {

        $ClusterName = $Cluster.Name + "." + $Cluster.Domain
        $S2DEnabled = $Cluster.S2DEnabled
        $ClusterDomain = $Cluster.Domain;

        Write-Host "Cluster Name                  : $ClusterName"
        Write-Host "S2D Enabled                   : $S2DEnabled"

    } else {

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

    if ($Cluster) {

        $ClusterGroups = Import-ClixmlIf (Join-Path $Path "GetClusterGroup.XML")

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

        $ClusterNetworks = Import-ClixmlIf (Join-Path $Path "GetClusterNetwork.XML")

        $NetsTotal = NCount($ClusterNetworks)
        $NetsHealthy = NCount($ClusterNetworks |? {$_.State -like "Up"})
        Write-Host "Cluster Networks up           : $NetsHealthy / $NetsTotal"

        if ($NetsTotal -lt $ExpectedNetworks) { Show-Warning "Fewer cluster networks than the $ExpectedNetworks expected" }
        if ($NetsHealthy -lt $NetsTotal) { Show-Warning "Unhealthy cluster networks detected" }

        # Cluster resource health

        $ClusterResources = Import-ClixmlIf (Join-Path $Path "GetClusterResource.XML")
        $ClusterResourceParameters = Import-ClixmlIf (Join-Path $Path "GetClusterResourceParameters.XML")

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

    } else {

        Show-Warning "Skipping Cluster status since it was unavailable"
    }

    # Storage subsystem health
    $Subsystem = Import-ClixmlIf (Join-Path $Path "GetStorageSubsystem.XML")

    $SubsystemUnhealthy = $false
    if ($null -eq $Subsystem) {
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
    $StorageJobs = Import-ClixmlIf (Join-Path $Path "GetStorageJob.XML")

    if ($null -eq $StorageJobs) {
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
    $ShareStatus = Import-ClixmlIf (Join-Path $Path "ShareStatus.XML")

    $ShTotal = NCount($ShareStatus)
    $ShHealthy = NCount($ShareStatus |? Health -like "Accessible")
    "SMB CA Shares Accessible      : $ShHealthy / $ShTotal"
    if ($ShHealthy -lt $ShTotal) { Show-Warning "Inaccessible CA shares detected" }

    # SMB Open Files

    $SmbOpenFiles = Import-ClixmlIf (Join-Path $Path "GetSmbOpenFile.XML")

    $FileTotal = NCount( $SmbOpenFiles | Group-Object ClientComputerName)
    Write-Host "Users with Open Files         : $FileTotal"
    if ($FileTotal -eq 0) { Show-Warning "No users with open files" }

    # SMB witness

    $SmbWitness = Import-ClixmlIf (Join-Path $Path "GetSmbWitness.XML")

    $WitTotal = NCount($SmbWitness |? State -eq RequestedNotifications | Group-Object ClientName)
    Write-Host "Users with a Witness          : $WitTotal"
    if ($FileTotal -ne 0 -and $WitTotal -eq 0) { Show-Warning "No users with a Witness" }

    # Cluster shared volume status

    if ($Cluster) {

        $CSV = Import-ClixmlIf (Join-Path $Path "GetClusterSharedVolume.XML")

        $CSVTotal = NCount($CSV)
        $CSVHealthy = NCount($CSV |? State -like "Online")
        Write-Host "Cluster Shared Volumes Online : $CSVHealthy / $CSVTotal"
        if ($CSVHealthy -lt $CSVTotal) { Show-Warning "Offline cluster shared volumes detected" }

    } else {

        Show-Warning "Skipping Cluster shared volume status since cluster was unavailable"
    }

    # Volume health

    $Volumes = Import-ClixmlIf (Join-Path $Path "GetVolume.XML")

    $VolsTotal = NCount($Volumes |? FileSystem -eq CSVFS )
    $VolsHealthy = NCount($Volumes  |? FileSystem -eq CSVFS |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) })
    Write-Host "Cluster Shared Volumes Healthy: $VolsHealthy / $VolsTotal "

    #
    # Deduplicated volume health - if the volume XML exists, it was present (may still be empty)
    #

    $DedupEnabled = $false

    if (Test-Path (Join-Path $Path "GetDedupVolume.XML")) {
        $DedupEnabled = $true

        $DedupVolumes = Import-ClixmlIf (Join-Path $Path "GetDedupVolume.XML")
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

    $VirtualDisks = Import-ClixmlIf (Join-Path $Path "GetVirtualDisk.XML")

    $VDsTotal = NCount($VirtualDisks)
    $VDsHealthy = NCount($VirtualDisks |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Virtual Disks Healthy         : $VDsHealthy / $VDsTotal"

    if ($VDsHealthy -lt $VDsTotal) { Show-Warning "Unhealthy virtual disks detected" }

    # Storage pool health

    $StoragePools = @(Import-ClixmlIf (Join-Path $Path "GetStoragePool.XML"))

    $PoolsTotal = NCount($StoragePools)
    $PoolsHealthy = NCount($StoragePools |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Storage Pools Healthy         : $PoolsHealthy / $PoolsTotal "

    if ($S2DEnabled -and $StoragePools.Count -ne 1) {
        Show-Warning "S2D is enabled but the number of non-primordial pools $($StoragePools.Count) != 1"
    }

    if ($PoolsTotal -lt $ExpectedPools) { Show-Warning "Fewer storage pools than the $ExpectedPools expected" }
    if ($PoolsHealthy -lt $PoolsTotal) { Show-Warning "Unhealthy storage pools detected" }

    # Physical disk health

    $PhysicalDisks = Import-ClixmlIf (Join-Path $Path "GetPhysicalDisk.XML")
    $PhysicalDiskSNV = Import-ClixmlIf (Join-Path $Path "GetPhysicalDiskSNV.XML")

    $PDsTotal = NCount($PhysicalDisks)
    $PDsHealthy = NCount($PhysicalDisks |? { ($_.HealthStatus -like "Healthy") -or ($_.HealthStatus -eq 0) } )
    Write-Host "Physical Disks Healthy        : $PDsHealthy / $PDsTotal"

    if ($PDsTotal -lt $ExpectedPhysicalDisks) { Show-Warning "Fewer physical disks than the $ExpectedPhysicalDisks expected" }
    if ($PDsHealthy -lt $PDsTotal) { Show-Warning "$($PDsTotal - $PDsHealthy) unhealthy physical disks detected" }

    # Storage enclosure health

    $StorageEnclosures = Import-ClixmlIf (Join-Path $Path "GetStorageEnclosure.XML")

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

    if ($Cluster) {

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

    } else {

        Show-Warning "Skipping cluster node, network and resource reporting since cluster was not available"
    }

    if ($SubsystemUnhealthy) {
        Write-Host "Clustered storage subsystem '$($Subsystem.FriendlyName)' not healthy:"
        Import-ClixmlIf (Join-Path $Path "DebugStorageSubsystem.XML") -MessageIf "Expected if cluster not available" | ft -AutoSize
    }

    if ($Cluster) {

        if ($CSVTotal -ne $CSVHealthy) {
            $Failed = $true
            Write-Host "Cluster Shared Volumes not Online:"
            $CSV |? State -ne "Online" | Format-Table -AutoSize
        }
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
        Import-ClixmlIf (Join-Path (Get-NodePath $Path $node) "GetDrivers.XML") |? {
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
        $CutoffMs = 500
    )

    # Common header for path validation

    if (-not (Test-Path $Path)) {
        Write-Error "Path is not accessible. Please check and try again: $Path"
        return
    }

    # Extract ZIP if neccesary
    $Path = (gi $Path).FullName
    $Path = Check-ExtractZip $Path

    # get the timebase from the capture parameters
    $Parameters = Import-ClixmlIf (Join-Path $Path "GetParameters.XML")
    $CaptureDate = $Parameters.TodayDate

    if ($Hours -eq -1 -or $Days -eq -1) {
        $HoursOfEvents = -1
    } elseif ($Hours) {
        $HoursOfEvents = $Hours
    } else {
        $HoursOfEvents = $Days * 24
    }

    $t0 = Get-Date

    Get-StorageLatencyReport -Path $Path -ReportLevel $ReportLevel -CutoffMs $CutoffMs -TimeBase $CaptureDate -HoursOfEvents $HoursOfEvents

    $td = (Get-Date) - $t0
    Write-Output ("Report took {0:N2} seconds" -f $td.TotalSeconds)
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

    if (-not (Test-Path $Path)) {
        Write-Error "Path is not accessible. Please check and try again: $Path"
        return
    }

    # Extract ZIP if neccesary
    $Path = (gi $Path).FullName
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

# DEPRECATED New-Alias -Value Get-SddcDiagnosticInfo -Name Test-StorageHealth # So, Original name when Jose started (CPSv1)
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
    'Show-StorageCounters',
    'Get-SpacesTimeline',
    'Set-SddcDiagnosticArchiveJobParameters',
    'Get-SddcDiagnosticArchiveJobParameters'