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
