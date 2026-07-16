# OmniAdmin.psm1

$publicDir  = Join-Path -Path $PSScriptRoot -ChildPath 'Public'
$privateDir = Join-Path -Path $PSScriptRoot -ChildPath 'Private'

# Load Private Functions (small helpers, fast to parse)
Get-ChildItem -Path $privateDir -Filter '*.ps1' | ForEach-Object {
    . $_.FullName
}

# Load Public Functions — skip Get-BrowserHistory (5 MB, loaded lazily below)
Get-ChildItem -Path $publicDir -Filter '*.ps1' |
    Where-Object Name -ne 'Get-BrowserHistory.ps1' |
    ForEach-Object { . $_.FullName }

# Lazy-load stub for Get-BrowserHistory.
# The 5 MB script is only parsed when the user actually calls the command.
# On first call the stub dot-sources the real file (which replaces this stub),
# then forwards the invocation to the now-loaded real function.
$script:_moduleRoot = $PSScriptRoot
function Get-BrowserHistory {
    . "$script:_moduleRoot\Public\Get-BrowserHistory.ps1"
    Get-BrowserHistory @args
}

# NOTE: Initialize-NetworkEngine is called lazily by Measure-Speed on first use.
# Compiling C# via Add-Type at import time was adding ~1-3s to every PS startup.

Export-ModuleMember -Function Start-SystemMonitor, Measure-Speed, Get-BrowserHistory
