<#
.SYNOPSIS
    Performs a high-performance network speed test (Latency, Download, Upload) using native C# sockets.

.DESCRIPTION
    This tool measures network throughput by leveraging the NativeNetworkTest C# class.
    It overcomes PowerShell 5.1/Legacy .NET limitations to allow high-concurrency testing.
    
    Key Features:
    - Accurate Latency test to Cloudflare.
    - Multi-threaded Download and Upload tests (Infinite Loop logic).
    - Automatic Remote Execution via -ComputerName.
    - Unlocks connection limits on remote hosts for accurate Gigabit+ testing.
    - Peer-to-Peer mode (-PeerToPeer) for measuring LAN throughput between two machines.

.PARAMETER Threads
    The number of concurrent streams to use. Defaults to 8. 
    Higher numbers (up to 64) may be needed for Gigabit+ connections.

.PARAMETER TimeoutSeconds
    The maximum duration for each test phase. Defaults to 15 seconds.

.PARAMETER ComputerName
    One or more remote computers to run the test on. 
    If omitted, the test runs on the local machine.

.PARAMETER Credential
    Optional credentials to use when connecting to remote computers.

.PARAMETER PeerToPeer
    Switch that changes the test mode from Cloudflare (internet) to a direct 
    peer-to-peer throughput test between your machine and the remote target.
    Requires -ComputerName.

.PARAMETER Port
    The TCP port used for the peer-to-peer test server. Defaults to 5201.
    Only used with -PeerToPeer.

.EXAMPLE
    Measure-Speed
    Runs the test locally with default settings.

.EXAMPLE
    Measure-Speed -ComputerName "TONY-PROBOOK"
    Runs the test on a remote machine using your current credentials.

.EXAMPLE
    Measure-Speed -ComputerName "Server01", "Server02" -Credential (Get-Credential)
    Runs the test on multiple servers sequentially with specific credentials.

.EXAMPLE
    Measure-Speed -ComputerName "Server01" -PeerToPeer
    Measures direct network throughput between your machine and Server01.

.EXAMPLE
    Measure-Speed -ComputerName "Server01" -P2P -Port 9999
    Peer-to-peer test on a custom port.
