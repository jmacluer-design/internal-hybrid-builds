[CmdletBinding()]
param(
    [string]$OwnedDataRoot = $env:SKATE3_OWNED_DATA_ROOT,
    [string]$Blender = $env:BLENDER_EXECUTABLE,
    [switch]$ForceRebuild
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OwnedDataRoot)) {
    $OwnedDataRoot = Join-Path $ProjectRoot 'work\private-assets\owned-game'
}
if ([string]::IsNullOrWhiteSpace($Blender)) {
    $BlenderCandidates = @(
        'C:\Program Files\Blender Foundation\Blender 5.1\blender.exe',
        'C:\Program Files\Blender Foundation\Blender 5.0\blender.exe',
        'C:\Program Files\Blender Foundation\Blender 4.5\blender.exe'
    )
    $Blender = $BlenderCandidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

$VendorRoot = Join-Path $ProjectRoot 'tools\vendor\university'
$MapRoot = Join-Path $VendorRoot 'tools\vanilla_map_extraction'
$MapTools = Join-Path $MapRoot 'tools'
$MapBlender = Join-Path $MapRoot 'blender'
$ExporterRoot = Join-Path $VendorRoot 'tools\blender_owned_map'
$UttRoot = Join-Path $ProjectRoot 'tools\vendor\utt'
$BuildRoot = Join-Path $ProjectRoot 'work\private-assets\university-build'
$Intermediate = Join-Path $BuildRoot 'intermediate'
$Manifest = Join-Path $Intermediate 'manifest.json'
$BaseBlend = Join-Path $BuildRoot 'DIST_University_FullFidelity.blend'
$OwnedBlend = Join-Path $BuildRoot 'DIST_University_FullFidelity_Owned.blend'
$Package = Join-Path $BuildRoot 'University.full-fidelity.v15.skate'
$CollisionArchive = Join-Path $BuildRoot 'University.retail-collision.rwcmset'
$IdentityPackage = "$Package.with-rcid"
$EmbeddedPackage = "$Package.with-rwcm"
$StreamDirectory = Join-Path $OwnedDataRoot `
    'university-archive\data\content\world\stream\DIST_University'
$ExpectedPackageHash = '2328EDE92A1546B4BD08ADC4425CDB95769FF9BCD519DF1909643A26E1C8633A'
$ExpectedPackageBytes = 243409206
$BasePackageHash = 'D585F273CDC756878E1264921F969566BF7C47DEC0E45F656016AC505A4E3B7E'
$BasePackageBytes = 226065703

foreach ($required in @(
    $Blender,
    (Join-Path $MapTools 'prepare_university.py'),
    (Join-Path $MapBlender 'import_university.py'),
    (Join-Path $MapBlender 'prepare_university_owned.py'),
    (Join-Path $MapBlender 'validate_university_blend.py'),
    (Join-Path $ExporterRoot 'export_skate.py'),
    (Join-Path $UttRoot 'rx2_parser.py'),
    $StreamDirectory
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required University source or tool is missing: $required"
    }
}

function Test-Package {
    if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Package
    if ($item.Length -ne $ExpectedPackageBytes) {
        return $false
    }
    return (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash -eq
        $ExpectedPackageHash
}

function Test-BasePackage {
    if (-not (Test-Path -LiteralPath $Package -PathType Leaf)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Package
    if ($item.Length -ne $BasePackageBytes) {
        return $false
    }
    return (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash -eq
        $BasePackageHash
}

New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
if ($ForceRebuild -or -not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
    Write-Host 'Decoding the owned University streams and retail lightmaps...' `
        -ForegroundColor Cyan
    & python (Join-Path $MapTools 'prepare_university.py') `
        '--stream-dir' $StreamDirectory `
        '--output' $Intermediate `
        '--utt-root' $UttRoot
    if ($LASTEXITCODE -ne 0) {
        throw "University stream preparation failed with exit code $LASTEXITCODE."
    }
}

if ($ForceRebuild -or -not (Test-Path -LiteralPath $BaseBlend -PathType Leaf)) {
    Write-Host 'Building the full-fidelity University Blender scene...' `
        -ForegroundColor Cyan
    & $Blender '--background' '--factory-startup' '--python-exit-code' '1' `
        '--python' (Join-Path $MapBlender 'import_university.py') '--' `
        $Manifest $BaseBlend
    if ($LASTEXITCODE -ne 0) {
        throw "University Blender import failed with exit code $LASTEXITCODE."
    }
}

if ($ForceRebuild -or -not (Test-Path -LiteralPath $OwnedBlend -PathType Leaf)) {
    & $Blender '--background' '--python-exit-code' '1' $BaseBlend `
        '--python' (Join-Path $MapBlender 'prepare_university_owned.py') '--' `
        $OwnedBlend
    if ($LASTEXITCODE -ne 0) {
        throw "University ownership preparation failed with exit code $LASTEXITCODE."
    }
}

& $Blender '--background' '--python-exit-code' '1' $OwnedBlend `
    '--python' (Join-Path $MapBlender 'validate_university_blend.py')
if ($LASTEXITCODE -ne 0) {
    throw "University scene validation failed with exit code $LASTEXITCODE."
}

if ($ForceRebuild -or (-not (Test-Package) -and -not (Test-BasePackage))) {
    & $Blender '--background' '--python-exit-code' '1' $OwnedBlend `
        '--python' (Join-Path $ExporterRoot 'export_skate.py') '--' `
        $Package '--force'
    if ($LASTEXITCODE -ne 0) {
        throw "University package export failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Package)) {
    & python (Join-Path $MapTools 'build_university_collision_probe.py') `
        $Manifest $CollisionArchive
    if ($LASTEXITCODE -ne 0) {
        throw "Exact retail collision archive failed with exit code $LASTEXITCODE."
    }
    & python (Join-Path $MapTools 'attach_retail_collision_identity.py') `
        $Package $CollisionArchive $IdentityPackage '--dynamic-lighting-off'
    if ($LASTEXITCODE -ne 0) {
        throw "Retail collision identity failed with exit code $LASTEXITCODE."
    }
    Move-Item -LiteralPath $IdentityPackage -Destination $Package -Force
    & python (Join-Path $MapTools 'embed_retail_collision_archive.py') `
        $Package $CollisionArchive $EmbeddedPackage
    if ($LASTEXITCODE -ne 0) {
        throw "Retail collision embedding failed with exit code $LASTEXITCODE."
    }
    Move-Item -LiteralPath $EmbeddedPackage -Destination $Package -Force
}
if (-not (Test-Package)) {
    $actualBytes = (Get-Item -LiteralPath $Package).Length
    $actualHash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash
    throw (
        'University package did not match the preserved baseline. ' +
        "bytes=$actualBytes sha256=$actualHash"
    )
}

$env:SKATE3_UNIVERSITY_SK8_SOURCE = $VendorRoot
$env:SKATE3_UNIVERSITY_PACKAGE = $Package
$env:SKATE3_UNIVERSITY_SOURCE_MANIFEST = $Manifest
$env:SKATE3_UTT_ROOT = $UttRoot
& python (Join-Path $ProjectRoot 'tools\build_university_bevy_cache.py')
if ($LASTEXITCODE -ne 0) {
    throw "University Bevy cache generation failed with exit code $LASTEXITCODE."
}

Write-Output "UNIVERSITY_BUILD_OK package=$Package"
