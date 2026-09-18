#!/usr/bin/env bash
#
# setup-rpi-zram.sh - compressed swap in RAM (zram) for Raspberry Pi OS.
# SD-card swap (/var/swap) is slow and wears the flash; zram swaps to a
# compressed block device in RAM instead. Installs zram-tools, raises
# vm.swappiness, and drains stale pages out of the old swapfile.
#
# Target: Raspberry Pi OS / Debian with systemd.
# Usage:  sudo scripts/setup-rpi-zram.sh
# Safe to re-run; managed config files are overwritten to match this repo.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "This script must run as root. Try: sudo $0" >&2
    exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not found. This script targets Raspberry Pi OS / Debian." >&2
    exit 1
fi

echo "Installing zram-tools..."
apt_lists_fresh=$(find /var/lib/apt/lists -maxdepth 1 -name '*_Packages*' -mtime -1 -print -quit 2>/dev/null || true)
if [ -z "$apt_lists_fresh" ]; then
    echo "APT package lists are missing or stale; running apt-get update..."
    apt-get update
fi
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools; then
    echo "WARN: install failed; refreshing package lists and retrying..." >&2
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools
fi

echo "Writing /etc/default/zramswap..."
cat > /etc/default/zramswap <<'EOF'
# Managed by dotfiles scripts/setup-rpi-zram.sh
# Compressed swap in RAM; the SD swapfile stays as a low-priority fallback.

# zstd compresses better than lz4 at similar speed.
ALGO=zstd

# 50% of RAM: ~4 GB of swap on an 8 GB Pi, ~nothing while empty.
PERCENT=50

# Prefer zram over the SD swapfile (which keeps default priority -2).
PRIORITY=100
EOF

echo "Enabling and restarting the zramswap service..."
systemctl enable zramswap
systemctl restart zramswap

echo "Setting vm.swappiness=100..."
cat > /etc/sysctl.d/99-swappiness.conf <<'EOF'
# Managed by dotfiles scripts/setup-rpi-zram.sh
# Swapping to zram is cheap, so prefer it over dropping page cache.
vm.swappiness=100
EOF
sysctl vm.swappiness=100

meminfo_kb() {
    awk -v key="$1" '$1 == key ":" { print $2; exit }' /proc/meminfo
}

# Drain stale pages out of the old SD swapfile so future swapping goes to
# zram first; only when MemAvailable covers the swap in use with 20% headroom.
swap_used=$(( $(meminfo_kb SwapTotal) - $(meminfo_kb SwapFree) ))
mem_available=$(meminfo_kb MemAvailable)

if [ "$swap_used" -le 0 ]; then
    echo "No swap in use; skipping the swap drain."
elif [ $((mem_available * 10)) -gt $((swap_used * 12)) ]; then
    echo "Draining ${swap_used} kB of swap back into RAM..."
    swapoff -a && swapon -a
    # Neither /var/swap (dphys-swapfile) nor /dev/zram0 (zram-tools) is in
    # /etc/fstab, so swapon -a re-enables neither; restore both explicitly.
    if [ -e /var/swap ] && ! grep -q '^/var/swap[[:space:]]' /proc/swaps; then
        swapon /var/swap
    fi
    systemctl restart zramswap
else
    echo "WARN: not draining swap: only ${mem_available} kB MemAvailable for ${swap_used} kB in use." >&2
fi

echo
echo "Done. Verify with:"
echo "  zramctl        # expect /dev/zram0, ~4G, algorithm zstd"
echo "  swapon --show  # expect /dev/zram0 at priority 100 and /var/swap at -2"
