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

**Note**: this is generally deprecated unless you are working directly with Microsoft engineering. For normal usage please acquire the module from the Powershell Gallery.

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

## Whole-cluster data
Whole-cluster data as Powershell object XML export files (Import-Clixml)
- GetCluster.XML : **Get-Cluster**
- GetClusterGroup.XML : **Get-ClusterGroup**
- GetClusterNetwork.XML : **Get-ClusterNetwork**
- GetClusterNode.XML : **Get-ClusterNode**
- GetClusterResource.XML : **Get-ClusterResource**
- GetClusterResourceParameters.XML : **Get-ClusterResource** | **Get-ClusterParameter**
- GetClusterSharedVolume.XML : **Get-ClusterSharedVolume**
- GetParameters.XML : Parameters provided to **Get-SDDCDiagnosticInfo**
- GetPhysicalDisk.XML : **Get-PhysicalDisk** at the StorageSubsystem
- GetPhysicalDiskSNV.XML : **Get-PhysicalDiskSNV** at the StorageSubsystem
- GetPhysicalDisk_Pool.xml : **Get-PhysicalDisk** at the StoragePool
- GetSmbOpenFile.XML : **Get-SMBOpenFile**
- GetSmbWitness.XML : **Get-SMBWitnessClient**
- GetStorageEnclosure.XML : **Get-StoragEnclosure** at the StorageSubsystem
- GetStorageFaultDomain_SSU.xml : **Get-StorageFaultDomain** at the StorageSubsystem, for StorageScaleUnits
- GetStorageJob.XML : **Get-StorageJob**
- GetStoragePool.XML : **Get-StoragePool** at the StorageSubsystem, all non-primordial
- GetStorageSubsystem.XML : **Get-StorageSubsystem** for the clustered StorageSubsystem
- GetStorageTier.XML : **Get-StorageTier**
- GetVirtualDisk.XML : **Get-VirtualDisk** at the StorageSubsystem
- GetVolume.XML : **Get-Volume** at the StorageSubsystem
- ShareStatus.XML : **Get-SMBShare** with a 'Health' parameter added indicating accessibility at time of capture

### If de-duplication was present

-	GetDedupVolume.XML : **Get-DedupStatus**

### If the clustered storage subsystem was not healthy

- DebugStorageSubsystem.XML : **Debug-StorageSubsystem** at the StorageSubsystem

### Performance counters

- GetCounters.blg

### Cluster & Health logs
- NodeName.FQDN_cluster.log : **Get-ClusterLog**
- NodeName.FQDN_health.log : **Get-ClusterLog** -Health

### If the Sddc Diagnostic Archive was active

- SddcDiagnosticArchiveJob.txt : **Show-SddcDiagnosticArchiveJob**
- SddcDiagnosticArchiveJobWarn.txt : any WARNINGs from **Show-SddcDiagnosticArchiveJob**

## Per node

Per-node data as Powershell object XML export files (Import-Clixml)

- ClusBflt.xml : **Get-CimInstance** -Namespace root\wmi -ClassName **ClusBfltDeviceInformation** (S2D Cache/Target)
- ClusPort.xml : **Get-CimInstance** -Namespace root\wmi -ClassName **ClusPortDeviceInformation** (S2D Client)
- GetDrivers.XML : **Get-CimInstance** -ClassName Win32_PnPSignedDriver

As XML and text

- GetHotFix.xml : **Get-HotFix**
- GetScheduledTask.xml : **Get-ScheduledTask**
- GetSmbServerNetworkInterface.xml : **Get-SmbServerNetworkInterface**

Network focused, as XML and text

- GetNetAdapter.xml : **Get-NetAdapter**
- GetNetAdapterAdvancedProperty.xml : **Get-NetAdapterAdvancedProperty**
- GetNetAdapterBinding.xml : **Get-NetAdapterBinding**
- GetNetAdapterChecksumOffload.xml : **Get-NetAdapterChecksumOffload**
- GetNetAdapterIPsecOffload.xml : **Get-NetAdapterIPsecOffload**
- GetNetAdapterLso.xml : **Get-NetAdapterLso**
- GetNetAdapterPacketDirect.xml : **Get-NetAdapterPacketDirect**
- GetNetAdapterRdma.xml : **Get-NetAdapterRdma**
- GetNetAdapterRsc.xml : **GetNetAdapterRsc**
- GetNetIpAddress.xml : **Get-NetIpAddress**
- GetNetAdapterRss.xml : **GetNetAdapterRss**
- GetNetIPv4Protocol.xml : **Get-NetIPv4Protocol**
- GetNetIPv6Protocol.xml : **Get-NetIPv6Protocol**
- GetNetLbfoTeam.xml : **Get-NetLbfoTeam**
- GetNetLbfoTeamMember.xml : **Get-NetLbfoTeamMember**
- GetNetLbfoTeamNic.xml : **Get-NetLbfoTeamNic**
- GetNetOffloadGlobalSetting.xml : **Get-NetOffloadGlobalSetting**
- GetNetPrefixPolicy.xml : **Get-NetPrefixPolicy**
- GetNetQosPolicy.xml : **Get-NetQosPolicy**
- GetNetRoute.xml : **Get-NetRoute**
- GetNetTCPConnection.xml : **Get-NetTcpConnection**
- GetNetTcpSetting.xml **Get-NetTcpSetting**

