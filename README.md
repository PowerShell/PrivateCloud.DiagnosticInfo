PrivateCloud.DiagnosticInfo
===========================
# Overview
This module contains the comprehensive diagnostic information gatherer for Microsoft Software Defined Datacenter solutions. It assumes deployment with compute and/or storage clusters running Windows Server 2016 or newer. The module has the diagnostic commands Get-SDDCDiagnosticInfo (previously Get-PCStorageDiagnosticInfo), which gathers triage payload, and Show-SDDCDiagnosticReport, which provides a number of reports & health checks for Failover Clustering (Cluster, Resources, Networks, Nodes), Storage and Storage Spaces Direct (Physical Disks, Enclosures, Virtual Disks), Cluster Shared Volumes, SMB File Shares, and Deduplication. Sources available at GitHub ( http://github.com/Powershell/PrivateCloud.DiagnosticInfo) and download available via Powershell Gallery at (https://www.powershellgallery.com/packages/PrivateCloud.DiagnosticInfo)

The Get-SDDCDiagnosticInfo command in this module includes several sections, including:
1. Gathering of cluster, cluster Health service and event logs from all cluster nodes to a ZIP archive
2. Reporting of Storage Health, plus details on unhealthy components.
3. Reporting of Storage Capacity by Pool, Volume and Deduplicated volumes.
4. Reporting of Storage Performance with IOPS and Latency per Volume

By default the ZIP archive will be created at $env:USERPROFILE\HealthTest-<cluster\>-<timestamp\>.ZIP. A temporary folder "HealthTest" will be used at the same location during the gathering process.
## What to expect next?
A lot of improvements and new cmdlets to analyze SDDC system health.
Provide feedback on what you'd like to see.

## To install module from PowerShell gallery
Powershell gallery: https://www.powershellgallery.com/packages/PrivateCloud.DiagnosticInfo
Note: Installing items from the Gallery requires the latest version of the PowerShellGet module, which is available in Windows 10. Installation will generally require administrative privileges.

``` PowerShell
Install-PackageProvider PowerShellGet
```
Install the module by running following command in PowerShell
``` PowerShell
Install-Module PrivateCloud.DiagnosticInfo
```
Update the module by running following command in PowerShell
``` PowerShell
Update-Module PrivateCloud.DiagnosticInfo
```
## To install module from GitHub
Download the latest module from github - https://github.com/PowerShell/PrivateCloud.DiagnosticInfo/archive/master.zip and extract directory PrivateCloud.DiagnosticInfo to the correct powershell modules path pointed by $env:PSModulePath

``` PowerShell
# Allow Tls12 and Tls11 -- GitHub now requires Tls12
# If this is not set, the Invoke-WebRequest fails with "The request was aborted: Could not create SSL/TLS secure channel."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

$module = 'PrivateCloud.DiagnosticInfo'; $branch = 'master'
Invoke-WebRequest -Uri https://github.com/PowerShell/$module/archive/$branch.zip -OutFile $env:TEMP\$branch.zip
Expand-Archive -Path $env:TEMP\$branch.zip -DestinationPath $env:TEMP -Force
if (Test-Path $env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\$module) {
       rm -Recurse $env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\$module -ErrorAction Stop
       Remove-Module $module -ErrorAction SilentlyContinue
} else {
       Import-Module $module -ErrorAction SilentlyContinue
}
if (-not ($m = Get-Module $module -ErrorAction SilentlyContinue)) {
       $md = "$env:ProgramFiles\WindowsPowerShell\Modules"
} else {
       $md = (gi $m.ModuleBase -ErrorAction SilentlyContinue).PsParentPath
       Remove-Module $module -ErrorAction SilentlyContinue
       rm -Recurse $m.ModuleBase -ErrorAction Stop
}
cp -Recurse $env:TEMP\$module-$branch\$module $md -Force -ErrorAction Stop
rm -Recurse $env:TEMP\$module-$branch,$env:TEMP\$branch.zip
Import-Module $module -Force  
Get-Command -Module PrivateCloud.DiagnosticInfo
Get-Help Get-SDDCDiagnosticInfo
```
# Examples
## To execute on the cluster the current node is a member of
``` PowerShell
Get-SDDCDiagnosticInfo
```
## To execute against a remote cluster
``` PowerShell
Get-SDDCDiagnosticInfo -ClusterName CLUS01
```
## To specify a folder for temporary content during gather
``` PowerShell
Get-SDDCDiagnosticInfo -WriteToPath D:\Folder
```
## To specify where to create the gathered ZIP
``` PowerShell
Get-SDDCDiagnosticInfo -ZipPrefix D:\MyHealth
```
The ZIP will be placed at <ZipPrefix\>-<cluster\>-<timestamp\>.ZIP

This example would result in a form like: D:\MyHealth-MyCluster-20180615-1256.ZIP
## To review the summary report from previously gathered results
``` PowerShell
Get-SDDCDiagnosticInfo -ReadFromPath D:\HealthTest-MyCluster-20180615-1232.ZIP
```
or equivalently
``` PowerShell
Show-SDDCDiagnosticReport -Report Summary D:\HealthTest-MyCluster-20180615-1232.ZIP
```
The summary report generated at the time of gather is at 0_CloudHealthSummary.log in the ZIP. The commands above re-generate the report based on the currently installed PrivateCloud.DiagnosticInfo module - if newer, additional reporting may be available.
## To review all of the available reports
``` PowerShell
Show-SddcDiagnosticReport D:\HealthTest-MyCluster-20180615-1232.ZIP
```
# What does the gather include by default?
Transcripts of the gather process and its summary report.
- 0_CloudHealthGatherTranscript.log
- 0_CloudHealthSummary.log

## Whole cluster data
As XML files (Import-Clixml)
-	GetAllErrors.XML
-	GetAssociations.XML
-	GetCluster.XML
-	GetClusterGroup.XML
-	GetClusterNetwork.XML
-	GetClusterNode.XML
-	GetClusterResource.XML
-	GetClusterSharedVolume.XML
-	GetDedupVolume.XML
-	GetNetAdapter_NodeName.FQDN.XML
-	GetParameters.XML
-	GetPhysicalDisk.XML
-	GetReliabilityCounter.XML
-	GetSmbOpenFile.XML
-	GetSmbServerNetworkInterface_NodeName.FQDN.XML
-	GetSmbWitness.XML
-	GetStorageEnclosure.XML
-	GetStorageNodeView.XML
-	GetStoragePool.XML
-	GetVirtualDisk.XML
-	GetVolume.XML
-	NonHealthyVDs.XML
-	NodeName_GetDrivers.XML

Cluster & Health log
- NodeName.FQDN_cluster.log
- NodeName.FQDN_health.log

## System Information (MSInfo32)
- NodeName.FQDN_SystemInfo.TXT

## Event Logs (unfiltered)
- NodeName_UnfilteredEvent_Application.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-BranchCacheSMB-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-CloudStorageWizard-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-DiskDiagnostic-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-DiskDiagnosticDataCollector-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-DiskDiagnosticResolver-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-ClusBflt-Management.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-ClusBflt-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-Clusport-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-CsvFs-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-Diagnostic.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-DiagnosticVerbose.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-Manager-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-Manager-Diagnostic.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-Manager-Tracing.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-NetFt-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-FailoverClustering-WMIProvider-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Compute-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Compute-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Config-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Config-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Guest-Drivers-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Guest-Drivers-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-High-Availability-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Hypervisor-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Hypervisor-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Shared-VHDX-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Shared-VHDX-Reservation.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-StorageVSP-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-VID-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-VMMS-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-VMMS-Networking.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-VMMS-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-VMMS-Storage.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-VmSwitch-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Hyper-V-Worker-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-ApphelpCache-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-Boot-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-EventTracing-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-IO-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-PnP-Configuration.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-Power-Thermal-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-ShimEngine-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-StoreMgr-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-WDI-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-WHEA-Errors.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Kernel-WHEA-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Ntfs-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Ntfs-WHC.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-ResumeKeyFilter-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-ScmDisk0101-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SmbClient-Connectivity.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBClient-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SmbClient-Security.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBDirect-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBServer-Audit.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBServer-Connectivity.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBServer-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBServer-Security.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBWitnessClient-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBWitnessClient-Informational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-SMBWitnessServer-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-ATAPort-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-ATAPort-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-ClassPnP-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-ClassPnP-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-Disk-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-Disk-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-Storport-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-Storport-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-Storage-Tiering-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-StorageManagement-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-StorageSpaces-Driver-Diagnostic.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-StorageSpaces-Driver-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-StorageSpaces-ManagementAgent-WHC.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-StorageSpaces-SpaceManager-Diagnostic.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-StorageSpaces-SpaceManager-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-TerminalServices-PnPDevices-Admin.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-TerminalServices-PnPDevices-Operational.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-UserPnp-ActionCenter.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-UserPnp-DeviceInstall.EVTX
- NodeName_UnfilteredEvent_Microsoft-Windows-VHDMP-Operational.EVTX
- NodeName_UnfilteredEvent_System.EVTX   

## Storage Diagnostics
- OperationalLog.evtx
- OperationalLog_0.MTA
