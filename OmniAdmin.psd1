@{
    RootModule           = 'OmniAdmin.psm1'
    ModuleVersion        = '1.0.1'
    CompatiblePSEditions = 'Desktop', 'Core'
    GUID                 = '22991a0c-1234-4321-abcd-1234567890cd'
    Author               = 'Tony Petkoff'
    CompanyName          = 'OmniAdmin'
    Copyright            = '(c) 2026. All rights reserved.'
    Description          = 'A high-performance administration module containing monitoring, network speed testing, and browser forensics.'
    PowerShellVersion    = '5.1'
    FunctionsToExport    = @('Start-SystemMonitor', 'Measure-Speed', 'Get-BrowserHistory')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('Admin', 'Monitoring', 'Forensics', 'Network', 'Dashboard')
            ProjectUri   = 'https://github.com/gapetkoff/OmniAdmin'
            ReleaseNotes = 'Added GitHub repository metadata and project links.'
        }
    }
}
