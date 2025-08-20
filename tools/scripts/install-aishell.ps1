# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

#Requires -Version 7.4.6

[CmdletBinding(DefaultParameterSetName = "Install")]
param(
    [Parameter(HelpMessage = "Specify the version to install, e.g. 'v1.0.0-preview.2'", ParameterSetName = "Install")]
    [ValidatePattern("^v\d+\.\d+\.\d+(-\w+\.\d{1,2})?$")]
    [string] $Version,

    [Parameter(HelpMessage = "Specify this parameter to uninstall AI Shell", ParameterSetName = "Uninstall")]
    [switch] $Uninstall
)

$Script:MacSymbolicLink = '/usr/local/bin/aish'
$Script:MacInstallationLocation = "/usr/local/AIShell"
$Script:WinInstallationLocation = "$env:LOCALAPPDATA\Programs\AIShell"
$Script:InstallLocation = $null
$Script:PackageURL = $null
$Script:ModuleVersion = $null
$Script:NewPSRLInstalled = $false
$Script:PSRLDependencyMap = @{
    '1.0.4-preview4' = '2.4.2-beta2'
    '1.0.6-preview6' = '2.4.3-beta3'
}

function Resolve-Environment {
    if ($PSVersionTable.PSVersion -lt [version]"7.4.6") {
        throw "PowerShell v7.4.6 or higher is required for using the AIShell module. You can download it at https://github.com/PowerShell/PowerShell/releases/tag/v7.4.6 "
    }
    if ($IsLinux) {
        throw "Sorry, this install script is only compatible with Windows and macOS. If you want to install on Linux, please download the package directly from the GitHub repo at aka.ms/AIShell-Repo."
    }

    ($platShortName, $platFullName, $pkgExt, $Script:InstallLocation) = if ($IsWindows) {
        'win', 'Windows', 'zip', $Script:WinInstallationLocation
    } else {
        'osx', 'macOS', 'tar.gz', $Script:MacInstallationLocation
    }

    if ($Uninstall) {
        return
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($architecture -notin @('X86', 'X64', 'Arm64')) {
        throw "AI Shell doesn't support the $architecture architecture on $platFullName."
    }

    $tags = (Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/AIShell/tags" -ErrorAction Stop).name
    if ($Version -and $Version -notin $tags) {
        throw "The specified version '$Version' doesn't exist. Available versions are: $($tags -join ', ')"
    }

    $tagToUse = [string]::IsNullOrEmpty($Version) ? $tags[0] : $Version
    $appVersion = $tagToUse.TrimStart('v')

    $Script:PackageURL = "https://github.com/PowerShell/AIShell/releases/download/${tagToUse}/AIShell-${appVersion}-${platShortName}-$($architecture.ToLower()).${pkgExt}"

    $dashIndex = $appVersion.IndexOf('-')
    $Script:ModuleVersion = if ($dashIndex -eq -1) {
        ## The mapping between module version and the app version is not clear yet.
        throw "Not implemented for stable releases."
    } else {
        $previewLabel = $appVersion.Substring($dashIndex + 1)
        $previewDigit = $previewLabel.Substring($previewLabel.LastIndexOf('.') + 1)
        $patchDotIndex = $appVersion.LastIndexOf('.', $dashIndex)
        $appVersion.Substring(0, $patchDotIndex) + ".$previewDigit-" + $previewLabel.Replace('.', '')
    }
}

function Install-AIShellApp {
    [CmdletBinding()]
    param()

    $destination = $Script:InstallLocation
    $packageUrl = $Script:PackageURL

    $destinationExists = Test-Path -Path $destination
    if ($destinationExists) {
        $anyFile = Get-ChildItem -Path $destination | Select-Object -First 1
        if ($anyFile) {
            $remove = $PSCmdlet.ShouldContinue("Do you want to remove it for a new installation?", "AI Shell was already installed (or partially installed) at '$destination'.")
            if ($remove) {
                $destinationExists = $false
                if ($IsWindows) {
                    Remove-Item -Path $destination -Recurse -Force -ErrorAction Stop
                } else {
                    sudo rm -rf $destination
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to remove '$destination'."
                    }
                }
            } else {
                throw "Operation cancelled. You can remove the current installation by './install-aishell.ps1 -Uninstall' and try again."
            }
        }
    }

    if (-not $destinationExists) {
        # Create the directory if not existing.
        Write-Host "Creating the target folder '$destination' ..."
        if ($IsWindows) {
            $null = New-Item -Path $destination -ItemType Directory -Force
        } else {
            # '/usr/local' requires sudo.
            sudo mkdir $destination
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create the installation folder '$destination'."
            }
        }
    }

    $fileName = [System.IO.Path]::GetFileName($packageUrl)
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) $fileName
    if (Test-Path $tempPath) {
        Remove-Item $tempPath -Force -ErrorAction Stop
    }

    # Download AIShell package.
    Write-Host "Downloading AI Shell package '$fileName' ..."
    Invoke-WebRequest -Uri $packageUrl -OutFile $tempPath -ErrorAction Stop

    try {
        # Extract AIShell package.
        Write-Host "Extracting AI Shell to '$destination' ..."
        Unblock-File -Path $tempPath
        if ($IsWindows) {
            Expand-Archive -Path $tempPath -DestinationPath $destination -Force -ErrorAction Stop

            # Set the process-scope and user-scope Path env variables to include AIShell.
            $envPath = $env:Path
            if (-not $envPath.Contains($destination)) {
                Write-Host "Adding AI Shell app to the Path environment variable ..."
                $env:Path = "${destination};${envPath}"
                $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
                $newUserPath = $userPath.EndsWith(';') ? "${userPath}${destination}" : "${userPath};${destination}"
                [Environment]::SetEnvironmentVariable('Path', $newUserPath, [EnvironmentVariableTarget]::User)
            }
        } else {
            sudo tar -xzf $tempPath -C $destination
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract '$tempPath' to the folder '$destination'."
            }

            $aishPath = Join-Path $destination 'aish'
            sudo chmod +x $aishPath
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to set the execution permission to the executable '$aishPath'."
            }

            # No need to setup the Path env variable as the symbolic link is already within Path.
            $symlink = $Script:MacSymbolicLink
            if (-not (Test-Path -Path $symlink)) {
                sudo ln -s $aishPath $symlink
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create the symbolic link '$symlink' to '$aishPath'."
                }
            }
        }
    } finally {
        if (Test-Path -Path $tempPath) {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-AIShellApp {
    $destination = $Script:InstallLocation
    if (Test-Path $destination) {
        Write-Host "Removing AI Shell app from '$destination' ..."
        if ($IsWindows) {
            Remove-Item -Path $destination -Recurse -Force -ErrorAction Stop

            # Update the user-scope Path env variables to remove AIShell.
            $userPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
            if ($userPath.Contains($destination)) {
                Write-Host "Removing AI Shell app from the user-scope Path environment variable ..."
                $newUserPath = $userPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries) |
                    Where-Object { $_ -ne $destination } |
                    Join-String -Separator ';'
                [Environment]::SetEnvironmentVariable("Path", $newUserPath, [EnvironmentVariableTarget]::User)
            }

            # Update the process-scope Path env variables to remove AIShell.
            $procPath = $env:Path
            if ($procPath.Contains($destination)) {
                Write-Host "Removing AI Shell app from the process-scope Path environment variable ..."
                $newProcPath = $procPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries -bor [StringSplitOptions]::TrimEntries) |
                    Where-Object { $_ -ne $destination } |
                    Join-String -Separator ';'
                $env:Path = $newProcPath
            }
        } else {
            sudo rm -rf $destination
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove the AIShell app from '$destination'."
            }

            $symlink = $Script:MacSymbolicLink
            sudo rm $symlink
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to remove the symbolic link '$symlink'."
            }
        }
    } else {
        Write-Host "AI Shell app was not found at '$destination'. Skip removing it."
    }
}

