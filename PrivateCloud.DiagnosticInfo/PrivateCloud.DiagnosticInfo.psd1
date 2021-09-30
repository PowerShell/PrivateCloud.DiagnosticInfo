#
# Module manifest for module 'PrivateCloud.DiagnosticInfo'
#
# Generated on: 4/25/2016
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'PrivateCloud.DiagnosticInfo.psm1'

# Version number of this module.
ModuleVersion = '1.1.37'

# ID used to uniquely identify this module
GUID = '7e0bc824-c371-4936-98e6-b7216ba5f348'

# Author of this module
Author = 'Microsoft Corporation'

# Company or vendor of this module
CompanyName = 'Microsoft Corporation'

# Copyright statement for this module
Copyright = '(c) 2016 Microsoft Corporation. All rights reserved.'

# Description of the functionality provided by this module
Description = 'Evaluates and Reports Windows Server Software Defined Data Center (SDDC) & Hyper-Converged Infrastrucure (HCI) Health'

# Minimum version of the Windows PowerShell engine required by this module
# PowerShellVersion = ''

# Name of the Windows PowerShell host required by this module
# PowerShellHostName = ''

# Minimum version of the Windows PowerShell host required by this module
# PowerShellHostVersion = ''

# Minimum version of Microsoft .NET Framework required by this module
# DotNetFrameworkVersion = ''

# Minimum version of the common language runtime (CLR) required by this module
# CLRVersion = ''

# Processor architecture (None, X86, Amd64) required by this module
# ProcessorArchitecture = ''

# Modules that must be imported into the global environment prior to importing this module
#RequiredModules = @(@{ModuleName = 'Get-NetView'; ModuleVersion = '2019.6.7.8'; })
RequiredModules = @()

# Assemblies that must be loaded prior to importing this module
# RequiredAssemblies = @()

# Script files (.ps1) that are run in the caller's environment prior to importing this module.
# ScriptsToProcess = @()

# Type files (.ps1xml) to be loaded when importing this module
# TypesToProcess = @()

# Format files (.ps1xml) to be loaded when importing this module
# FormatsToProcess = @()

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
# NestedModules = @()

# Functions to export from this module
FunctionsToExport = 'Get-SddcDiagnosticInfo',
                    'Show-SddcDiagnosticReport',
                    'Show-SddcDiagnosticStorageLatencyReport',
                    'Install-SddcDiagnosticModule',
                    'Confirm-SddcDiagnosticModule',
                    'Register-SddcDiagnosticArchiveJob',
                    'Unregister-SddcDiagnosticArchiveJob',
                    'Update-SddcDiagnosticArchive',
                    'Show-StorageCounters',
                    'Get-SpacesTimeline',
                    'Limit-SddcDiagnosticArchive',
                    'Show-SddcDiagnosticArchiveJob',
                    'Set-SddcDiagnosticArchiveJobParameters',
                    'Get-SddcDiagnosticArchiveJobParameters'

# Cmdlets to export from this module
# CmdletsToExport = @()

# Variables to export from this module
# VariablesToExport = ''

# Aliases to export from this module
AliasesToExport = 'gsddcdi',
                  'Get-PCStorageDiagnosticInfo',
                  'getpcsdi',
                  'Get-PCStorageReport'

# List of all modules packaged with this module
# ModuleList = @()

# List of all files packaged with this module
# FileList = @()

# Private data to pass to the module specified in RootModule/ModuleToProcess
# PrivateData = ''

# HelpInfo URI of this module
# HelpInfoURI = ''

# Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
# DefaultCommandPrefix = ''

}