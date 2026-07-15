function Get-DynamicPageSize {
    param(
        [Parameter(Mandatory=$true)][int]$HeaderHeight,
        [Parameter(Mandatory=$true)][bool]$UseFixedPageSize,
        [int]$PageSize = 0,
        [int]$Padding = 0
    )
    
    # Initialize variables if not present in the module scope
    if ($null -eq $script:LastPageSize) { $script:LastPageSize = -1 }
    if ($null -eq $script:LastSizeChangeTime) { $script:LastSizeChangeTime = [DateTime]::MinValue }

    $AvailableRows = $Host.UI.RawUI.WindowSize.Height - $HeaderHeight - $Padding
    if ($AvailableRows -lt 5) { $AvailableRows = 5 }
    if ($UseFixedPageSize) {
        $script:LastPageSize = [math]::Min($PageSize, $AvailableRows)
    } else {
        $NewSize = $AvailableRows - 4
        if ($NewSize -lt 5) { $NewSize = 5 }
        if ($script:LastPageSize -eq -1) {
            $script:LastPageSize = $NewSize
            $script:LastSizeChangeTime = Get-Date
        } else {
            $TimeSinceChange = (Get-Date) - $script:LastSizeChangeTime
            if ([math]::Abs($NewSize - $script:LastPageSize) -gt 2 -and $TimeSinceChange.TotalMilliseconds -gt 150) {
                $script:LastPageSize = $NewSize
                $script:LastSizeChangeTime = Get-Date
            }
        }
    }
    return $script:LastPageSize
}
