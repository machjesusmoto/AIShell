if ($IsMacOS -and $env:TERM_PROGRAM -ne "iTerm.app") {
    throw "The AIShell module requires iTerm2 to work properly. Please install and run from the iTerm2 terminal."
}

$module = Get-Module -Name PSReadLine
if ($null -eq $module -or $module.Version -lt [version]"2.4.3") {
    throw "The PSReadLine v2.4.3-beta3 or higher is required for the AIShell module to work properly."
}

$runspace = $Host.Runspace
if ($null -eq $runspace) {
    throw "Failed to import the module because '`$Host.Runspace' unexpectedly returns null.`nThe host details:`n$($Host | Out-String -Width 120)"
}

## Create the channel singleton when loading the module.
$null = [AIShell.Integration.Channel]::CreateSingleton($runspace, $ExecutionContext, [Microsoft.PowerShell.PSConsoleReadLine])
