#
# Module manifest for module 'PrivateCloud.DiagnosticInfo'
#
# Generated on: 4/25/2016
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'PrivateCloud.DiagnosticInfo.psm1'

# Version number of this module.
ModuleVersion = '1.1.8'

# ID used to uniquely identify this module
GUID = '7e0bc824-c371-4936-98e6-b7216ba5f348'

# Author of this module
Author = 'Microsoft Corporation'

# Company or vendor of this module
CompanyName = 'Microsoft Corporation'

# Copyright statement for this module
Copyright = '(c) 2016 Microsoft Corporation. All rights reserved.'

# Description of the functionality provided by this module
Description = 'Evaluates and Reports Windows Software Defined Data Center (SDDC) Health'

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
# RequiredModules = @()

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
# SIG # Begin signature block
# MIIjngYJKoZIhvcNAQcCoIIjjzCCI4sCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDxSgtDKFXEQn2K
# RQnUCsGhYLIHwF8GFCb81bpCbC6GPqCCDYEwggX/MIID56ADAgECAhMzAAABA14l
# HJkfox64AAAAAAEDMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMTgwNzEyMjAwODQ4WhcNMTkwNzI2MjAwODQ4WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDRlHY25oarNv5p+UZ8i4hQy5Bwf7BVqSQdfjnnBZ8PrHuXss5zCvvUmyRcFrU5
# 3Rt+M2wR/Dsm85iqXVNrqsPsE7jS789Xf8xly69NLjKxVitONAeJ/mkhvT5E+94S
# nYW/fHaGfXKxdpth5opkTEbOttU6jHeTd2chnLZaBl5HhvU80QnKDT3NsumhUHjR
# hIjiATwi/K+WCMxdmcDt66VamJL1yEBOanOv3uN0etNfRpe84mcod5mswQ4xFo8A
# DwH+S15UD8rEZT8K46NG2/YsAzoZvmgFFpzmfzS/p4eNZTkmyWPU78XdvSX+/Sj0
# NIZ5rCrVXzCRO+QUauuxygQjAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUR77Ay+GmP/1l1jjyA123r3f3QP8w
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDM3OTY1MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAn/XJ
# Uw0/DSbsokTYDdGfY5YGSz8eXMUzo6TDbK8fwAG662XsnjMQD6esW9S9kGEX5zHn
# wya0rPUn00iThoj+EjWRZCLRay07qCwVlCnSN5bmNf8MzsgGFhaeJLHiOfluDnjY
# DBu2KWAndjQkm925l3XLATutghIWIoCJFYS7mFAgsBcmhkmvzn1FFUM0ls+BXBgs
# 1JPyZ6vic8g9o838Mh5gHOmwGzD7LLsHLpaEk0UoVFzNlv2g24HYtjDKQ7HzSMCy
# RhxdXnYqWJ/U7vL0+khMtWGLsIxB6aq4nZD0/2pCD7k+6Q7slPyNgLt44yOneFuy
# bR/5WcF9ttE5yXnggxxgCto9sNHtNr9FB+kbNm7lPTsFA6fUpyUSj+Z2oxOzRVpD
# MYLa2ISuubAfdfX2HX1RETcn6LU1hHH3V6qu+olxyZjSnlpkdr6Mw30VapHxFPTy
# 2TUxuNty+rR1yIibar+YRcdmstf/zpKQdeTr5obSyBvbJ8BblW9Jb1hdaSreU0v4
# 6Mp79mwV+QMZDxGFqk+av6pX3WDG9XEg9FGomsrp0es0Rz11+iLsVT9qGTlrEOla
# P470I3gwsvKmOMs1jaqYWSRAuDpnpAdfoP7YO0kT+wzh7Qttg1DO8H8+4NkI6Iwh
# SkHC3uuOW+4Dwx1ubuZUNWZncnwa6lL2IsRyP64wggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVczCCFW8CAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAQNeJRyZH6MeuAAAAAABAzAN
# BglghkgBZQMEAgEFAKCBxjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgXMNKjAz8
# UzYIB3Jb1FRK7RkqGz1qCRlA0dASFxIVPd4wWgYKKwYBBAGCNwIBDDFMMEqgJIAi
# AE0AaQBjAHIAbwBzAG8AZgB0ACAAVwBpAG4AZABvAHcAc6EigCBodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vd2luZG93czANBgkqhkiG9w0BAQEFAASCAQCUya90YMQ5
# fTYNKjLVpjtnUxUS7jFdzqBPYH70SXhWtIm5uZ0aE6KQnPKtr66GREL5Iaw1ELEJ
# I8SgiVjry6NLBttVF7pOrUY3QQw+/MSd06dssW2GWovbUJGIW9mwg7LhG2XwOx5S
# rDhbPQSWA0s3j02MGO4u2yzG8k63XE2virZowlXNxKUAITd/0/xtS7ZR8/XJjQiH
# /fZ31PSBL/ttRI9CoCaVhU2Shzwvm60vJNOurePElROqYvDiS6X6ekIW44eG6UXU
# hTEbJFZdE5Rjk5mySGMLkKEPxHAcwWpEBbHaYbp7Skk6QcyhQ8MbS5VkP8K0hBBQ
# WZEoe4z/eb5XoYIS5TCCEuEGCisGAQQBgjcDAwExghLRMIISzQYJKoZIhvcNAQcC
# oIISvjCCEroCAQMxDzANBglghkgBZQMEAgEFADCCAVEGCyqGSIb3DQEJEAEEoIIB
# QASCATwwggE4AgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIHjyVk1U
# lNHCfV6qmeiJlPn6PXwbbYRGigeI40KJg9NnAgZcGAEp/IsYEzIwMTkwMTAyMjA1
# ODIwLjY3OVowBIACAfSggdCkgc0wgcoxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpX
# YXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlv
# bnMxJjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjQ5QkMtRTM3QS0yMzNDMSUwIwYD
# VQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIOPDCCBPEwggPZoAMC
# AQICEzMAAADu+MX1NjuBHIwAAAAAAO4wDQYJKoZIhvcNAQELBQAwfDELMAkGA1UE
# BhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAc
# BgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0
# IFRpbWUtU3RhbXAgUENBIDIwMTAwHhcNMTgxMDI0MjExNDE1WhcNMjAwMTEwMjEx
# NDE1WjCByjELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNV
# BAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMG
# A1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEmMCQGA1UECxMdVGhh
# bGVzIFRTUyBFU046NDlCQy1FMzdBLTIzM0MxJTAjBgNVBAMTHE1pY3Jvc29mdCBU
# aW1lLVN0YW1wIFNlcnZpY2UwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQCj91Y1hPPdNOSjk0hlspJpuKFRwvtRHgi+pYSv80hGm2wM3I/DgksSEbERXP8i
# sz7C3rfarJNFkfSK/xIWb9ItT8ggdgUhN0uf1P1Xfqn0kSGmuYxpv+khuJgMILdb
# tMW/T8NsdIaNEPxo/o0MhWRb8CMt2iQLDFC0jI9nAg2XN7QfHa+LzdWHjB5w0+7f
# Isn+VKxX9L7NVRL7m6Ap4ctWAi5Ny3Iqv0yMFJqEKiXfEc6AgeoVYGJXog4aCXSl
# GK3pmohWLM2v0mldL/GIGpYROFEOl73dbBFS6DKllRekJ0mpfjgahB3o5efNn2yc
# L0RlE12JWoA9PFo3fv1fxqstAgMBAAGjggEbMIIBFzAdBgNVHQ4EFgQUJnfNOCtF
# fr3TM2Uo98/jaPIOZU0wHwYDVR0jBBgwFoAU1WM6XIoxkPNDe3xGG8UzaFqFbVUw
# VgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9j
# cmwvcHJvZHVjdHMvTWljVGltU3RhUENBXzIwMTAtMDctMDEuY3JsMFoGCCsGAQUF
# BwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aS9jZXJ0cy9NaWNUaW1TdGFQQ0FfMjAxMC0wNy0wMS5jcnQwDAYDVR0TAQH/BAIw
# ADATBgNVHSUEDDAKBggrBgEFBQcDCDANBgkqhkiG9w0BAQsFAAOCAQEAkT/i0RUb
# ICEc8nu85JtZA9+MmlxixB7BxdNOliFg9QPlz4OYlCdNXfgaTuykWeMjhywsyHL4
# xCbDcwZap//t/u6hiifFZWjI9haPWk5y5TfxkYH8GORuLM2UmbXaYKBgX3Y8ZEZF
# /xkWDEAlf2e7Lzr8H78YbGiQjK2aI2/9qaY+KbJXHqqDjKMatZXj1wt4yaTRCxy7
# zcXP4xNFV0MPH8EXhiZxL60nbhHzprNyXZCj3aArdIf3dybZBo9fTf0eD3sMNPAl
# VCHkbksfq32dmgGAAt/2qaYZ+STSqBQuOPohWTP+m2fKEHdPZk58l7cEWqUEs1Y5
# ti9UIeJcxQGoRjCCBnEwggRZoAMCAQICCmEJgSoAAAAAAAIwDQYJKoZIhvcNAQEL
# BQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNV
# BAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEwMB4X
# DTEwMDcwMTIxMzY1NVoXDTI1MDcwMTIxNDY1NVowfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCpHQ28
# dxGKOiDs/BOX9fp/aZRrdFQQ1aUKAIKF++18aEssX8XD5WHCdrc+Zitb8BVTJwQx
# H0EbGpUdzgkTjnxhMFmxMEQP8WCIhFRDDNdNuDgIs0Ldk6zWczBXJoKjRQ3Q6vVH
# gc2/JGAyWGBG8lhHhjKEHnRhZ5FfgVSxz5NMksHEpl3RYRNuKMYa+YaAu99h/EbB
# Jx0kZxJyGiGKr0tkiVBisV39dx898Fd1rL2KQk1AUdEPnAY+Z3/1ZsADlkR+79BL
# /W7lmsqxqPJ6Kgox8NpOBpG2iAg16HgcsOmZzTznL0S6p/TcZL2kAcEgCZN4zfy8
# wMlEXV4WnAEFTyJNAgMBAAGjggHmMIIB4jAQBgkrBgEEAYI3FQEEAwIBADAdBgNV
# HQ4EFgQU1WM6XIoxkPNDe3xGG8UzaFqFbVUwGQYJKwYBBAGCNxQCBAweCgBTAHUA
# YgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU
# 1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2Ny
# bC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIw
# MTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDov
# L3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0w
# Ni0yMy5jcnQwgaAGA1UdIAEB/wSBlTCBkjCBjwYJKwYBBAGCNy4DMIGBMD0GCCsG
# AQUFBwIBFjFodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vUEtJL2RvY3MvQ1BTL2Rl
# ZmF1bHQuaHRtMEAGCCsGAQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAFAAbwBsAGkA
# YwB5AF8AUwB0AGEAdABlAG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQAH
# 5ohRDeLG4Jg/gXEDPZ2joSFvs+umzPUxvs8F4qn++ldtGTCzwsVmyWrf9efweL3H
# qJ4l4/m87WtUVwgrUYJEEvu5U4zM9GASinbMQEBBm9xcF/9c+V4XNZgkVkt070IQ
# yK+/f8Z/8jd9Wj8c8pl5SpFSAK84Dxf1L3mBZdmptWvkx872ynoAb0swRCQiPM/t
# A6WWj1kpvLb9BOFwnzJKJ/1Vry/+tuWOM7tiX5rbV0Dp8c6ZZpCM/2pif93FSguR
# JuI57BlKcWOdeyFtw5yjojz6f32WapB4pm3S4Zz5Hfw42JT0xqUKloakvZ4argRC
# g7i1gJsiOCC1JeVk7Pf0v35jWSUPei45V3aicaoGig+JFrphpxHLmtgOR5qAxdDN
# p9DvfYPw4TtxCd9ddJgiCGHasFAeb73x4QDf5zEHpJM692VHeOj4qEir995yfmFr
# b3epgcunCaw5u+zGy9iCtHLNHfS4hQEegPsbiSpUObJb2sgNVZl6h3M7COaYLeqN
# 4DMuEin1wC9UJyH3yKxO2ii4sanblrKnQqLJzxlBTeCG+SqaoxFmMNO7dDJL32N7
# 9ZmKLxvHIa9Zta7cRDyXUHHXodLFVeNp3lfB0d4wwP3M5k37Db9dT+mdHhk4L7zP
# WAUu7w2gUDXa7wknHNWzfjUeCLraNtvTX4/edIhJEqGCAs4wggI3AgEBMIH4oYHQ
# pIHNMIHKMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYD
# VQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMSYwJAYDVQQLEx1UaGFs
# ZXMgVFNTIEVTTjo0OUJDLUUzN0EtMjMzQzElMCMGA1UEAxMcTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIaAxUAOD2sJkEijzzGxlXaBgr5
# Mm2TLmmggYMwgYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkq
# hkiG9w0BAQUFAAIFAN/Xl5MwIhgPMjAxOTAxMDMwNDAzMzFaGA8yMDE5MDEwNDA0
# MDMzMVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA39eXkwIBADAKAgEAAgIm/QIB
# /zAHAgEAAgIRjzAKAgUA39jpEwIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEE
# AYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GB
# AATUfC/Qd8jgjOFbLQNzQIixsrTdou0Zq59Ib5WG09n+iNJVVDI3jmwAU1323XBG
# UQDfYM1fcu5CDLXQGrBf9EoKX4eHSMD7lYnEUBHmBr3t7LzS6HFM/RUa9sB1pjZr
# 7bYIORLiuct+IjLDeGgod5zTPT8GORMFSIgPYFPDWcUQMYIDDTCCAwkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAADu+MX1NjuBHIwAAAAA
# AO4wDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQg1wEf23jLln1oPpBasV0GT1skkOHLDsjAJoZOwJwH
# AjwwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCA/rsYitz77+LSxd5M1PpJR
# Cp8LIQHymSsSDNEjLxAuwzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAAA7vjF9TY7gRyMAAAAAADuMCIEIAlY06aoVmwXG6etscJP+vHz
# a2NDQ5lbneNgX0I/c09ZMA0GCSqGSIb3DQEBCwUABIIBAITfUjuitunX22tdmfiQ
# isVGbZvrBhVyz7k69WiU4jxgIGXsvCbnoXvtYTGw6mvI3CVCUvhvzznW3BzJ4shy
# laslfbNOowjhaNu7nosPEPTD/6m2afx74xPe1w4pbiAfv5W2PjmQImh42cAWCL0e
# g+4yp9pJ8172K2T9chpZCx1EMyzaizQ5KkLPyWwD494M1f2qeG2Nf7i+unmjphYG
# q4kUOCSfSTVgytZ7LrHnbl5DDDFLwnFSPyMs79ZgWYgjp43q33uDu8HnLLz78rlE
# 06696pz5tZKB3k8ka7k0Nos0qobmPXel+3sar0ehiQ6RsbDmVZxvaT9hdKrfYbwG
# zbw=
# SIG # End signature block
