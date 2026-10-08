[CmdletBinding()]
param(
    [string]$OwnedDataRoot = $env:SKATE3_OWNED_DATA_ROOT,
    [string]$Blender = $env:BLENDER_EXECUTABLE,
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Blender)) {
    $Blender = 'C:\Program Files\Blender Foundation\Blender 5.1\blender.exe'
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path))
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OwnedDataRoot)) {
    $OwnedDataRoot = Join-Path $ProjectRoot 'work\private-assets\owned-game'
}
$SourceAbin = Join-Path $OwnedDataRoot 'data\anim\OnBoard.abin'
$SourceRx2 = Join-Path $ProjectRoot 'work\private-assets\default_skater\selected\models'
$ImporterDir = Join-Path $ProjectRoot 'tools\vendor\skate3_anim'
$Exporter = Join-Path $ImporterDir 'blender_rx2_abin_export.py'
$TargetExporter = Join-Path $PSScriptRoot 'add_onboard_ik_targets.py'
$GlbExporter = Join-Path $PSScriptRoot 'export_bevy_glb.py'
$WorkDir = Join-Path $ProjectRoot 'work\manual-private-assets'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $ProjectRoot 'assets\private\manual'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$Blend = Join-Path $WorkDir 'manual_skater_source.blend'
$Validation = Join-Path $WorkDir 'manual_skater_source.validation.json'
$CandidateGlb = Join-Path $OutputDirectory 'skater_rig.candidate.glb'
$CandidateManifest = Join-Path $OutputDirectory 'skater_rig.candidate.manifest.txt'
$CandidateRootMotion = Join-Path $OutputDirectory 'skater_rig.candidate.root_motion.json'
$Glb = Join-Path $OutputDirectory 'skater_rig.glb'
$Manifest = Join-Path $OutputDirectory 'skater_rig.manifest.txt'
$RootMotion = Join-Path $OutputDirectory 'skater_rig.root_motion.json'

$clips = @(
    'M_NOSEBRAKE_N_0_CYC',
    'M_NOSEBRAKE_STAT_0_CYC',
    'M_NOSEIDLE_CROUCH_0_CYC',
    'M_NOSEIDLE_CROUCH_0_INTO',
    'M_NOSEIDLE_CROUCH_0_OUT',
    'M_NOSEIDLE_CROUCH_0_TURN_BS_0_CYC',
    'M_NOSEIDLE_CROUCH_0_TURN_FS_0_CYC',
    'M_NOSEIDLE_N_0_CYC',
    'M_NOSEIDLE_N_0_INTO',
    'M_NOSEIDLE_N_0_OUT',
    'M_NOSEIDLE_N_0_TURN_BS_0_CYC',
    'M_NOSEIDLE_N_0_TURN_FS_0_CYC',
    'M_NOSELEAN_CROUCH_0_CYC',
    'M_NOSELEAN_CROUCH_0_TURN_BS_0_CYC',
    'M_NOSELEAN_CROUCH_0_TURN_FS_0_CYC',
    'M_NOSELEAN_N_0_CYC',
    'M_NOSELEAN_TURN_BS_0_CYC',
    'M_NOSELEAN_TURN_FS_0_CYC',
    'M_BRAKE_N_0_CYC',
    'M_BRAKE_STAT_0_CYC',
    'M_IDLE_CROUCH_0_CYC',
    'M_IDLE_CROUCH_0_TURN_BS_0_CYC',
    'M_IDLE_CROUCH_0_TURN_FS_0_CYC',
    'M_IDLE_N_0_CYC',
    'M_IDLE_N_0_TURN_BS_0_CYC',
    'M_IDLE_N_0_TURN_FS_0_CYC',
    'M_LEAN_CROUCH_0_CYC',
    'M_LEAN_CROUCH_0_TURN_BS_0_CYC',
    'M_LEAN_CROUCH_0_TURN_FS_0_CYC',
    'M_LEAN_N_0_CYC',
    'M_LEAN_TURN_BS_0_CYC',
    'M_LEAN_TURN_FS_0_CYC'
)

