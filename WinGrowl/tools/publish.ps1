param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$OutputDir = ""
)

# Build a self-contained, single-file Windows publish of WinGrowl.
#
# - Self-contained: bundles the .NET 8 runtime, no user-side install required.
# - Single-file: all DLLs packed into one WinGrowl.exe (native deps still
#   extracted at runtime via IncludeNativeLibrariesForSelfExtract).
# - PublishReadyToRun: AOT pre-jits to trim cold-start time.
#
# Output: <repo>\publish\<runtime>\ by default.

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$proj = Join-Path $repo "src\WinGrowl.App\WinGrowl.App.csproj"
if (-not $OutputDir) {
    $OutputDir = Join-Path $repo "publish\$Runtime"
}

# Wipe previous output so leftover files from a prior run don't ship.
if (Test-Path $OutputDir) {
    Remove-Item -Recurse -Force $OutputDir
}
New-Item -ItemType Directory -Path $OutputDir | Out-Null

Write-Host "Publishing WinGrowl ($Configuration, $Runtime) to $OutputDir"

& dotnet publish $proj `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:PublishReadyToRun=true `
    -p:DebugType=embedded `
    -o $OutputDir

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Publish complete. Output:"
Get-ChildItem $OutputDir | ForEach-Object {
    $size = if ($_.PSIsContainer) { "<DIR>" } else { "{0,12:N0} bytes" -f $_.Length }
    Write-Host ("  {0,-50} {1}" -f $_.Name, $size)
}
