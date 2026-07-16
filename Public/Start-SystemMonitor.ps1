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
    # Increased header height buffer to account for optional GPU spacing
    $HEADER_HEIGHT = 22 
    
    #region 0. ADMIN CHECK
    $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Warning "You are NOT running as Administrator. Actions (Kill, Logoff, Services, Tasks) may fail."
        Start-Sleep -Seconds 1
    }
    #endregion

    #region 1. SHARED MEMORY
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

    # UI State
    $SelColIndex = 2      
    $IsDesc      = $true  
    $Paused      = $false
    $UserMode    = $false 
    $ServiceMode = $false 
    $TaskMode    = $false
    $AppMode     = $false
    $SpeedTestMode = $false
    $ShowServiceProps = $false 
    $ShowTaskProps    = $false
    $ShowMainMenu     = $false
    
    $IsLocal = ($ComputerName -eq "localhost" -or $ComputerName -eq "." -or $ComputerName -eq $env:COMPUTERNAME)
    $SyncHash.SpeedTest.TestMode = if ($IsLocal) { "Local" } else { "Remote" }
    $SpeedTestRowIndex = 0
    
    $FrozenList  = $null
    $FilterText  = ""
    $PageIndex   = 0      
    $RowIndex    = 0
    $UserRowIndex = 0     
    $SvcRowIndex  = 0     
    $TaskRowIndex = 0
    $AppRowIndex  = 0
    $UILoaded    = $false
    $AnimFrames = @("●", "○", "◐", "◓", "◑", "◒")
    $AnimIndex = 0
    
    $LastWinWidth  = $Host.UI.RawUI.WindowSize.Width
    $LastWinHeight = $Host.UI.RawUI.WindowSize.Height
    $NeedsRedraw = $true
    $LastRenderedUpdate = [DateTime]::MinValue
    $LastRedrawTime = [DateTime]::UtcNow

    # Column Definitions
    $ColHeaders = @("PID", "Name", "CPU(%)", "RAM(MB)", "Threads", "Handles")
    $RealProps  = @("IDProcess", "Name", "PercentProcessorTime", "WorkingSet", "ThreadCount", "HandleCount")
    $ColWidths  = @(8, 15, 10, 10, 10, 10)
    $ColAligns  = @("-", "-", "", "", "", "")

    $SvcHeaders = @("Status", "Name", "Display Name", "Type")
    $SvcProps   = @("Status", "Name", "DisplayName", "StartType")
    $SvcWidths  = @(10, 25, 25, 10)
    $SvcAligns  = @("-", "-", "-", "-")

    $TskHeaders = @("State", "Task Name", "Last Run Time", "Result")
    $TskProps   = @("State", "TaskName", "LastRunTime", "LastTaskResult")
    $TskWidths  = @(10, 30, 25, 10)
    $TskAligns  = @("-", "-", "-", "-")

    $AppHeaders = @("Name", "Version", "Publisher", "Type", "Install Date")
    $AppProps   = @("DisplayName", "DisplayVersion", "Publisher", "AppType", "InstallDate")
    $AppAligns  = @("-", "-", "-", "-", "-")

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
        Clear-Host
    #endregion

    #region 5. UI MAIN LOOP
        while ($true) {
            # Dynamically calculate header height based on visible elements
            $HEADER_HEIGHT = 10
            if ($SyncHash.StaticData -and $SyncHash.StaticData.GpuName) { $HEADER_HEIGHT += 3 }
            if ($Diagnostics) { $HEADER_HEIGHT += 1 }

            # Check if Speed Test background runspace is completed
            if ($SpeedTestPS -and $SpeedTestAsyncHandle -and $SpeedTestAsyncHandle.IsCompleted) {
                try { $SpeedTestPS.EndInvoke($SpeedTestAsyncHandle) } catch {}
                try { $SpeedTestPS.Dispose() } catch {}
                $SpeedTestPS = $null
                $SpeedTestAsyncHandle = $null
            }

            # Update progress percent smoothly during active network tests (Download/Upload)
            if ($SyncHash.SpeedTest.Running -and ($SyncHash.SpeedTest.ActivePhase -in "Download", "Upload")) {
                $Elapsed = ([DateTime]::UtcNow - $SyncHash.SpeedTest.PhaseStartTime).TotalSeconds
                $Pct = [math]::Min(95.0, ($Elapsed / $SyncHash.SpeedTest.TimeoutSeconds) * 100.0)
                $SyncHash.SpeedTest.ProgressPercent = $Pct
            }

            $SyncHash.UserModeActive = $UserMode
            $SyncHash.ServiceModeActive = ($ServiceMode -and -not $ShowServiceProps)
            $SyncHash.TaskModeActive = ($TaskMode -and -not $ShowTaskProps)
            $SyncHash.AppModeActive = $AppMode

            $CurrentWidth = $Host.UI.RawUI.WindowSize.Width
            $CurrentHeight = $Host.UI.RawUI.WindowSize.Height
            if ($CurrentWidth -ne $LastWinWidth -or $CurrentHeight -ne $LastWinHeight) {
                Clear-Host
                $LastWinWidth = $CurrentWidth
                $LastWinHeight = $CurrentHeight
                $NeedsRedraw = $true
            }
            # Check if worker posted new data since our last render
            if ($SyncHash.LastUpdate -ne $LastRenderedUpdate) {
                $NeedsRedraw = $true
            }
            $FrameWidth = $CurrentWidth - 1 

            if ($CurrentWidth -lt 95 -or $CurrentHeight -lt 20) {
                Clear-Host; Write-Host "Terminal too small. Min 95x20." -ForegroundColor Red
                Start-Sleep -Seconds 1; continue
            }
            if ($SyncHash.CriticalError) { Clear-Host; Write-Warning $SyncHash.Error; return }

            #region INPUT: HANDLE KEYS
            if ([Console]::KeyAvailable) {
                $NeedsRedraw = $true
                $Key = [Console]::ReadKey($true).Key
                if ($Key -in "LeftArrow", "RightArrow", "UpArrow", "DownArrow") {
                    while ([Console]::KeyAvailable) { $null = [Console]::ReadKey($true) }
                }

                if ($Key -eq "Q") { return }
                if ($Key -eq "M") { $ShowMainMenu = $true }

                if ($Key -eq "Escape") { 
                    $UserMode = $false; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $SpeedTestMode = $false; $ShowMainMenu = $false; Clear-Host 
                }
                elseif ($Key -eq "P") {
                    if ($ServiceMode) { $ShowServiceProps = $true }
                    elseif ($TaskMode) { $ShowTaskProps = $true }
                    elseif (-not $UserMode -and -not $AppMode) {
                         Clear-Host
                         $Paused = -not $Paused
                         $RowIndex = 0; $PageIndex = 0
                         $SelColIndex = 2; $IsDesc = $true
                         $SyncHash.ActionStatus = ""; $FilterText = ""
                         if ($Paused -and $SyncHash.RawProcessList) {
                              $FrozenList = @($SyncHash.RawProcessList | Select-Object *)
                         }
                    }
                }
                
                # --- INPUT: SERVICE MODE ---
                if ($ServiceMode -and -not $ShowServiceProps) {
                    $FilteredSvc = $SyncHash.ServiceData
                    if ($FilterText) { $FilteredSvc = $FilteredSvc | Where-Object { $_.Name -like "*$FilterText*" -or $_.DisplayName -like "*$FilterText*" } }
                    $SvcCount = if ($FilteredSvc) { $FilteredSvc.Count } else { 0 }
                    
                    $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                    $MaxPages = [math]::Ceiling($SvcCount / $CurrentPageSize)
                    if ($MaxPages -eq 0) { $MaxPages = 1 }
                    $ItemsOnPage = $CurrentPageSize
                    if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $SvcCount - ($PageIndex * $CurrentPageSize) }

                    switch ($Key) {
                        "RightArrow" { if ($PageIndex -lt ($MaxPages - 1)) { $PageIndex++; $SvcRowIndex = 0 } }
                        "LeftArrow"  { if ($PageIndex -gt 0) { $PageIndex--; $SvcRowIndex = 0 } }
                        "UpArrow"    { if ($SvcRowIndex -gt 0) { $SvcRowIndex-- } }
                        "DownArrow"  { if ($SvcRowIndex -lt ($ItemsOnPage - 1)) { $SvcRowIndex++ } }
                        "S" { 
                             try { [Console]::CursorVisible = $true } catch {}
                             try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                             Write-Host " SEARCH: " -NoNewline -ForegroundColor Cyan
                             $FilterText = Read-Host
                             $PageIndex = 0; $SvcRowIndex = 0
                             try { [Console]::CursorVisible = $false } catch {}
                             Clear-Host 
                        }
                        "T" { 
                            $SortedSvcs = $FilteredSvc | Sort-Object $SvcProps[$SelColIndex] -Descending:$IsDesc
                            $AbsIndex = ($PageIndex * $CurrentPageSize) + $SvcRowIndex
                            if ($AbsIndex -lt $SortedSvcs.Count) {
                                $Target = $SortedSvcs[$AbsIndex]
                                $Act = if ($Target.Status -eq 'Running') { "Stop" } else { "Start" }
                                $SyncHash.ServiceQueue.Enqueue(@{ Name = $Target.Name; Action = $Act })
                            }
                        }
                        "R" {
                            $SortedSvcs = $FilteredSvc | Sort-Object $SvcProps[$SelColIndex] -Descending:$IsDesc
                            $AbsIndex = ($PageIndex * $CurrentPageSize) + $SvcRowIndex
                            if ($AbsIndex -lt $SortedSvcs.Count) {
                                $Target = $SortedSvcs[$AbsIndex]
                                $SyncHash.ServiceQueue.Enqueue(@{ Name = $Target.Name; Action = "Restart" })
                            }
                        }
                        "D1" { if ($SelColIndex -eq 0) { $IsDesc = -not $IsDesc } else { $SelColIndex = 0; $IsDesc = $false } }
                        "D2" { if ($SelColIndex -eq 1) { $IsDesc = -not $IsDesc } else { $SelColIndex = 1; $IsDesc = $false } }
                        "D3" { if ($SelColIndex -eq 2) { $IsDesc = -not $IsDesc } else { $SelColIndex = 2; $IsDesc = $true } }
                        "D4" { if ($SelColIndex -eq 3) { $IsDesc = -not $IsDesc } else { $SelColIndex = 3; $IsDesc = $true } }
                    }
                }
                # --- INPUT: TASK MODE ---
                elseif ($TaskMode -and -not $ShowTaskProps) {
                    $TaskList = $SyncHash.TaskData
                    if ($FilterText) { $TaskList = $TaskList | Where-Object { $_.TaskName -like "*$FilterText*" } }
                    $TotalCount = if ($TaskList) { $TaskList.Count } else { 0 }
                    $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                    $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                    if ($MaxPages -eq 0) { $MaxPages = 1 }
                    $ItemsOnPage = $CurrentPageSize
                    if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }

                    switch ($Key) {
                        "RightArrow" { if ($PageIndex -lt ($MaxPages - 1)) { $PageIndex++; $TaskRowIndex = 0 } }
                        "LeftArrow"  { if ($PageIndex -gt 0) { $PageIndex--; $TaskRowIndex = 0 } }
                        "UpArrow"    { if ($TaskRowIndex -gt 0) { $TaskRowIndex-- } }
                        "DownArrow"  { if ($TaskRowIndex -lt ($ItemsOnPage - 1)) { $TaskRowIndex++ } }
                        
                        "S" {
                             try { [Console]::CursorVisible = $true } catch {}
                             try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                             Write-Host " SEARCH: " -NoNewline -ForegroundColor Cyan
                             $FilterText = Read-Host
                             $PageIndex = 0; $TaskRowIndex = 0
                             try { [Console]::CursorVisible = $false } catch {}
                             Clear-Host 
                        }
                        "T" {
                            $SortedTasks = $TaskList | Sort-Object $TskProps[$SelColIndex] -Descending:$IsDesc
                            $AbsIndex = ($PageIndex * $CurrentPageSize) + $TaskRowIndex
                            if ($AbsIndex -lt $SortedTasks.Count) {
                                $Target = $SortedTasks[$AbsIndex]
                                $SyncHash.TaskQueue.Enqueue($Target.TaskName)
                            }
                        }
                        "D1" { if ($SelColIndex -eq 0) { $IsDesc = -not $IsDesc } else { $SelColIndex = 0; $IsDesc = $false } }
                        "D2" { if ($SelColIndex -eq 1) { $IsDesc = -not $IsDesc } else { $SelColIndex = 1; $IsDesc = $false } }
                        "D3" { if ($SelColIndex -eq 2) { $IsDesc = -not $IsDesc } else { $SelColIndex = 2; $IsDesc = $true } }
                        "D4" { if ($SelColIndex -eq 3) { $IsDesc = -not $IsDesc } else { $SelColIndex = 3; $IsDesc = $true } }
                    }
                }
                # --- INPUT: PROCESS MODE ---
                elseif ($Paused) {
                    $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                    $FilteredList = $FrozenList
                    if ($FilterText) { $FilteredList = $FrozenList | Where-Object { $_.Name -like "*$FilterText*" } }
                    $TotalCount = if ($FilteredList) { $FilteredList.Count } else { 0 }
                    $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                    if ($MaxPages -eq 0) { $MaxPages = 1 }
                    $ItemsOnPage = $CurrentPageSize
                    if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }

                    switch ($Key) {
                        "RightArrow" { if ($PageIndex -lt ($MaxPages - 1)) { $PageIndex++; $RowIndex = 0 } }
                        "LeftArrow"  { if ($PageIndex -gt 0) { $PageIndex--; $RowIndex = 0 } }
                        "UpArrow"    { if ($RowIndex -gt 0) { $RowIndex-- } }
                        "DownArrow"  { if ($RowIndex -lt ($ItemsOnPage - 1)) { $RowIndex++ } }
                        "S" {
                             try { [Console]::CursorVisible = $true } catch {}
                             try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                             Write-Host " SEARCH: " -NoNewline -ForegroundColor Cyan
                             $FilterText = Read-Host
                             $PageIndex = 0; $RowIndex = 0
                             try { [Console]::CursorVisible = $false } catch {}
                             Clear-Host 
                        }
                        "K" { 
                             $SortedProcs = $FilteredList | Sort-Object $RealProps[$SelColIndex] -Descending:$IsDesc
                             $AbsIndex = ($PageIndex * $CurrentPageSize) + $RowIndex
                             if ($AbsIndex -lt $SortedProcs.Count) {
                                $Target = $SortedProcs[$AbsIndex]
                                $SyncHash.KillQueue.Enqueue($Target.IDProcess)
                             }
                        }
                        "D1" { if ($SelColIndex -eq 0) { $IsDesc = -not $IsDesc } else { $SelColIndex = 0; $IsDesc = $false } }
                        "D2" { if ($SelColIndex -eq 1) { $IsDesc = -not $IsDesc } else { $SelColIndex = 1; $IsDesc = $false } }
                        "D3" { if ($SelColIndex -eq 2) { $IsDesc = -not $IsDesc } else { $SelColIndex = 2; $IsDesc = $true } }
                        "D4" { if ($SelColIndex -eq 3) { $IsDesc = -not $IsDesc } else { $SelColIndex = 3; $IsDesc = $true } }
                        "D5" { if ($SelColIndex -eq 4) { $IsDesc = -not $IsDesc } else { $SelColIndex = 4; $IsDesc = $true } }
                        "D6" { if ($SelColIndex -eq 5) { $IsDesc = -not $IsDesc } else { $SelColIndex = 5; $IsDesc = $true } }
                    }
                } 
                # --- INPUT: USER MODE ---
                elseif ($UserMode) {
                    $FilteredUsers = $SyncHash.UserData
                    if ($FilterText) { $FilteredUsers = $FilteredUsers | Where-Object { $_.UserName -like "*$FilterText*" -or $_.SessionName -like "*$FilterText*" } }
                    $UCount = if ($FilteredUsers) { $FilteredUsers.Count } else { 0 }
                    $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                    $MaxPages = [math]::Ceiling($UCount / $CurrentPageSize)
                    if ($MaxPages -eq 0) { $MaxPages = 1 }
                    $ItemsOnPage = $CurrentPageSize
                    if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $UCount - ($PageIndex * $CurrentPageSize) }

                    switch ($Key) {
                        "RightArrow" { if ($PageIndex -lt ($MaxPages - 1)) { $PageIndex++; $UserRowIndex = 0 } }
                        "LeftArrow"  { if ($PageIndex -gt 0) { $PageIndex--; $UserRowIndex = 0 } }
                        "UpArrow"    { if ($UserRowIndex -gt 0) { $UserRowIndex-- } }
                        "DownArrow"  { if ($UserRowIndex -lt ($ItemsOnPage - 1)) { $UserRowIndex++ } }
                        "S" { 
                             try { [Console]::CursorVisible = $true } catch {}
                             try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                             Write-Host " SEARCH: " -NoNewline -ForegroundColor Cyan
                             $FilterText = Read-Host
                             $PageIndex = 0; $UserRowIndex = 0
                             try { [Console]::CursorVisible = $false } catch {}
                             Clear-Host 
                        }
                        "D1" { if ($SelColIndex -eq 0) { $IsDesc = -not $IsDesc } else { $SelColIndex = 0; $IsDesc = $false } }
                        "D2" { if ($SelColIndex -eq 1) { $IsDesc = -not $IsDesc } else { $SelColIndex = 1; $IsDesc = $false } }
                        "D3" { if ($SelColIndex -eq 2) { $IsDesc = -not $IsDesc } else { $SelColIndex = 2; $IsDesc = $true } }
                        "D4" { if ($SelColIndex -eq 3) { $IsDesc = -not $IsDesc } else { $SelColIndex = 3; $IsDesc = $true } }
                        "D5" { if ($SelColIndex -eq 4) { $IsDesc = -not $IsDesc } else { $SelColIndex = 4; $IsDesc = $true } }
                        "D6" { if ($SelColIndex -eq 5) { $IsDesc = -not $IsDesc } else { $SelColIndex = 5; $IsDesc = $true } }
                        "L" { 
                            $SortedUsers = $FilteredUsers
                            try { $SortedUsers = $FilteredUsers | Sort-Object @("UserName", "SessionName", "SessionId", "State", "IdleTime", "LogonTime")[$SelColIndex] -Descending:$IsDesc } catch {}
                            $AbsIndex = ($PageIndex * $CurrentPageSize) + $UserRowIndex
                            if ($AbsIndex -lt $SortedUsers.Count) {
                                $TargetUser = $SortedUsers[$AbsIndex]
                                $SyncHash.LogoffQueue.Enqueue($TargetUser.SessionId)
                            }
                        }
                    }
                }
                # --- INPUT: APP MODE ---
                elseif ($AppMode) {
                    $AppList = $SyncHash.AppData
                    if ($FilterText) { $AppList = $AppList | Where-Object { $_.DisplayName -like "*$FilterText*" -or $_.Publisher -like "*$FilterText*" } }
                    $TotalCount = if ($AppList) { $AppList.Count } else { 0 }
                    $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                    $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                    if ($MaxPages -eq 0) { $MaxPages = 1 }
                    $ItemsOnPage = $CurrentPageSize
                    if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }

                    switch ($Key) {
                        "RightArrow" { if ($PageIndex -lt ($MaxPages - 1)) { $PageIndex++; $AppRowIndex = 0 } }
                        "LeftArrow"  { if ($PageIndex -gt 0) { $PageIndex--; $AppRowIndex = 0 } }
                        "UpArrow"    { if ($AppRowIndex -gt 0) { $AppRowIndex-- } }
                        "DownArrow"  { if ($AppRowIndex -lt ($ItemsOnPage - 1)) { $AppRowIndex++ } }
                        "S" { 
                             try { [Console]::CursorVisible = $true } catch {}
                             try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                             Write-Host " SEARCH: " -NoNewline -ForegroundColor Cyan
                             $FilterText = Read-Host
                             $PageIndex = 0; $AppRowIndex = 0
                             try { [Console]::CursorVisible = $false } catch {}
                             Clear-Host 
                        }
                        "D1" { if ($SelColIndex -eq 0) { $IsDesc = -not $IsDesc } else { $SelColIndex = 0; $IsDesc = $false } }
                        "D2" { if ($SelColIndex -eq 1) { $IsDesc = -not $IsDesc } else { $SelColIndex = 1; $IsDesc = $false } }
                        "D3" { if ($SelColIndex -eq 2) { $IsDesc = -not $IsDesc } else { $SelColIndex = 2; $IsDesc = $true } }
                        "D4" { if ($SelColIndex -eq 3) { $IsDesc = -not $IsDesc } else { $SelColIndex = 3; $IsDesc = $true } }
                        "D5" { if ($SelColIndex -eq 4) { $IsDesc = -not $IsDesc } else { $SelColIndex = 4; $IsDesc = $true } }
                    }
                }
                # --- INPUT: SPEED TEST MODE ---
                elseif ($SpeedTestMode) {
                    if ($SyncHash.SpeedTest.Running) {
                        # Do not allow modifying settings or triggering a test while running
                    } else {
                        $MaxRow = if ($IsLocal) { 3 } else { 4 }
                        switch ($Key) {
                            "UpArrow" {
                                if ($SpeedTestRowIndex -gt 0) { $SpeedTestRowIndex-- }
                            }
                            "DownArrow" {
                                if ($SpeedTestRowIndex -lt $MaxRow) { $SpeedTestRowIndex++ }
                            }
                            "LeftArrow" {
                                if ($SpeedTestRowIndex -eq 0) {
                                    if (-not $IsLocal) {
                                        # Toggle Test Mode between Remote and P2P
                                        $SyncHash.SpeedTest.TestMode = if ($SyncHash.SpeedTest.TestMode -eq "Remote") { "P2P" } else { "Remote" }
                                    }
                                }
                                elseif ($SpeedTestRowIndex -eq 1) {
                                    if ($SyncHash.SpeedTest.Threads -gt 1) { $SyncHash.SpeedTest.Threads-- }
                                }
                                elseif ($SpeedTestRowIndex -eq 2) {
                                    if ($SyncHash.SpeedTest.TimeoutSeconds -gt 5) { $SyncHash.SpeedTest.TimeoutSeconds -= 5 }
                                }
                                elseif ($SpeedTestRowIndex -eq 3 -and -not $IsLocal) {
                                    if ($SyncHash.SpeedTest.Port -gt 1024) { $SyncHash.SpeedTest.Port-- }
                                }
                            }
                            "RightArrow" {
                                if ($SpeedTestRowIndex -eq 0) {
                                    if (-not $IsLocal) {
                                        $SyncHash.SpeedTest.TestMode = if ($SyncHash.SpeedTest.TestMode -eq "Remote") { "P2P" } else { "Remote" }
                                    }
                                }
                                elseif ($SpeedTestRowIndex -eq 1) {
                                    if ($SyncHash.SpeedTest.Threads -lt 64) { $SyncHash.SpeedTest.Threads++ }
                                }
                                elseif ($SpeedTestRowIndex -eq 2) {
                                    if ($SyncHash.SpeedTest.TimeoutSeconds -lt 60) { $SyncHash.SpeedTest.TimeoutSeconds += 5 }
                                }
                                elseif ($SpeedTestRowIndex -eq 3 -and -not $IsLocal) {
                                    if ($SyncHash.SpeedTest.Port -lt 65535) { $SyncHash.SpeedTest.Port++ }
                                }
                            }
                            "Enter" {
                                if ($SpeedTestRowIndex -eq 1) {
                                    try { [Console]::CursorVisible = $true } catch {}
                                    try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                                    Write-Host " ENTER THREADS (1-64): " -NoNewline -ForegroundColor Cyan
                                    $Val = Read-Host
                                    if ($Val -match "^\d+$") {
                                        $IntVal = [int]$Val
                                        if ($IntVal -ge 1 -and $IntVal -le 64) { $SyncHash.SpeedTest.Threads = $IntVal }
                                    }
                                    try { [Console]::CursorVisible = $false } catch {}
                                    Clear-Host
                                }
                                elseif ($SpeedTestRowIndex -eq 2) {
                                    try { [Console]::CursorVisible = $true } catch {}
                                    try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                                    Write-Host " ENTER TIMEOUT SECONDS (5-60): " -NoNewline -ForegroundColor Cyan
                                    $Val = Read-Host
                                    if ($Val -match "^\d+$") {
                                        $IntVal = [int]$Val
                                        if ($IntVal -ge 5 -and $IntVal -le 60) { $SyncHash.SpeedTest.TimeoutSeconds = $IntVal }
                                    }
                                    try { [Console]::CursorVisible = $false } catch {}
                                    Clear-Host
                                }
                                elseif ($SpeedTestRowIndex -eq 3) {
                                    if ($IsLocal) {
                                        $TriggerSpeedTest = $true
                                    } else {
                                        if ($SyncHash.SpeedTest.TestMode -eq "P2P") {
                                            try { [Console]::CursorVisible = $true } catch {}
                                            try { [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1) } catch {}
                                            Write-Host " ENTER P2P PORT (1024-65535): " -NoNewline -ForegroundColor Cyan
                                            $Val = Read-Host
                                            if ($Val -match "^\d+$") {
                                                $IntVal = [int]$Val
                                                if ($IntVal -ge 1024 -and $IntVal -le 65535) { $SyncHash.SpeedTest.Port = $IntVal }
                                            }
                                            try { [Console]::CursorVisible = $false } catch {}
                                            Clear-Host
                                        }
                                    }
                                }
                                elseif ($SpeedTestRowIndex -eq 4 -and -not $IsLocal) {
                                    $TriggerSpeedTest = $true
                                }
                            }
                        }
                    }
                }
                # --- INPUT: LIVE ---
                else {
                    switch ($Key) {
                        "LeftArrow"  { if ($SelColIndex -gt 0) { $SelColIndex-- } }
                        "RightArrow" { if ($SelColIndex -lt 5) { $SelColIndex++ } }
                        "UpArrow"    { $IsDesc = $false }
                        "DownArrow"  { $IsDesc = $true }
                        "D1" { if ($SelColIndex -eq 0) { $IsDesc = -not $IsDesc } else { $SelColIndex = 0; $IsDesc = $false } }
                        "D2" { if ($SelColIndex -eq 1) { $IsDesc = -not $IsDesc } else { $SelColIndex = 1; $IsDesc = $false } }
                        "D3" { if ($SelColIndex -eq 2) { $IsDesc = -not $IsDesc } else { $SelColIndex = 2; $IsDesc = $true } }
                        "D4" { if ($SelColIndex -eq 3) { $IsDesc = -not $IsDesc } else { $SelColIndex = 3; $IsDesc = $true } }
                        "D5" { if ($SelColIndex -eq 4) { $IsDesc = -not $IsDesc } else { $SelColIndex = 4; $IsDesc = $true } }
                        "D6" { if ($SelColIndex -eq 5) { $IsDesc = -not $IsDesc } else { $SelColIndex = 5; $IsDesc = $true } }
                    }
                }
            }
            #endregion

            # --- TRIGGER SPEED TEST RUNNER ---
            if ($TriggerSpeedTest) {
                $TriggerSpeedTest = $false
                $SyncHash.SpeedTest.Running = $true
                $SyncHash.SpeedTest.ActivePhase = "Latency"
                $SyncHash.SpeedTest.ProgressPercent = 0.0
                $SyncHash.SpeedTest.Results.Latency = $null
                $SyncHash.SpeedTest.Results.Download = $null
                $SyncHash.SpeedTest.Results.Upload = $null
                $SyncHash.SpeedTest.Results.Error = ""
                
                $InitNetEngineSB = ${function:Initialize-NetworkEngine}
                
                $STWorker = {
                    param($SyncHash, $InitNetEngineSB, $ComputerName)
                    try {
                        function Initialize-NetworkEngine { & $InitNetEngineSB }
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
                            $remoteScript = [scriptblock]::Create(@"
                                function Initialize-NetworkEngine { $InitNetEngineSB }
                                Initialize-NetworkEngine
                                [NativeNetworkTest]::Download('https://speed.cloudflare.com/__down?bytes=50000000', $Threads, $Timeout)
"@)
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
                            
                            # Remote worker
                            $workerLifetime = ($Timeout * 3) + 60
                            $totalConnections = ($Threads * 2) + 1
                            $workerScript = [scriptblock]::Create(@"
                                function Initialize-NetworkEngine { $InitNetEngineSB }
                                Initialize-NetworkEngine
                                [PeerSpeedTest]::WorkerConnect('$localIP', $Port, $totalConnections, $workerLifetime)
"@)
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
                            $remoteScript = [scriptblock]::Create(@"
                                function Initialize-NetworkEngine { $InitNetEngineSB }
                                Initialize-NetworkEngine
                                [NativeNetworkTest]::Upload('https://speed.cloudflare.com/__up', $Threads, $Timeout)
"@)
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
                            $workerLifetime = ($Timeout * 3) + 60
                            $totalConnections = ($Threads * 2) + 1
                            $workerScript = [scriptblock]::Create(@"
                                function Initialize-NetworkEngine { $InitNetEngineSB }
                                Initialize-NetworkEngine
                                [PeerSpeedTest]::WorkerConnect('$localIP', $Port, $totalConnections, $workerLifetime)
"@)
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
                
                $SpeedTestPS = [PowerShell]::Create()
                $null = $SpeedTestPS.AddScript($STWorker).AddArgument($SyncHash).AddArgument($InitNetEngineSB).AddArgument($ComputerName)
                $SpeedTestAsyncHandle = $SpeedTestPS.BeginInvoke()
            }

            #region PREPARE: VIEW STATE
            # Prepare Header and Footer data based on current mode
            $HeaderText = ""
            $HeaderBg   = "Cyan"
            $HeaderFg   = "Black"
            $FooterText = ""
            $FooterBg   = "Black"
            $FooterFg   = "Cyan"

            if ($UserMode) {
                $FilteredUsers = $SyncHash.UserData
                if ($FilterText) { $FilteredUsers = $FilteredUsers | Where-Object { $_.UserName -like "*$FilterText*" -or $_.SessionName -like "*$FilterText*" } }
                $TotalCount = if ($FilteredUsers) { $FilteredUsers.Count } else { 0 }
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                if ($MaxPages -eq 0) { $MaxPages = 1 }
                
                if ($PageIndex -ge $MaxPages) { $PageIndex = [math]::Max(0, $MaxPages - 1) }
                $ItemsOnPage = $CurrentPageSize
                if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }
                if ($UserRowIndex -ge $ItemsOnPage) { $UserRowIndex = [math]::Max(0, $ItemsOnPage - 1) }

                $HeaderText = " 👥 USER MANAGEMENT - PAGE $($PageIndex+1)/$MaxPages "
                if ($FilterText) { $HeaderText += "[Filter: $FilterText] " }
                $HeaderBg   = "DarkMagenta"; $HeaderFg = "White"
                $FooterText = " [S] Search  │  [L] Logoff User  │  [←/→] Page  │  [M] Menu  │  [ESC] Back "
                $FooterBg   = "DarkMagenta"; $FooterFg = "White"
            }
            elseif ($ServiceMode) {
                $FilteredSvc = $SyncHash.ServiceData
                if ($FilterText) { $FilteredSvc = $FilteredSvc | Where-Object { $_.Name -like "*$FilterText*" -or $_.DisplayName -like "*$FilterText*" } }
                $TotalCount = if ($FilteredSvc) { $FilteredSvc.Count } else { 0 }
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                if ($MaxPages -eq 0) { $MaxPages = 1 }
                
                if ($PageIndex -ge $MaxPages) { $PageIndex = [math]::Max(0, $MaxPages - 1) }
                $ItemsOnPage = $CurrentPageSize
                if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }
                if ($SvcRowIndex -ge $ItemsOnPage) { $SvcRowIndex = [math]::Max(0, $ItemsOnPage - 1) }
                
                $HeaderText = " ⚙️ SERVICE MANAGER - PAGE $($PageIndex+1)/$MaxPages "
                if ($FilterText) { $HeaderText += "[Filter: $FilterText] " }
                $HeaderBg   = "Yellow"; $HeaderFg = "Black"
                
                $FooterText = " [S] Search  │  [P] Props  │  [T] Start/Stop  │  [R] Restart  │  [←/→] Page  │  [M] Menu  │  [ESC] Back "
                $FooterBg   = "Yellow"; $FooterFg = "Black"
            }
            elseif ($TaskMode) {
                $FilteredTasks = $SyncHash.TaskData
                if ($FilterText) { $FilteredTasks = $FilteredTasks | Where-Object { $_.TaskName -like "*$FilterText*" } }
                $TotalCount = if ($FilteredTasks) { $FilteredTasks.Count } else { 0 }
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                if ($MaxPages -eq 0) { $MaxPages = 1 }
                
                if ($PageIndex -ge $MaxPages) { $PageIndex = [math]::Max(0, $MaxPages - 1) }
                $ItemsOnPage = $CurrentPageSize
                if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }
                if ($TaskRowIndex -ge $ItemsOnPage) { $TaskRowIndex = [math]::Max(0, $ItemsOnPage - 1) }
                
                $HeaderText = " 📅 SCHEDULED TASKS - PAGE $($PageIndex+1)/$MaxPages "
                if ($FilterText) { $HeaderText += "[Filter: $FilterText] " }
                $HeaderBg   = "DarkCyan"; $HeaderFg = "White"
                
                $FooterText = " [S] Search  │  [T] Start  │  [P] Props  │  [1-4] Sort  │  [←/→] Page  │  [M] Menu  │  [ESC] Back "
                $FooterBg   = "DarkCyan"; $FooterFg = "White"
            }
            elseif ($AppMode) {
                $FilteredApps = $SyncHash.AppData
                if ($FilterText) { $FilteredApps = $FilteredApps | Where-Object { $_.DisplayName -like "*$FilterText*" -or $_.Publisher -like "*$FilterText*" } }
                $TotalCount = if ($FilteredApps) { $FilteredApps.Count } else { 0 }
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                if ($MaxPages -eq 0) { $MaxPages = 1 }
                
                if ($PageIndex -ge $MaxPages) { $PageIndex = [math]::Max(0, $MaxPages - 1) }
                $ItemsOnPage = $CurrentPageSize
                if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }
                if ($AppRowIndex -ge $ItemsOnPage) { $AppRowIndex = [math]::Max(0, $ItemsOnPage - 1) }
                
                $HeaderText = " 📦 INSTALLED APPLICATIONS - PAGE $($PageIndex+1)/$MaxPages "
                if ($FilterText) { $HeaderText += "[Filter: $FilterText] " }
                $HeaderBg   = "DarkGreen"; $HeaderFg = "White"
                
                $FooterText = " [S] Search  │  [1-5] Sort  │  [←/→] Page  │  [M] Menu  │  [ESC] Back "
                $FooterBg   = "DarkGreen"; $FooterFg = "White"
            }
            elseif ($SpeedTestMode) {
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $HeaderText = " ⚡ NETWORK SPEED TEST "
                $HeaderBg   = "DarkMagenta"; $HeaderFg = "White"
                if ($SyncHash.SpeedTest.Running) {
                    $FooterText = " Testing in progress... Please do not close or resize the terminal. "
                } else {
                    $FooterText = " [↕] Select Field  │  [←/→] Adjust  │  [Enter] Edit/Start  │  [M] Menu  │  [ESC] Back "
                }
                $FooterBg   = "DarkMagenta"; $FooterFg = "White"
            }
            elseif ($Paused) {
                $FilteredList = $FrozenList
                if ($FilterText) { $FilteredList = $FrozenList | Where-Object { $_.Name -like "*$FilterText*" } }
                $TotalCount = if ($FilteredList) { $FilteredList.Count } else { 0 }
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $MaxPages = [math]::Ceiling($TotalCount / $CurrentPageSize)
                if ($MaxPages -eq 0) { $MaxPages = 1 }
                
                if ($PageIndex -ge $MaxPages) { $PageIndex = [math]::Max(0, $MaxPages - 1) }
                $ItemsOnPage = $CurrentPageSize
                if (($PageIndex + 1) -eq $MaxPages) { $ItemsOnPage = $TotalCount - ($PageIndex * $CurrentPageSize) }
                if ($RowIndex -ge $ItemsOnPage) { $RowIndex = [math]::Max(0, $ItemsOnPage - 1) }
                
                $HeaderText = " ⏸ PAUSED - PAGE $($PageIndex + 1)/$MaxPages "
                if ($FilterText) { $HeaderText += "[Filter: $FilterText] " }
                $HeaderBg   = "DarkRed"; $HeaderFg = "White"
                
                $FooterText = " [S] Search  │  [1-6] Sort  │  [K] Kill  │  [←/→] Page  │  [P] Resume  │  [M] Menu  │  [Q] Quit "
                $FooterBg   = "Black"; $FooterFg = "Green"
            }
            else {
                # Live Mode
                $AnimIndex = ($AnimIndex + 1) % $AnimFrames.Count
                $Spinner   = $AnimFrames[$AnimIndex]
                $HeaderText = " $Spinner LIVE MONITOR: $ComputerName │ Refreshing every 1s "
                $HeaderBg   = "Cyan"; $HeaderFg = "Black"
                
                $FooterText = " [M] Menu  │  [P] Pause  │  [Q] Quit "
                $FooterBg   = "Black"; $FooterFg = "Cyan"
            }
            #endregion

            #region RENDER: HEADER
            # Time-based fallback: force a redraw every 500ms to keep spinner alive and display feeling responsive
            if (-not $NeedsRedraw -and ([DateTime]::UtcNow - $LastRedrawTime).TotalMilliseconds -ge 500) {
                $NeedsRedraw = $true
            }
            if (-not $NeedsRedraw) { Start-Sleep -Milliseconds 50; continue }
            $NeedsRedraw = $false
            $LastRenderedUpdate = $SyncHash.LastUpdate
            $LastRedrawTime = [DateTime]::UtcNow
            [Console]::SetCursorPosition(0,0)
            $HeaderColor = if ($HeaderBg -eq "DarkRed" -or $HeaderBg -eq "DarkMagenta") { "Red" } else { "Cyan" } # Border Color fallback
            if ($ServiceMode) { $HeaderColor = "Yellow" }
            if ($TaskMode) { $HeaderColor = "DarkCyan" }
            if ($UserMode) { $HeaderColor = "DarkMagenta" }
            if ($AppMode) { $HeaderColor = "DarkGreen" }
            
            Write-Host ("═" * $FrameWidth) -ForegroundColor $HeaderColor
            Write-Host "$HeaderText".PadRight($FrameWidth) -ForegroundColor $HeaderFg -BackgroundColor $HeaderBg
            Write-Host ("═" * $FrameWidth) -ForegroundColor $HeaderColor
            
            # --- DEBUG BAR (Optional) ---
            if ($Diagnostics) {
                $SvcC = if ($SyncHash.ServiceData) { $SyncHash.ServiceData.Count } else { 0 }
                $TskC = if ($SyncHash.TaskData) { $SyncHash.TaskData.Count } else { 0 }
                $UsrC = if ($SyncHash.UserData) { $SyncHash.UserData.Count } else { 0 }
                $AppC = if ($SyncHash.AppData) { $SyncHash.AppData.Count } else { 0 }
                $UIDebug = "UI: Svc=$SvcC Tsk=$TskC Usr=$UsrC App=$AppC"
                Write-Host "$($SyncHash.DebugLog) | $UIDebug".PadRight($FrameWidth) -ForegroundColor Yellow -BackgroundColor Black
            }
            #endregion

            #region RENDER: STATS BAR
            $Sys = $SyncHash.SysData
            $Static = $SyncHash.StaticData
            
            if ($Static -and $Sys) {
                $UpSpan = New-TimeSpan -Start $Static.BootTime -End (Get-Date)
                $UpStr  = "{0}d {1}h {2}m" -f $UpSpan.Days, $UpSpan.Hours, $UpSpan.Minutes
                
                $CpuStr = " 🖥️ CPU: {0} │ {1} Cores" -f $Static.CpuName, $Static.Cores
                Write-Host $CpuStr.PadRight($FrameWidth) -ForegroundColor Cyan
                if ($Static.GpuName) {
                  $GpuStr = " 🎮 GPU: $($Static.GpuName)"
                  Write-Host $GpuStr.PadRight($FrameWidth) -ForegroundColor Cyan
                }
                Write-Host " 💾 RAM: $($Static.TotalRam) GB Total │ ⏱️ Uptime: $UpStr".PadRight($FrameWidth) -ForegroundColor Cyan
                $UsedRam = $Sys.TotalRam - $Sys.FreeRam
                $RamPct = if ($Sys.TotalRam -gt 0) { [math]::Round(($UsedRam / $Sys.TotalRam) * 100) } else { 0 }
                
                $CpuBar = Get-ProgressBar -Percent $Sys.CpuLoad -Width 20
                $RamBar = Get-ProgressBar -Percent $RamPct -Width 20
                
                # --- CPU/RAM LINE ---
                Write-Host " CPU: " -NoNewline -ForegroundColor White
                Write-Host "$($CpuBar.Bar) " -NoNewline -ForegroundColor $CpuBar.Color
                Write-Host "$($Sys.CpuLoad)%  " -NoNewline -ForegroundColor White
                
                Write-Host "RAM: " -NoNewline -ForegroundColor White
                Write-Host "$($RamBar.Bar) " -NoNewline -ForegroundColor $RamBar.Color
                Write-Host "$RamPct%" -ForegroundColor White
                
                # --- GPU LINE ---
                if ($Static.GpuName) {
                  Write-Host ""  # spacer
                  $GpuBar = Get-ProgressBar -Percent $Sys.GpuLoad -Width 20
                  Write-Host " GPU: " -NoNewline -ForegroundColor White
                  Write-Host "$($GpuBar.Bar) " -NoNewline -ForegroundColor $GpuBar.Color
                  Write-Host "$($Sys.GpuLoad)%" -ForegroundColor White
                }
                $NetLine = " 🌐 Net: ↑$($Sys.UpMbps) Mbps ↓$($Sys.DnMbps) Mbps  │  💽 Disk: W:$($Sys.DiskWrite) R:$($Sys.DiskRead) MB/s"
                Write-Host $NetLine.PadRight($FrameWidth) -ForegroundColor DarkGray
                
                $UCount = if ($SyncHash.UserData) { $SyncHash.UserData.Count } else { 0 }
                $ProcLine = " 📊 Processes: $($Sys.Processes.Count)  │  🧵 Threads: $($Sys.ThreadCount)  │  👤 Users: $UCount"
                Write-Host $ProcLine.PadRight($FrameWidth) -ForegroundColor DarkGray

                if ($SyncHash.ActionStatus) {
                    Write-Host " ➤ $($SyncHash.ActionStatus) ".PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor Green
                } elseif ($SyncHash.Error) {
                    Write-Host " ⚠ $($SyncHash.Error) ".PadRight($FrameWidth) -ForegroundColor Yellow -BackgroundColor Black
                } else {
                    Write-Host " ".PadRight($FrameWidth)
                }
            } else {
                Write-Host " Loading...".PadRight($FrameWidth)
                for($i=0; $i -lt 5; $i++) { Write-Host "".PadRight($FrameWidth) }
            }
            Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray
            #endregion

            #region RENDER: CONTENT GRIDS
            $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
            if ($ServiceMode) {
                Out-ServiceGrid -Services $SyncHash.ServiceData -SelectedRow $SvcRowIndex -PageIndex $PageIndex -PageSize $CurrentPageSize -FrameWidth $FrameWidth -SelColIndex $SelColIndex -IsDesc $IsDesc
            }
            elseif ($TaskMode) {
                Out-TaskGrid -Tasks $SyncHash.TaskData -SelectedRow $TaskRowIndex -PageIndex $PageIndex -PageSize $CurrentPageSize -FrameWidth $FrameWidth -SelColIndex $SelColIndex -IsDesc $IsDesc -ShowTaskProps $ShowTaskProps
            }
            elseif ($AppMode) {
                Out-AppGrid -Apps $SyncHash.AppData -SelectedRow $AppRowIndex -PageIndex $PageIndex -PageSize $CurrentPageSize -FrameWidth $FrameWidth -SelColIndex $SelColIndex -IsDesc $IsDesc
            }
            elseif ($UserMode) {
                Out-UserGrid -Users $SyncHash.UserData -SelectedRow $UserRowIndex -PageIndex $PageIndex -PageSize $CurrentPageSize -FrameWidth $FrameWidth -SelColIndex $SelColIndex -IsDesc $IsDesc
            }
            elseif ($SpeedTestMode) {
                Out-SpeedTestGrid -SpeedTest $SyncHash.SpeedTest -SelectedRow $SpeedTestRowIndex -PageSize $CurrentPageSize -FrameWidth $FrameWidth -IsLocal $IsLocal -ComputerName $ComputerName
            }
            else {
                $Cores = if ($Static.Cores) { $Static.Cores } else { 1 }
                $ListToRender = @()
                if ($Paused) {
                    $FilteredList = $FrozenList
                    if ($FilterText) { $FilteredList = $FrozenList | Where-Object { $_.Name -like "*$FilterText*" } }
                    $ListToRender = $FilteredList | Sort-Object $RealProps[$SelColIndex] -Descending:$IsDesc
                } else {
                    $ListToRender = $SyncHash.RawProcessList | Sort-Object $RealProps[$SelColIndex] -Descending:$IsDesc
                }
                Out-ProcessGrid -ProcessList $ListToRender -SelectedRow $RowIndex -PageIndex $PageIndex -PageSize $CurrentPageSize -FrameWidth $FrameWidth -SelColIndex $SelColIndex -IsDesc $IsDesc -Paused $Paused -Cores $Cores
            }
            #endregion

            #region RENDER: OVERLAYS
            # --- SERVICE PROPERTIES ---
            if ($ShowServiceProps) {
                $SortedSvcs = $FilteredSvc | Sort-Object $SvcProps[$SelColIndex] -Descending:$IsDesc
                $AbsIndex = ($PageIndex * (Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize)) + $SvcRowIndex
                
                if ($AbsIndex -lt $SortedSvcs.Count) {
                    $Target = $SortedSvcs[$AbsIndex]
                    $BoxWidth = 60; $BoxHeight = 12
                    $StartX = [math]::Floor(($CurrentWidth - $BoxWidth) / 2)
                    $StartY = [math]::Floor(($CurrentHeight - $BoxHeight) / 2)
                    
                    # Draw Popup Box ONCE
                    for ($y = 0; $y -le $BoxHeight; $y++) {
                        [Console]::SetCursorPosition($StartX, $StartY + $y)
                        Write-Host (" " * $BoxWidth) -BackgroundColor DarkBlue -NoNewline
                    }
                    
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 1)
                    Write-Host "SERVICE PROPERTIES" -ForegroundColor Yellow -BackgroundColor DarkBlue
                    
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 2)
                    Write-Host "Name: $($Target.Name)" -ForegroundColor Cyan -BackgroundColor DarkBlue
                        
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 3)
                    Write-Host "Display: $($Target.DisplayName.Substring(0, [math]::Min($Target.DisplayName.Length, 55)))" -ForegroundColor White -BackgroundColor DarkBlue
                    
                    # Description Wrap
                    $Desc = if ($Target.Description) { $Target.Description } else { "No description." }
                    $Words = $Desc -split "\s+"
                    $CurrentLine = ""; $LineCount = 0
                    
                    foreach ($Word in $Words) {
                        if (($CurrentLine.Length + $Word.Length) -gt ($BoxWidth - 4)) {
                            [Console]::SetCursorPosition($StartX + 2, $StartY + 5 + $LineCount)
                            Write-Host $CurrentLine -ForegroundColor Gray -BackgroundColor DarkBlue
                            $CurrentLine = "$Word "; $LineCount++
                            if ($LineCount -gt 5) { break }
                        } else { $CurrentLine += "$Word " }
                    }
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 5 + $LineCount)
                    Write-Host $CurrentLine -ForegroundColor Gray -BackgroundColor DarkBlue
                    
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 11)
                    Write-Host "[ESC] Close" -ForegroundColor White -BackgroundColor DarkBlue
                    
                    # BLOCK EXECUTION HERE UNTIL ESC IS PRESSED
                    while ($true) {
                        if ([Console]::KeyAvailable) {
                            $SubKey = [Console]::ReadKey($true).Key
                            if ($SubKey -eq "Escape" -or $SubKey -eq "P") {
                                $ShowServiceProps = $false
                                Clear-Host
                                break
                            }
                        }
                        Start-Sleep -Milliseconds 50
                    }
                }
            }
            # --- TASK PROPERTIES ---
            if ($ShowTaskProps) {
                $SortedTasks = $SyncHash.TaskData | Sort-Object $TskProps[$SelColIndex] -Descending:$IsDesc
                $AbsIndex = ($PageIndex * (Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize)) + $TaskRowIndex
                if ($AbsIndex -lt $SortedTasks.Count) {
                    $Target = $SortedTasks[$AbsIndex]
                    $BoxWidth = 70; $BoxHeight = 12
                    $StartX = [math]::Floor(($CurrentWidth - $BoxWidth) / 2)
                    $StartY = [math]::Floor(($CurrentHeight - $BoxHeight) / 2)
                    for ($y = 0; $y -le $BoxHeight; $y++) { [Console]::SetCursorPosition($StartX, $StartY + $y); Write-Host (" " * $BoxWidth) -BackgroundColor DarkCyan -NoNewline }
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 1); Write-Host "TASK DETAILS" -ForegroundColor White -BackgroundColor DarkCyan
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 2); Write-Host "Name: $($Target.TaskName)" -ForegroundColor Yellow -BackgroundColor DarkCyan
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 3); Write-Host "Run:  $($Target.LastRunTime)" -ForegroundColor White -BackgroundColor DarkCyan
                    $CodeColor = if ($Target.LastTaskResult -eq 0) { "Green" } else { "Red" }
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 4); Write-Host "Code: $($Target.LastTaskResult)" -ForegroundColor $CodeColor -BackgroundColor DarkCyan
                    $Trig = "Triggers: " + $Target.Triggers; if ($Trig.Length -gt 65) { $Trig = $Trig.Substring(0,65) + "..." }
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 6); Write-Host $Trig -ForegroundColor Gray -BackgroundColor DarkCyan
                    $Act = "Actions:  " + $Target.Actions; if ($Act.Length -gt 65) { $Act = $Act.Substring(0,65) + "..." }
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 8); Write-Host $Act -ForegroundColor Gray -BackgroundColor DarkCyan
                    [Console]::SetCursorPosition($StartX + 2, $StartY + 11); Write-Host "[ESC] Close" -ForegroundColor White -BackgroundColor DarkCyan
                    while ($true) { if ([Console]::KeyAvailable) { $SubKey = [Console]::ReadKey($true).Key; if ($SubKey -eq "Escape" -or $SubKey -eq "P") { $ShowTaskProps = $false; Clear-Host; break } }; Start-Sleep -Milliseconds 50 }
                }
            }
            # --- MAIN MENU ---
            if ($ShowMainMenu) {
                $MenuOpts = @("Live Monitor", "Services", "Scheduled Tasks", "Installed Apps", "User Sessions", "Speed Test", "Quit")
                $MenuIndex = 0
                $BoxWidth = 40; $BoxHeight = 10
                $StartX = [math]::Floor(($CurrentWidth - $BoxWidth) / 2)
                $StartY = [math]::Floor(($CurrentHeight - $BoxHeight) / 2)
                
                # Draw box chrome once
                for ($y = 0; $y -le $BoxHeight; $y++) { [Console]::SetCursorPosition($StartX, $StartY + $y); Write-Host (" " * $BoxWidth) -BackgroundColor DarkBlue -NoNewline }
                [Console]::SetCursorPosition($StartX + 2, $StartY + 1); Write-Host "MAIN MENU" -ForegroundColor Yellow -BackgroundColor DarkBlue
                $MenuDirty = $true
                
                while ($ShowMainMenu) {
                    # Only repaint menu items when selection changed
                    if ($MenuDirty) {
                        $MenuDirty = $false
                        for ($i = 0; $i -lt $MenuOpts.Count; $i++) {
                            [Console]::SetCursorPosition($StartX + 4, $StartY + 3 + $i)
                            $Prefix = "[$($i+1)]"
                            if ($i -eq 6) { $Prefix = "[Q]" }
                            
                            if ($i -eq $MenuIndex) { Write-Host " > $Prefix $($MenuOpts[$i]) " -ForegroundColor Black -BackgroundColor White -NoNewline } 
                            else { Write-Host "   $Prefix $($MenuOpts[$i]) " -ForegroundColor White -BackgroundColor DarkBlue -NoNewline }
                        }
                    }
                    if ([Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true).Key
                        if ($k -eq 'UpArrow' -and $MenuIndex -gt 0) { $MenuIndex--; $MenuDirty = $true }
                        if ($k -eq 'DownArrow' -and $MenuIndex -lt 6) { $MenuIndex++; $MenuDirty = $true }
                        if ($k -eq 'Escape') { $ShowMainMenu = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'Enter') {
                            $ShowMainMenu = $false
                            switch ($MenuIndex) {
                                0 { $UserMode = $false; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $SpeedTestMode = $false; $SelColIndex = 2; $IsDesc = $true } # Live defaults to CPU desc
                                1 { $ServiceMode = $true; $UserMode = $false; $TaskMode = $false; $AppMode = $false; $SpeedTestMode = $false; $SelColIndex = 1; $IsDesc = $false } # Services defaults to Name asc
                                2 { $TaskMode = $true; $ServiceMode = $false; $UserMode = $false; $AppMode = $false; $SpeedTestMode = $false; $SelColIndex = 1; $IsDesc = $false } # Tasks defaults to Task Name asc
                                3 { $AppMode = $true; $TaskMode = $false; $ServiceMode = $false; $UserMode = $false; $SpeedTestMode = $false; $SelColIndex = 0; $IsDesc = $false } # Installed Apps defaults to Name asc (A-Z)
                                4 { $UserMode = $true; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $SpeedTestMode = $false; $SelColIndex = 0; $IsDesc = $false } # Users defaults to Username asc
                                5 { $SpeedTestMode = $true; $UserMode = $false; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $SelColIndex = 0; $IsDesc = $false } # Speed Test
                                6 { return }
                            }
                            $SvcRowIndex = 0; $TaskRowIndex = 0; $UserRowIndex = 0; $AppRowIndex = 0; $PageIndex = 0; $NeedsRedraw = $true; Clear-Host
                        }
                        # Hotkeys 1-6 and Q
                        if ($k -eq 'D1') { $ShowMainMenu = $false; $UserMode=$false; $ServiceMode=$false; $TaskMode=$false; $AppMode=$false; $SpeedTestMode=$false; $SelColIndex = 2; $IsDesc = $true; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D2') { $ShowMainMenu = $false; $ServiceMode=$true; $UserMode=$false; $TaskMode=$false; $AppMode=$false; $SpeedTestMode=$false; $SelColIndex = 1; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D3') { $ShowMainMenu = $false; $TaskMode=$true; $ServiceMode=$false; $UserMode=$false; $AppMode=$false; $SpeedTestMode=$false; $SelColIndex = 1; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D4') { $ShowMainMenu = $false; $AppMode=$true; $TaskMode=$false; $ServiceMode=$false; $UserMode=$false; $SpeedTestMode=$false; $SelColIndex = 0; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D5') { $ShowMainMenu = $false; $UserMode=$true; $ServiceMode=$false; $TaskMode=$false; $AppMode=$false; $SpeedTestMode=$false; $SelColIndex = 0; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D6') { $ShowMainMenu = $false; $SpeedTestMode=$true; $UserMode=$false; $ServiceMode=$false; $TaskMode=$false; $AppMode=$false; $SelColIndex = 0; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'Q')  { return }
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
            #endregion

            #region RENDER: FOOTER
            $FooterY = $CurrentHeight - 3
            if ($FooterY -gt 0) { try { [Console]::SetCursorPosition(0, $FooterY) } catch {} }
            Write-Host ("─" * ($FrameWidth - 1)) -ForegroundColor DarkGray
            
            # --- GENERIC FOOTER DRAWING LOGIC ---
            if ($FooterText.Length -lt ($FrameWidth - 2)) {
                Write-Host $FooterText.PadRight($FrameWidth - 1) -ForegroundColor $FooterFg -BackgroundColor $FooterBg
                Write-Host ("═" * ($FrameWidth - 1)) -ForegroundColor DarkGray -NoNewline
            } else {
                $Cutoff = $FrameWidth - 2
                $SplitIdx = $FooterText.LastIndexOf("│", $Cutoff)
                if ($SplitIdx -gt 0) {
                    $Line1 = $FooterText.Substring(0, $SplitIdx).Trim()
                    $Line2 = $FooterText.Substring($SplitIdx).Trim()
                    Write-Host $Line1.PadRight($FrameWidth - 1) -ForegroundColor $FooterFg -BackgroundColor $FooterBg
                    try { [Console]::SetCursorPosition(0, $FooterY + 2) } catch {}
                    Write-Host $Line2.PadRight($FrameWidth - 1) -ForegroundColor $FooterFg -BackgroundColor $FooterBg -NoNewline
                } else {
                    Write-Host $FooterText.Substring(0, $Cutoff) -ForegroundColor $FooterFg -BackgroundColor $FooterBg
                }
            }
            #endregion
            
            Start-Sleep -Milliseconds 50
            #endregion
        }
    }
    #region CLEANUP
    finally {
        Write-Host "`nStopping..." -ForegroundColor DarkGray
        $SyncHash.Running = $false
        try { $PS.EndInvoke($AsyncHandle) } catch {}
        try { $PS.Dispose() } catch {}
        if ($SpeedTestPS) {
            try { $SpeedTestPS.Dispose() } catch {}
        }
        try { [Console]::CursorVisible = $true } catch {}
        Clear-Host
    }
    #endregion
}
