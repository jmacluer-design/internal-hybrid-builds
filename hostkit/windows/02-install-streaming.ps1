# 02-install-streaming.ps1 — installs the streaming side of the host with winget. DRY RUN by default: prints what it
# would do. Add -Apply to actually install. Idempotent (skips what's already there). Needs winget (Windows 10/11).
#   powershell -ExecutionPolicy Bypass -File 02-install-streaming.ps1            # dry run
#   powershell -ExecutionPolicy Bypass -File 02-install-streaming.ps1 -Apply     # do it
# Not covered here (do these yourself, they're personal/slow): GPU driver update, Steam + your game installs,
# Windows auto-login for the streaming account (netplwiz), a dummy HDMI plug if no monitor is attached.
param([switch]$Apply)

$packages = @(
  @{ id = 'Tailscale.Tailscale';  why = 'private network to every device you own' },
  @{ id = 'LizardByte.Sunshine';  why = 'game-stream host (NVENC hardware encoding); web UI on https://localhost:47990' }
)

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Host "winget not found. Install 'App Installer' from the Microsoft Store first."; exit 1 }

foreach ($p in $packages) {
  $have = winget list --id $p.id --exact 2>$null | Select-String $p.id
  if ($have) { Write-Host ("[skip]    {0} already installed" -f $p.id); continue }
  if ($Apply) { Write-Host ("[install] {0}  ({1})" -f $p.id, $p.why); winget install --id $p.id --exact --accept-package-agreements --accept-source-agreements }
  else        { Write-Host ("[dry-run] would install {0}  ({1})" -f $p.id, $p.why) }
}

Write-Host ""
Write-Host "Next, by hand:"
Write-Host " 1. Sign in to Tailscale (tray icon). Then: tailscale status"
Write-Host " 2. Open https://localhost:47990, set a Sunshine username/password (local only), add your Steam as an application."
Write-Host " 3. Pair a client (Moonlight on a phone/tablet/TV, or Moonlight-Web: see hostkit/README.md)."
Write-Host " 4. Run 03-tailscale-serve.ps1 once the browser client is running."
