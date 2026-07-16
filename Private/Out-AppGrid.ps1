function Out-AppGrid {
    param(
        [array]$Apps,
        [Parameter(Mandatory=$true)][int]$SelectedRow,
        [Parameter(Mandatory=$true)][int]$PageIndex,
        [Parameter(Mandatory=$true)][int]$PageSize,
        [Parameter(Mandatory=$true)][int]$FrameWidth,
        [Parameter(Mandatory=$true)][int]$SelColIndex,
        [Parameter(Mandatory=$true)][bool]$IsDesc
    )

    $AppHeaders = @("Name", "Version", "Publisher", "Type", "Install Date")
    $AppProps   = @("DisplayName", "DisplayVersion", "Publisher", "AppType", "InstallDate")
    $AppAligns  = @("-", "-", "-", "-", "-")

    $Avail = [math]::Max(20, $FrameWidth - 42)
    $NameW = [math]::Floor($Avail * 0.6)
    $PubW  = $Avail - $NameW
    $AppWidths = @($NameW, 15, $PubW, 10, 12)

    # --- APP GRID ---
    Write-Host "  " -NoNewline
    for ($i = 0; $i -lt $AppHeaders.Count; $i++) {
        $HText = $AppHeaders[$i]
        if ($i -eq $SelColIndex) {
            $Arrow = if ($IsDesc) { "▼" } else { "▲" }
            $HText = "$HText$Arrow"
        }
        if ($HText.Length -gt $AppWidths[$i]) { $HText = $HText.Substring(0, $AppWidths[$i]) }
        
        $Fmt = "{0," + $AppAligns[$i] + $AppWidths[$i] + "}"
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

    # Get apps and sort
    $SortedApps = $Apps | Sort-Object $AppProps[$SelColIndex] -Descending:$IsDesc
    $Start = $PageIndex * $PageSize
    $ListToShow = $SortedApps | Select-Object -Skip $Start -First $PageSize
    
    $RowsDrawn = 0
    if ($ListToShow) {
        $CurrentListArray = @($ListToShow)
        for ($i = 0; $i -lt $PageSize; $i++) {
            if ($i -lt $CurrentListArray.Count) {
                $appObj = $CurrentListArray[$i]
                
                $Name = Pad-String $appObj.DisplayName $NameW
                $Ver  = Pad-String $appObj.DisplayVersion 15
                $Pub  = Pad-String $appObj.Publisher $PubW
                $Type = Pad-String $appObj.AppType 10
                $Date = Pad-String $appObj.InstallDate 12
                
                $Line = "  $Name $Ver $Pub $Type $Date"
                $PaddedLine = Pad-String $Line $FrameWidth
                
                if ($i -eq $SelectedRow) {
                    Write-Host $PaddedLine -ForegroundColor Black -BackgroundColor White
                } else {
                    Write-Host $PaddedLine -ForegroundColor White
                }
            } else { Write-Host "".PadRight($FrameWidth) }
            $RowsDrawn++
        }
    }
    $Empty = $PageSize - $RowsDrawn
    if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
}
