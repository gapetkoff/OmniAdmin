function Out-SpeedTestGrid {
    param(
        [hashtable]$SpeedTest,
        [int]$SelectedRow,
        [int]$PageSize,
        [int]$FrameWidth,
        [bool]$IsLocal,
        [string]$ComputerName
    )

    # Format helpers
    function Format-Speed([double]$Mbps) {
        if ($Mbps -ge 1000) { return "$([math]::Round($Mbps / 1000, 2)) Gbps" }
        return "$([math]::Round($Mbps, 2)) Mbps"
    }

    function Get-ProgressGauge([double]$Percent) {
        $Width = 25
        $Chars = [math]::Round(($Percent / 100.0) * $Width)
        if ($Chars -lt 0) { $Chars = 0 }
        if ($Chars -gt $Width) { $Chars = $Width }
        $Bar = ("█" * $Chars) + ("░" * ($Width - $Chars))
        return "[$Bar]"
    }

    # Render top header line
    Write-Host "  NETWORK SPEED TEST CONFIGURATION & RESULTS" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

    $Lines = @()
    $Lines += "  SETTINGS"

    # Row 0: Test Mode
    if ($IsLocal) {
        # Fixed Local Mode
        $FmtMode = "    [1] Test Mode:   Local Internet (Cloudflare)"
        $Lines += if ($SelectedRow -eq 0) { @{ Text = $FmtMode; Highlight = $true } } else { @{ Text = $FmtMode; Highlight = $false } }
    } else {
        # Cycles between Remote and P2P
        $ModeStr = $SpeedTest.TestMode
        $ModeDisp = if ($ModeStr -eq "Remote") { "◄ Remote Internet (Cloudflare) ►" } else { "◄ Peer-to-Peer (P2P LAN) ►" }
        $FmtMode = "    [1] Test Mode:   $ModeDisp"
        $Lines += if ($SelectedRow -eq 0) { @{ Text = $FmtMode; Highlight = $true } } else { @{ Text = $FmtMode; Highlight = $false } }
    }

    # Row 1: Threads
    $FmtThreads = "    [2] Threads:     $($SpeedTest.Threads) (concurrent streams)"
    $Lines += if ($SelectedRow -eq 1) { @{ Text = $FmtThreads; Highlight = $true } } else { @{ Text = $FmtThreads; Highlight = $false } }

    # Row 2: Timeout
    $FmtTimeout = "    [3] Timeout:     $($SpeedTest.TimeoutSeconds) seconds per phase"
    $Lines += if ($SelectedRow -eq 2) { @{ Text = $FmtTimeout; Highlight = $true } } else { @{ Text = $FmtTimeout; Highlight = $false } }

    if ($IsLocal) {
        # Row 3: Start Button
        $FmtButton = "                     [   S T A R T   T E S T   ]"
        $Lines += if ($SelectedRow -eq 3) { @{ Text = $FmtButton; Highlight = $true } } else { @{ Text = $FmtButton; Highlight = $false } }
    } else {
        # Row 3: P2P Port
        $PortDisp = if ($SpeedTest.TestMode -eq "P2P") { "$($SpeedTest.Port)" } else { "N/A (Only for P2P Mode)" }
        $FmtPort = "    [4] P2P Port:    $PortDisp"
        $PortFg = if ($SpeedTest.TestMode -eq "P2P") { "White" } else { "DarkGray" }
        $Lines += if ($SelectedRow -eq 3) { @{ Text = $FmtPort; Highlight = $true; Fg = "Black" } } else { @{ Text = $FmtPort; Highlight = $false; Fg = $PortFg } }

        # Spacer
        $Lines += ""

        # Row 4: Start Button
        $FmtButton = "                     [   S T A R T   T E S T   ]"
        $Lines += if ($SelectedRow -eq 4) { @{ Text = $FmtButton; Highlight = $true } } else { @{ Text = $FmtButton; Highlight = $false } }
    }

    $Lines += ""
    $Lines += "  STATUS & RESULTS"

    # Status / Phase
    $PhaseDisp = "Idle"
    $PhaseColor = "DarkGray"
    if ($SpeedTest.Running) {
        $PhaseColor = "Cyan"
        if ($SpeedTest.ActivePhase -eq "Latency") { $PhaseDisp = "Testing Latency (Target: $ComputerName)..." }
        elseif ($SpeedTest.ActivePhase -eq "Download") { $PhaseDisp = "Testing Download..." }
        elseif ($SpeedTest.ActivePhase -eq "Upload") { $PhaseDisp = "Testing Upload..." }
    } else {
        if ($SpeedTest.ActivePhase -eq "Done") { $PhaseDisp = "Completed!"; $PhaseColor = "Green" }
        elseif ($SpeedTest.ActivePhase -eq "Error") { $PhaseDisp = "Failed: $($SpeedTest.Results.Error)"; $PhaseColor = "Red" }
    }
    $Lines += @{ Text = "    Phase:    $PhaseDisp"; Highlight = $false; Fg = $PhaseColor }

    # Progress Bar
    $ProgressLine = "    Progress: "
    if ($SpeedTest.Running) {
        $ProgressLine += "$(Get-ProgressGauge $SpeedTest.ProgressPercent) $([math]::Round($SpeedTest.ProgressPercent))%"
        $Lines += @{ Text = $ProgressLine; Highlight = $false; Fg = "Cyan" }
    } else {
        $ProgressLine += "--"
        $Lines += @{ Text = $ProgressLine; Highlight = $false; Fg = "DarkGray" }
    }

    # Latency
    $LatVal = if ($null -ne $SpeedTest.Results.Latency) { "$($SpeedTest.Results.Latency) ms" } else { "-- ms" }
    $LatFg = if ($null -ne $SpeedTest.Results.Latency) { "Green" } else { "DarkGray" }
    $Lines += @{ Text = "    Latency:  $LatVal"; Highlight = $false; Fg = $LatFg }

    # Download
    $DlVal = if ($null -ne $SpeedTest.Results.Download) { "$(Format-Speed $SpeedTest.Results.Download)" } else { "-- Mbps" }
    $DlFg = if ($null -ne $SpeedTest.Results.Download) { "Green" } else { "DarkGray" }
    $Lines += @{ Text = "    Download: $DlVal"; Highlight = $false; Fg = $DlFg }

    # Upload
    $UlVal = if ($null -ne $SpeedTest.Results.Upload) { "$(Format-Speed $SpeedTest.Results.Upload)" } else { "-- Mbps" }
    $UlFg = if ($null -ne $SpeedTest.Results.Upload) { "Green" } else { "DarkGray" }
    $Lines += @{ Text = "    Upload:   $UlVal"; Highlight = $false; Fg = $UlFg }

    # Draw lines
    $LinesDrawn = 0
    foreach ($L in $Lines) {
        if ($LinesDrawn -lt $PageSize) {
            if ($L -is [hashtable]) {
                $FgColor = if ($null -ne $L.Fg) { $L.Fg } else { "White" }
                if ($L.Highlight) {
                    Write-Host $L.Text.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor White
                } else {
                    Write-Host $L.Text.PadRight($FrameWidth) -ForegroundColor $FgColor
                }
            } else {
                Write-Host $L.PadRight($FrameWidth)
            }
            $LinesDrawn++
        }
    }

    # Pad remaining lines to strictly match PageSize
    $Empty = $PageSize - $LinesDrawn
    if ($Empty -gt 0) {
        for ($x = 0; $x -lt $Empty; $x++) {
            Write-Host "".PadRight($FrameWidth)
        }
    }
}
