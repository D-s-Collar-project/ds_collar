param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64"
)

# End-to-end installer build: publishes WinGrowl as a self-contained
# single-file Windows app, then wraps the publish directory in an Inno
# Setup installer .exe.
#
# Output:
#   publish\<runtime>\WinGrowl.exe         (portable single-file)
#   installer\Output\WinGrowl-<ver>-Setup.exe   (installer)
#
# Inno Setup is the only external dependency. Install from
# https://jrsoftware.org/isdl.php (the "QuickStart Pack" is fine).

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

# Step 1: dotnet publish.
& (Join-Path $PSScriptRoot "publish.ps1") -Configuration $Configuration -Runtime $Runtime
if ($LASTEXITCODE -ne 0) {
    throw "Publish step failed."
}

# Step 2: find Inno Setup's compiler. Standard install path first;
# fall back to PATH lookup.
$iscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) {
    $iscc = "C:\Program Files\Inno Setup 6\ISCC.exe"
}
if (-not (Test-Path $iscc)) {
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $iscc = $cmd.Source }
}
if (-not (Test-Path $iscc)) {
    Write-Host ""
    Write-Host "ERROR: Inno Setup compiler (ISCC.exe) not found." -ForegroundColor Red
    Write-Host "Install from https://jrsoftware.org/isdl.php and re-run."
    Write-Host "The publish output is still available at publish\$Runtime\WinGrowl.exe"
    exit 1
}

$iss = Join-Path $repo "installer\WinGrowl.iss"
Write-Host ""
Write-Host "Compiling installer via $iscc"
& $iscc $iss
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compilation failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Installer built. Look in installer\Output\ for the .exe."
Get-ChildItem (Join-Path $repo "installer\Output") -ErrorAction SilentlyContinue | ForEach-Object {
    $size = "{0,12:N0} bytes" -f $_.Length
    Write-Host ("  {0,-50} {1}" -f $_.Name, $size)
}