foreach ($required in @(
    $Blender,
    $SourceAbin,
    $SourceRx2,
    $Exporter,
    $TargetExporter,
    $GlbExporter
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required private source or tool is missing: $required"
    }
}

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
foreach ($candidate in @($CandidateGlb, $CandidateManifest, $CandidateRootMotion)) {
    if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Force
    }
}

$arguments = @(
    '--background',
    '--python', $Exporter,
    '--',
    '--abin', $SourceAbin,
    '--rx2', $SourceRx2,
    '--output', $Blend,
    '--preview-fps', '60'
)
foreach ($clip in $clips) {
    $arguments += @('--clip', $clip)
}

& $Blender @arguments
if (
    $LASTEXITCODE -ne 0 -or
    -not (Test-Path -LiteralPath $Blend) -or
    -not (Test-Path -LiteralPath $Validation)
) {
    throw "Manual RX2/ABIN extraction failed with exit code $LASTEXITCODE"
}

& $Blender '--background' $Blend '--python' $TargetExporter '--' $SourceAbin $ImporterDir
if ($LASTEXITCODE -ne 0) {
    throw "Manual SkeletonIK target export failed with exit code $LASTEXITCODE"
}

& $Blender '--background' $Blend '--python' $GlbExporter '--' `
    $CandidateGlb $CandidateManifest $CandidateRootMotion
if (
    $LASTEXITCODE -ne 0 -or
    -not (Test-Path -LiteralPath $CandidateGlb) -or
    -not (Test-Path -LiteralPath $CandidateManifest) -or
    -not (Test-Path -LiteralPath $CandidateRootMotion)
) {
    throw "Manual Bevy glTF export failed with exit code $LASTEXITCODE"
}

$manifestLines = @(Get-Content -LiteralPath $CandidateManifest)
$manifestActions = @(
    $manifestLines |
        Where-Object { $_.StartsWith('action=') } |
        ForEach-Object { $_.Substring('action='.Length) }
)
$missing = @($clips | Where-Object { $_ -notin $manifestActions })
$extra = @($manifestActions | Where-Object { $_ -notin $clips })
if (
    $missing.Count -gt 0 -or
    $extra.Count -gt 0 -or
    $manifestActions.Count -ne $clips.Count
) {
    throw (
        "Manual action-set mismatch. expected=$($clips.Count) " +
        "actual=$($manifestActions.Count) missing=[$($missing -join ', ')] " +
        "extra=[$($extra -join ', ')]"
    )
}

$abinHash = Get-Sha256 -Path $SourceAbin
$glbHash = Get-Sha256 -Path $CandidateGlb
$rootMotionHash = Get-Sha256 -Path $CandidateRootMotion
$portableManifestLines = @(
    Get-Content -LiteralPath $CandidateManifest |
        ForEach-Object {
            if ($_.StartsWith('output=')) {
                "output=$([IO.Path]::GetFileName($Glb))"
            }
            elseif ($_.StartsWith('root_motion=')) {
                "root_motion=$([IO.Path]::GetFileName($RootMotion))"
            }
            else {
                $_
            }
        }
)
Set-Content -LiteralPath $CandidateManifest -Value $portableManifestLines `
    -Encoding utf8
Add-Content -LiteralPath $CandidateManifest `
    -Value 'onboard_source=data/anim/OnBoard.abin'
Add-Content -LiteralPath $CandidateManifest -Value "onboard_sha256=$abinHash"
Add-Content -LiteralPath $CandidateManifest -Value "root_motion_sha256=$rootMotionHash"
Add-Content -LiteralPath $CandidateManifest -Value "glb_sha256=$glbHash"

Move-Item -LiteralPath $CandidateGlb -Destination $Glb -Force
Move-Item -LiteralPath $CandidateManifest -Destination $Manifest -Force
Move-Item -LiteralPath $CandidateRootMotion -Destination $RootMotion -Force

$manifestHash = Get-Sha256 -Path $Manifest
Write-Output "MANUAL_VISUAL_ASSET_READY path=$Glb"
Write-Output "MANUAL_VISUAL_GLB_SHA256=$glbHash"
Write-Output "MANUAL_VISUAL_MANIFEST_SHA256=$manifestHash"
