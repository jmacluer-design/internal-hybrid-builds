# Builds the mod DLL on Windows (see "Building" in README.md). With -Dist, also puts it into an
# ER-Mario folder, e.g.  .\build.ps1 -Dist "$env:USERPROFILE\Documents\ER-Mario"
# Needs: Rust (rustup), Visual Studio Build Tools (C++), LLVM (clang-cl for libsm64's C code).
param(
    # the ER-Mario folder the game loads the mod from (optional)
    [string]$Dist = ""
)
$ErrorActionPreference = 'Stop'
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path += ";$env:USERPROFILE\.cargo\bin;C:\Program Files\LLVM\bin"
# libsm64 is decompiled N64 C code: clang-cl handles it like the Linux cross build did
$env:CC_x86_64_pc_windows_msvc = 'clang-cl'
# no local paths (user name) in the DLL's panic messages
$reg = Get-ChildItem "$env:USERPROFILE\.cargo\registry\src" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$flags = @("--remap-path-prefix=$(Split-Path $PSScriptRoot)=src", "--remap-path-prefix=$env:USERPROFILE=~")
if ($reg) { $flags = @("--remap-path-prefix=$($reg.FullName)=crates") + $flags }
$env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = $flags -join ' '

Push-Location $PSScriptRoot
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed" }
} finally {
    Pop-Location
}
$dll = "$PSScriptRoot\target\x86_64-pc-windows-msvc\release\er_mario.dll"
if (-not $Dist) {
    Write-Host "built $dll"
    return
}
# swap in by rename: overwriting the DLL a running game has loaded crashed the game
Copy-Item $dll "$Dist\er_mario.dll.new" -Force
# Windows locks a loaded DLL against overwriting but allows renaming it: a running game keeps the
# old copy (er_mario.dll.old*), the next start loads the new one
Get-ChildItem "$Dist\er_mario.dll.old*" -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-Item $_ -Force -ErrorAction Stop } catch {} }
if (Test-Path "$Dist\er_mario.dll") {
    Move-Item "$Dist\er_mario.dll" "$Dist\er_mario.dll.old$(Get-Date -Format HHmmss)" -Force
}
Move-Item "$Dist\er_mario.dll.new" "$Dist\er_mario.dll" -Force
Write-Host "built and installed into $Dist"
