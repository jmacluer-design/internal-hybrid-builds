# 03-tailscale-serve.ps1 — publish a local web app (the browser streaming client) over HTTPS to YOUR tailnet only.
# `tailscale serve` gives https://<this-machine>.<tailnet>.ts.net with a real certificate (WebXR and gamepad APIs need
# HTTPS). It is reachable only by your own tailnet devices. Prerequisites in the Tailscale admin console:
# enable MagicDNS and "HTTPS Certificates" (DNS page). Note: enabling HTTPS publishes machine names in a public
# certificate log; that's a Tailscale behaviour, not ours.
#   powershell -ExecutionPolicy Bypass -File 03-tailscale-serve.ps1 -Port 8080      # publish http://127.0.0.1:8080
#   powershell -ExecutionPolicy Bypass -File 03-tailscale-serve.ps1 -Reset          # stop publishing
param([int]$Port = 8080, [switch]$Reset)

if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) { Write-Host "tailscale not found (run 02-install-streaming.ps1 -Apply first)"; exit 1 }
if ($Reset) { tailscale serve reset; Write-Host "serve config cleared"; exit 0 }
tailscale serve --bg --https=443 ("http://127.0.0.1:{0}" -f $Port)
tailscale serve status
