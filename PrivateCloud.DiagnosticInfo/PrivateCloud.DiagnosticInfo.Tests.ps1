#
#
#

Set-StrictMode -Version 3.0

$zpfx = Join-Path $env:TEMP "PesterTest"

function RunGetSddcDiagnosticInfo
{
    param(
        [System.Management.Automation.Runspaces.PSSession]
        $Session,

        [switch]
        $ShouldBeSuccessful
    )

    { Invoke-Command -Session $Session -ErrorVariable script:e { Get-SddcDiagnosticInfo -ZipPrefix $using:zpfx }} | Should Not Throw

    if ($ShouldBeSuccessful)
    {
        $script:e | Should BeNullOrEmpty Becaue "the invocation should be successful without errors"
    }
    else
    {
        $script:e | Should Not BeNullOrEmpty Becaue "the invocation should be unsuccessful"
    }
}

function CleanupSddcDiagnosticInfo
{
    $z = Get-Item "$zpfx*"

    # $z | Should Not BeNullOrEmpty
    $z | Remove-Item
}

<#
#
# Preserving rough start at a constrained language mode test. This is not correct as written since clm
# requires using Device Guard/AppLocker to express constrained language exceptions for signed modules
# (not limited to but inclusive of system modules) and/or modules located under secured paths. However,
# it may still lay out useful bones of what it will eventually look like.
#

