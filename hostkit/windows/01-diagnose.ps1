# 01-diagnose.ps1  — READ-ONLY. Changes nothing. Prints what this Windows machine can do and saves it to
# %USERPROFILE%\hostkit-diagnose.txt so it can be pasted back. Safe to run.
#   powershell -ExecutionPolicy Bypass -File 01-diagnose.ps1
$ErrorActionPreference = 'SilentlyContinue'
$lines = New-Object System.Collections.Generic.List[string]
function Say([string]$t) { Write-Host $t; $lines.Add($t) }

Say "=== host ==="
$os = Get-CimInstance Win32_OperatingSystem
Say ("{0} | {1} | build {2}" -f $env:COMPUTERNAME, $os.Caption, $os.BuildNumber)

Say "=== GPU ==="
if (Get-Command nvidia-smi) { nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | ForEach-Object { Say $_ } }
Get-CimInstance Win32_VideoController | ForEach-Object { Say ("{0} | driver {1}" -f $_.Name, $_.DriverVersion) }

Say "=== CPU / RAM ==="
Say ((Get-CimInstance Win32_Processor).Name)
Say ("RAM GB: {0}" -f [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB))

Say "=== disks (free space matters for game installs) ==="
Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
  Say ("{0}: used {1} GB, free {2} GB" -f $_.Name, [math]::Round($_.Used / 1GB), [math]::Round($_.Free / 1GB)) }

Say "=== network adapters (Ethernet is best for a host; Wi-Fi 6E/7 for the Quest side) ==="
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object { Say ("{0} | {1}" -f $_.Name, $_.LinkSpeed) }

Say "=== Tailscale ==="
if (Get-Command tailscale) { tailscale status | Select-Object -First 15 | ForEach-Object { Say $_ } } else { Say "tailscale CLI not found" }

Say "=== Steam games installed ==="
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
if ($steam) {
  $libs = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path $vdf) { (Get-Content $vdf) | ForEach-Object { if ($_ -match '"path"\s+"(.+)"') { $libs += ($Matches[1] -replace '\\\\', '\') } } }
  $libs | Select-Object -Unique | ForEach-Object {
    Get-ChildItem (Join-Path $_ 'steamapps') -Filter 'appmanifest_*.acf' | ForEach-Object {
      $n = (Select-String -Path $_.FullName -Pattern '"name"\s+"(.+)"').Matches.Groups[1].Value
      if ($n) { Say ("  steam: {0}" -f $n) } } }
} else { Say "Steam not found" }

Say "=== streaming / VR software already installed ==="
$apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
  Where-Object { $_.DisplayName -match 'Sunshine|Moonlight|Parsec|Virtual Desktop|ALVR|SteamVR|Meta Quest|Oculus|UEVR|Tailscale|Minecraft|Prism|MultiMC' }
if ($apps) { $apps | ForEach-Object { Say ("  {0} {1}" -f $_.DisplayName, $_.DisplayVersion) } } else { Say "  none of the usual suspects found" }

$path = Join-Path $env:USERPROFILE 'hostkit-diagnose.txt'
$lines | Set-Content -Path $path -Encoding UTF8
Say ""
Say ("Saved to {0}  (paste that file's contents back; nothing in it is secret)" -f $path)
