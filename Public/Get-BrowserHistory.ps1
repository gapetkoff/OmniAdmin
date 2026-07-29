<#
.SYNOPSIS
    Extracts Chrome and Edge browsing history via SQLite.

.DESCRIPTION
    A forensic tool to parse Chrome and Edge History files, both locally and remotely.
    This version uses an embedded Base64 sqlite3.exe to avoid external dependencies, enabling highly portable operation.
    
    Features:
    - Target local or remote machines.
    - Support for custom credentials.
    - Automatically discovers user profiles.
    - Time-filtered extraction (-Hours).

.PARAMETER ComputerName
    The target computer to pull history from. Defaults to localhost.

.PARAMETER Credential
    Optional credentials for remote connections.

.PARAMETER TargetUsers
    Specific user profiles to target (e.g. "tpetkoff"). If omitted, it will prompt for selection or use -AllUsers.

.PARAMETER AllUsers
    Switch to bypass the GUI prompt and extract from all discovered user profiles.

.PARAMETER Hours
    The number of hours of history to extract. Defaults to 24.

.EXAMPLE
    Get-BrowserHistory -Hours 48 -AllUsers
    Extracts the last 48 hours of history from all users on the local machine.

.EXAMPLE
    Get-BrowserHistory -ComputerName "Server01" -Credential (Get-Credential)
    Connects to Server01, prompts for a user profile, and extracts 24 hours of history.