#>
function Measure-Speed {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$ComputerName,

        [int]$Threads = 8,
        
        [int]$TimeoutSeconds = 15,
        
        [pscredential]$Credential,
        
        [Alias('P2P')]
        [switch]$PeerToPeer,
        
        [int]$Port = 5201
    )

    $isWindowsOS = $true
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        $isWindowsOS = $false
    }
    if (-not $isWindowsOS) {
        Write-Error "Measure-Speed requires Windows as it relies on Windows-specific networking APIs."
        return
    }

    # Speed formatting helper: auto-scale to Gbps for high speeds
    function Format-Speed([double]$Mbps) {
        if ($Mbps -ge 1000) { return "$([math]::Round($Mbps / 1000, 2)) Gbps" }
        return "$([math]::Round($Mbps, 2)) Mbps"
    }

    # ╔════════════════════════════════════════════════════════════╗
    # ║  PEER-TO-PEER MODE  (Reverse-Connection Architecture)     ║
    # ║  LOCAL = server/listener    REMOTE = outbound data pump   ║
    # ╚════════════════════════════════════════════════════════════╝
    if ($PeerToPeer) {
        if (-not $ComputerName) {
            Write-Error "-PeerToPeer requires -ComputerName. A peer-to-peer test needs a remote target."
            return
        }

        # Ensure engine is loaded locally
        if (-not ("PeerSpeedTest" -as [type])) {
            Initialize-NetworkEngine
        }

        $initBlock = ${function:Initialize-NetworkEngine}

        foreach ($target in $ComputerName) {
            $headerWidth = 42
            Write-Host ""
            Write-Host ("═" * $headerWidth) -ForegroundColor Magenta
            Write-Host " ⚡ PEER-TO-PEER: $($env:COMPUTERNAME) ↔ $target" -ForegroundColor Magenta
            Write-Host "    Timeout: ${TimeoutSeconds}s │ Threads: $Threads │ Port: $Port" -ForegroundColor DarkGray
            Write-Host ("═" * $headerWidth) -ForegroundColor Magenta

            $workerJob = $null
            $fwRuleCreated = $false

            try {
                # --- Step 1: Determine local IP visible to the remote ---
                $localIP = $null
                try {
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Connect($target, 1)
                    $localIP = $udp.Client.LocalEndPoint.Address.ToString()
                    $udp.Close()
                } catch {}

                if (-not $localIP) {
                    Write-Host "`n   Could not determine local IP to reach $target" -ForegroundColor Red
                    continue
                }

                # --- Step 2: Open temporary LOCAL firewall rule ---
                Write-Host "`n [•] Opening local firewall (port $Port)..." -NoNewline -ForegroundColor DarkGray
                try {
                    New-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -ErrorAction Stop | Out-Null
                    $fwRuleCreated = $true
                    Write-Host " OK" -ForegroundColor Green
                }
                catch {
                    Write-Host " BLOCKED" -ForegroundColor Red
                    Write-Host "   ⚠ Could not create firewall rule: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "   ⚠ Run as Administrator, or manually allow TCP $Port inbound." -ForegroundColor Yellow
                }

                # --- Step 3: Launch remote worker (connects OUTBOUND to us) ---
                Write-Host " [•] Launching remote worker on $target..." -NoNewline -ForegroundColor DarkGray
                $workerLifetime = ($TimeoutSeconds * 3) + 60
                $totalConnections = ($Threads * 2) + 1  # N download + N upload + 1 probe
                $workerScript = [scriptblock]::Create(@"
                    function Initialize-NetworkEngine { $initBlock }
                    Initialize-NetworkEngine
                    [PeerSpeedTest]::WorkerConnect('$localIP', $Port, $totalConnections, $workerLifetime)
"@)
                $jobParams = @{
                    ComputerName = $target
                    ScriptBlock  = $workerScript
                    AsJob        = $true
                }
                if ($PSBoundParameters.ContainsKey('Credential')) { $jobParams['Credential'] = $Credential }
                $workerJob = Invoke-Command @jobParams
                Write-Host " OK" -ForegroundColor Green

                # --- Step 4: Readiness probe (wait for first worker connection) ---
                Write-Host " [•] Waiting for remote worker..." -NoNewline -ForegroundColor DarkGray
                $probeReady = $false
                try {
                    $probeStart = [datetime]::UtcNow
                    $probeListen = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, $Port)
                    $probeListen.Start()
                    $probeDeadline = [datetime]::UtcNow.AddSeconds(60)
                    while ([datetime]::UtcNow -lt $probeDeadline) {
                        # Check if the job failed (compilation error, etc.)
                        if ($workerJob.State -eq 'Failed') {
                            $workerJob | Receive-Job -ErrorAction SilentlyContinue -ErrorVariable jobErrors | Out-Null
                            break
                        }
                        $ar = $probeListen.BeginAcceptTcpClient($null, $null)
                        if ($ar.AsyncWaitHandle.WaitOne(1000)) {
                            $probeClient = $probeListen.EndAcceptTcpClient($ar)
                            $probeClient.Close()
                            $probeReady = $true
                            break
                        }
                    }
                    $probeListen.Stop()
                }
                catch { }

                if (-not $probeReady) {
                    Write-Host " FAILED" -ForegroundColor Red
                    if ($jobErrors) {
                        foreach ($e in $jobErrors) { Write-Host "   $e" -ForegroundColor Red }
                    } else {
                        Write-Host "   ⚠ Remote worker could not connect to ${localIP}:${Port}" -ForegroundColor Yellow
                        Write-Host "   ⚠ A network firewall may be blocking TCP $Port." -ForegroundColor Yellow
                        Write-Host "   ⚠ Try a different port:  Measure-Speed $target -P2P -Port 443" -ForegroundColor DarkGray
                    }
                    continue
                }
                $probeElapsed = [math]::Round(([datetime]::UtcNow - $probeStart).TotalSeconds, 1)
                Write-Host " Ready (${probeElapsed}s)" -ForegroundColor Green

                # --- TEST 1: LATENCY (TCP handshake to WinRM port) ---
                Write-Host "`n [1/3] Testing Latency..." -NoNewline
                try {
                    $measurements = @()
                    for ($i = 0; $i -lt 10; $i++) {
                        $tcpPing = New-Object System.Net.Sockets.TcpClient
                        try {
                            $sw = [System.Diagnostics.Stopwatch]::StartNew()
                            $tcpPing.Connect($target, 5985)
                            $sw.Stop()
                            $measurements += $sw.Elapsed.TotalMilliseconds
                        }
                        finally { $tcpPing.Dispose() }
                        Start-Sleep -Milliseconds 100
                    }
                    $avgMs = [math]::Round(($measurements | Measure-Object -Average).Average, 1)
                    $color = "Green"
                    if ($avgMs -gt 5)  { $color = "Yellow" }
                    if ($avgMs -gt 20) { $color = "Red" }
                    Write-Host "   $avgMs ms" -ForegroundColor $color
                }
                catch { Write-Host "   Error" -ForegroundColor Red }

                # --- TEST 2: remote → local throughput ---
                # Local listens, remote connects outbound and sends data
                Write-Host " [2/3] $target → $($env:COMPUTERNAME)..." -NoNewline
                try {
                    $dlSpeed = [PeerSpeedTest]::MeasureDownload($Port, $Threads, $TimeoutSeconds)
                    if ($dlSpeed -eq 0) {
                        Write-Host "  0 Mbps" -ForegroundColor Red
                        Write-Host "   ⚠ No connections received — firewall is blocking TCP $Port inbound." -ForegroundColor Yellow
                        Write-Host "   ⚠ Run as Administrator or: New-NetFirewallRule -DisplayName 'P2P' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow" -ForegroundColor DarkGray
                    } else {
                        Write-Host "  $(Format-Speed $dlSpeed)" -ForegroundColor Green
                    }
                }
                catch { Write-Host " Error ($($_.Exception.Message))" -ForegroundColor Red }

                # --- TEST 3: local → remote throughput ---
                # Local listens, remote connects outbound and sinks data
                Write-Host " [3/3] $($env:COMPUTERNAME) → $target..." -NoNewline
                try {
                    $ulSpeed = [PeerSpeedTest]::MeasureUpload($Port, $Threads, $TimeoutSeconds)
                    if ($ulSpeed -eq 0) {
                        Write-Host "  0 Mbps" -ForegroundColor Red
                        Write-Host "   ⚠ No connections received — firewall is blocking TCP $Port inbound." -ForegroundColor Yellow
                    } else {
                        Write-Host "  $(Format-Speed $ulSpeed)" -ForegroundColor Green
                    }
                }
                catch { Write-Host " Error ($($_.Exception.Message))" -ForegroundColor Red }

            }
            finally {
                # --- Cleanup ---
                if ($workerJob) {
                    try { [PeerSpeedTest]::KillWorkers($Port) } catch {}
                    # Fire-and-forget job cleanup to return to prompt instantly
                    Start-Job { param($j) $j | Remove-Job -Force -ErrorAction SilentlyContinue } -ArgumentList $workerJob | Out-Null
                }
                if ($fwRuleCreated) {
                    Remove-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -ErrorAction SilentlyContinue
                }
            }

            Write-Host ("═" * $headerWidth) -ForegroundColor Magenta
        }
        return
    }

    # ╔════════════════════════════════════════════════════════════╗
    # ║  REMOTE CLOUDFLARE MODE (existing behavior)               ║
    # ╚════════════════════════════════════════════════════════════╝
    if ($ComputerName) {
        $initBlock = ${function:Initialize-NetworkEngine}
        $mainBlock = $MyInvocation.MyCommand.ScriptBlock
        
        $remoteScript = [scriptblock]::Create(@"
            function Initialize-NetworkEngine { $initBlock }
            Initialize-NetworkEngine
            & { $mainBlock } -Threads `$args[0] -TimeoutSeconds `$args[1]
"@)
        
        $params = @{
            ComputerName = $ComputerName
            ScriptBlock  = $remoteScript
            ArgumentList = $Threads, $TimeoutSeconds
        }
        if ($PSBoundParameters.ContainsKey('Credential')) { $params['Credential'] = $Credential }
        
        Invoke-Command @params
        return # Stop processing locally
    }

    # ╔════════════════════════════════════════════════════════════╗
    # ║  LOCAL CLOUDFLARE MODE (existing behavior)                ║
    # ╚════════════════════════════════════════════════════════════╝
    # Ensure the engine is initialized (in case it runs remotely, the remote script block initializes it)
    if (-not ("NativeNetworkTest" -as [type])) {
        Initialize-NetworkEngine
    }

    $hostName = $env:COMPUTERNAME
    $headerWidth = 42
    Write-Host ""
    Write-Host ("═" * $headerWidth) -ForegroundColor Cyan
    Write-Host " ⚡ NETWORK DIAGNOSTIC: $hostName"       -ForegroundColor Cyan
    Write-Host "    Timeout: ${TimeoutSeconds}s │ Threads: $Threads" -ForegroundColor DarkGray
    Write-Host ("═" * $headerWidth) -ForegroundColor Cyan

    # --- TEST 1: LATENCY ---
    $pingTarget = "speed.cloudflare.com"
    $pingPort = 443
    Write-Host "`n [1/3] Testing Latency..." -NoNewline
    try {
        $measurements = @()
        for ($i = 0; $i -lt 10; $i++) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $tcp.Connect($pingTarget, $pingPort)
                $sw.Stop()
                $measurements += $sw.Elapsed.TotalMilliseconds
            }
            finally { $tcp.Dispose() }
            Start-Sleep -Milliseconds 100 
        }
        $avgMs = [math]::Round(($measurements | Measure-Object -Average).Average, 0)
        
        $color = "Green"
        if ($avgMs -gt 50) { $color = "Yellow" }
        if ($avgMs -gt 100) { $color = "Red" }
        Write-Host "   $avgMs ms" -ForegroundColor $color
    }
    catch { Write-Host "   Error" -ForegroundColor Red }

    # --- TEST 2: DOWNLOAD ---
    $downUrl = "https://speed.cloudflare.com/__down?bytes=50000000" 
    Write-Host " [2/3] Testing Download..." -NoNewline
    try {
        # Warmup
        [NativeNetworkTest]::Download($downUrl, 2, 3) | Out-Null 
        # Real Test
        $dlSpeed = [NativeNetworkTest]::Download($downUrl, $Threads, $TimeoutSeconds)
        Write-Host "  $(Format-Speed $dlSpeed)" -ForegroundColor Green
    } catch { Write-Host " Error ($($_.Exception.Message))" -ForegroundColor Red }

    # --- TEST 3: UPLOAD ---
    $upUrl = "https://speed.cloudflare.com/__up"
    Write-Host " [3/3] Testing Upload..." -NoNewline
    try {
        # Warmup
        [NativeNetworkTest]::Upload($upUrl, 2, 3) | Out-Null
        # Real Test
        $ulSpeed = [NativeNetworkTest]::Upload($upUrl, $Threads, $TimeoutSeconds)
        Write-Host "    $(Format-Speed $ulSpeed)" -ForegroundColor Green
    } catch { Write-Host " Error" -ForegroundColor Red }

    Write-Host ("═" * $headerWidth) -ForegroundColor Cyan
}
