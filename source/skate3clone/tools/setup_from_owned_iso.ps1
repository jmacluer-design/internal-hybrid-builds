[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Iso', Mandatory = $true, Position = 0)]
    [string]$Iso,

    [Parameter(ParameterSetName = 'Extracted', Mandatory = $true)]
    [string]$GameRoot,

    [string]$MiscloadOverride = '',
    [switch]$ForceRebuild,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$OwnedGameRoot = Join-Path $ProjectRoot 'runtime\owned-game'
$OwnedDataRoot = Join-Path $ProjectRoot 'work\private-assets\owned-game'
$BootstrapRoot = Join-Path $ProjectRoot 'work\private-assets\bootstrap-tools'
$ExtractXisoVersion = 'build-202505152050'
$ExtractXisoUrl = (
    'https://github.com/XboxDev/extract-xiso/releases/download/' +
    "$ExtractXisoVersion/extract-xiso-Win64_Release.zip"
)
$ExtractXisoZipHash = 'FEC88D03C7EFD6205AB09BE4ABBA70C0AFD0EB27A5709F0A6235B828BA5AC11E'

function Find-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }
    return $command.Source
}

function Find-Blender {
    if (-not [string]::IsNullOrWhiteSpace($env:BLENDER_EXECUTABLE) -and
        (Test-Path -LiteralPath $env:BLENDER_EXECUTABLE -PathType Leaf)) {
        return [IO.Path]::GetFullPath($env:BLENDER_EXECUTABLE)
    }
    $onPath = Find-CommandPath -Name 'blender.exe'
    if ($null -ne $onPath) {
        return $onPath
    }
    $roots = @(
        (Join-Path $env:ProgramFiles 'Blender Foundation'),
        (Join-Path ${env:ProgramFiles(x86)} 'Blender Foundation')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $candidates = @(
        foreach ($root in $roots) {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -Filter blender.exe -File -Recurse
            }
        }
    )
    return (
        $candidates |
            Sort-Object -Property FullName -Descending |
            Select-Object -First 1
    ).FullName
}

function Require-Success {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE."
    }
}

$Python = Find-CommandPath -Name 'python.exe'
$Cargo = Find-CommandPath -Name 'cargo.exe'
$Blender = Find-Blender
if ($null -eq $Python) {
    throw 'Python 3.11 or newer is required and was not found on PATH.'
}
& $Python -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)'
if ($LASTEXITCODE -ne 0) {
    throw 'Python 3.11 or newer is required.'
}
if ($null -eq $Cargo) {
    throw 'Rust/Cargo is required. Install Rust from https://rustup.rs and rerun this file.'
}
if ([string]::IsNullOrWhiteSpace($Blender)) {
    throw 'Blender 5.x is required. Install Blender, then rerun this file.'
}
$BlenderVersionLine = (& $Blender --version | Select-Object -First 1)
if (
    $LASTEXITCODE -ne 0 -or
    [string]::IsNullOrWhiteSpace($BlenderVersionLine) -or
    $BlenderVersionLine -notmatch '^Blender 5\.'
) {
    throw (
        'Blender 5.x is required. Detected: ' +
        $(if ($BlenderVersionLine) { $BlenderVersionLine } else { 'unknown' })
    )
}

