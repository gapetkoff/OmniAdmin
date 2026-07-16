function Out-TaskGrid {
    param(
        [array]$Tasks,
        [Parameter(Mandatory=$true)][int]$SelectedRow,
        [Parameter(Mandatory=$true)][int]$PageIndex,
        [Parameter(Mandatory=$true)][int]$PageSize,
        [Parameter(Mandatory=$true)][int]$FrameWidth,
        [Parameter(Mandatory=$true)][int]$SelColIndex,
        [Parameter(Mandatory=$true)][bool]$IsDesc,
        [Parameter(Mandatory=$true)][bool]$ShowTaskProps
    )

    $TskHeaders = @("State", "Task Name", "Last Run Time", "Result")
    $TskProps   = @("State", "TaskName", "LastRunTime", "LastTaskResult")
    $TskAligns  = @("-", "-", "-", "-")

    $Avail = $FrameWidth - 26
    $NameW = [math]::Floor($Avail * 0.55)
    $TimeW = $Avail - $NameW
    $TskWidths = @(10, $NameW, $TimeW, 10)

    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $TskHeaders.Count; $i++) {
        $HText = $TskHeaders[$i]
        if ($i -eq $SelColIndex) { $Arrow = if ($IsDesc) { "▼" } else { "▲" }; $HText = "$HText$Arrow" }
        if ($HText.Length -gt $TskWidths[$i]) { $HText = $HText.Substring(0, $TskWidths[$i]) }
        $Fmt = "{0," + $TskAligns[$i] + $TskWidths[$i] + "}"
        if ($i -eq $SelColIndex) { Write-Host ($Fmt -f $HText) -ForegroundColor Black -BackgroundColor White -NoNewline } 
        else { Write-Host ($Fmt -f $HText) -ForegroundColor Gray -NoNewline }
        Write-Host " " -NoNewline
    }
    Write-Host "".PadRight(10)
    Write-Host ""
    Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

    $SortedTasks = $Tasks | Sort-Object $TskProps[$SelColIndex] -Descending:$IsDesc
    $Start = $PageIndex * $PageSize
    $ListToShow = $SortedTasks | Select-Object -Skip $Start -First $PageSize
    
    $RowsDrawn = 0
    if ($ListToShow) {
        $CurrentListArray = @($ListToShow)
        for ($i = 0; $i -lt $PageSize; $i++) {
            if ($i -lt $CurrentListArray.Count) {
                $t = $CurrentListArray[$i]
                $Name = if ($t.TaskName.Length -gt $NameW) { $t.TaskName.Substring(0, $NameW) } else { $t.TaskName }
                $Last = if ($t.LastRunTime) { $t.LastRunTime.ToString("MM/dd HH:mm") } else { "Never" }
                $Res  = $t.LastTaskResult
                
                $Line = "  {0,-10} {1,-$NameW} {2,-$TimeW} {3,-10}" -f $t.State, $Name, $Last, $Res
                $Fg = if ($t.State -eq 'Running') { "Green" } elseif ($t.State -eq 'Ready') { "White" } else { "Gray" }
                $ResColor = if ($Res -eq 0) { "Green" } else { "Red" }
                
                if ($i -eq $SelectedRow -and -not $ShowTaskProps) {
                    Write-Host $Line.Substring(0, $Line.Length-10).PadRight($FrameWidth-10) -ForegroundColor Black -BackgroundColor White -NoNewline
                    Write-Host ("{0,-10}" -f $Res) -ForegroundColor Black -BackgroundColor White
                } else {
                    Write-Host $Line.Substring(0, $Line.Length-10).PadRight($FrameWidth-10) -ForegroundColor $Fg -NoNewline
                    Write-Host ("{0,-10}" -f $Res) -ForegroundColor $ResColor
                }
            } else { Write-Host "".PadRight($FrameWidth) }
            $RowsDrawn++
        }
    }
    $Empty = $PageSize - $RowsDrawn
    if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
}
