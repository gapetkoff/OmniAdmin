function Out-UserGrid {
    param(
        [array]$Users,
        [Parameter(Mandatory=$true)][int]$SelectedRow,
        [Parameter(Mandatory=$true)][int]$PageIndex,
        [Parameter(Mandatory=$true)][int]$PageSize,
        [Parameter(Mandatory=$true)][int]$FrameWidth,
        [Parameter(Mandatory=$true)][int]$SelColIndex,
        [Parameter(Mandatory=$true)][bool]$IsDesc
    )

    $UHeaders = @("USER", "SESSION", "ID", "STATE", "IDLE", "LOGON TIME")
    $UProps   = @("UserName", "SessionName", "SessionId", "State", "IdleTime", "LogonTime")
    $UWidths  = @(20, 15, 10, 12, 15, 20)
    $UAligns  = @("-", "-", "-", "-", "-", "-")

    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $UHeaders.Count; $i++) {
        $HText = $UHeaders[$i]
        if ($i -eq $SelColIndex) { $Arrow = if ($IsDesc) { "▼" } else { "▲" }; $HText = "$HText$Arrow" }
        if ($HText.Length -gt $UWidths[$i]) { $HText = $HText.Substring(0, $UWidths[$i]) }
        $Fmt = "{0," + $UAligns[$i] + $UWidths[$i] + "}"
        if ($i -eq $SelColIndex) { Write-Host ($Fmt -f $HText) -ForegroundColor Black -BackgroundColor White -NoNewline } 
        else { Write-Host ($Fmt -f $HText) -ForegroundColor Yellow -NoNewline }
        Write-Host " " -NoNewline
    }
    Write-Host "".PadRight(10)
    Write-Host ""
    Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

    $SortedUsers = $Users
    try { $SortedUsers = $Users | Sort-Object $UProps[$SelColIndex] -Descending:$IsDesc } catch {}
    
    $Start = $PageIndex * $PageSize
    $ListToShow = $SortedUsers | Select-Object -Skip $Start -First $PageSize

    $UserRowsDrawn = 0
    if ($ListToShow) {
        $CurrentListArray = @($ListToShow)
        for ($i = 0; $i -lt $PageSize; $i++) {
            if ($i -lt $CurrentListArray.Count) {
                $u = $CurrentListArray[$i]
                $Line = "  {0,-20} {1,-15} {2,-10} {3,-12} {4,-15} {5,-20}" -f $u.UserName, $u.SessionName, $u.SessionId, $u.State, $u.IdleTime, $u.LogonTime
                if ($Line.Length -gt $FrameWidth) { $Line = $Line.Substring(0, $FrameWidth) }
                if ($i -eq $SelectedRow) { Write-Host $Line.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor White } 
                else { Write-Host $Line.PadRight($FrameWidth) }
            } else { Write-Host "".PadRight($FrameWidth) }
            $UserRowsDrawn++
        }
    }
    $Empty = $PageSize - $UserRowsDrawn
    if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
}
