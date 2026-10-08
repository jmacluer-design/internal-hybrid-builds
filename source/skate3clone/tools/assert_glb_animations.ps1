[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string[]]$RequiredAction
)

$ErrorActionPreference = 'Stop'
$ResolvedPath = [IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    throw "Required private animation GLB is missing: $ResolvedPath"
}

$Stream = [IO.File]::OpenRead($ResolvedPath)
$Reader = [IO.BinaryReader]::new($Stream)
try {
    $Magic = $Reader.ReadUInt32()
    $Version = $Reader.ReadUInt32()
    $DeclaredLength = $Reader.ReadUInt32()
    if ($Magic -ne 0x46546C67 -or $Version -ne 2) {
        throw "Not a glTF 2 GLB: $ResolvedPath"
    }
    if ($DeclaredLength -ne $Stream.Length) {
        throw (
            "GLB declared length $DeclaredLength does not match " +
            "file length $($Stream.Length): $ResolvedPath"
        )
    }

    $JsonLength = $Reader.ReadUInt32()
    $JsonType = $Reader.ReadUInt32()
    if ($JsonType -ne 0x4E4F534A) {
        throw "GLB first chunk is not JSON: $ResolvedPath"
    }
    $JsonBytes = $Reader.ReadBytes($JsonLength)
    if ($JsonBytes.Length -ne $JsonLength) {
        throw "GLB JSON chunk is truncated: $ResolvedPath"
    }
    $JsonText = [Text.Encoding]::UTF8.GetString($JsonBytes).TrimEnd(
        [char[]]@(0, 9, 10, 13, 32)
    )
    $Gltf = $JsonText | ConvertFrom-Json
    $Actions = @($Gltf.animations | ForEach-Object { [string]$_.name })
}
finally {
    $Reader.Dispose()
    $Stream.Dispose()
}

$DuplicateActions = @(
    $Actions |
        Group-Object |
        Where-Object { $_.Count -ne 1 } |
        ForEach-Object { $_.Name }
)
if ($DuplicateActions.Count -gt 0) {
    throw "GLB contains duplicate animation names: $($DuplicateActions -join ', ')"
}

$MissingActions = @(
    $RequiredAction |
        Sort-Object -Unique |
        Where-Object { $_ -notin $Actions }
)
if ($MissingActions.Count -gt 0) {
    throw (
        "GLB is missing required animation actions: " +
        "$($MissingActions -join ', '). Path: $ResolvedPath"
    )
}

$HashStream = [IO.File]::OpenRead($ResolvedPath)
$Sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $HashBytes = $Sha256.ComputeHash($HashStream)
    $Hash = [BitConverter]::ToString($HashBytes).Replace('-', '')
}
finally {
    $Sha256.Dispose()
    $HashStream.Dispose()
}
Write-Output (
    "GLB_ANIMATIONS_OK path=$ResolvedPath actions=$($Actions.Count) " +
    "required=$($RequiredAction.Count) sha256=$Hash"
)