### System Information (SystemInfo.exe)
- SystemInfo.txt

### System verifier configuration
- verifier-query.txt : **verifer** /query
- verifier-querysettings.txt : **verifier** /querysettings

### Event Logs
Application and System events:
- Application.EVTX
- System.EVTX

All event channels prefixed with the following:

- Microsoft-Windows-ClusterAwareUpdating
- Microsoft-Windows-DataIntegrityScan
- Microsoft-Windows-FailoverClustering
- Microsoft-Windows-HostGuardian
- Microsoft-Windows-Hyper-V
- Microsoft-Windows-Kernel
- Microsoft-Windows-NDIS
- Microsoft-Windows-Network
- Microsoft-Windows-NTFS
- Microsoft-Windows-REFS
- Microsoft-Windows-ResumeKeyFilter
- Microsoft-Windows-SMB
- Microsoft-Windows-Storage
- Microsoft-Windows-TCPIP
- Microsoft-Windows-VHDMP
- Microsoft-Windows-WMI-Activity

Certain channels may be excluded for size and value considerations. At this time, that includes:

- Microsoft-Windows-FailoverClustering/Diagnostic
- Microsoft-Windows-FailoverClustering/DiagnosticVerbose
- Microsoft-Windows-FailoverClustering-Client/Diagnostic
- Microsoft-Windows-StorageSpaces-Driver/Performance

On Windows Server 2016, this results in the following being captured. Note that if event channels are
added which match the criteria above, they will be automatically added to the capture.

