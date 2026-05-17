param(
    [Parameter(Mandatory=$true)][string]$InPath,
    [Parameter(Mandatory=$true)][string]$OutPath
)

# Wrap a PNG into a single-image .ico file (Vista+ supports embedded PNG
# inside ICO entries, no BMP re-encoding required). Used as a pre-build
# step so the build is self-contained from a single PNG source.
#
# Layout:
#   ICONDIR    (6 bytes)
#   ICONDIRENTRY (16 bytes) — points to the PNG data after the header
#   PNG bytes  (verbatim)

if (-not (Test-Path -LiteralPath $InPath)) {
    throw "Input PNG not found: $InPath"
}

$pngBytes = [System.IO.File]::ReadAllBytes($InPath)

# Read width/height from the PNG IHDR chunk. PNG file structure:
#   8-byte signature, then chunks; first chunk is IHDR.
#   IHDR data starts at byte 16 (signature 8 + chunk length 4 + chunk type 4).
#   Width is a big-endian uint32 at offset 16..19, height at 20..23.
if ($pngBytes.Length -lt 24 -or $pngBytes[0] -ne 0x89 -or $pngBytes[1] -ne 0x50) {
    throw "Input does not look like a PNG: $InPath"
}
$width  = ($pngBytes[16] -shl 24) -bor ($pngBytes[17] -shl 16) -bor ($pngBytes[18] -shl 8) -bor $pngBytes[19]
$height = ($pngBytes[20] -shl 24) -bor ($pngBytes[21] -shl 16) -bor ($pngBytes[22] -shl 8) -bor $pngBytes[23]

# ICONDIRENTRY width/height bytes use 0 to mean 256 (the field is 1 byte).
$wByte = if ($width  -ge 256) { 0 } else { [byte]$width }
$hByte = if ($height -ge 256) { 0 } else { [byte]$height }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
try {
    # ICONDIR: reserved=0, type=1 (icon), count=1
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]1)
    # ICONDIRENTRY
    $bw.Write([byte]$wByte)
    $bw.Write([byte]$hByte)
    $bw.Write([byte]0)          # palette colour count (0 = no palette)
    $bw.Write([byte]0)          # reserved
    $bw.Write([uint16]1)        # colour planes
    $bw.Write([uint16]32)       # bits per pixel
    $bw.Write([uint32]$pngBytes.Length)   # PNG byte count
    $bw.Write([uint32]22)       # offset to PNG bytes (ICONDIR 6 + ICONDIRENTRY 16)
    $bw.Write($pngBytes)
    [System.IO.File]::WriteAllBytes($OutPath, $ms.ToArray())
}
finally {
    $bw.Dispose()
    $ms.Dispose()
}

Write-Host "png-to-ico: wrote $OutPath ($($pngBytes.Length) PNG bytes, ${width}x${height})"