Push-Location -LiteralPath $ProjectRoot
try {
    if ($PSCmdlet.ParameterSetName -eq 'Iso') {
        $Iso = [IO.Path]::GetFullPath($Iso)
        if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) {
            throw "Owned Skate 3 ISO not found: $Iso"
        }
        $requiredArchive = Join-Path $OwnedGameRoot `
            'data\content\worldDIST_University.big'
        if (-not (Test-Path -LiteralPath $requiredArchive -PathType Leaf)) {
            if (Test-Path -LiteralPath $OwnedGameRoot -PathType Container) {
                $resolvedOwnedGame = [IO.Path]::GetFullPath($OwnedGameRoot)
                $expectedOwnedGame = [IO.Path]::GetFullPath(
                    (Join-Path $ProjectRoot 'runtime\owned-game')
                )
                if ($resolvedOwnedGame -ne $expectedOwnedGame) {
                    throw "Unsafe owned-game reset path: $resolvedOwnedGame"
                }
                $existingOwnedGame = @(
                    Get-ChildItem -LiteralPath $resolvedOwnedGame -Force
                )
                if ($existingOwnedGame.Count -ne 0) {
                    Write-Host (
                        'Removing an incomplete prior local ISO extraction...'
                    ) -ForegroundColor Yellow
                    Remove-Item -LiteralPath $resolvedOwnedGame -Recurse -Force
                }
            }
            New-Item -ItemType Directory -Path $BootstrapRoot -Force | Out-Null
            $zip = Join-Path $BootstrapRoot 'extract-xiso-Win64_Release.zip'
            $toolRoot = Join-Path $BootstrapRoot 'extract-xiso'
            $extractXiso = Join-Path $toolRoot 'artifacts\extract-xiso.exe'
            if (-not (Test-Path -LiteralPath $extractXiso -PathType Leaf)) {
                Write-Host 'Downloading the pinned open-source Xbox ISO extractor...' `
                    -ForegroundColor Cyan
                Invoke-WebRequest -Uri $ExtractXisoUrl -OutFile $zip
                $actualZipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
                if ($actualZipHash -ne $ExtractXisoZipHash) {
                    throw (
                        'extract-xiso download hash mismatch. ' +
                        "Expected $ExtractXisoZipHash, got $actualZipHash."
                    )
                }
                if (Test-Path -LiteralPath $toolRoot) {
                    $resolvedToolRoot = [IO.Path]::GetFullPath($toolRoot)
                    $resolvedBootstrap = [IO.Path]::GetFullPath($BootstrapRoot)
                    if (-not $resolvedToolRoot.StartsWith($resolvedBootstrap)) {
                        throw "Unsafe bootstrap tool path: $resolvedToolRoot"
                    }
                    Remove-Item -LiteralPath $resolvedToolRoot -Recurse -Force
                }
                Expand-Archive -LiteralPath $zip -DestinationPath $toolRoot
            }
            & (Join-Path $PSScriptRoot 'extract_owned_xiso.ps1') `
                -Iso $Iso -ExtractXiso $extractXiso -Destination $OwnedGameRoot
        }
        $GameRoot = $OwnedGameRoot
    }
    else {
        $GameRoot = [IO.Path]::GetFullPath($GameRoot)
    }

    Write-Host 'Checking source-only conversion dependencies...' -ForegroundColor Cyan
    & $Python -c 'import numpy; from PIL import Image'
    if ($LASTEXITCODE -ne 0) {
        Require-Success -Label 'Python dependency installation' -Action {
            & $Python -m pip install --user numpy Pillow
        }
    }

    $extractArguments = @(
        (Join-Path $PSScriptRoot 'owned_game\extract_retail_inputs.py'),
        '--game-root', $GameRoot,
        '--output-root', $OwnedDataRoot
    )
    if (-not [string]::IsNullOrWhiteSpace($MiscloadOverride)) {
        $extractArguments += @(
            '--miscload',
            [IO.Path]::GetFullPath($MiscloadOverride)
        )
    }
    Require-Success -Label 'Retail input extraction' -Action {
        & $Python @extractArguments
    }

    $env:SKATE3_OWNED_DATA_ROOT = $OwnedDataRoot
    $env:BLENDER_EXECUTABLE = $Blender
    $buildCharacterArguments = @{
        OwnedDataRoot = $OwnedDataRoot
        Blender = $Blender
    }
    if ($ForceRebuild) {
        $buildCharacterArguments.ForceRebuild = $true
    }
    & (Join-Path $PSScriptRoot 'build_default_skater_assets.ps1') `
        @buildCharacterArguments

    & (Join-Path $PSScriptRoot 'build_manual_visual_assets.ps1') `
        -OwnedDataRoot $OwnedDataRoot -Blender $Blender

    $buildMapArguments = @{
        OwnedDataRoot = $OwnedDataRoot
        Blender = $Blender
    }
    if ($ForceRebuild) {
        $buildMapArguments.ForceRebuild = $true
    }
    & (Join-Path $PSScriptRoot 'build_university_from_owned_game.ps1') `
        @buildMapArguments

    Require-Success -Label 'Rust test suite' -Action {
        & $Cargo test
    }
    Require-Success -Label 'Game compilation' -Action {
        & $Cargo build
    }

    Write-Host 'SETUP COMPLETE - the ISO-derived assets remain local and ignored.' `
        -ForegroundColor Green
    if (-not $NoLaunch) {
        & $Cargo run -- --level=university
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}
