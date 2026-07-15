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
