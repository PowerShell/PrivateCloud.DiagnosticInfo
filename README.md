# Cloud.Health
# Overview
This module is used to check the health, diagnostics and capacity of a private clouds. It assumes private cloud deployment with compute and/or storage clusters running Windows Server 2012 R2 or Windows Server 2016.The module has diagnostic commands like Test-StorageHealth which performs specific health checks for Failover Clustering (Cluster, Resources, Networks, Nodes), Storage Spaces (Physical Disks, Enclosures, Virtual Disks), Cluster Shared Volumes, SMB File Shares and Deduplication. Sources available at Github ( http://github.com/Powershell/PrivateCloud.Health) and download available via Powershell Gallery at (https://www.powershellgallery.com/packages/PrivateCloud.Health)

Test-StorageHealth command in this module includes several sections, including:
1. Reporting of Storage Health, plus details on unhealthy components. 
2. Reporting of Storage Capacity by Pool, Volume and Deduplicated volume. 
3. Reporting of Storage Performance with IOPS and Latency per Volume 
4. Collection of event logs from all cluster nodes and Summary Error Report. 

# To install module from PowerShell gallery
Powershell gallery: https://www.powershellgallery.com/packages/PrivateCloud.Health
Note: Installing items from the Gallery requires the latest version of the PowerShellGet module, which is available in Windows 10, in Windows Management Framework (WMF) 5.0, or in the MSI-based installer (for PowerShell 3 and 4).

Install the module by running following command in PowerShell with administrator priviledges
``` PowerShell
Install-Module PrivateCloud.Health -Verbose
```
Update the module by running following command in PowerShell
``` PowerShell
Update-Module PrivateCloud.Health -Verbose
```
# To install module from GitHub
Download the latest module from github - https://github.com/PowerShell/PrivateCloud.Health/archive/master.zip and extract directory Cloud.Health to the correct powershell modules path pointed by $env:PSModulePath

``` PowerShell
Invoke-WebRequest -Uri "https://github.com/PowerShell/PrivateCloud.Health/archive/master.zip" -outfile "$env:TEMP\master.zip" -Verbose
Expand-Archive -Path "$env:TEMP\master.zip" -DestinationPath "$env:TEMP" -Force -Verbose
Copy-Item -Recurse -Path "$env:TEMP\PrivateCloud.Health-master\PrivateCloud.Health" -Destination "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\" -Force -Verbose
Import-Module PrivateCloud.Health -Verbose
Get-Command -Module PrivateCloud.Health
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

# What to expect next ?
A lot of improvements and new cmdlets to analyze the cloud health.
Provide feedback on what you'd like to see.