- Microsoft-Windows-ClusterAwareUpdating-Admin.EVTX
- Microsoft-Windows-ClusterAwareUpdating-Debug.EVTX
- Microsoft-Windows-ClusterAwareUpdating-Management-Admin.EVTX
- Microsoft-Windows-DataIntegrityScan-Admin.EVTX
- Microsoft-Windows-DataIntegrityScan-CrashRecovery.EVTX
- Microsoft-Windows-FailoverClustering-ClusBflt-Diagnostic.EVTX
- Microsoft-Windows-FailoverClustering-ClusBflt-Management.EVTX
- Microsoft-Windows-FailoverClustering-ClusBflt-Operational.EVTX
- Microsoft-Windows-FailoverClustering-Clusport-Diagnostic.EVTX
- Microsoft-Windows-FailoverClustering-Clusport-Operational.EVTX
- Microsoft-Windows-FailoverClustering-CsvFlt-Diagnostic.EVTX
- Microsoft-Windows-FailoverClustering-CsvFs-Diagnostic.EVTX
- Microsoft-Windows-FailoverClustering-CsvFs-Operational.EVTX
- Microsoft-Windows-FailoverClustering-Manager-Admin.EVTX
- Microsoft-Windows-FailoverClustering-Manager-Diagnostic.EVTX
- Microsoft-Windows-FailoverClustering-Manager-Tracing.EVTX
- Microsoft-Windows-FailoverClustering-NetFt-Diagnostic.EVTX
- Microsoft-Windows-FailoverClustering-NetFt-Operational.EVTX
- Microsoft-Windows-FailoverClustering-Operational.EVTX
- Microsoft-Windows-FailoverClustering-Performance-CSV.EVTX
- Microsoft-Windows-FailoverClustering-WMIProvider-Admin.EVTX
- Microsoft-Windows-FailoverClustering-WMIProvider-Diagnostic.EVTX
- Microsoft-Windows-HostGuardianService-Client-Admin.EVTX
- Microsoft-Windows-HostGuardianService-Client-Analytic.EVTX
- Microsoft-Windows-HostGuardianService-Client-Debug.EVTX
- Microsoft-Windows-HostGuardianService-Client-Operational.EVTX
- Microsoft-Windows-Hyper-V-Compute-Admin.EVTX
- Microsoft-Windows-Hyper-V-Compute-Analytic.EVTX
- Microsoft-Windows-Hyper-V-Compute-Operational.EVTX
- Microsoft-Windows-Hyper-V-Config-Admin.EVTX
- Microsoft-Windows-Hyper-V-Config-Analytic.EVTX
- Microsoft-Windows-Hyper-V-Config-Operational.EVTX
- Microsoft-Windows-Hyper-V-Guest-Drivers-Admin.EVTX
- Microsoft-Windows-Hyper-V-Guest-Drivers-Analytic.EVTX
- Microsoft-Windows-Hyper-V-Guest-Drivers-Debug.EVTX
- Microsoft-Windows-Hyper-V-Guest-Drivers-Diagnose.EVTX
- Microsoft-Windows-Hyper-V-Guest-Drivers-Operational.EVTX
- Microsoft-Windows-Hyper-V-High-Availability-Admin.EVTX
- Microsoft-Windows-Hyper-V-High-Availability-Analytic.EVTX
- Microsoft-Windows-Hyper-V-Hypervisor-Admin.EVTX
- Microsoft-Windows-Hyper-V-Hypervisor-Analytic.EVTX
- Microsoft-Windows-Hyper-V-Hypervisor-Operational.EVTX
- Microsoft-Windows-Hyper-V-NETVSC-Diagnostic.EVTX
- Microsoft-Windows-Hyper-V-Shared-VHDX-Diagnostic.EVTX
- Microsoft-Windows-Hyper-V-Shared-VHDX-Operational.EVTX
- Microsoft-Windows-Hyper-V-Shared-VHDX-Reservation.EVTX
- Microsoft-Windows-Hyper-V-StorageVSP-Admin.EVTX
- Microsoft-Windows-Hyper-V-VfpExt-Analytic.EVTX
- Microsoft-Windows-Hyper-V-VID-Admin.EVTX
- Microsoft-Windows-Hyper-V-VID-Analytic.EVTX
- Microsoft-Windows-Hyper-V-VMMS-Admin.EVTX
- Microsoft-Windows-Hyper-V-VMMS-Analytic.EVTX
- Microsoft-Windows-Hyper-V-VMMS-Networking.EVTX
- Microsoft-Windows-Hyper-V-VMMS-Operational.EVTX
- Microsoft-Windows-Hyper-V-VMMS-Storage.EVTX
- Microsoft-Windows-Hyper-V-VMSP-Debug.EVTX
- Microsoft-Windows-Hyper-V-VmSwitch-Diagnostic.EVTX
- Microsoft-Windows-Hyper-V-VmSwitch-Operational.EVTX
- Microsoft-Windows-Hyper-V-Worker-Admin.EVTX
- Microsoft-Windows-Hyper-V-Worker-Analytic.EVTX
- Microsoft-Windows-Hyper-V-Worker-VDev-Analytic.EVTX
- Microsoft-Windows-Kernel-Acpi-Diagnostic.EVTX
- Microsoft-Windows-Kernel-AppCompat-General.EVTX
- Microsoft-Windows-Kernel-AppCompat-Performance.EVTX
- Microsoft-Windows-Kernel-ApphelpCache-Analytic.EVTX
- Microsoft-Windows-Kernel-ApphelpCache-Debug.EVTX
- Microsoft-Windows-Kernel-ApphelpCache-Operational.EVTX
- Microsoft-Windows-Kernel-Boot-Analytic.EVTX
- Microsoft-Windows-Kernel-Boot-Operational.EVTX
- Microsoft-Windows-Kernel-BootDiagnostics-Diagnostic.EVTX
- Microsoft-Windows-Kernel-Disk-Analytic.EVTX
- Microsoft-Windows-Kernel-EventTracing-Admin.EVTX
- Microsoft-Windows-Kernel-EventTracing-Analytic.EVTX
- Microsoft-Windows-Kernel-File-Analytic.EVTX
- Microsoft-Windows-Kernel-Interrupt-Steering-Diagnostic.EVTX
- Microsoft-Windows-Kernel-IO-Operational.EVTX
- Microsoft-Windows-Kernel-LiveDump-Analytic.EVTX
- Microsoft-Windows-Kernel-Memory-Analytic.EVTX
- Microsoft-Windows-Kernel-Network-Analytic.EVTX
- Microsoft-Windows-Kernel-Pdc-Diagnostic.EVTX
- Microsoft-Windows-Kernel-Pep-Diagnostic.EVTX
- Microsoft-Windows-Kernel-PnP-Boot Diagnostic.EVTX
- Microsoft-Windows-Kernel-PnP-Configuration Diagnostic.EVTX
- Microsoft-Windows-Kernel-PnP-Configuration.EVTX
- Microsoft-Windows-Kernel-PnP-Device Enumeration Diagnostic.EVTX
- Microsoft-Windows-Kernel-PnP-Driver Diagnostic.EVTX
- Microsoft-Windows-Kernel-Power-Diagnostic.EVTX
- Microsoft-Windows-Kernel-Power-Thermal-Diagnostic.EVTX
- Microsoft-Windows-Kernel-Power-Thermal-Operational.EVTX
- Microsoft-Windows-Kernel-Prefetch-Diagnostic.EVTX
- Microsoft-Windows-Kernel-Process-Analytic.EVTX
- Microsoft-Windows-Kernel-Processor-Power-Diagnostic.EVTX
- Microsoft-Windows-Kernel-Registry-Analytic.EVTX
- Microsoft-Windows-Kernel-Registry-Performance.EVTX
- Microsoft-Windows-Kernel-ShimEngine-Debug.EVTX
- Microsoft-Windows-Kernel-ShimEngine-Diagnostic.EVTX
- Microsoft-Windows-Kernel-ShimEngine-Operational.EVTX
- Microsoft-Windows-Kernel-StoreMgr-Analytic.EVTX
- Microsoft-Windows-Kernel-StoreMgr-Operational.EVTX
- Microsoft-Windows-Kernel-WDI-Analytic.EVTX
- Microsoft-Windows-Kernel-WDI-Debug.EVTX
- Microsoft-Windows-Kernel-WDI-Operational.EVTX
- Microsoft-Windows-Kernel-WHEA-Errors.EVTX
- Microsoft-Windows-Kernel-WHEA-Operational.EVTX
- Microsoft-Windows-Kernel-XDV-Analytic.EVTX
- Microsoft-Windows-NDIS-Diagnostic.EVTX
- Microsoft-Windows-NDIS-Operational.EVTX
- Microsoft-Windows-NDIS-PacketCapture-Diagnostic.EVTX
- Microsoft-Windows-NdisImPlatform-Operational.EVTX
- Microsoft-Windows-Network-and-Sharing-Center-Diagnostic.EVTX
- Microsoft-Windows-Network-Connection-Broker.EVTX
- Microsoft-Windows-Network-DataUsage-Analytic.EVTX
- Microsoft-Windows-Network-Setup-Diagnostic.EVTX
- Microsoft-Windows-NetworkBridge-Diagnostic.EVTX
- Microsoft-Windows-NetworkController-NcHostAgent-Admin.EVTX
- Microsoft-Windows-Networking-Correlation-Diagnostic.EVTX
- Microsoft-Windows-Networking-RealTimeCommunication-Tracing.EVTX
- Microsoft-Windows-NetworkLocationWizard-Operational.EVTX
- Microsoft-Windows-NetworkProfile-Diagnostic.EVTX
- Microsoft-Windows-NetworkProfile-Operational.EVTX
- Microsoft-Windows-NetworkProvider-Operational.EVTX
- Microsoft-Windows-NetworkSecurity-Debug.EVTX
- Microsoft-Windows-NetworkStatus-Analytic.EVTX
- Microsoft-Windows-Ntfs-Operational.EVTX
- Microsoft-Windows-Ntfs-Performance.EVTX
- Microsoft-Windows-Ntfs-WHC.EVTX
- Microsoft-Windows-ReFS-Operational.EVTX
- Microsoft-Windows-ResumeKeyFilter-Analytic.EVTX
- Microsoft-Windows-ResumeKeyFilter-Operational.EVTX
- Microsoft-Windows-ResumeKeyFilter-Performance.EVTX
- Microsoft-Windows-SMBClient-Analytic.EVTX
- Microsoft-Windows-SmbClient-Connectivity.EVTX
- Microsoft-Windows-SmbClient-Diagnostic.EVTX
- Microsoft-Windows-SMBClient-HelperClassDiagnostic.EVTX
- Microsoft-Windows-SMBClient-ObjectStateDiagnostic.EVTX
- Microsoft-Windows-SMBClient-Operational.EVTX
- Microsoft-Windows-SmbClient-Security.EVTX
- Microsoft-Windows-SMBDirect-Admin.EVTX
- Microsoft-Windows-SMBDirect-Debug.EVTX
- Microsoft-Windows-SMBDirect-Netmon.EVTX
- Microsoft-Windows-SMBServer-Analytic.EVTX
- Microsoft-Windows-SMBServer-Audit.EVTX
- Microsoft-Windows-SMBServer-Connectivity.EVTX
- Microsoft-Windows-SMBServer-Diagnostic.EVTX
- Microsoft-Windows-SMBServer-Operational.EVTX
- Microsoft-Windows-SMBServer-Performance.EVTX
- Microsoft-Windows-SMBServer-Security.EVTX
- Microsoft-Windows-SMBWitnessClient-Admin.EVTX
- Microsoft-Windows-SMBWitnessClient-Informational.EVTX
- Microsoft-Windows-SMBWitnessServer-Admin.EVTX
- Microsoft-Windows-Storage-ATAPort-Admin.EVTX
- Microsoft-Windows-Storage-ATAPort-Analytic.EVTX
- Microsoft-Windows-Storage-ATAPort-Debug.EVTX
- Microsoft-Windows-Storage-ATAPort-Diagnose.EVTX
- Microsoft-Windows-Storage-ATAPort-Operational.EVTX
- Microsoft-Windows-Storage-ClassPnP-Admin.EVTX
- Microsoft-Windows-Storage-ClassPnP-Analytic.EVTX
- Microsoft-Windows-Storage-ClassPnP-Debug.EVTX
- Microsoft-Windows-Storage-ClassPnP-Diagnose.EVTX
- Microsoft-Windows-Storage-ClassPnP-Operational.EVTX
- Microsoft-Windows-Storage-Disk-Admin.EVTX
- Microsoft-Windows-Storage-Disk-Analytic.EVTX
- Microsoft-Windows-Storage-Disk-Debug.EVTX
- Microsoft-Windows-Storage-Disk-Diagnose.EVTX
- Microsoft-Windows-Storage-Disk-Operational.EVTX
- Microsoft-Windows-Storage-Storport-Admin.EVTX
- Microsoft-Windows-Storage-Storport-Analytic.EVTX
- Microsoft-Windows-Storage-Storport-Debug.EVTX
- Microsoft-Windows-Storage-Storport-Diagnose.EVTX
- Microsoft-Windows-Storage-Storport-Operational.EVTX
- Microsoft-Windows-Storage-Tiering-Admin.EVTX
- Microsoft-Windows-Storage-Tiering-IoHeat-Heat.EVTX
- Microsoft-Windows-StorageManagement-Debug.EVTX
- Microsoft-Windows-StorageManagement-Operational.EVTX
- Microsoft-Windows-StorageSpaces-Driver-Diagnostic.EVTX
- Microsoft-Windows-StorageSpaces-Driver-Operational.EVTX
- Microsoft-Windows-StorageSpaces-ManagementAgent-WHC.EVTX
- Microsoft-Windows-StorageSpaces-SpaceManager-Diagnostic.EVTX
- Microsoft-Windows-StorageSpaces-SpaceManager-Operational.EVTX
- Microsoft-Windows-TCPIP-Diagnostic.EVTX
- Microsoft-Windows-TCPIP-Operational.EVTX
- Microsoft-Windows-VHDMP-Analytic.EVTX
- Microsoft-Windows-VHDMP-Operational.EVTX
- Microsoft-Windows-WMI-Activity-Debug.EVTX
- Microsoft-Windows-WMI-Activity-Operational.EVTX
- Microsoft-Windows-WMI-Activity-Trace.EVTX

