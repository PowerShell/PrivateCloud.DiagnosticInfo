# Cloud.Health
# Overview
This module is used to check the health, diagnostics and capacity of a private clouds. It assumes private cloud deployment with compute and/or storage clusters running Windows Server 2012 R2 or Windows Server 2016.The module has diagnostic commands like Test-StorageHealth which performs specific health checks for Failover Clustering (Cluster, Resources, Networks, Nodes), Storage Spaces (Physical Disks, Enclosures, Virtual Disks), Cluster Shared Volumes, SMB File Shares and Deduplication. Sources available at Github ( http://github.com/Powershell/Cloud.Health) and download available via Powershell Gallery at (https://www.powershellgallery.com/packages/Cloud.Health)

Test-StorageHealth command in this module includes several sections, including:
1. Reporting of Storage Health, plus details on unhealthy components. 
2. Reporting of Storage Capacity by Pool, Volume and Deduplicated volume. 
3. Reporting of Storage Performance with IOPS and Latency per Volume 
4. Collection of event logs from all cluster nodes and Summary Error Report. 

# To install module from PowerShell gallery
Powershell gallery: https://www.powershellgallery.com/packages/Cloud.Health
Note: Installing items from the Gallery requires the latest version of the PowerShellGet module, which is available in Windows 10, in Windows Management Framework (WMF) 5.0, or in the MSI-based installer (for PowerShell 3 and 4). 
Install the module by running following command in powershell
``` PowerShell
Install-Module Cloud.Health -Verbose
```
Update the module by running following command in powershell
``` PowerShell
Update-Module Cloud.Health -Verbose
```
# To install module without PowerShell gallery
1. Download the latest module from github - https://github.com/PowerShell/Cloud.Health/archive/master.zip
2. Extract directory Cloud.Health to the correct modules path pointed by $env:PSModulePath
3. Start using the cmdlet(s) made available via this module
``` PowerShell
Import-Module Cloud.Health -Verbose
Get-Command -Module Cloud.Health
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
A lot of improvements and new cmdlets to better guage and analyze the cloud health.
Provide feedback on what you'd like to see.
