function Invoke-SystemMonitorWorker {
    param($Sync)
    
    $Session = $null
    $LastUserFetch = [DateTime]::MinValue
    $LastAppFetch = [DateTime]::MinValue
    $IsLocal = ($Sync.TargetComputer -eq "localhost" -or $Sync.TargetComputer -eq $env:COMPUTERNAME)
    
    #region CONNECTION SETUP
    try {
        if (-not $IsLocal) {
            $SessParams = @{ 
                ComputerName = $Sync.TargetComputer
                ErrorAction  = 'Stop'
                SessionOption = (New-PSSessionOption -OperationTimeout 5000)
            }
            if ($Sync.Credential) { $SessParams['Credential'] = $Sync.Credential }
            $Session = New-PSSession @SessParams
        }
    }
    catch {
        $Sync.Error = "Connection Failed: $($_.Exception.Message)"
        $Sync.CriticalError = $true
        return 
    }

    # Optimized Runner
    function Run-Script {
        param($Script, $Arguments) 
        
        if ($IsLocal) {
            if ($Arguments) { & $Script @Arguments } else { & $Script }
        } else {
            if ($Session) {
                Invoke-Command -Session $Session -ScriptBlock $Script -ArgumentList $Arguments
            }
        }
    }
    #endregion

    #region PRE-FETCH STATIC
    while ($null -eq $Sync.StaticData -and $Sync.Running) {
        try {
            $Sync.DebugLog = "WMI Warmup..."
            $ScriptBlock = {
                $CPU = Get-CimInstance Win32_Processor -ErrorAction Stop
                $OS  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                $CS  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                $CpuName = $CPU.Name -replace "\s+", " " -replace "\(R\)", "" -replace "\(TM\)", ""
                
                # GPU Static Info Fetch
                $GpuName = $null
                try {
                    $Video = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($Video) { $GpuName = $Video.Name }
                } catch {}

                [PSCustomObject]@{
                    CpuName  = $CpuName
                    GpuName  = $GpuName
                    Cores    = $CS.NumberOfLogicalProcessors
                    TotalRam = [math]::Round($OS.TotalVisibleMemorySize / 1024 / 1024, 1)
                    BootTime = $OS.LastBootUpTime
                }
            }
            
            if ($IsLocal) { $Sync.StaticData = (& $ScriptBlock) }
            else { $Sync.StaticData = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock }
            
        } catch { 
            $Sync.Error = "Waiting for WMI..." 
            Start-Sleep -Seconds 2
        }
    }
    #endregion

    #region MAIN DATA LOOP
    $CachedGpuLoad = 0
    $GpuCycleCount = 0
    $CycleCount = 0
    while ($Sync.Running) {
        $CycleStart = [DateTime]::UtcNow
        try {
            # --- ACTION PROCESSING ---
            $PidToKill = 0
            while ($Sync.KillQueue.TryDequeue([ref]$PidToKill)) {
                if ($IsLocal) { Stop-Process -Id $PidToKill -Force -ErrorAction SilentlyContinue }
                else { Invoke-Command -Session $Session -ScriptBlock { Stop-Process -Id $args[0] -Force } -ArgumentList $PidToKill }
                $Sync.ActionStatus = "Killed PID $PidToKill"
            }

            $SessionToLogoff = 0
            while ($Sync.LogoffQueue.TryDequeue([ref]$SessionToLogoff)) {
                $Sb = { 
                    $res = logoff $args[0] 2>&1 
                    if ($LASTEXITCODE -ne 0) { throw "Exit Code $LASTEXITCODE" }
                }
                if ($IsLocal) { & $Sb $SessionToLogoff }
                else { Invoke-Command -Session $Session -ScriptBlock $Sb -ArgumentList $SessionToLogoff }
                $Sync.ActionStatus = "Logoff sent to Session $SessionToLogoff"
            }
            
            $SvcAction = $null
            while ($Sync.ServiceQueue.TryDequeue([ref]$SvcAction)) {
                $Sb = { 
                    param($N,$A) 
                    if($A -eq "Start"){Start-Service $N} elseif($A -eq "Stop"){Stop-Service $N -Force} else{Restart-Service $N -Force} 
                }
                if ($IsLocal) { & $Sb $SvcAction.Name $SvcAction.Action }
                else { Invoke-Command -Session $Session -ScriptBlock $Sb -ArgumentList $SvcAction.Name, $SvcAction.Action }
                $Sync.ActionStatus = "$($SvcAction.Action) $($SvcAction.Name)"
            }

            $TaskToStart = $null
            while ($Sync.TaskQueue.TryDequeue([ref]$TaskToStart)) {
                $Sb = { Start-ScheduledTask -TaskName $args[0] }
                if ($IsLocal) { & $Sb $TaskToStart }
                else { Invoke-Command -Session $Session -ScriptBlock $Sb -ArgumentList $TaskToStart }
                $Sync.ActionStatus = "Started $TaskToStart"
            }

            # --- DATA FETCHING CONFIG ---
            $FetchUsers = $false
            if ($Sync.UserModeActive -or ((Get-Date) - $LastUserFetch).TotalSeconds -gt 30) {
                $FetchUsers = $true
                $LastUserFetch = Get-Date
            }
            
            $FetchApps = $false
            if ($Sync.AppModeActive -or ((Get-Date) - $LastAppFetch).TotalSeconds -gt 60) {
                $FetchApps = $true
                $LastAppFetch = Get-Date
            }
            
            # GPU: only query every 5 cycles (~5s) since it's the slowest WMI class
            $GpuCycleCount++
            $DoGpu = ($GpuCycleCount -ge 5)
            if ($DoGpu) { $GpuCycleCount = 0 }
            
            # Pass logical core count so the Run-Script block can normalize per-core CPU %
            $CoreCount = if ($Sync.StaticData -and $Sync.StaticData.Cores -gt 0) { [int]$Sync.StaticData.Cores } else { 1 }
            $ArgsArray = @([bool]$FetchUsers, [bool]$Sync.ServiceModeActive, [bool]$Sync.TaskModeActive, [bool]$DoGpu, [bool]$FetchApps, [int]$CoreCount, [bool]($CycleCount -eq 0))

            $Result = Run-Script -Script {
                param($DoUsers, $DoServices, $DoTasks, $DoGpu, $DoApps, $CoreCount, $IsFirstCycle)
                
                $DebugStr = ""

                # 1. Performance Data (V71: Optimized with -Filter to avoid piping all instances)
                $CpuTotal = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction SilentlyContinue
                $RAM = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                $DiskIO = Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
                
                # Network Stats (Robust Initialization & Error Handling)
                $TotalSent = 0
                $TotalRecv = 0
                try {
                    $NetStats = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop
                    if ($NetStats) {
                        $TotalSent = ($NetStats | Measure-Object -Property BytesSentPersec -Sum).Sum
                        $TotalRecv = ($NetStats | Measure-Object -Property BytesReceivedPersec -Sum).Sum
                    }
                } catch {} # Silent fail to 0 if WMI error

                # GPU Load (only queried every 5 cycles as this WMI class is very slow)
                $GpuLoad = 0
                if ($DoGpu) {
                    try {
                        $GpuCounters = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction SilentlyContinue
                        if ($GpuCounters) {
                            $GpuLoad = ($GpuCounters | Measure-Object -Property UtilizationPercentage -Average).Average
                        }
                    } catch {}
                }

                # Normalize per-core CPU% to 0-100% range.
                # Win32_PerfFormattedData_PerfProc_Process reports PercentProcessorTime
                # as (usage * LogicalCores), so divide by core count to get true %.
                $Procs = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Name -ne "Idle" -and $_.Name -ne "_Total" } |
                    ForEach-Object {
                        # Divide by core count and cap at 100.0
                        $CpuVal = 0.0
                        if (-not $IsFirstCycle) {
                            $CpuVal = [math]::Round([double]$_.PercentProcessorTime / $CoreCount, 1)
                            if ($CpuVal -gt 100.0) { $CpuVal = 100.0 }
                            if ($CpuVal -lt 0.0) { $CpuVal = 0.0 }
                        }
                        [PSCustomObject]@{
                            Name = [string]$_.Name
                            IDProcess = [int]$_.IDProcess
                            PercentProcessorTime = $CpuVal
                            WorkingSet = [long]$_.WorkingSet
                            ThreadCount = [int]$_.ThreadCount
                            HandleCount = [int]$_.HandleCount
                        }
                    }

                # 2. User Data
                $UserList = $null
                if ($DoUsers) {
                    $UserList = @()
                    try {
                        $quserOut = query user 2>&1 
                        if ($quserOut -is [string] -or $quserOut -is [Array]) {
                            $quserOut | Select-Object -Skip 1 | ForEach-Object {
                                $line = $_.Trim()
                                if ($line -match '^>?([^\s]+)\s+([^\s]*)\s+(\d+)\s+([^\s]+)\s+([^\s]+)\s+(.+)$') {
                                    $UserList += [PSCustomObject]@{
                                        UserName    = $Matches[1]
                                        SessionName = if ($Matches[2]) { $Matches[2] } else { "console" }
                                        SessionId   = [int]$Matches[3]
                                        State       = $Matches[4]
                                        IdleTime    = $Matches[5]
                                        LogonTime   = $Matches[6]
                                    }
                                }
                            }
                        }
                        $DebugStr += "Usr: $($UserList.Count) "
                    } catch { $DebugStr += "Usr:Err " }
                }

                # 3. Services Data
                $SvcList = $null
                if ($DoServices) {
                    $SvcList = Get-Service | Select-Object Name, @{N='Status';E={$_.Status.ToString()}}, @{N='StartType';E={$_.StartType.ToString()}}, DisplayName, Description
                    $DebugStr += "Svc: $($SvcList.Count) "
                }

                # 4. Tasks Data
                $TaskList = $null
                if ($DoTasks) {
                    try {
                        if (-not (Get-Module -Name ScheduledTasks)) { Import-Module ScheduledTasks -ErrorAction SilentlyContinue }
                        
                        $RawTasks = Get-ScheduledTask -TaskPath "" -ErrorAction SilentlyContinue
                        if (-not $RawTasks) { $RawTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object -First 50 }

                        $TaskList = $RawTasks | ForEach-Object {
                            $info = $_ | Get-ScheduledTaskInfo
                            [PSCustomObject]@{
                                TaskName = $_.TaskName
                                State = $_.State.ToString()
                                LastRunTime = $info.LastRunTime
                                LastTaskResult = $info.LastTaskResult
                                Triggers = if ($_.Triggers) { "Yes" } else { "No" }
                                Actions = if ($_.Actions) { "Yes" } else { "No" }
                            }
                        }
                        $DebugStr += "Tsk: $($TaskList.Count) "
                    } catch { $DebugStr += "Tsk:Err " }
                }

                # 5. Installed Apps Data
                $AppList = $null
                if ($DoApps) {
                    try {
                        # Load and register Shlwapi type if not already loaded (for indirect string resolution)
                        if (-not ("Win32.Shlwapi" -as [type])) {
                            try {
                                $MethodDefinition = @'
[DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
public static extern int SHLoadIndirectString(string pszSource, System.Text.StringBuilder pszOutBuf, int cchOutBuf, System.IntPtr ppvReserved);
'@
                                Add-Type -MemberDefinition $MethodDefinition -Name "Shlwapi" -Namespace "Win32" -ErrorAction SilentlyContinue
                            } catch {}
                        }

                        $GetFriendlyName = {
                            param([string]$RawString)
                            if ($RawString -and $RawString.StartsWith("@") -and ("Win32.Shlwapi" -as [type])) {
                                try {
                                    $OutBuf = [System.Text.StringBuilder]::new(1024)
                                    $Result = [Win32.Shlwapi]::SHLoadIndirectString($RawString, $OutBuf, $OutBuf.Capacity, [IntPtr]::Zero)
                                    if ($Result -eq 0) {
                                        return $OutBuf.ToString()
                                    }
                                } catch {}
                            }
                            return $RawString
                        }

                        $LocalApps = @()
                        
                        # A. Registry entries (Classic)
                        $RegPaths = @(
                            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                            "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
                        )
                        $RegApps = Get-ItemProperty $RegPaths -ErrorAction SilentlyContinue |
                            Where-Object { $_.DisplayName -and -not $_.SystemComponent -and $_.ParentKeyName -eq $null } |
                            ForEach-Object {
                                $Date = $_.InstallDate
                                if ($Date -match '^\d{8}$') {
                                    $Date = "$($Date.Substring(0,4))-$($Date.Substring(4,2))-$($Date.Substring(6,2))"
                                }
                                $DispName = & $GetFriendlyName $_.DisplayName
                                $PubName = & $GetFriendlyName $_.Publisher
                                [PSCustomObject]@{
                                    DisplayName    = [string]$DispName
                                    DisplayVersion = if ($_.DisplayVersion) { [string]$_.DisplayVersion } else { "" }
                                    Publisher      = [string]$PubName
                                    AppType        = "Classic"
                                    InstallDate    = if ($Date) { [string]$Date } else { "" }
                                }
                            }
                        if ($RegApps) { $LocalApps += $RegApps }
                        
                        # B. AppX Packages (Store)
                        $StoreApps = Get-AppxPackage -ErrorAction SilentlyContinue |
                            Where-Object { -not $_.IsFramework -and $_.SignatureKind -in 'Store', 'Developer', 'None' } |
                            ForEach-Object {
                                $Name = $_.Name
                                # Strip hex-like publisher hash or numeric domain prefixes (e.g. AD2F1837.HPPrinterControl -> HPPrinterControl, 19453.net.Rufus -> Rufus)
                                $Name = $Name -replace '^[a-fA-F0-9]{8}[. -]', '' -replace '^\d+\.net\.', ''
                                $Name = $Name -replace '\.', ' '
                                $Name = $Name -creplace '(?<=[a-z])(?=[A-Z])', ' '
                                $Name = $Name -replace '\bMicrosoft Microsoft\b', 'Microsoft'
                                
                                $Pub = $_.Publisher
                                if ($Pub -match 'CN=([^,]+)') { $Pub = $Matches[1] }
                                $Pub = & $GetFriendlyName $Pub
                                
                                [PSCustomObject]@{
                                    DisplayName    = [string]$Name
                                    DisplayVersion = if ($_.Version) { [string]$_.Version } else { "" }
                                    Publisher      = if ($Pub) { [string]$Pub } else { "" }
                                    AppType        = "Store"
                                    InstallDate    = ""
                                }
                            }
                        if ($StoreApps) { $LocalApps += $StoreApps }
                        
                        # Deduplicate by DisplayName and sort
                        $AppList = $LocalApps | Group-Object DisplayName | ForEach-Object { $_.Group[0] }
                        $DebugStr += "App: $($AppList.Count) "
                    } catch { $DebugStr += "App:Err " }
                }

                # V71: Safety clamps on total system stats to avoid overflow anomalies
                $SafeCpuLoad = if ($CpuTotal) { [math]::Min(100, [math]::Max(0, [math]::Round([double]$CpuTotal.PercentProcessorTime))) } else { 0 }
                $SafeDiskR   = if ($DiskIO) { [math]::Round([double]$DiskIO.DiskReadBytesPersec / 1MB, 1) } else { 0 }
                $SafeDiskW   = if ($DiskIO) { [math]::Round([double]$DiskIO.DiskWriteBytesPersec / 1MB, 1) } else { 0 }
                # Compute thread count from the process data we already have (avoids a second expensive WMI call)
                $ThreadCnt = if ($Procs) { ($Procs | Measure-Object -Property ThreadCount -Sum).Sum } else { 0 }

                [PSCustomObject]@{
                    CpuLoad   = $SafeCpuLoad
                    GpuLoad   = [math]::Round([double]$GpuLoad)
                    TotalRam  = [math]::Round([double]$RAM.TotalVisibleMemorySize / 1024)
                    FreeRam   = [math]::Round([double]$RAM.FreePhysicalMemory / 1024)
                    UpMbps    = [math]::Round(([double]$TotalSent * 8) / 1000000, 1)
                    DnMbps    = [math]::Round(([double]$TotalRecv * 8) / 1000000, 1)
                    DiskRead  = $SafeDiskR
                    DiskWrite = $SafeDiskW
                    Processes = $Procs
                    UserList  = $UserList
                    SvcList   = $SvcList
                    TaskList  = $TaskList
                    AppList   = $AppList
                    DebugStr  = $DebugStr
                    ThreadCount = $ThreadCnt
                }
            } -Arguments $ArgsArray

            $Sync.SysData = $Result
            $Sync.RawProcessList = $Result.Processes
            
            # Cache GPU load for non-GPU cycles
            if ($DoGpu) { $CachedGpuLoad = $Result.GpuLoad }
            elseif ($Result) { $Result.GpuLoad = $CachedGpuLoad; $Sync.SysData = $Result }
            
            # FORCE UPDATE SHARED MEMORY
            if ($Result.UserList) { $Sync.UserData = @($Result.UserList) }
            if ($Result.SvcList) { $Sync.ServiceData = @($Result.SvcList) }
            if ($Result.TaskList) { $Sync.TaskData = @($Result.TaskList) }
            if ($Result.AppList) { $Sync.AppData = @($Result.AppList) }
            
            if ($Result.DebugStr) { $Sync.DebugLog = $Result.DebugStr }
            
            $Sync.LastUpdate = Get-Date
            $CycleCount++
        }
        catch { $Sync.DebugLog = "CRASH: $($_.Exception.Message)" }
        # Dynamic sleep: target 1-second total cycle time, accounting for query duration
        $Elapsed = ([DateTime]::UtcNow - $CycleStart).TotalMilliseconds
        $SleepMs = [math]::Max(100, 1000 - $Elapsed)
        Start-Sleep -Milliseconds $SleepMs
    }
    
    # CLEANUP REMOTE SESSION
    if ($Session) { Remove-PSSession $Session }
    #endregion
}