#>
function Get-BrowserHistory {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline=$true)]
        [string]$ComputerName = "localhost",
        
        [PSCredential]$Credential,
        
        [string[]]$TargetUsers,
        
        [switch]$AllUsers,
        
        [int]$Hours = 24
    )

    begin {
        $isWindowsOS = $true
        if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
            $isWindowsOS = $false
        }
        if (-not $isWindowsOS) {
            Write-Error "Get-BrowserHistory requires Windows."
            return
        }

        # --- PORTABILITY LOGIC: Base64 Embedded sqlite3.exe ---
        $B64Path = if ($global:OAD_SqliteB64Path) { $global:OAD_SqliteB64Path } else { Join-Path -Path $PSScriptRoot -ChildPath "..\Private\sqlite3.exe.b64" }
        $Base64Sqlite = (Get-Content -Path $B64Path -Raw).Trim()
        $SqliteTool = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "sqlite3_omniadmin.exe"

        try {
            if (-not (Test-Path $SqliteTool)) {
                if ($Base64Sqlite -ne "PASTE_BASE64_HERE") {
                    $bytes = [Convert]::FromBase64String($Base64Sqlite)
                    [IO.File]::WriteAllBytes($SqliteTool, $bytes)
                } else {
                    # Fallback mechanism if placeholder is unreplaced
                    Write-Warning "Placeholder Base64 used. Relying on system sqlite3.exe if available..."
                    $SqliteTool = "sqlite3.exe"
                }
            }
        } catch {
            Write-Error "Failed to unpack sqlite3.exe: $($_.Exception.Message)"
            return
        }

        # --- SETUP ---
        $LocalTempBase = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "History_Analysis"
        New-Item -Path $LocalTempBase -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        
        # Calculate Unix cutoff time based on hours
        $CutoffTime = ([DateTime]::UtcNow.AddHours(-$Hours).ToFileTime()) / 10
    }

    process {
        $UseTempDrive = $false
        $BaseRoot = "\\$ComputerName\C$"

        try {
            # Connection Logic
            if ($Credential) {
                Write-Verbose "Using provided credentials..."
                $TempDriveName = "ForensicTemp_$(Get-Random)"
                New-PSDrive -Name $TempDriveName -PSProvider FileSystem -Root "\\$ComputerName\C$" -Credential $Credential -ErrorAction Stop | Out-Null
                $BaseRoot = "$($TempDriveName):"
                $UseTempDrive = $true
            }

            # User Discovery
            if ($null -eq $TargetUsers -or $TargetUsers.Count -eq 0) {
                $UsersPath = "$BaseRoot\Users"
                if (Test-Path $UsersPath) {
                    $FoundUsers = Get-ChildItem -Path $UsersPath -Directory -ErrorAction Stop | 
                                  Where-Object { $_.Name -notin @("Public", "Default", "All Users", "Default User", "Administrator") } |
                                  Select-Object -ExpandProperty Name
                    
                    if ($AllUsers) { $TargetUsers = $FoundUsers } 
                    else { 
                        $headerWidth = 42
                        Write-Host ""
                        Write-Host ("═" * $headerWidth) -ForegroundColor Cyan
                        Write-Host " 🔍 BROWSER HISTORY: $ComputerName"  -ForegroundColor Cyan
                        Write-Host "    Hours: $Hours │ Users: $($FoundUsers.Count) found" -ForegroundColor DarkGray
                        Write-Host ("═" * $headerWidth) -ForegroundColor Cyan
                        Write-Host ""
                        Write-Host " Available Users:" -ForegroundColor Cyan
                        for ($i = 0; $i -lt $FoundUsers.Count; $i++) {
                            Write-Host "   [$i] $($FoundUsers[$i])" -ForegroundColor White
                        }
                        
                        Write-Host ""
                        $selection = Read-Host "Enter user numbers to target (comma-separated, or leave blank for ALL)"
                        
                        if ([string]::IsNullOrWhiteSpace($selection)) {
                            $TargetUsers = $FoundUsers
                        } else {
                            $TargetUsers = @()
                            $indexes = $selection -split ',' | ForEach-Object { $_.Trim() }
                            foreach ($idx in $indexes) {
                                if ([int]::TryParse($idx, [ref]$null) -and $idx -ge 0 -and $idx -lt $FoundUsers.Count) {
                                    $TargetUsers += $FoundUsers[[int]$idx]
                                } else {
                                    Write-Warning "Invalid selection: $idx"
                                }
                            }
                            
                            if ($TargetUsers.Count -eq 0) {
                                Write-Warning "No valid users selected. Defaulting to All Users."
                                $TargetUsers = $FoundUsers
                            }
                        }
                    }
                }
            }

            if (-not $TargetUsers) { return }

            $allHistory = @()

            # Extraction Loop
            foreach ($User in $TargetUsers) {
                $Paths = @{
                    "Chrome" = "$BaseRoot\Users\$User\AppData\Local\Google\Chrome\User Data\Default\History"
                    "Edge"   = "$BaseRoot\Users\$User\AppData\Local\Microsoft\Edge\User Data\Default\History"
                }

                foreach ($Browser in $Paths.Keys) {
                    $SourcePath = $Paths[$Browser]
                    $DestFile   = Join-Path -Path $LocalTempBase -ChildPath "${Browser}_${User}_$(Get-Random).db"

                    if (Test-Path $SourcePath -ErrorAction SilentlyContinue) {
                        try {
                            Copy-Item -Path $SourcePath -Destination $DestFile -Force -ErrorAction Stop
                            
                            $Query = "SELECT datetime(visit_time/1000000-11644473600, 'unixepoch', 'localtime') as Time, urls.title as Title, urls.url as URL FROM visits JOIN urls ON visits.url = urls.id WHERE visits.visit_time > $CutoffTime ORDER BY visits.visit_time DESC;"
                            
                            # Execute embedded sqlite3.exe to export CSV
                            $Output = & $SqliteTool -header -csv $DestFile $Query

                            if ($Output) {
                                $Output | ConvertFrom-Csv | ForEach-Object {
                                    $allHistory += [PSCustomObject]@{
                                        Computer = $ComputerName
                                        User     = $User
                                        Browser  = $Browser
                                        Time     = [DateTime]$_.Time
                                        Title    = $_.Title
                                        URL      = $_.URL
                                    }
                                }
                            }
                        }
                        catch { Write-Error "Failed extracting $Browser history for $User : $($_.Exception.Message)" }
                        finally { Remove-Item -Path $DestFile -Force -ErrorAction SilentlyContinue }
                    }
                }
            }
            return $allHistory
        }
        finally {
            if ($UseTempDrive) { Remove-PSDrive -Name $TempDriveName -ErrorAction SilentlyContinue }
        }
    }
}