Describe "VerifyConstrainedLanguageMode" {

    BeforeAll {
        $session = New-PSSession -EnableNetworkAccess
        $script:e = $null
    }

    It "ParentFullBefore" {
        $ExecutionContext.SessionState.LanguageMode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    It "IsFull" {
        $mode = Invoke-Command -Session $session { $ExecutionContext.SessionState.LanguageMode }
        $mode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    It "SetConstrained" {
        Invoke-Command -Session $session { $ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage' }
        $mode = Invoke-Command -Session $session { $ExecutionContext.SessionState.LanguageMode }
        $mode | Should Be ([System.Management.Automation.PSLanguageMode]::ConstrainedLanguage)
    }

    #
    # do it
    #

    RunGetSddcDiagnosticInfo $session -ShouldBeSuccessful:$true
    CleanupSddcDiagnosticInfo

    It "RemainedConstrained" {
        $mode = Invoke-Command -Session $session { $ExecutionContext.SessionState.LanguageMode }
        $mode | Should Be ([System.Management.Automation.PSLanguageMode]::ConstrainedLanguage)
    }

    It "ParentFullAfter" {
        $ExecutionContext.SessionState.LanguageMode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    AfterAll {
        Remove-PSSession $session
    }
}
#>

Describe "VerifyFullLanguageMode" {

    BeforeAll {
        $session = New-PSSession -EnableNetworkAccess
        $script:e = $null
    }

    It "ParentFullBefore" {
        $ExecutionContext.SessionState.LanguageMode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    It "IsFull" {
        $mode = Invoke-Command -Session $session { $ExecutionContext.SessionState.LanguageMode }
        $mode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    #
    # do it
    #

    RunGetSddcDiagnosticInfo $session -ShouldBeSuccessful:$true
    CleanupSddcDiagnosticInfo

    It "RemainedFull" {
        $mode = Invoke-Command -Session $session { $ExecutionContext.SessionState.LanguageMode }
        $mode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    It "ParentFullAfter" {
        $ExecutionContext.SessionState.LanguageMode | Should Be ([System.Management.Automation.PSLanguageMode]::FullLanguage)
    }

    AfterAll {
        Remove-PSSession $session
    }
}

Describe "TestPrefixFilePath" {

    It "SystemDriveIsDriveLetterColon" {
        $env:SystemDrive.Length | Should Be 2
        ($env:SystemDrive[0] -match '[A-Z]') | Should Be $true
        $env:SystemDrive[1] | Should Be ':'
    }

    InModuleScope PrivateCloud.DiagnosticInfo {

        Context "InScope" {

            BeforeAll {

                # Get the first lexical existing name in the directory and duplicate the first
                # character, which guarantees creating a non-existent name. If none exists
                # use a trivial name.
                function MakeAvailableName
                {
                    param(
                        [string]
                        $Path
                    )

                    $firstName = Get-ChildItem $Path | Select-Object -First 1

                    if ($null -ne $firstName)
                    {
                        return $firstName.Name[0] + $firstName.Name
                    }
                    else
                    {
                        return 'a'
                    }

                }

                # An available name at the root of the system drive
                $sysdAvailableName = MakeAvailableName (Join-Path $env:SystemDrive '')

                # An available name in the Windows directory
                $windAvailableName = MakeAvailableName $env:windir

                # An available name in the current directory
                $cwdAvailableName = MakeAvailableName '.'

                # Simplify later expressions building UNC paths
                $cName = $env:COMPUTERNAME
                $sysDL = $env:SystemDrive[0]
            }

            It "NoDriveLetter" {
                Test-PrefixFilePath $env:SystemDrive | Should BeNullOrEmpty Because "this is a bare drive letter with no possible file prefix"
            }

            It "NoDriveLetterSlash" {
                Test-PrefixFilePath (Join-Path $env:SystemDrive '') | Should BeNullOrEmpty Because "this is a trailing seperator with no possible file prefix"
            }

            # at root of drive
            # c:\somenewname -> yes
            # c:\somenewname\test -> no
            It "YesAvailableNameAtRoot" {
                Test-PrefixFilePath (Join-Path $env:SystemDrive $sysdAvailableName) | Should Not BeNullOrEmpty Because "this is an available name in the system drive and should work"
            }

            It "NoChildOfAvailableNameAtRoot" {
                Test-PrefixFilePath (Join-Path (Join-Path $env:SystemDrive $sysdAvailableName) 'test') | Should BeNullOrEmpty Because "this is an available name, and cannot be a directory to put test into"
            }

            It "NoAvailableNameAtRootAsDirectory" {
                Test-PrefixFilePath (Join-Path (Join-Path $env:SystemDrive $sysdAvailableName) '') | Should BeNullOrEmpty Because "this is an available name as a directory with no possible file prefix"
            }


            # in child directory, using windir as a convenient must-exist directory
            # c:\dir\somenewname -> yes
            # c:\dir\somenewname\test -> no
            It "YesAvailableNameInChild" {
                Test-PrefixFilePath (Join-Path $env:windir $windAvailableName) | Should Not BeNullOrEmpty Because "this is an available name in the windows directory and should work"
            }

            It "NoChildOfAvailableNameInChild" {
                Test-PrefixFilePath (Join-Path (Join-Path $env:windir $windAvailableName) 'test') | Should BeNullOrEmpty Because "this is an available name, and cannot be a directory to put test into"
            }

            It "NoAvailableNameInChildAsDirectory" {
                Test-PrefixFilePath (Join-Path (Join-Path $env:windir $windAvailableName) '') | Should BeNullOrEmpty Because "this is an available name as a directory with no possible file prefix"
            }

            # unc cases
            # \\foo -> no
            # \\foo\bar -> no
            # \\foo\bar\somenewname -> yes
            It "NoUNCComputerName" {
                Test-PrefixFilePath "\\$cName" | Should BeNullOrEmpty Because "this is just a computer name, not a potential filename prefix"
            }

            It "NoUNCShare" {
                Test-PrefixFilePath "\\$cName\$sysDL$" | Should BeNullOrEmpty Because "this is just a share, not a potential filename prefix"
            }

            It "YesUNCShareWithName" {
                Test-PrefixFilePath "\\$cName\$sysDL$\$sysdAvailableName" | Should Not BeNullOrEmpty Because "this is just a share, not a potential filename prefix"
            }

            # relative cases using current working directory
            It "YesCWDAvailableName" {
                Test-PrefixFilePath "$cwdAvailableName" | Should Not BeNullOrEmpty Because "this is an available name in the cwd"
            }

            It "NoChildOfCWDAvailableName" {
                Test-PrefixFilePath (Join-Path $cwdAvailableName "test") | Should BeNullOrEmpty Because "this is an available name, and cannot be a directory to put test into"
            }
        }
    }
}