param(
    [Parameter(Mandatory=$true)][string]$SdkBin,
    [Parameter(Mandatory=$true)][string]$DeveloperKey,
    [string]$Device = "fenix8solar51mm",
    [switch]$Export,
    [switch]$Test
)
$ErrorActionPreference = "Stop"
if ($Export -and $Test) { throw "Choose either -Export or -Test." }
$projectRoot = Split-Path -Parent $PSScriptRoot
$SdkBin = (Resolve-Path -LiteralPath $SdkBin).Path
$DeveloperKey = (Resolve-Path -LiteralPath $DeveloperKey).Path
$compiler = Join-Path $SdkBin "monkeyc.bat"
if (-not (Test-Path -LiteralPath $compiler)) { throw "monkeyc.bat missing from SDK bin directory." }
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Force -Path "bin" | Out-Null
    $compilerArgs = @("-f", "monkey.jungle", "-y", $DeveloperKey)
    if ($Export) {
        $compilerArgs += @("-e", "-r", "-o", "bin/SolarTruth.iq")
    } elseif ($Test) {
        $compilerArgs += @("-d", $Device, "-t", "-o", "bin/SolarTruth-tests.prg")
    } else {
        $compilerArgs += @("-d", $Device, "-r", "-o", "bin/SolarTruth.prg")
    }
    & $compiler @compilerArgs
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $LASTEXITCODE" }
    if ($Test) {
        & (Join-Path $SdkBin "monkeydo.bat") "bin/SolarTruth-tests.prg" $Device "/t"
        if ($LASTEXITCODE -ne 0) { throw "Simulator tests failed: $LASTEXITCODE" }
    }
} finally {
    Pop-Location
}
