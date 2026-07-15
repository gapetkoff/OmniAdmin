function Get-ProgressBar {
    param([int]$Percent, [int]$Width = 20)
    # Cap limits for drawing safety
    if ($Percent -gt 100) { $Percent = 100 }
    if ($Percent -lt 0) { $Percent = 0 }
    
    $Filled = [math]::Floor($Width * $Percent / 100)
    $Empty = $Width - $Filled
    $Bar = ("▓" * $Filled) + ("░" * $Empty)
    $Color = if ($Percent -ge 90) { "Red" } elseif ($Percent -ge 70) { "Yellow" } else { "Green" }
    return @{ Bar = $Bar; Color = $Color }
}
