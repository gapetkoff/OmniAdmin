function Out-ServiceGrid {
    param(
        [array]$Services,
        [Parameter(Mandatory=$true)][int]$SelectedRow,
        [Parameter(Mandatory=$true)][int]$PageIndex,
        [Parameter(Mandatory=$true)][int]$PageSize,
        [Parameter(Mandatory=$true)][int]$FrameWidth,
        [Parameter(Mandatory=$true)][int]$SelColIndex,
        [Parameter(Mandatory=$true)][bool]$IsDesc
    )

    $SvcHeaders = @("Status", "Name", "Display Name", "Type")
    $SvcProps   = @("Status", "Name", "DisplayName", "StartType")
    $SvcAligns  = @("-", "-", "-", "-")

    $Avail = [math]::Max(10, $FrameWidth - 26)
    $NameW = [math]::Floor($Avail / 2)
    $DispW = $Avail - $NameW
    $SvcWidths = @(10, $NameW, $DispW, 10)

    # --- SERVICE GRID ---
    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $SvcHeaders.Count; $i++) {
        $HText = $SvcHeaders[$i]
        if ($i -eq $SelColIndex) {
            $Arrow = if ($IsDesc) { "▼" } else { "▲" }
            $HText = "$HText$Arrow"
        }
        if ($HText.Length -gt $SvcWidths[$i]) { $HText = $HText.Substring(0, $SvcWidths[$i]) }
        
        $Fmt = "{0," + $SvcAligns[$i] + $SvcWidths[$i] + "}"
        if ($i -eq $SelColIndex) {
            Write-Host ($Fmt -f $HText) -ForegroundColor Black -BackgroundColor White -NoNewline
        } else {
            Write-Host ($Fmt -f $HText) -ForegroundColor Gray -NoNewline
        }
        Write-Host " " -NoNewline
    }
    Write-Host "".PadRight(10)
    Write-Host ""
    Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

    $SortedSvcs = $Services | Sort-Object $SvcProps[$SelColIndex] -Descending:$IsDesc
    $Start = $PageIndex * $PageSize
    $ListToShow = $SortedSvcs | Select-Object -Skip $Start -First $PageSize
    
    $RowsDrawn = 0
    if ($ListToShow) {
        $CurrentListArray = @($ListToShow)
        for ($i = 0; $i -lt $PageSize; $i++) {
            if ($i -lt $CurrentListArray.Count) {
                $s = $CurrentListArray[$i]
                
                $Name = if ($s.Name.Length -gt $NameW) { $s.Name.Substring(0, $NameW) } else { $s.Name }
                $DName = if ($s.DisplayName.Length -gt $DispW) { $s.DisplayName.Substring(0, $DispW) } else { $s.DisplayName }
                
                $Line = "  {0,-10} {1,-$NameW} {2,-$DispW} {3,-10}" -f $s.Status, $Name, $DName, $s.StartType
                $Fg = if ($s.Status -eq 'Running') { "Green" } elseif ($s.Status -eq 'Stopped') { "Red" } else { "Yellow" }
                
                if ($i -eq $SelectedRow) {
                    Write-Host $Line.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor White
                } else {
                    Write-Host $Line.PadRight($FrameWidth) -ForegroundColor $Fg
                }
            } else { Write-Host "".PadRight($FrameWidth) }
            $RowsDrawn++
        }
    }
    $Empty = $PageSize - $RowsDrawn
    if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
}
