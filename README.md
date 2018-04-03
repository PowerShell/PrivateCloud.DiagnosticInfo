# PrivateCloud.DiagnosticInfo
# Overview
This module is used as a comprehensive diagnostic information gatherer for Microsoft Software Defined Datacenter solutions. It assumes deployment with compute and/or storage clusters running Windows Server 2016 or newer. The module has diagnostic commands like Get-PCStorageDiagnosticInfo (aka Test-StorageHealth) which performs specific health checks for Failover Clustering (Cluster, Resources, Networks, Nodes), Storage Spaces (Physical Disks, Enclosures, Virtual Disks), Cluster Shared Volumes, SMB File Shares and Deduplication. Sources available at Github ( http://github.com/Powershell/PrivateCloud.DiagnosticInfo) and download available via Powershell Gallery at (https://www.powershellgallery.com/packages/PrivateCloud.DiagnosticInfo)

Test-StorageHealth command in this module includes several sections, including:
1. Reporting of Storage Health, plus details on unhealthy components. 
2. Reporting of Storage Capacity by Pool, Volume and Deduplicated volume. 
3. Reporting of Storage Performance with IOPS and Latency per Volume 
4. Collection of event logs from all cluster nodes and Summary Error Report. 

# To install module from PowerShell gallery
Powershell gallery: https://www.powershellgallery.com/packages/PrivateCloud.DiagnosticInfo
Note: Installing items from the Gallery requires the latest version of the PowerShellGet module, which is available in Windows 10, in Windows Management Framework (WMF) 5.0, or in the MSI-based installer (for PowerShell 3 and 4).

Install the module by running following command in PowerShell with administrator priviledges
``` PowerShell
Install-Module PrivateCloud.DiagnosticInfo -Verbose
```
Update the module by running following command in PowerShell
``` PowerShell
Update-Module PrivateCloud.DiagnosticInfo -Verbose
```
# To install module from GitHub
Download the latest module from github - https://github.com/PowerShell/PrivateCloud.DiagnosticInfo/archive/master.zip and extract directory PrivateCloud.DiagnosticInfo to the correct powershell modules path pointed by $env:PSModulePath

``` PowerShell
Invoke-WebRequest -Uri "https://github.com/PowerShell/PrivateCloud.DiagnosticInfo/archive/master.zip" -outfile "$env:TEMP\master.zip" -Verbose
Expand-Archive -Path "$env:TEMP\master.zip" -DestinationPath "$env:TEMP" -Force -Verbose
Copy-Item -Recurse -Path "$env:TEMP\PrivateCloud.DiagnosticInfo-master\PrivateCloud.DiagnosticInfo" -Destination "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\" -Force -Verbose
Import-Module PrivateCloud.DiagnosticInfo -Verbose
Get-Command -Module PrivateCloud.DiagnosticInfo
Get-Help Test-StorageHealth
``` 

# To execute against a remote storage cluster
Note: Example below runs against storage cluster name "CLUS01"
``` PowerShell
Test-StorageHealth -ClusterName CLUS01 -Verbose
```

# To execute locally on clustered storage node
``` PowerShell
Test-StorageHealth -Verbose
```

# To save results to a specified folder
``` PowerShell
Test-StorageHealth -WriteToPath D:\Folder 
```

# To review results previously save to a folder
``` PowerShell
Test-StorageHealth -ReadFromPath D:\Folder 
```

# To exclude events from data collection
``` PowerShell
Test-StorageHealth -IncludeEvents:$false
```

# What to expect next?
A lot of improvements and new cmdlets to analyze SDDC system health.
Provide feedback on what you'd like to see.

# What does the cmdlet output include?
## Files Collected
 0_CloudHealthSummary.log
## XML Files
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

## Cluster & Health log
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

