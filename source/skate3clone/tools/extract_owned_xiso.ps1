[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Iso,

    [Parameter(Mandatory = $true)]
    [string]$ExtractXiso,

    [Parameter(Mandatory = $true)]
    [string]$Destination
)

$ErrorActionPreference = 'Stop'

$Iso = [IO.Path]::GetFullPath($Iso)
$ExtractXiso = [IO.Path]::GetFullPath($ExtractXiso)
$Destination = [IO.Path]::GetFullPath($Destination)

if (-not (Test-Path -LiteralPath $Iso -PathType Leaf)) {
    throw "Owned Xbox 360 ISO not found: $Iso"
}
if (-not (Test-Path -LiteralPath $ExtractXiso -PathType Leaf)) {
    throw "extract-xiso executable not found: $ExtractXiso"
}
if (Test-Path -LiteralPath $Destination) {
    $existing = @(Get-ChildItem -LiteralPath $Destination -Force)
    if ($existing.Count -ne 0) {
        throw "Destination must be empty: $Destination"
    }
}
else {
    New-Item -ItemType Directory -Path $Destination | Out-Null
}

Write-Host 'Extracting the user-supplied owned Xbox 360 image...' -ForegroundColor Cyan
& $ExtractXiso -x $Iso -d $Destination
if ($LASTEXITCODE -ne 0) {
    throw "extract-xiso failed with exit code $LASTEXITCODE."
}

$DefaultXex = Join-Path $Destination 'default.xex'
$Content = Join-Path $Destination 'data\content'
if (
    -not (Test-Path -LiteralPath $DefaultXex -PathType Leaf) -or
    -not (Test-Path -LiteralPath $Content -PathType Container)
) {
    throw @"
Extraction completed, but the destination does not look like Skate 3 game data.
Expected:
  $DefaultXex
  $Content
"@
}

Write-Host "Owned game data extracted to: $Destination" -ForegroundColor Green
Write-Host 'Keep this directory outside Git and do not redistribute it.'
