#
# Module manifest for module 'PrivateCloud.DiagnosticInfo'
#
# Generated on: 4/25/2016
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'PrivateCloud.DiagnosticInfo.psm1'

# Version number of this module.
ModuleVersion = '1.1.2'

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
# MIIkWAYJKoZIhvcNAQcCoIIkSTCCJEUCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDmfi20c8nQLj2n
# BOiJfSqujCH0bfDOTofy0HCHYo6rz6CCDXYwggX0MIID3KADAgECAhMzAAABApvw
# C6eOXcNNAAAAAAECMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMTgwNzEyMjAwODQ4WhcNMTkwNzI2MjAwODQ4WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDUDAYEhQiWKKfpa3TQ4mGT46UwX/UIw1uE9sGnMPeISoedadT4fvCy8/PZRrTh
# ZBX9b57KFsdYqKOZjNWn/PGNGndg7F1FC8ebalEJhAOS5BBqqPtyOA06BMewVkEv
# TJSrsMDIoi+f0fMD2QkBpQuo3RWmXmIooaqu29rVRJqjCTLZxSva7CttEYz10R2a
# c3D/mvjopbp0qOp2c3vVlvAYuCfM6O2URhG4aZeV+JizcZgx7nvYu3W1OV8iZHkN
# WeqmhDjx+o9jl6xUF7rJnT9lLTeX6n5wHJnl2uPqbj7XJRzfGASda+BDhGNvBUix
# uV08JmisMcr9fu7u2ttsRsNbAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUiRcFro07Z+9cIaFfJbDdSbk3Tu8w
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzQzNzk2NDAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAJP2AnJLtJYleQ4Y+xu0
# mJhorCOZ5ethfBHgoSMAyX7zSSjgdf3zaMQZxqBWVWoiuzVVJRvBZnJzp2IitEFu
# hzB6LGOkJi1/+UCxeHnFw/V7jaHn6EBWZ3k1BHZgJleNNhmSLZvYbdBBSsVM1x3H
# dvJ6sz8lE4+N2yvXTxTJwmWKoxu53+LEGFgFrPHtDEvn5IR/RGLLZqKSKrfIkXNK
# PPuLpyr/4mG0EVkB14trliGGrUZu26qZX7HwYOjo+DkqEkZWe1l7fA0C9ZwCFLYV
# /Gdb/7Ior5ARqTh89EV/IB/0K79VyS3VY1PA6xegIIuYGOVX9QKUMoQSbzpQb/XW
# hRLntzMDwcVHMPaHj/x/iQpiGaUTSMsPPl+UgFZZMLPTyHT6ID3OMYhuWrDcxuTI
# r1MIqCpZObp6ulQ9MIM9QZlt1s/Y6LAlpDzUi+YrVRR6PpqROT+MfrtXhJUQJkPC
# ZoTcK5kjzE1PJfHQQDlJ7z8t0VGyPgu9KtQ9oW/1cKmfa1WZQSlpElOoS/NT4si2
# UTf9a787z68X7IJ4cKEnAHj0U7PhyZFJ5sC0z5vZMWVbQJcE6DgBk+IJxyv7+b8I
# fgKTnryEQDxLwmX87vU2FCU1a4sxJEAlVAOkZkez0CO2jxfJsO9gciiEJOCoCDcK
# 7pzYBx6Fi5zPFJ+h5pLv1XWHMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCFjgwghY0AgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAAECm/ALp45dw00AAAAAAQIwDQYJYIZIAWUDBAIB
# BQCggcYwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIPqSFYYNp9P4nDi0k3zy5Joz
# RfZoGdkBRcbLdWYSYenXMFoGCisGAQQBgjcCAQwxTDBKoCSAIgBNAGkAYwByAG8A
# cwBvAGYAdAAgAFcAaQBuAGQAbwB3AHOhIoAgaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3dpbmRvd3MwDQYJKoZIhvcNAQEBBQAEggEAaVG0z2Z82v4n0QCEExi0u7pU
# tZU213Vrht+oY7O0VDlFT8Ks5odm1UMC44bdYwJi40fY2j9xq4TBn0vf57OrhrpN
# by+EVhuzyTxNvCaHIFumQBk1AGBx2bmy67DxIrYL+umOOljcu8JArmdOHGmYBD0x
# sfB6ToVRWfI34bcFVTi2dQKZpZiMTelQlA+WB9nYE+SNwjaL7841r0hxf7yvowep
# cecXeZCpnS9maT3+XuoEDuB0WuD3eWHR9AQ+bjk6juefuLxPLuiTMwtxiW60lZz0
# gvIfP5fVzbTvf3TZGwLqihTyhexmv7e2/6jJa1fR60MjfkPt2U7AhxoA90d7TaGC
# E6owghOmBgorBgEEAYI3AwMBMYITljCCE5IGCSqGSIb3DQEHAqCCE4MwghN/AgED
# MQ8wDQYJYIZIAWUDBAIBBQAwggFUBgsqhkiG9w0BCRABBKCCAUMEggE/MIIBOwIB
# AQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCDiD7DXyS4SKGImCQVy1i6U
# A6IspUhwIO7Dqi/fhH8SlQIGW9unlJpEGBMyMDE4MTExMDAwMDcxNy4wMTZaMAcC
# AQGAAgH0oIHQpIHNMIHKMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMSYwJAYD
# VQQLEx1UaGFsZXMgVFNTIEVTTjo1N0M4LTJEMTUtMUM4QjElMCMGA1UEAxMcTWlj
# cm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCDxYwggZxMIIEWaADAgECAgphCYEq
# AAAAAAACMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0xMDA3MDEyMTM2NTVaFw0yNTA3MDEyMTQ2NTVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIIBIjANBgkqhkiG9w0BAQEF
# AAOCAQ8AMIIBCgKCAQEAqR0NvHcRijog7PwTl/X6f2mUa3RUENWlCgCChfvtfGhL
# LF/Fw+Vhwna3PmYrW/AVUycEMR9BGxqVHc4JE458YTBZsTBED/FgiIRUQwzXTbg4
# CLNC3ZOs1nMwVyaCo0UN0Or1R4HNvyRgMlhgRvJYR4YyhB50YWeRX4FUsc+TTJLB
# xKZd0WETbijGGvmGgLvfYfxGwScdJGcSchohiq9LZIlQYrFd/XcfPfBXday9ikJN
# QFHRD5wGPmd/9WbAA5ZEfu/QS/1u5ZrKsajyeioKMfDaTgaRtogINeh4HLDpmc08
# 5y9Euqf03GS9pAHBIAmTeM38vMDJRF1eFpwBBU8iTQIDAQABo4IB5jCCAeIwEAYJ
# KwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNVjOlyKMZDzQ3t8RhvFM2hahW1VMBkG
# CSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1UdDwQEAwIBhjAPBgNVHRMBAf8E
# BTADAQH/MB8GA1UdIwQYMBaAFNX2VsuP6KJcYmjRPZSQW9fOmhjEMFYGA1UdHwRP
# ME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNybDBaBggrBgEFBQcBAQROMEww
# SgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3J0MIGgBgNVHSABAf8EgZUwgZIwgY8G
# CSsGAQQBgjcuAzCBgTA9BggrBgEFBQcCARYxaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL1BLSS9kb2NzL0NQUy9kZWZhdWx0Lmh0bTBABggrBgEFBQcCAjA0HjIgHQBM
# AGUAZwBhAGwAXwBQAG8AbABpAGMAeQBfAFMAdABhAHQAZQBtAGUAbgB0AC4gHTAN
# BgkqhkiG9w0BAQsFAAOCAgEAB+aIUQ3ixuCYP4FxAz2do6Ehb7Prpsz1Mb7PBeKp
# /vpXbRkws8LFZslq3/Xn8Hi9x6ieJeP5vO1rVFcIK1GCRBL7uVOMzPRgEop2zEBA
# QZvcXBf/XPleFzWYJFZLdO9CEMivv3/Gf/I3fVo/HPKZeUqRUgCvOA8X9S95gWXZ
# qbVr5MfO9sp6AG9LMEQkIjzP7QOllo9ZKby2/QThcJ8ySif9Va8v/rbljjO7Yl+a
# 21dA6fHOmWaQjP9qYn/dxUoLkSbiOewZSnFjnXshbcOco6I8+n99lmqQeKZt0uGc
# +R38ONiU9MalCpaGpL2eGq4EQoO4tYCbIjggtSXlZOz39L9+Y1klD3ouOVd2onGq
# BooPiRa6YacRy5rYDkeagMXQzafQ732D8OE7cQnfXXSYIghh2rBQHm+98eEA3+cx
# B6STOvdlR3jo+KhIq/fecn5ha293qYHLpwmsObvsxsvYgrRyzR30uIUBHoD7G4kq
# VDmyW9rIDVWZeodzOwjmmC3qjeAzLhIp9cAvVCch98isTtoouLGp25ayp0Kiyc8Z
# QU3ghvkqmqMRZjDTu3QyS99je/WZii8bxyGvWbWu3EQ8l1Bx16HSxVXjad5XwdHe
# MMD9zOZN+w2/XU/pnR4ZOC+8z1gFLu8NoFA12u8JJxzVs341Hgi62jbb01+P3nSI
# SRIwggTxMIID2aADAgECAhMzAAAA6PgHIzbhUtWmAAAAAADoMA0GCSqGSIb3DQEB
# CwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQH
# EwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNV
# BAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTE4MDgyMzIwMjcx
# MloXDTE5MTEyMzIwMjcxMlowgcoxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JjAkBgNVBAsTHVRoYWxlcyBUU1MgRVNOOjU3QzgtMkQxNS0xQzhCMSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEF
# AAOCAQ8AMIIBCgKCAQEAkSXJTUcSvt6YsgUCguGhk/ofQbq1uBt9lF5GcbUKSmW4
# hZRrkGCy9LF9+LdrgKfVVjzQ0IGTYzuLE9htBcEcNJWhe1B2bcv9GHepI3wTLdsL
# 5gbGF3M58heRNRPIakdf7IGO0Ve67S/Rt1aS0L/DaLZ5iojbjCUX06UP79+STrcY
# yAiCIoJJnQ0FJunnEyR2xZ9tqPcLRqjGs66mv1uC8FugBb3PmxbtL+OxYW60basS
# 1MOs/rffUwYO/f+8zzjMLgt7akAyjPvTjloEAmTmHjTtDbpnenZz8Q11ThWqCCcq
# LIlHQv+MACpzsb6flgiYSagUkys/rM6JtrGHTLoDgwIDAQABo4IBGzCCARcwHQYD
# VR0OBBYEFBSgYUtmsOfvKSXKHH+RkPs4HCpTMB8GA1UdIwQYMBaAFNVjOlyKMZDz
# Q3t8RhvFM2hahW1VMFYGA1UdHwRPME0wS6BJoEeGRWh0dHA6Ly9jcmwubWljcm9z
# b2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1RpbVN0YVBDQV8yMDEwLTA3LTAx
# LmNybDBaBggrBgEFBQcBAQROMEwwSgYIKwYBBQUHMAKGPmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljVGltU3RhUENBXzIwMTAtMDctMDEuY3J0
# MAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZIhvcNAQEL
# BQADggEBAEmOEZdeNOXtM7+78p1UDjrkLqM3s5zKh1CvBTKyd6DSMXqky+PZjYko
# dpF75ce2tb0UsbiwJw/OVCA3NsN3K2hMvZiNlZnaZLRdQ885WwLkLHrD+blaOYaP
# DWy0N0IjRWWIlvd54/FJz2kXEzys277U8cF2+xVwe5eJkoWDnodJT7Nd0A540lm7
# sy6PlmEw5iseV1k5VgcdvtxCBY2WAFjvgCVAjEH2FzpJc4SUHXGdp1QgH/CwnFDa
# fiRRUl8yrHXkHSpGX3TT53WE2WojP7t6E9K9lAKuLTgJxfWuoKBv85riJRchX4DW
# Wofxjt1O7cPht2zrzYCNMZkvTWhS0k6hggOoMIICkAIBATCB+qGB0KSBzTCByjEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWlj
# cm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEmMCQGA1UECxMdVGhhbGVzIFRTUyBF
# U046NTdDOC0yRDE1LTFDOEIxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFNlcnZpY2WiJQoBATAJBgUrDgMCGgUAAxUAUAQ583ooWySzXqEMUGGGlIcwFg+g
# gdowgdekgdQwgdExCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsT
# Hm5DaXBoZXIgTlRTIEVTTjoyNjY1LTRDM0YtQzVERTErMCkGA1UEAxMiTWljcm9z
# b2Z0IFRpbWUgU291cmNlIE1hc3RlciBDbG9jazANBgkqhkiG9w0BAQUFAAIFAN+Q
# efQwIhgPMjAxODExMDkyMTI2MTJaGA8yMDE4MTExMDIxMjYxMlowdzA9BgorBgEE
# AYRZCgQBMS8wLTAKAgUA35B59AIBADAKAgEAAgIrvwIB/zAHAgEAAgIaLDAKAgUA
# 35HLdAIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMBoAowCAIBAAID
# FuNgoQowCAIBAAIDHoSAMA0GCSqGSIb3DQEBBQUAA4IBAQCjx9sen9q1ypL5OzaY
# AHrm0i1RmfusJnqQONc3HTQjPyj8718tfsM3AFvqYPQQEvxyjHRWhBgxdblnPbof
# fyBQB7UKq26KdL5S5ZXvo2IObif9HV9Azk4N6bX6BvkZ4WJ9gXmdIVCpJgZg2hn5
# DUQ20bWHiaYQXxnI0UOVQ+7Bf7PecjfifWg1l8ILh3qLkqICLd7Au1yvYkf/PEnX
# HH03gtZVy99a1n2iJMK9i2LGiO9MW/tQYKKlZJOorFsIWZX/OpyFt9FUzQVXhT15
# 0PnYPqXs4bFTRbVedYLHXf1bBQptM0Ivoqt4IOAdAup3XGb4vBbRBZKkjK/TdZHC
# b2RdMYIC9TCCAvECAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTAC
# EzMAAADo+AcjNuFS1aYAAAAAAOgwDQYJYIZIAWUDBAIBBQCgggEyMBoGCSqGSIb3
# DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgNzeEkygDq1rNEYAS
# 6idMS19nsBs+6uMJIgt2e2MqKRUwgeIGCyqGSIb3DQEJEAIMMYHSMIHPMIHMMIGx
# BBRQBDnzeihbJLNeoQxQYYaUhzAWDzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwAhMzAAAA6PgHIzbhUtWmAAAAAADoMBYEFO93tmlJLZE8/U/8
# QsBPxLd/uvPcMA0GCSqGSIb3DQEBCwUABIIBAHig5XYP+7+0zwyi7U99iuhQmcdu
# AJWfC8uMhtCbqgs6xr8wJ4euwS1e2/NN5EgsYIPJKRbJyZJYtLu0mMLCPvNbkvlG
# ssQNYMvvgpeHpx+ziD7b3xWsSDHmSLf8cw+mtE2Z9Zyo7W1tyKcAR+OskcXuYsDV
# Fm7YXWrN6Aq/GIkd7c/zkJMHQvAY6Lr5apsDqTIxUnqyC3Du9O3JL0hXiyvp7lLe
# nIzEpsbG0Ofblp2/zmtPCKb3Syu/44avnrZK3EJKbeyab0bC8OyUIuzmkT6Z0Xfx
# pa8PyzBS5Rr0KKhPZ4Q7OLuxDIb/AATL1SATIxvsqojRBc53s07TIx3wM5g=
# SIG # End signature block
