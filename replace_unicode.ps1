$path = 'c:\Users\tpetkoff\Projects\OmniAdmin\Private\TuiEngine.cs'
$content = Get-Content $path -Raw -Encoding UTF8
$replacements = @{
    '─' = '\u2500'; '│' = '\u2502'; '┌' = '\u250C'; '┐' = '\u2510';
    '└' = '\u2514'; '┘' = '\u2518'; '├' = '\u251C'; '┤' = '\u2524';
    '┬' = '\u252C'; '┴' = '\u2534'; '┼' = '\u253C'; '═' = '\u2550';
    '║' = '\u2551'; '█' = '\u2588'; '░' = '\u2591'; '▒' = '\u2592';
    '▓' = '\u2593'; '◄' = '\u25C4'; '►' = '\u25BA'; '▶' = '\u25B6';
    '⏸' = '\u23F8'; '≡' = '\u2261'; '⚠' = '\u26A0'
}
foreach ($key in $replacements.Keys) {
    $content = $content.Replace($key, $replacements[$key])
}
[System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8)
Copy-Item $path -Destination "C:\Users\tpetkoff\OneDrive - Alliance Healthcare Services\Documents\WindowsPowerShell\Modules\OmniAdmin\Private\TuiEngine.cs" -Force
Write-Host "Replaced unicode chars"
