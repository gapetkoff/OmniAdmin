<#
.SYNOPSIS
    A high-performance, asynchronous TUI System Monitor and Task Manager.

.DESCRIPTION
    Start-SystemMonitor is a terminal-based system dashboard.

.PARAMETER ComputerName
    The target computer to monitor. Defaults to "localhost".

.PARAMETER PageSize
    Optional. Sets a fixed number of rows to display in lists.

.PARAMETER Credential
    Optional. PSCredential object to use for remote connections.
    
.PARAMETER Diagnostics
    Optional Switch. Displays the yellow diagnostic bar showing internal worker thread counters.

.EXAMPLE
    Start-SystemMonitor -Diagnostics
#>
function Start-SystemMonitor {
    [CmdletBinding()]
    param (
        [Parameter(Position=0)]
        [string]$ComputerName = "localhost",

        [Parameter(Position=1)]
        [ValidateRange(5,100)]
        [int]$PageSize = 0,

        [Parameter(HelpMessage="Credentials for remote connection")]
        [System.Management.Automation.PSCredential]$Credential = $null,
        
        [Parameter(HelpMessage="Enable diagnostic output bar")]
        [switch]$Diagnostics
    )

    $isWindowsOS = $true
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
        $isWindowsOS = $false
    }
    if (-not $isWindowsOS) {
        Write-Error "Start-SystemMonitor requires Windows as it relies on WMI."
        return
    }

    $UseFixedPageSize = $PSBoundParameters.ContainsKey('PageSize')
    
    #region 0. ADMIN CHECK
    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Warning "You are NOT running as Administrator. Actions (Kill, Logoff, Services, Tasks) may fail."
        Start-Sleep -Seconds 1
    }
    #endregion
    #region 0b. REMOTE HOST REACHABILITY PRE-CHECK
    $IsLocal = ($ComputerName -eq "localhost" -or $ComputerName -eq "." -or $ComputerName -eq $env:COMPUTERNAME)
    if (-not $IsLocal) {
        Write-Host ""
        Write-Host " Checking reachability of '$ComputerName'..." -ForegroundColor DarkGray
        
        # First try a fast TCP connect to WinRM port 5985 (2 second timeout)
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connected = $false
        try {
            $connectResult = $tcpClient.BeginConnect($ComputerName, 5985, $null, $null)
            $connected = $connectResult.AsyncWaitHandle.WaitOne(2000, $false)
            if ($connected -and $tcpClient.Connected) {
                $tcpClient.EndConnect($connectResult)
            } else {
                $connected = $false
            }
        } catch { $connected = $false }
        finally { $tcpClient.Dispose() }

        if (-not $connected) {
            # TCP failed — try ICMP ping to distinguish host-down from WinRM-not-configured
            $pingReachable = $false
            try {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $pingResult = $ping.Send($ComputerName, 1500)
                $pingReachable = ($pingResult.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
            } catch { $pingReachable = $false }

            Write-Host ""
            if ($pingReachable) {
                Write-Host " HOST REACHABLE but WinRM is not responding on port 5985." -ForegroundColor Yellow
                Write-Host " Ensure WinRM is enabled on '$ComputerName':" -ForegroundColor Yellow
                Write-Host "   Enable-PSRemoting -Force   (run on the remote machine)" -ForegroundColor DarkGray
            } else {
                Write-Host " HOST UNREACHABLE: '$ComputerName' did not respond." -ForegroundColor Red
                Write-Host " Verify the hostname/IP is correct and the machine is online." -ForegroundColor DarkGray
            }
            Write-Host ""
            return
        }

        Write-Host " Host reachable. Connecting..." -ForegroundColor DarkGray
    }
    #endregion

    $SyncHash = [hashtable]::Synchronized(@{
        TargetComputer    = $ComputerName
        Credential        = $Credential
        Running           = $true
        # Optimization Flags
        UserModeActive    = $false
        ServiceModeActive = $false
        TaskModeActive    = $false
        AppModeActive     = $false
        # Queues
        KillQueue         = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
        LogoffQueue       = [System.Collections.Concurrent.ConcurrentQueue[int]]::new()
        ServiceQueue      = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        TaskQueue         = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        # Data
        SysData           = $null
        UserData          = @()   
        ServiceData       = @()
        TaskData          = @()
        AppData           = @()
        StaticData        = $null        
        RawProcessList    = $null
        LastUpdate        = [DateTime]::MinValue
        # Status
        Error             = $null
        CriticalError     = $false
        Disconnected      = $false
        ReconnectAttempt  = 0
        ReconnectMessage  = ""
        DisconnectTime    = [DateTime]::MinValue
        ActionStatus      = ""
        DebugLog          = "Init..."
        SpeedTest         = [hashtable]::Synchronized(@{
            TestMode        = "Local"
            TargetHost      = if ($ComputerName -ne "localhost") { $ComputerName } else { "" }
            Threads         = 8
            TimeoutSeconds  = 15
            Port            = 5201
            Running         = $false
            ActivePhase     = "Idle"
            ProgressPercent = 0.0
            Results         = [hashtable]::Synchronized(@{ Latency = $null; Download = $null; Upload = $null; Error = "" })
        })
    })
    #endregion

    #region 4. UI THREAD STARTUP
    $PS = [PowerShell]::Create()
    
    # Pass the function script block to the Runspace
    $WorkerScript = ${function:Invoke-SystemMonitorWorker}
    $null = $PS.AddScript($WorkerScript).AddArgument($SyncHash)
    $AsyncHandle = $PS.BeginInvoke()

    try { [Console]::CursorVisible = $false } catch {}
    Clear-Host

    $UILoaded = $false
    $SyncHash.SpeedTest.TestMode = if ($IsLocal) { "Local" } else { "Remote" }

    # Initial Wait
    try {
        $LoadWidth = [math]::Min($Host.UI.RawUI.WindowSize.Width, 42)
        Write-Host ""
        Write-Host ("═" * $LoadWidth) -ForegroundColor Cyan
        Write-Host " ⚡ SYSTEM MONITOR: $ComputerName" -ForegroundColor Cyan
        Write-Host ("═" * $LoadWidth) -ForegroundColor Cyan
        Write-Host " 🌐 Connecting..." -ForegroundColor DarkGray

        while (-not $UILoaded) {
            if ($SyncHash.CriticalError) { break }
            if ($SyncHash.SysData -and $SyncHash.StaticData) { $UILoaded = $true; break }
            if ($SyncHash.Error -like "Waiting*") {
                [Console]::SetCursorPosition(0, 3)
                Write-Host " ⏳ $($SyncHash.Error)".PadRight($LoadWidth) -ForegroundColor Cyan
            }
            Start-Sleep -Milliseconds 100
        }
        if ($SyncHash.CriticalError) {
            Clear-Host
            Write-Host ""
            Write-Host " CONNECTION FAILED" -ForegroundColor Red
            Write-Host " $($SyncHash.Error)" -ForegroundColor Yellow
            Write-Host ""
            return
        }
        Clear-Host
    #endregion

        # Load BrowserHistory script and sqlite3 base64 path into SyncHash
        # Resolve module root dynamically - works on any computer regardless of install path.
        # Strategy 1: ScriptBlock.File from Get-Command - most reliable, returns the actual .ps1 source path
        $ModuleRoot = $null
        $dbgLog = "PathRes: "
        try {
            $cmd = Get-Command Start-SystemMonitor -ErrorAction SilentlyContinue
            $sbFile = if ($cmd) { $cmd.ScriptBlock.File } else { $null }
            if ($sbFile) {
                # ScriptBlock.File = .../Public/Start-SystemMonitor.ps1 -> parent's parent = module root
                $ModuleRoot = Split-Path -Parent (Split-Path -Parent $sbFile)
                $dbgLog += "SBF=$sbFile->$ModuleRoot"
            } else {
                $dbgLog += "SBF=null"
            }
        } catch { $dbgLog += "SBF threw: $_" }

        # Strategy 2: Module.ModuleBase from Get-Command
        if (-not $ModuleRoot) {
            try {
                $cmd = Get-Command Start-SystemMonitor -ErrorAction SilentlyContinue
                if ($cmd -and $cmd.Module -and $cmd.Module.ModuleBase) {
                    $ModuleRoot = $cmd.Module.ModuleBase
                    $dbgLog += " | GCM=$ModuleRoot"
                } else { $dbgLog += " | GCM=noMod" }
            } catch { $dbgLog += " | GCM threw: $_" }
        }

        # Strategy 3: PSScriptRoot parent (works when dot-sourced directly)
        if (-not $ModuleRoot -and $PSScriptRoot) {
            $ModuleRoot = Split-Path -Parent $PSScriptRoot
            $dbgLog += " | PSR=$ModuleRoot"
        }

        $HistoryScriptPath = Join-Path $ModuleRoot "Public\Get-BrowserHistory.ps1"
        $dbgLog += " | HP=$(Test-Path $HistoryScriptPath):$HistoryScriptPath"
        if (Test-Path $HistoryScriptPath) {
            $SyncHash.BrowserHistoryScript = Get-Content $HistoryScriptPath -Raw
            $dbgLog += " LOADED"
        }

        $B64Path = Join-Path $ModuleRoot "Private\sqlite3.exe.b64"
        $dbgLog += " | B64=$(Test-Path $B64Path)"
        if (Test-Path $B64Path) {
            $SyncHash.SqliteB64Path = (Resolve-Path $B64Path).Path
        }

        $SyncHash.DebugLog = $dbgLog

        # Compile TuiEngine if not loaded
        $TuiEnginePath = Join-Path $ModuleRoot "Private\TuiEngine.cs"
        if (Test-Path $TuiEnginePath) {
            if (-not ("OmniAdmin.TuiEngine" -as [type])) {
                $TuiCode = Get-Content $TuiEnginePath -Raw
                Add-Type -TypeDefinition $TuiCode
            }
        } else {
            throw "Could not find TuiEngine.cs at: $TuiEnginePath"
        }

        # Define Speed Test background worker script block
        $InitNetEngineSB = ${function:Initialize-NetworkEngine}
        $STWorker = {
            param($SyncHash, $InitNetEngineSB, $ComputerName)
            try {
                # $InitNetEngineSB arrives as a plain string when launched from C# TuiEngine.
                # Wrap in [scriptblock]::Create() so & executes it as code, not a command name.
                $InitSB = [scriptblock]::Create($InitNetEngineSB)
                function Initialize-NetworkEngine { & $InitSB }
                if (-not ("NativeNetworkTest" -as [type])) {
                    Initialize-NetworkEngine
                }
                
                $Threads = $SyncHash.SpeedTest.Threads
                $Timeout = $SyncHash.SpeedTest.TimeoutSeconds
                $Port = $SyncHash.SpeedTest.Port
                $Target = $ComputerName
                $Mode = $SyncHash.SpeedTest.TestMode
                
                # --- PHASE 1: LATENCY ---
                $SyncHash.SpeedTest.ActivePhase = "Latency"
                $SyncHash.SpeedTest.ProgressPercent = 10
                
                $PingTarget = if ($Mode -eq "Local") { "speed.cloudflare.com" } else { $Target }
                $PingPort = if ($Mode -eq "Local") { 443 } else { 5985 }
                
                if ($Mode -eq "P2P" -and -not $Target) {
                    throw "Target Host is required for Peer-to-Peer test."
                }
                if ($Mode -eq "Remote" -and -not $Target) {
                    throw "Target Host is required for Remote test."
                }
                
                $measurements = @()
                for ($i = 0; $i -lt 10; $i++) {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    try {
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        $tcp.Connect($PingTarget, $PingPort)
                        $sw.Stop()
                        $measurements += $sw.Elapsed.TotalMilliseconds
                    }
                    catch {
                        # Ignore single connection failures
                    }
                    finally { $tcp.Dispose() }
                    $SyncHash.SpeedTest.ProgressPercent = 10 + ($i * 10)
                    Start-Sleep -Milliseconds 100
                }
                if ($measurements.Count -gt 0) {
                    $SyncHash.SpeedTest.Results.Latency = [math]::Round(($measurements | Measure-Object -Average).Average, 1)
                } else {
                    $SyncHash.SpeedTest.Results.Latency = 0.0
                }
                
                # --- PHASE 2: DOWNLOAD ---
                $SyncHash.SpeedTest.ActivePhase = "Download"
                $SyncHash.SpeedTest.ProgressPercent = 0.0
                $SyncHash.SpeedTest.PhaseStartTime = [DateTime]::UtcNow
                
                $dlSpeed = 0.0
                if ($Mode -eq "Local") {
                    $downUrl = "https://speed.cloudflare.com/__down?bytes=50000000"
                    $dlSpeed = [NativeNetworkTest]::Download($downUrl, $Threads, $Timeout)
                }
                elseif ($Mode -eq "Remote") {
                    # Build remote scriptblock via string concat to avoid here-string/interpolation issues
                    $initBody = $InitNetEngineSB.ToString()
                    $remoteScriptText = "function Initialize-NetworkEngine { " + $initBody + " }`n" +
                                        "Initialize-NetworkEngine`n" +
                                        "[NativeNetworkTest]::Download('https://speed.cloudflare.com/__down?bytes=50000000', $Threads, $Timeout)"
                    $remoteScript = [scriptblock]::Create($remoteScriptText)
                    $params = @{
                        ComputerName = $Target
                        ScriptBlock  = $remoteScript
                    }
                    if ($SyncHash.Credential) { $params['Credential'] = $SyncHash.Credential }
                    $dlSpeed = Invoke-Command @params
                }
                elseif ($Mode -eq "P2P") {
                    # Local IP
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Connect($Target, 1)
                    $localIP = $udp.Client.LocalEndPoint.Address.ToString()
                    $udp.Close()
                    
                    # Local firewall rule
                    New-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
                    $fwCreated = $true
                    
                    # Remote worker — build via string concat to avoid here-string issues
                    $initBody = $InitNetEngineSB.ToString()
                    $workerLifetime = ($Timeout * 3) + 60
                    $totalConnections = ($Threads * 2) + 1
                    $workerScriptText = "function Initialize-NetworkEngine { " + $initBody + " }`n" +
                                        "Initialize-NetworkEngine`n" +
                                        "[PeerSpeedTest]::WorkerConnect('$localIP', $Port, $totalConnections, $workerLifetime)"
                    $workerScript = [scriptblock]::Create($workerScriptText)
                    $jobParams = @{
                        ComputerName = $Target
                        ScriptBlock  = $workerScript
                        AsJob        = $true
                    }
                    if ($SyncHash.Credential) { $jobParams['Credential'] = $SyncHash.Credential }
                    $workerJob = Invoke-Command @jobParams
                    
                    # Measure download
                    $dlSpeed = [PeerSpeedTest]::MeasureDownload($Port, $Threads, $Timeout)
                    
                    # Cleanup
                    try { [PeerSpeedTest]::KillWorkers($Port) } catch {}
                    if ($workerJob) { Remove-Job -Force $workerJob -ErrorAction SilentlyContinue }
                    if ($fwCreated) { Remove-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -ErrorAction SilentlyContinue; $fwCreated = $false }
                }
                $SyncHash.SpeedTest.Results.Download = $dlSpeed
                $SyncHash.SpeedTest.ProgressPercent = 100.0
                
                # --- PHASE 3: UPLOAD ---
                $SyncHash.SpeedTest.ActivePhase = "Upload"
                $SyncHash.SpeedTest.ProgressPercent = 0.0
                $SyncHash.SpeedTest.PhaseStartTime = [DateTime]::UtcNow
                
                $ulSpeed = 0.0
                if ($Mode -eq "Local") {
                    $upUrl = "https://speed.cloudflare.com/__up"
                    $ulSpeed = [NativeNetworkTest]::Upload($upUrl, $Threads, $Timeout)
                }
                elseif ($Mode -eq "Remote") {
                    $initBody = $InitNetEngineSB.ToString()
                    $remoteScriptText = "function Initialize-NetworkEngine { " + $initBody + " }`n" +
                                        "Initialize-NetworkEngine`n" +
                                        "[NativeNetworkTest]::Upload('https://speed.cloudflare.com/__up', $Threads, $Timeout)"
                    $remoteScript = [scriptblock]::Create($remoteScriptText)
                    $params = @{
                        ComputerName = $Target
                        ScriptBlock  = $remoteScript
                    }
                    if ($SyncHash.Credential) { $params['Credential'] = $SyncHash.Credential }
                    $ulSpeed = Invoke-Command @params
                }
                elseif ($Mode -eq "P2P") {
                    # Local IP
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Connect($Target, 1)
                    $localIP = $udp.Client.LocalEndPoint.Address.ToString()
                    $udp.Close()
                    
                    # Local firewall rule
                    New-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
                    $fwCreated = $true
                    
                    # Remote worker
                    $initBody = $InitNetEngineSB.ToString()
                    $workerLifetime = ($Timeout * 3) + 60
                    $totalConnections = ($Threads * 2) + 1
                    $workerScriptText = "function Initialize-NetworkEngine { " + $initBody + " }`n" +
                                        "Initialize-NetworkEngine`n" +
                                        "[PeerSpeedTest]::WorkerConnect('$localIP', $Port, $totalConnections, $workerLifetime)"
                    $workerScript = [scriptblock]::Create($workerScriptText)
                    $jobParams = @{
                        ComputerName = $Target
                        ScriptBlock  = $workerScript
                        AsJob        = $true
                    }
                    if ($SyncHash.Credential) { $jobParams['Credential'] = $SyncHash.Credential }
                    $workerJob = Invoke-Command @jobParams
                    
                    # Measure upload
                    $ulSpeed = [PeerSpeedTest]::MeasureUpload($Port, $Threads, $Timeout)
                    
                    # Cleanup
                    try { [PeerSpeedTest]::KillWorkers($Port) } catch {}
                    if ($workerJob) { Remove-Job -Force $workerJob -ErrorAction SilentlyContinue }
                    if ($fwCreated) { Remove-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -ErrorAction SilentlyContinue; $fwCreated = $false }
                }
                $SyncHash.SpeedTest.Results.Upload = $ulSpeed
                $SyncHash.SpeedTest.ProgressPercent = 100.0
                $SyncHash.SpeedTest.ActivePhase = "Done"
            }
            catch {
                $SyncHash.SpeedTest.Results.Error = $_.Exception.Message
                $SyncHash.SpeedTest.ActivePhase = "Error"
                if ($fwCreated) { Remove-NetFirewallRule -DisplayName "OmniAdmin-PeerTest" -ErrorAction SilentlyContinue }
            }
            finally {
                $SyncHash.SpeedTest.Running = $false
            }
        }

        # Run compiled C# TUI Loop
        [OmniAdmin.TuiEngine]::Run(
            $SyncHash,
            $ComputerName,
            $PageSize,
            $UseFixedPageSize,
            $Diagnostics,
            $Credential,
            $STWorker.ToString(),
            $InitNetEngineSB.ToString()
        )
    }
    #region CLEANUP
    finally {
        Write-Host "`nStopping..." -ForegroundColor DarkGray
        $SyncHash.Running = $false
        try { $PS.EndInvoke($AsyncHandle) } catch {}
        try { $PS.Dispose() } catch {}
        try { [Console]::CursorVisible = $true } catch {}
        Clear-Host
    }
    #endregion
}
