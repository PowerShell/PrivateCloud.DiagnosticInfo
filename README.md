# Cloud.Health
# Overview
This module is used to check the health and capacity of a Storage Cluster based on Windows Server 2012 R2 Scale-Out File Servers. By default it assumes a specific configuration for Private Clouds using the solution described at http://technet.microsoft.com/en-us/library/dn554251.aspx.

It performs specific health checks for
1. Failover Clustering (Cluster, Resources, Networks, Nodes)
2. Storage Spaces (Physical Disks, Enclosures, Virtual Disks)
3. Cluster Shared Volumes
4. SMB File Shares 
5. Deduplication 

It includes several sections, including:
1. Reporting of Storage Health, plus details on unhealthy components. 
2. Reporting of Storage Capacity by Pool, Volume and Deduplicated volume. 
3. Reporting of Storage Performance with IOPS and Latency per Volume 
4. Collection of event logs from all cluster nodes and Summary Error Report. 

# For basic operation
Test-StorageHealth 

# To save results to a specified folder
Test-StorageHealth -WriteToPath D:\Folder 

# To review results previously save to a folder
Test-StorageHealth -ReadFromPath D:\Folder 

# To execute against a remote cluster
Test-StorageHealth -ClusterName CLUS01 

# To exclude events and other diagnostic information 
Test-StorageHealth -IncludeEvents:$false

# To install module from PowerShell gallery
Installing items from the Gallery requires the latest version of the PowerShellGet module, which is available in Windows 10, in Windows Management Framework (WMF) 5.0, or in the MSI-based installer (for PowerShell 3 and 4). 
If any of the PowerShell gallery requirements are met, you can install the module directly by running 
"Install-Module Cloud.Health"

# To install without PowerShell gallery
1. Download and copy the directory Cloud.Health to the correct modules path pointed by $env:PSModulePath.
2. Run, "Import-Module Cloud.Health"
3. Start using the cmdlet(s)

# What to expect next ?
A lot of improvements and new cmdlets to better guage and analyze the cloud health.
Provide feedback on what you'd like to see.
