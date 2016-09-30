# PrivateCloud.DiagnosticInfo
# Overview
This module is used to check the health, diagnostics and capacity of a private clouds. It assumes private cloud deployment with compute and/or storage clusters running Windows Server 2012 R2 or Windows Server 2016.The module has diagnostic commands like Get-PCStorageDiagnosticInfo (aka Test-StorageHealth) which performs specific health checks for Failover Clustering (Cluster, Resources, Networks, Nodes), Storage Spaces (Physical Disks, Enclosures, Virtual Disks), Cluster Shared Volumes, SMB File Shares and Deduplication. Sources available at Github ( http://github.com/Powershell/PrivateCloud.DiagnosticInfo) and download available via Powershell Gallery at (https://www.powershellgallery.com/packages/PrivateCloud.DiagnosticInfo)

Test-StorageHealth command in this module includes several sections, including:
1. Reporting of Storage Health, plus details on unhealthy components. 
2. Reporting of Storage Capacity by Pool, Volume and Deduplicated volume. 
3. Reporting of Storage Performance with IOPS and Latency per Volume 
4. Collection of event logs from all cluster nodes and Summary Error Report. 

Get-PCAzureStackACSDiagnosticInfo command in this module will collect Azure Stack consistent storage diagnostic information, including logs, related events and dumps.

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

# To collect debug logs of Azure Stack Consistent Storage
1. Log on to any cluster VM or the host with domain admin credential.
2. Create a log folder or use an existing folder to store collected logs. e.g. Folder on the share: \\\\SU1FileServer\\SU1_Tenant_1
3. Run the following scripts, update the StartTime and EndTime value with your own preferred time range. Make sure you do set the SettingsStoreLiteralPath if you are not running the command on an ACS Node.
4. Collected log files will be compacted and saved as [TargetFolderPath]/ACSLogs_[datetime].zip

Default value of StartTime is two hours before current time, default value of EndTime is current time.
Default value fo TargetFolderPath is $env:temp.

``` PowerShell
$end = get-date 
$start = $end.AddMinutes(-10) 
$output = “\\SU1FileServer\SU1_Tenant_1” 
Get-PCAzureStackACSDiagnosticInfo –StartTime $start –EndTime $end –TargetFolderPath $output -SettingsStoreLiteralPath file:\\SU1FileServer\SU1_Infrastructure_1\ObjectStorageService\Settings -Verbose
```

# What to expect next ?
A lot of improvements and new cmdlets to analyze the cloud health.
Provide feedback on what you'd like to see.
