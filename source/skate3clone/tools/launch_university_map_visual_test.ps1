[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$CharacterBuilder = Join-Path $PSScriptRoot "build_default_skater_assets.ps1"
$PythonLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
$Python = Get-Command python.exe -ErrorAction SilentlyContinue
$Arguments = @(
    $Arguments | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }
)
$Headless = $Arguments -contains "--headless" -or $Arguments -contains "-Headless"
$Unknown = @(
    $Arguments | Where-Object {
        $_ -notin @("--headless", "-Headless")
    }
)
if ($Unknown.Count -ne 0) {
    throw "Unknown argument(s): $($Unknown -join ', '). Supported: --headless"
}

Push-Location -LiteralPath $Root
try {
    Write-Host "University source/cache verification" -ForegroundColor Cyan
    Write-Host "Worktree: $Root"
    Write-Host "This launcher performs offline conversion only and never starts SK8."

    if ($null -ne $PythonLauncher) {
        & $PythonLauncher.Source -3 (Join-Path $Root "tools\build_university_bevy_cache.py")
    }
    elseif ($null -ne $Python) {
        & $Python.Source (Join-Path $Root "tools\build_university_bevy_cache.py")
    }
    else {
        throw "Python 3 was not found. Install Python 3.11 or newer."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "University cache build/verification failed (exit $LASTEXITCODE)."
    }

    if (-not (Test-Path -LiteralPath $CharacterBuilder -PathType Leaf)) {
        throw "Default-skater asset builder is missing: $CharacterBuilder"
    }
    try {
        & $CharacterBuilder -VerifyOnly
    }
    catch {
        if ($_.Exception.Message -like "*needs reconstruction*") {
            Write-Host "Reconstructing the recovered default skater..." -ForegroundColor Cyan
            & $CharacterBuilder
        }
        else {
            throw
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Default-skater preparation failed (exit $LASTEXITCODE)."
    }

    $VisualAsset = if ([string]::IsNullOrWhiteSpace($env:SKATE3_PRIVATE_VISUAL_MODEL_PATH)) {
        "private/default_skate3_skater.glb"
    }
    else {
        $env:SKATE3_PRIVATE_VISUAL_MODEL_PATH
    }
    $VisualAssetFile = Join-Path (Join-Path $Root "assets") $VisualAsset
    if (-not (Test-Path -LiteralPath $VisualAssetFile -PathType Leaf)) {
        throw @"
The textured private skater visual is missing:
  $VisualAssetFile
Expected the recovered default Skate 3 skater GLB. Set
SKATE3_PRIVATE_VISUAL_MODEL_PATH to another asset-relative textured GLB.
"@
    }
    if ($null -ne $PythonLauncher) {
        & $PythonLauncher.Source -3 (Join-Path $Root "tools\verify_skater_visual_compatibility.py")
    }
    else {
        & $Python.Source (Join-Path $Root "tools\verify_skater_visual_compatibility.py")
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Private textured skater compatibility verification failed (exit $LASTEXITCODE)."
    }

    $env:SKATE3_LEVEL = "university"
    if ($Headless) {
        Write-Host "Running no-window University Bevy verification..." -ForegroundColor Cyan
        & cargo.exe run -- --verify-university
        if ($LASTEXITCODE -ne 0) {
            throw "University headless verification failed (exit $LASTEXITCODE)."
        }
        Write-Host "Headless verification complete; no game process remains." -ForegroundColor Green
    }
    else {
        Write-Host "Building and launching this exact worktree with University selected..." -ForegroundColor Cyan
        & cargo.exe run -- --level=university
        if ($LASTEXITCODE -ne 0) {
            throw "University visual test exited with code $LASTEXITCODE."
        }
    }
}
finally {
    Pop-Location
}
