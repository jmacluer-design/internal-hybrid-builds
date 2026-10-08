[CmdletBinding()]
param(
    [string]$OwnedDataRoot = $env:SKATE3_OWNED_DATA_ROOT,
    [string]$Blender = $env:BLENDER_EXECUTABLE,
    [switch]$ForceRebuild,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Blender)) {
    $blenderCommand = Get-Command blender.exe -ErrorAction SilentlyContinue
    if ($null -ne $blenderCommand) {
        $Blender = $blenderCommand.Source
    }
    else {
        $blenderCandidates = @(
            foreach ($programRoot in @(
                $env:ProgramFiles,
                ${env:ProgramFiles(x86)}
            )) {
                if (-not [string]::IsNullOrWhiteSpace($programRoot)) {
                    $foundation = Join-Path $programRoot 'Blender Foundation'
                    if (Test-Path -LiteralPath $foundation -PathType Container) {
                        Get-ChildItem -LiteralPath $foundation `
                            -Filter blender.exe -File -Recurse
                    }
                }
            }
        )
        $Blender = (
            $blenderCandidates |
                Sort-Object -Property FullName -Descending |
                Select-Object -First 1
        ).FullName
    }
}
if ([string]::IsNullOrWhiteSpace($Blender)) {
    throw (
        'Blender was not found. Install Blender 5.x or set ' +
        'BLENDER_EXECUTABLE to blender.exe.'
    )
}
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OwnedDataRoot)) {
    $OwnedDataRoot = Join-Path $ProjectRoot 'work\private-assets\owned-game'
}
$RetailManifest = Join-Path $PSScriptRoot 'default_skater_retail_manifest.json'
$Extractor = Join-Path $PSScriptRoot 'extract_default_skater.py'
$MaterialScript = Join-Path $PSScriptRoot 'apply_default_skater_materials.py'
$Validator = Join-Path $PSScriptRoot 'validate_default_skater.py'
$DeformationValidator = Join-Path $PSScriptRoot 'validate_default_skater_deformation.py'
$AnimationBuilder = Join-Path $PSScriptRoot 'build_private_assets.ps1'
$AnimationCheck = Join-Path $PSScriptRoot 'assert_glb_animations.ps1'
$ParserDirectory = Join-Path $ProjectRoot 'tools\vendor\skate3_anim'
$WorkRoot = Join-Path $ProjectRoot 'work\private-assets\default_skater'
$SelectedModels = Join-Path $WorkRoot 'selected\models'
$ExtractionReport = Join-Path $WorkRoot 'default_skater.generated.json'
$MaterialReport = Join-Path $WorkRoot 'default_skater.materials.json'
$ValidationReport = Join-Path $WorkRoot 'default_skater.validation.json'
$DeformationReport = Join-Path $WorkRoot 'default_skater.deformation.json'
$MaterialDirectory = Join-Path $ProjectRoot 'assets\private\default_skater\textures\materials'
$Glb = Join-Path $ProjectRoot 'assets\private\default_skate3_skater.glb'
$GlbManifest = Join-Path $ProjectRoot 'assets\private\default_skate3_skater.manifest.txt'
$RootMotion = Join-Path $ProjectRoot 'assets\private\default_skate3_skater.root_motion.json'
$ExpectedActionCount = 2580
$ExpectedNormalEncoding = 'dxt5nm-ag-to-gltf-rgb-v1'
$ExpectedUvEncoding = 'rx2-top-left-to-blender-bottom-left-v1'
$ExpectedTintEncoding = 'gltf-linear-base-color-factor-v1'
$ExpectedAlphaEncoding = 'gltf-mask-retail-alpha-v1'
$ExpectedMorphEncoding = 'rx2-dense-position-delta-direct-weight-v1'
$BuildMutex = [Threading.Mutex]::new(
    $false,
    'Local\Skate3CloneDefaultSkaterAssets'
)
$BuildMutexHeld = $false

try {
try {
    $BuildMutexHeld = $BuildMutex.WaitOne([TimeSpan]::FromMinutes(20))
}
catch [Threading.AbandonedMutexException] {
    $BuildMutexHeld = $true
}
if (-not $BuildMutexHeld) {
    throw 'Timed out waiting for another default-skater asset build to finish.'
}

foreach ($required in @(
    $RetailManifest,
    $Extractor,
    $MaterialScript,
    $Validator,
    $DeformationValidator,
    $AnimationBuilder,
    $AnimationCheck,
    $Blender,
    $ParserDirectory
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required default-skater source or tool is missing: $required"
    }
}

$extractArguments = @(
    $Extractor,
    '--manifest', $RetailManifest,
    '--owned-data-root', $OwnedDataRoot,
    '--utt-root', (Join-Path $ProjectRoot 'tools\vendor\utt'),
    '--work-root', $WorkRoot,
    '--private-root', (Join-Path $ProjectRoot 'assets\private\default_skater')
)
if ($VerifyOnly) {
    $extractArguments += '--verify-only'
}
& python @extractArguments
if ($LASTEXITCODE -ne 0) {
    throw "Default-skater retail extraction failed with exit code $LASTEXITCODE."
}

$mustBuild = $ForceRebuild -or -not (Test-Path -LiteralPath $Glb -PathType Leaf)
if (-not $mustBuild) {
    if (
        -not (Test-Path -LiteralPath $GlbManifest -PathType Leaf) -or
        -not (Test-Path -LiteralPath $RootMotion -PathType Leaf) -or
        "actions=$ExpectedActionCount" -notin @(
            Get-Content -LiteralPath $GlbManifest -ErrorAction SilentlyContinue
        )
    ) {
        Write-Output (
            'The private animation bank is absent or from an older checkout; ' +
            "reconstructing the required $ExpectedActionCount-action bank."
        )
        $mustBuild = $true
    }
}
if (-not $mustBuild) {
    if (-not (Test-Path -LiteralPath $MaterialReport -PathType Leaf)) {
        $mustBuild = $true
    }
    else {
        $previousMaterial = Get-Content -LiteralPath $MaterialReport -Raw |
            ConvertFrom-Json
        if (
            $previousMaterial.normal_encoding -ne $ExpectedNormalEncoding -or
            $previousMaterial.uv_encoding -ne $ExpectedUvEncoding -or
            $previousMaterial.tint_encoding -ne $ExpectedTintEncoding -or
            $previousMaterial.alpha_encoding -ne $ExpectedAlphaEncoding -or
            $previousMaterial.morph_encoding -ne $ExpectedMorphEncoding
        ) {
            Write-Output (
                'The private GLB uses an obsolete character material/UV path; ' +
                'reconstructing corrected retail textures.'
            )
            $mustBuild = $true
        }
    }
}
if ($VerifyOnly -and $mustBuild) {
    throw (
        'The private default-skater GLB needs reconstruction from the ' +
        'authorized local retail sources.'
    )
}

if ($mustBuild) {
    Write-Output (
        'Building the complete Bevy carrier with the exact retail default ' +
        'skater. Blender may take several minutes on the first build.'
    )
    $postProcessArguments = @(
        '--rx2-dir', $SelectedModels,
        '--manifest', $RetailManifest,
        '--material-dir', $MaterialDirectory,
        '--parser-dir', $ParserDirectory,
        '--report', $MaterialReport
    )
    & $AnimationBuilder `
        -OwnedDataRoot $OwnedDataRoot `
        -Blender $Blender `
        -OutputStem 'default_skate3_skater' `
        -Rx2Source $SelectedModels `
        -PostProcessScript $MaterialScript `
        -PostProcessArguments $postProcessArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Default-skater animation assembly failed with exit code $LASTEXITCODE."
    }
}

foreach ($required in @($Glb, $ExtractionReport, $MaterialReport)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Default-skater build output is missing: $required"
    }
}

& $AnimationCheck -Path $Glb -RequiredAction @(
    'R_IDLE_HCOM_000',
    'OLLIE_LOW_G',
    '360FLIP_D_LOW_G',
    'BR_WALK_FWD_CYC',
    'BR_STAND_0_INTO_MOUNT'
)
if ($LASTEXITCODE -ne 0) {
    throw "Default-skater action-bank validation failed with exit code $LASTEXITCODE."
}

& python $Validator `
    '--glb' $Glb `
    '--retail-manifest' $RetailManifest `
    '--extraction-report' $ExtractionReport `
    '--material-report' $MaterialReport `
    '--output' $ValidationReport
if ($LASTEXITCODE -ne 0) {
    throw "Default-skater structural validation failed with exit code $LASTEXITCODE."
}

Remove-Item -LiteralPath $DeformationReport -Force -ErrorAction SilentlyContinue
& $Blender '--background' '--python' $DeformationValidator '--' `
    $Glb $DeformationReport
if (
    $LASTEXITCODE -ne 0 -or
    -not (Test-Path -LiteralPath $DeformationReport -PathType Leaf)
) {
    throw "Default-skater deformation validation failed with exit code $LASTEXITCODE."
}

$validation = Get-Content -LiteralPath $ValidationReport -Raw | ConvertFrom-Json
Write-Output (
    'DEFAULT_SKATER_BUILD_OK ' +
    "actions=$($validation.actions) " +
    "parts=$($validation.source_parts) " +
    "materials=$($validation.materials) " +
    "joints=$($validation.skin_joints) " +
    "sha256=$($validation.glb_sha256)"
)
}
finally {
    if ($BuildMutexHeld) {
        $BuildMutex.ReleaseMutex()
    }
    $BuildMutex.Dispose()
}
