# OmniAdmin

`OmniAdmin` is a PowerShell module designed for systems administration, network diagnostics, and browser forensics.

## Installation

Install the module directly from the [PowerShell Gallery](https://www.powershellgallery.com/packages/OmniAdmin):

```powershell
Install-Module -Name OmniAdmin -Scope CurrentUser
```

To update to the latest version:

```powershell
Update-Module -Name OmniAdmin
```

## Features & Cmdlets

* **`Start-SystemMonitor`** – Launches real-time performance and resource monitoring.
* **`Measure-Speed`** – Tests local network bandwidth and speed metrics.
* **`Get-BrowserHistory`** – Extracts and parses historical browsing data for forensic analysis.

## Quick Usage Examples

### Measure Network Speed
```powershell
Measure-Speed
```

### Fetch Browser History
```powershell
Get-BrowserHistory -Browser Chrome
```

## Contributing & Feedback

Feel free to open an issue or submit a Pull Request for bug fixes or new features!
https://github.com/gapetkoff/OmniAdmin