function Install-AIShellModule {
    $modVersion = $Script:ModuleVersion
    Write-Host "Installing the PowerShell module 'AIShell' $modVersion ..."
    Install-PSResource -Name AIShell -Repository PSGallery -Prerelease -TrustRepository -Version $modVersion -ErrorAction Stop -WarningAction SilentlyContinue

    $psrldep = GetPSRLDependency -modVersion $modVersion

    if ($psrldep) {
        $psrlModule = Get-Module -Name PSReadLine
        $psrlVer = $psrldep.Contains('-') ? $psrldep.Split('-')[0] : $psrldep
        if ($null -eq $psrlModule -or $psrlModule.Version -lt [version]$psrlVer) {
            Write-Host "  - This version of AIShell module depends on PSReadLine '$psrldep' or higher, which is missing."
            Write-Host "    Installing the PowerShell module 'PSReadLine' $psrldep or a higher version ..."
            Install-PSResource -Name PSReadLine -Repository PSGallery -Prerelease -TrustRepository -Version "[$psrldep, ]" -ErrorAction Stop -WarningAction SilentlyContinue
            $Script:NewPSRLInstalled = $true
        }
    }

    if ($IsMacOS) {
        Write-Host -ForegroundColor Yellow "NOTE: The 'AIShell' PowerShell module only works in iTerm2 terminal in order to provide the sidecar experience."
    }
}

function GetPSRLDependency {
    param([string] $modVersion)

    $keys = $Script:PSRLDependencyMap.Keys
    $curVer = [version]($modVersion.Contains('-') ? $modVersion.Split('-')[0] : $modVersion)

    $psrldep = $null
    foreach ($key in $keys) {
        $ver = $key.Contains('-') ? $key.Split('-')[0] : $key
        if ($curVer -ge [version]$ver) {
            $psrldep = $Script:PSRLDependencyMap[$key]
        }
    }

    return $psrldep
}

function Uninstall-AIShellModule {
    if (Get-InstalledPSResource -Name "AIShell" -ErrorAction SilentlyContinue) {
        try {
            Write-Host "Uninstalling AIShell Module ..."
            Uninstall-PSResource -Name AIShell -ErrorAction Stop
        } catch {
            throw "Failed to uninstall the 'AIShell' module. Please check if the module got imported in any active PowerShell session. If so, please exit the session and try this script again."
        }
    }
}

<###################################
#
#           Setup/Execute
#
###################################>

Resolve-Environment

if ($Uninstall) {
    Uninstall-AIShellApp
    Uninstall-AIShellModule

    Write-Host -ForegroundColor Green "`nAI Shell App and PowerShell module have been successfully uninstalled."
} else {
    Install-AIShellApp
    Install-AIShellModule

    $condition = $IsMacOS ? " if you are in iTerm2" : $null
    Write-Host -ForegroundColor Green -Object @"

Installation succeeded.
To learn more about AI Shell please visit https://aka.ms/AIShell-Docs.
To get started, please run 'Start-AIShell' to use the sidecar experience${condition}, or run 'aish' to use the standalone experience.
"@
    if ($Script:NewPSRLInstalled) {
        Write-Host -ForegroundColor Yellow -Object @"
NOTE: A new version of the PSReadLine module was installed as a dependency.
To ensure the new PSReadLine gets used, please run 'Start-AIShell' from a new session.
"@
    }
}
