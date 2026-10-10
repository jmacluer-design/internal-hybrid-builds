#!/usr/bin/env bash
# 01-diagnose.sh: READ-ONLY. Changes nothing. Prints what this Linux box can do as a game/VR streaming host and
# saves it to ~/hostkit-diagnose.txt so it can be pasted back. Safe to run (no sudo needed; some lines are
# fuller with sudo, and say so).
#   bash 01-diagnose.sh
# One-liner (from an SSH session on the box):
#   curl -fsSL https://raw.githubusercontent.com/jmacluer-design/internal-hybrid-builds/claude/zealous-bell-jownt4/hostkit/linux/01-diagnose.sh | bash
set -u
OUT="$HOME/hostkit-diagnose.txt"
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
sec() { say ""; say "=== $* ==="; }
have() { command -v "$1" >/dev/null 2>&1; }
run() { "$@" 2>&1 | sed 's/^/  /' | tee -a "$OUT"; }   # run a command, indent + log its output

sec "host"
say "$(hostname) | $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") | kernel $(uname -r) | $(uname -m)"
say "uptime: $(uptime -p 2>/dev/null || true)"
say "user: $(id -un) | in groups: $(id -Gn | tr ' ' ',')"

sec "GPU"
if have nvidia-smi; then
  run nvidia-smi --query-gpu=index,name,memory.total,driver_version,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader
  say "  (NVENC sessions / encoder stats)"; run nvidia-smi --query-gpu=encoder.stats.sessionCount,encoder.stats.averageFps --format=csv,noheader
else
  say "  nvidia-smi not found (NVIDIA driver not installed, or not on PATH)"
fi
if have lspci; then run bash -c "lspci | grep -Ei 'vga|3d|display'"; else say "  lspci not found"; fi

sec "CPU / RAM"
say "  $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //') | $(nproc) threads"
say "  $(free -g | awk '/Mem:/ {print "RAM GB total " $2 ", available " $7}')"

sec "disks and free space (game installs are big)"
run df -h --output=target,size,avail,fstype -x tmpfs -x devtmpfs -x squashfs -x overlay

sec "can Windows go on this box? (partitions, EFI boot entries, free space)"
run lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT
if have efibootmgr; then run efibootmgr; else say "  efibootmgr not installed (boot entries not listed)"; fi
[ -d /sys/firmware/efi ] && say "  boots via UEFI: yes" || say "  boots via UEFI: no (legacy BIOS)"
say "  existing NTFS partitions: $(lsblk -rno FSTYPE 2>/dev/null | grep -ci ntfs)"

sec "display / session (Sunshine wants a monitor or a dummy HDMI plug)"
say "  XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-unset} | DISPLAY=${DISPLAY:-unset} | WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"
say "  desktop: ${XDG_CURRENT_DESKTOP:-none detected}"
for c in /sys/class/drm/card*-*/status; do [ -e "$c" ] && say "  $(basename "$(dirname "$c")"): $(cat "$c")"; done
if have loginctl; then run bash -c "loginctl list-sessions --no-legend 2>/dev/null"; fi

sec "network (wired is best for a host)"
if have ip; then run ip -br addr; fi
for n in /sys/class/net/*; do b=$(basename "$n"); [ "$b" = lo ] && continue; sp=$(cat "$n/speed" 2>/dev/null || true); [ "${sp:--1}" -gt 0 ] 2>/dev/null && say "  $b link speed: ${sp} Mb/s"; done

sec "Tailscale"
if have tailscale; then run bash -c "tailscale status 2>&1 | head -15"; say "  version: $(tailscale version 2>/dev/null | head -1)"; else say "  tailscale CLI not found"; fi

sec "virtualization (only matters for a Windows VM with GPU passthrough)"
say "  CPU virt flags: $(grep -Eoc 'vmx|svm' /proc/cpuinfo | head -1) | /dev/kvm: $([ -e /dev/kvm ] && echo present || echo absent)"
say "  IOMMU groups: $(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)"

sec "Steam / games"
for d in "$HOME/.steam/steam" "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
  if [ -d "$d/steamapps" ]; then
    say "  steam library: $d"
    for f in "$d"/steamapps/appmanifest_*.acf; do [ -e "$f" ] && say "    $(grep -m1 '"name"' "$f" | sed 's/.*"name"[[:space:]]*"\(.*\)"/\1/')"; done
    [ -d "$d/steamapps/compatdata" ] && say "    (compatdata present: Proton in use)"
  fi
done
have steam && say "  steam binary: $(command -v steam)" || say "  steam binary: not found"

sec "streaming / VR software already installed"
for x in sunshine moonlight wivrn alvr steam docker flatpak ffmpeg vainfo vulkaninfo; do have "$x" && say "  found: $x ($(command -v "$x"))"; done
have flatpak && run bash -c "flatpak list --app --columns=application 2>/dev/null | grep -Ei 'steam|sunshine|moonlight|wivrn|alvr|prism|minecraft' || true"
have vulkaninfo && say "  vulkan device: $(vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | sed 's/^ *//')"

say ""
say "Saved to $OUT (paste the file contents back; nothing in it is secret: hostnames and local IPs only)."
