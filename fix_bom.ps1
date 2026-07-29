$utf8BOM = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -Path 'C:\Users\tpetkoff\OneDrive - Alliance Healthcare Services\Documents\WindowsPowerShell\Modules\OmniAdmin' -Recurse -Include *.ps1,*.psm1,*.psd1,*.cs | ForEach-Object {
    $content = [System.IO.File]::ReadAllText($_.FullName)
    [System.IO.File]::WriteAllText($_.FullName, $content, $utf8BOM)
}
Write-Host 'Encoding fixed recursively in Modules folder'
