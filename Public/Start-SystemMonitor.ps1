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
    # region Unicode Helper Functions for Console Alignment
    function Get-DisplayWidth {
        param([string]$s)
        if (-not $s) { return 0 }
        $width = 0
        foreach ($char in $s.ToCharArray()) {
            $val = [int]$char
            if (($val -ge 0x4e00 -and $val -le 0x9fff) -or
                ($val -ge 0x3000 -and $val -le 0x30ff) -or
                ($val -ge 0xac00 -and $val -le 0xd7af) -or
                ($val -ge 0xff01 -and $val -le 0xff60)) {
                $width += 2
            } else {
                $width += 1
            }
        }
        return $width
    }

    function Pad-String {
        param([string]$s, [int]$width, [string]$paddingChar = " ")
        $currentWidth = Get-DisplayWidth $s
        if ($currentWidth -ge $width) {
            $result = ""
            $w = 0
            foreach ($char in $s.ToCharArray()) {
                $val = [int]$char
                $charW = 1
                if (($val -ge 0x4e00 -and $val -le 0x9fff) -or
                    ($val -ge 0x3000 -and $val -le 0x30ff) -or
                    ($val -ge 0xac00 -and $val -le 0xd7af) -or
                    ($val -ge 0xff01 -and $val -le 0xff60)) {
                    $charW = 2
                }
                if ($w + $charW -le $width) {
                    $result += $char
                    $w += $charW
                } else {
                    break
                }
            }
            $result += ($paddingChar * ($width - $w))
            return $result
        } else {
            return $s + ($paddingChar * ($width - $currentWidth))
        }
    }
    # endregion

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
    $ShowServiceProps = $false 
    $ShowTaskProps    = $false
    $ShowMainMenu     = $false
    
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
                    $UserMode = $false; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $ShowMainMenu = $false; Clear-Host 
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
                             [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1)
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
                             [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1)
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
                             [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1)
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
                             [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1)
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
                             [Console]::SetCursorPosition(0, $Host.UI.RawUI.WindowSize.Height - 1)
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
            if ($ServiceMode) {
                #region MODE: SERVICE GRID
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
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
                Write-Host "".PadRight(10); Write-Host ""; Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

                $SortedSvcs = $FilteredSvc | Sort-Object $SvcProps[$SelColIndex] -Descending:$IsDesc
                $Start = $PageIndex * $CurrentPageSize
                $ListToShow = $SortedSvcs | Select-Object -Skip $Start -First $CurrentPageSize
                
                $RowsDrawn = 0
                if ($ListToShow) {
                    $CurrentListArray = @($ListToShow)
                    for ($i = 0; $i -lt $CurrentPageSize; $i++) {
                        if ($i -lt $CurrentListArray.Count) {
                            $s = $CurrentListArray[$i]
                            
                            $Name = if ($s.Name.Length -gt $NameW) { $s.Name.Substring(0, $NameW) } else { $s.Name }
                            $DName = if ($s.DisplayName.Length -gt $DispW) { $s.DisplayName.Substring(0, $DispW) } else { $s.DisplayName }
                            
                            $Line = "  {0,-10} {1,-$NameW} {2,-$DispW} {3,-10}" -f $s.Status, $Name, $DName, $s.StartType
                            $Fg = if ($s.Status -eq 'Running') { "Green" } elseif ($s.Status -eq 'Stopped') { "Red" } else { "Yellow" }
                            
                            if ($i -eq $SvcRowIndex -and -not $ShowServiceProps) {
                                Write-Host $Line.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor White
                            } else {
                                Write-Host $Line.PadRight($FrameWidth) -ForegroundColor $Fg
                            }
                        } else { Write-Host "".PadRight($FrameWidth) }
                        $RowsDrawn++
                    }
                }
                $Empty = $CurrentPageSize - $RowsDrawn
                if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
                #endregion
            }
            elseif ($TaskMode) {
                #region MODE: TASK GRID
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
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
                Write-Host "".PadRight(10); Write-Host ""; Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

                # CRITICAL FIX V62: Bind Local Variable to Shared Hash
                $Tasks = $SyncHash.TaskData
                if ($FilterText) { $Tasks = $Tasks | Where-Object { $_.TaskName -like "*$FilterText*" } }
                $SortedTasks = $Tasks | Sort-Object $TskProps[$SelColIndex] -Descending:$IsDesc
                
                $Start = $PageIndex * $CurrentPageSize
                $ListToShow = $SortedTasks | Select-Object -Skip $Start -First $CurrentPageSize
                
                $RowsDrawn = 0
                if ($ListToShow) {
                    $CurrentListArray = @($ListToShow)
                    for ($i = 0; $i -lt $CurrentPageSize; $i++) {
                        if ($i -lt $CurrentListArray.Count) {
                            $t = $CurrentListArray[$i]
                            $Name = if ($t.TaskName.Length -gt $NameW) { $t.TaskName.Substring(0, $NameW) } else { $t.TaskName }
                            $Last = if ($t.LastRunTime) { $t.LastRunTime.ToString("MM/dd HH:mm") } else { "Never" }
                            $Res  = $t.LastTaskResult
                            
                            $Line = "  {0,-10} {1,-$NameW} {2,-$TimeW} {3,-10}" -f $t.State, $Name, $Last, $Res
                            $Fg = if ($t.State -eq 'Running') { "Green" } elseif ($t.State -eq 'Ready') { "White" } else { "Gray" }
                            $ResColor = if ($Res -eq 0) { "Green" } else { "Red" }
                            
                            if ($i -eq $TaskRowIndex -and -not $ShowTaskProps) {
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
                $Empty = $CurrentPageSize - $RowsDrawn
                if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
                #endregion
            }
            elseif ($AppMode) {
                #region MODE: APP GRID
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
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
                Write-Host "".PadRight(10); Write-Host ""; Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

                # Get apps and sort
                $Apps = $SyncHash.AppData
                if ($FilterText) { $Apps = $Apps | Where-Object { $_.DisplayName -like "*$FilterText*" -or $_.Publisher -like "*$FilterText*" } }
                $SortedApps = $Apps | Sort-Object $AppProps[$SelColIndex] -Descending:$IsDesc
                
                $Start = $PageIndex * $CurrentPageSize
                $ListToShow = $SortedApps | Select-Object -Skip $Start -First $CurrentPageSize
                
                $RowsDrawn = 0
                if ($ListToShow) {
                    $CurrentListArray = @($ListToShow)
                    for ($i = 0; $i -lt $CurrentPageSize; $i++) {
                        if ($i -lt $CurrentListArray.Count) {
                            $app = $CurrentListArray[$i]
                            
                            $Name = Pad-String $app.DisplayName $NameW
                            $Ver  = Pad-String $app.DisplayVersion 15
                            $Pub  = Pad-String $app.Publisher $PubW
                            $Type = Pad-String $app.AppType 10
                            $Date = Pad-String $app.InstallDate 12
                            
                            $Line = "  $Name $Ver $Pub $Type $Date"
                            $PaddedLine = Pad-String $Line $FrameWidth
                            
                            if ($i -eq $AppRowIndex) {
                                Write-Host $PaddedLine -ForegroundColor Black -BackgroundColor White
                            } else {
                                Write-Host $PaddedLine -ForegroundColor White
                            }
                        } else { Write-Host "".PadRight($FrameWidth) }
                        $RowsDrawn++
                    }
                }
                $Empty = $CurrentPageSize - $RowsDrawn
                if ($Empty -gt 0) { for($x=0;$x -lt $Empty;$x++) { Write-Host "".PadRight($FrameWidth) } }
                #endregion
            }
            elseif ($UserMode) {
                #region MODE: USER GRID
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
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
                Write-Host "".PadRight(10); Write-Host ""; Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray

                # CRITICAL FIX V62: Bind Local Variable to Shared Hash
                $Users = $SyncHash.UserData
                if ($FilterText) { $Users = $Users | Where-Object { $_.UserName -like "*$FilterText*" -or $_.SessionName -like "*$FilterText*" } }
                
                $SortedUsers = $Users
                try { $SortedUsers = $Users | Sort-Object $UProps[$SelColIndex] -Descending:$IsDesc } catch {}
                
                $Start = $PageIndex * $CurrentPageSize
                $ListToShow = $SortedUsers | Select-Object -Skip $Start -First $CurrentPageSize

                $UserRowsDrawn = 0
                if ($ListToShow) {
                    $CurrentListArray = @($ListToShow)
                    for ($i = 0; $i -lt $CurrentPageSize; $i++) {
                        if ($i -lt $CurrentListArray.Count) {
                            $u = $CurrentListArray[$i]
                            $Line = "  {0,-20} {1,-15} {2,-10} {3,-12} {4,-15} {5,-20}" -f $u.UserName, $u.SessionName, $u.SessionId, $u.State, $u.IdleTime, $u.LogonTime
                            if ($Line.Length -gt $FrameWidth) { $Line = $Line.Substring(0, $FrameWidth) }
                            if ($i -eq $UserRowIndex) { Write-Host $Line.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor White } 
                            else { Write-Host $Line.PadRight($FrameWidth) }
                        } else { Write-Host "".PadRight($FrameWidth) }
                        $UserRowsDrawn++
                    }
                }
                $EmptyRows = $CurrentPageSize - $UserRowsDrawn
                if ($EmptyRows -gt 0) { for ($x=0; $x -lt $EmptyRows; $x++) { Write-Host ("".PadRight($FrameWidth)) } }
                #endregion
            } else {
                #region MODE: LIVE PROCESS GRID
                $CurrentPageSize = Get-DynamicPageSize -HeaderHeight $HEADER_HEIGHT -UseFixedPageSize $UseFixedPageSize -PageSize $PageSize -Padding 1
                $FixedOverhead = 58
                $NameW = [math]::Max(10, $FrameWidth - $FixedOverhead)
                $ColWidths = @(8, $NameW, 10, 10, 10, 10)

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
                Write-Host "".PadRight(1); Write-Host ""; Write-Host ("─" * $FrameWidth) -ForegroundColor DarkGray
                
                $ListToShow = @()
                if ($Paused) {
                    $FilteredList = $FrozenList
                    if ($FilterText) { $FilteredList = $FrozenList | Where-Object { $_.Name -like "*$FilterText*" } }
                    $SortedList = $FilteredList | Sort-Object $RealProps[$SelColIndex] -Descending:$IsDesc
                    $Start = $PageIndex * $CurrentPageSize
                    $ListToShow = $SortedList | Select-Object -Skip $Start -First $CurrentPageSize
                } else {
                    $SortedList = $SyncHash.RawProcessList | Sort-Object $RealProps[$SelColIndex] -Descending:$IsDesc
                    $ListToShow = $SortedList | Select-Object -First $CurrentPageSize
                }
                
                $RowsDrawn = 0
                if ($ListToShow) {
                    $CurrentListArray = @($ListToShow) 
                    for ($i = 0; $i -lt $CurrentPageSize; $i++) {
                        if ($i -lt $CurrentListArray.Count) {
                            $p = $CurrentListArray[$i]
                            
                            # CLEANUP: Strip trailing WMI Instance tags (e.g. msedge#12 -> msedge)
                            $NameVal = if ($p.Name) { $p.Name -replace '#\d+$','' } else { "Unknown" }
                            if ($NameVal.Length -gt $NameW) { $NameVal = $NameVal.SubString(0, $NameW) }
                            
                            $Cores = if ($Static.Cores) { $Static.Cores } else { 1 }
                            $RawCpu = if ($p.PercentProcessorTime) { $p.PercentProcessorTime } else { 0 }
                            $CpuVal = [math]::Round($RawCpu / $Cores, 1)
                            
                            # V71 BUG FIX: WMI 'PercentProcessorTime' formatted counters are notorious 
                            # for spiking to massive > 500% numbers due to timer overlap and wrap around. 
                            # We strictly cap it at 100% to protect the column format alignment and stop scares.
                            if ($CpuVal -gt 100) { $CpuVal = 100.0 }
                            if ($CpuVal -lt 0) { $CpuVal = 0.0 }
                            
                            $MemVal = [math]::Round($p.WorkingSet / 1MB, 0)
                            $Icon = if ($CpuVal -gt 50) { "🔥" } elseif ($CpuVal -gt 25) { "⚡" } else { " " }
                            
                            $Line = "{0} {1,-8} {2,-$NameW} {3,10:0.0} {4,10} {5,10} {6,10}" -f $Icon, $p.IDProcess, $NameVal, $CpuVal, $MemVal, $p.ThreadCount, $p.HandleCount

                            if ($Paused -and $i -eq $RowIndex) { Write-Host $Line.PadRight($FrameWidth) -ForegroundColor Black -BackgroundColor Green } 
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
                $EmptyRows = $CurrentPageSize - $RowsDrawn
                if ($EmptyRows -gt 0) { for($x=0; $x -lt $EmptyRows; $x++) { Write-Host ("".PadRight($FrameWidth)) } }
                #endregion
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
                $MenuOpts = @("Live Monitor", "Services", "Scheduled Tasks", "Installed Apps", "User Sessions", "Quit")
                $MenuIndex = 0
                $BoxWidth = 40; $BoxHeight = 9
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
                            if ($i -eq 5) { $Prefix = "[Q]" }
                            
                            if ($i -eq $MenuIndex) { Write-Host " > $Prefix $($MenuOpts[$i]) " -ForegroundColor Black -BackgroundColor White -NoNewline } 
                            else { Write-Host "   $Prefix $($MenuOpts[$i]) " -ForegroundColor White -BackgroundColor DarkBlue -NoNewline }
                        }
                    }
                    if ([Console]::KeyAvailable) {
                        $k = [Console]::ReadKey($true).Key
                        if ($k -eq 'UpArrow' -and $MenuIndex -gt 0) { $MenuIndex--; $MenuDirty = $true }
                        if ($k -eq 'DownArrow' -and $MenuIndex -lt 5) { $MenuIndex++; $MenuDirty = $true }
                        if ($k -eq 'Escape') { $ShowMainMenu = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'Enter') {
                            $ShowMainMenu = $false
                            switch ($MenuIndex) {
                                0 { $UserMode = $false; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $SelColIndex = 2; $IsDesc = $true } # Live defaults to CPU desc
                                1 { $ServiceMode = $true; $UserMode = $false; $TaskMode = $false; $AppMode = $false; $SelColIndex = 1; $IsDesc = $false } # Services defaults to Name asc
                                2 { $TaskMode = $true; $ServiceMode = $false; $UserMode = $false; $AppMode = $false; $SelColIndex = 1; $IsDesc = $false } # Tasks defaults to Task Name asc
                                3 { $AppMode = $true; $TaskMode = $false; $ServiceMode = $false; $UserMode = $false; $SelColIndex = 0; $IsDesc = $false } # Installed Apps defaults to Name asc (A-Z)
                                4 { $UserMode = $true; $ServiceMode = $false; $TaskMode = $false; $AppMode = $false; $SelColIndex = 0; $IsDesc = $false } # Users defaults to Username asc
                                5 { return }
                            }
                            $SvcRowIndex = 0; $TaskRowIndex = 0; $UserRowIndex = 0; $AppRowIndex = 0; $PageIndex = 0; $NeedsRedraw = $true; Clear-Host
                        }
                        # Hotkeys 1-5 and Q
                        if ($k -eq 'D1') { $ShowMainMenu = $false; $UserMode=$false; $ServiceMode=$false; $TaskMode=$false; $AppMode=$false; $SelColIndex = 2; $IsDesc = $true; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D2') { $ShowMainMenu = $false; $ServiceMode=$true; $UserMode=$false; $TaskMode=$false; $AppMode=$false; $SelColIndex = 1; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D3') { $ShowMainMenu = $false; $TaskMode=$true; $ServiceMode=$false; $UserMode=$false; $AppMode=$false; $SelColIndex = 1; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D4') { $ShowMainMenu = $false; $AppMode=$true; $TaskMode=$false; $ServiceMode=$false; $UserMode=$false; $SelColIndex = 0; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
                        if ($k -eq 'D5') { $ShowMainMenu = $false; $UserMode=$true; $ServiceMode=$false; $TaskMode=$false; $AppMode=$false; $SelColIndex = 0; $IsDesc = $false; $NeedsRedraw = $true; Clear-Host }
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
                    [Console]::SetCursorPosition(0, $FooterY + 2)
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
        try { [Console]::CursorVisible = $true } catch {}
    }
    #endregion
}