### Additional captures in per-node subdirectories

The following subdirectories will appear per-node, containing additional captures.

- ClusterReports : all content at $env:SystemRoot\Cluster\Reports (validation reports, et.al.)
- LocaleMetaData : event log archive metadata for formatting event messages in the captured EVTX (wevtutil archive-log)
- SddcDiagnosticArchive : the Sddc Diagnostic Archive for the node

### Sddc Diagnostic Archive

The Sddc Diagnostic Archive is a series of timestamped ZIP containing a per-day snapshot of event, cluster and health logs. The event logs are the same as those mentioned previously.

- **Install-SddcDiagnosticModule** : install the Sddc Diagnostic Archive module (PrivateCloud.DiagnosticInfo) on a cluster/node
- **Confirm-SddcDiagnosticModule** : confirm (check) the status of the module on a cluster/node
- **Register-SddcDiagnosticArchiveJob** : register (start) the archive job for a cluster
- **Show-SddcDiagnosticArchiveJob** : show the state of the archive job for a cluster (module state, sizes)
- **Unregister-SddcDiagnosticArchiveJob** : unregister (remove/stop) the archive job for a cluster
- **Set-SddcDiagnosticArchiveJobParameters** : adjust garbage collection parameters for the diagnostic archive (days of, size, path)

See individual per-command help for more details.
