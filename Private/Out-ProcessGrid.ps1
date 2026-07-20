function Out-ProcessGrid {
    param(
        [array]$ProcessList,
        [Parameter(Mandatory=$true)][int]$SelectedRow,
        [Parameter(Mandatory=$true)][int]$PageIndex,
        [Parameter(Mandatory=$true)][int]$PageSize,
        [Parameter(Mandatory=$true)][int]$FrameWidth,
        [Parameter(Mandatory=$true)][int]$SelColIndex,
        [Parameter(Mandatory=$true)][bool]$IsDesc,
        [Parameter(Mandatory=$true)][bool]$Paused,
        [Parameter(Mandatory=$true)][int]$Cores,
        [Parameter(Mandatory=$false)][hashtable]$ServiceHostMap = @{}
    )

    if (-not $PSBoundParameters.ContainsKey('ServiceHostMap') -and $Sync -and $Sync.ServiceHostMap) {
        $ServiceHostMap = $Sync.ServiceHostMap
    }

    $ColHeaders = @("PID", "Name", "CPU(%)", "RAM(MB)", "Threads", "Handles")
    $RealProps  = @("IDProcess", "Name", "PercentProcessorTime", "WorkingSet", "ThreadCount", "HandleCount")
    $ColWidths  = @(8, 15, 10, 10, 10, 10)
    $ColAligns  = @("-", "-", "", "", "", "")

    $FixedOverhead = 58
    $NameW = [math]::Max(10, $FrameWidth - $FixedOverhead)
    $ColWidths[1] = $NameW

    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $ColHeaders.Count; $i++) {
        $HText = $ColHeaders[$i]
        if ($i -eq $SelColIndex) { $Arrow = if ($IsDesc) { "▼" } else { "▲" }; $HText = "$HText$Arrow" }
        if ($HText.Length -gt $ColWidths[$i]) { $HText = $HText.Substring(0, $ColWidths[$i]) }
        $Fmt = "{0," + $ColAligns[$i] + $ColWidths[$i] + "}"
        if ($i -eq $SelColIndex) { Write-Host ($Fmt -f $HText) -ForegroundColor Black -BackgroundColor White -NoNewline } 
        else { Write-Host ($Fmt -f $HText) -ForegroundColor Gray -NoNewline }
        Write-Host " " -NoNewline
    }
    Write-Host "".PadRight(1)
    Write-Host ""
    Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray
    
    $Start = $PageIndex * $PageSize
    $ListToShow = if ($Paused) {
        $ProcessList | Select-Object -Skip $Start -First $PageSize
    } else {
        $ProcessList | Select-Object -First $PageSize
    }
    
    $RowsDrawn = 0
    if ($ListToShow) {
        $CurrentListArray = @($ListToShow) 
        for ($i = 0; $i -lt $PageSize; $i++) {
            if ($i -lt $CurrentListArray.Count) {
                $p = $CurrentListArray[$i]
                
                $NameVal = if ($p.Name) { $p.Name -replace '#\d+$','' } else { "Unknown" }
                if ($NameVal -like "svchost*") {
                    $SvcPid = [int]$p.IDProcess
                    if ($ServiceHostMap -and $ServiceHostMap.ContainsKey($SvcPid)) {
                        $Services = $ServiceHostMap[$SvcPid]
                        if ($Services) {
                            $ServiceNames = if ($Services -is [string]) { $Services } else { $Services -join ", " }
                            $NameVal = "$NameVal ($ServiceNames)"
                        }
                    }
                }
                elseif ($NameVal -like "*webview*" -or $NameVal -like "*msedge*") {
                    $NameVal = "$NameVal (Microsoft Edge WebView2)"
                }
                if ($NameVal.Length -gt $NameW) { $NameVal = $NameVal.SubString(0, $NameW) }
                
                $RawCpu = if ($p.PercentProcessorTime) { $p.PercentProcessorTime } else { 0 }
                $CpuVal = [math]::Round($RawCpu / $Cores, 1)
                
                if ($CpuVal -gt 100) { $CpuVal = 100.0 }
                if ($CpuVal -lt 0) { $CpuVal = 0.0 }
                
                $MemVal = [math]::Round($p.WorkingSet / 1MB, 0)
                $Icon = if ($CpuVal -gt 50) { "🔥" } elseif ($CpuVal -gt 25) { "⚡" } else { " " }
                
                $Line = "{0} {1,-8} {2,-$NameW} {3,10:0.0} {4,10} {5,10} {6,10}" -f $Icon, $p.IDProcess, $NameVal, $CpuVal, $MemVal, $p.ThreadCount, $p.HandleCount

                if ($Paused -and $i -eq $SelectedRow) { Write-Host $Line.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor Green } 
                else {
                    $Color = "White"; $BgColor = "Black"
                    if ($CpuVal -gt 75) { $Color = "Red" } 
                    elseif ($CpuVal -gt 50) { $Color = "Yellow" } 
                    elseif ($CpuVal -gt 25) { $Color = "Cyan" } 
                    else { $Color = "Gray" }
                    Write-Host $Line.PadRight($FrameWidth) -ForegroundColor $Color -BackgroundColor $BgColor
                }
            } else { Write-Host ("".PadRight($FrameWidth)) }
            $RowsDrawn++
        }
    }
    $EmptyRows = $PageSize - $RowsDrawn
    if ($EmptyRows -gt 0) { for($x=0; $x -lt $EmptyRows; $x++) { Write-Host ("".PadRight($FrameWidth)) } }
}
