#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# setup-fresh.sh — maximal one-shot setup for a fresh Ubuntu/Debian machine.
#
# For friends / brand-new boxes. Installs everything the host needs, applies a
# few sensible defaults, then hands off to ./bootstrap.sh (which does .env,
# secrets, dirs, the docker network, symlinks, cron, and starts Arcane).
# Safe to re-run.
#
#   git clone https://github.com/mran116/homeserver.git
#   cd homeserver
#   ./scripts/setup-fresh.sh
#
# It does:
#   1. apt update + upgrade, base utilities
#   2. Docker engine + compose plugin
#   3. Docker log rotation (so container logs can't fill the disk)
#   4. qemu-guest-agent (only if running in a VM — helps Proxmox manage it)
#   5. unattended-upgrades (automatic OS security patches)
#   6. adds your user to the docker group
#   7. runs ./bootstrap.sh
#
# It does NOT (you handle these):
#   - mount your media/data disks — do that first if they're separate drives/NAS
#   - a host firewall — do that at your router (recommended) to avoid SSH lockouts
#   - deploy stacks / fill secrets — done from Arcane after, then harvest-keys.sh
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"

command -v apt-get >/dev/null || die "This script is for Debian/Ubuntu (apt). On other distros install Docker + git manually, then run ./bootstrap.sh."

# ---- 1. system update + base utilities --------------------------------------
say "Updating apt and installing base utilities"
sudo apt-get update -y
sudo apt-get upgrade -y
# cifs-utils provides mount.cifs — needed if media lives on an SMB/CIFS NAS
# (harmless otherwise; no daemon). Avoids "unknown filesystem type 'cifs'".
# lnav: terminal log navigator — merges/searches container logs (Docker's own
# files, or Vector's ndjson tree under CONFIG_PATH/logs when the `logs` profile
# is on). It's a host CLI, not a container. cifs-utils: SMB/CIFS NAS mounts.
sudo apt-get install -y curl git ca-certificates gnupg htop vim unzip jq cifs-utils lnav

# ---- 2. Docker engine + compose plugin --------------------------------------
if ! command -v docker >/dev/null; then
  say "Installing Docker (official convenience script)"
  curl -fsSL https://get.docker.com | sudo sh
  sudo systemctl enable --now docker
else
  say "Docker already installed: $(docker --version)"
fi
docker compose version >/dev/null 2>&1 || die "Docker installed but compose plugin missing — install 'docker-compose-plugin' and re-run."

# ---- 3. Docker log rotation (containers can't fill the disk) -----------------
if [[ ! -f /etc/docker/daemon.json ]]; then
  # 20m x 5 = up to ~100MB of recent history per container — enough for lnav to
  # dig through after a crash, while still capped so logs can't fill the disk.
  say "Configuring Docker log rotation (20m x 5 files per container)"
  sudo mkdir -p /etc/docker
  printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "20m", "max-file": "5" }\n}\n' \
    | sudo tee /etc/docker/daemon.json >/dev/null
  sudo systemctl restart docker
else
  warn "/etc/docker/daemon.json already exists — left as-is (check log rotation is set there)."
fi

# ---- 4. qemu-guest-agent if this is a VM (Proxmox/etc.) ----------------------
if command -v systemd-detect-virt >/dev/null && systemd-detect-virt -q --vm; then
  say "VM detected — installing qemu-guest-agent"
  sudo apt-get install -y qemu-guest-agent
  sudo systemctl enable --now qemu-guest-agent 2>/dev/null || true
fi

# ---- 4b. free port 53 for AdGuard (optional, opt-in) ------------------------
# Fresh Ubuntu/Debian runs systemd-resolved on :53, which blocks AdGuard Home
# (infrastructure stack). Offer to free it. Default NO — it changes host DNS and
# only matters if you'll actually run AdGuard.
if command -v systemctl >/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  echo
  warn "systemd-resolved holds port 53 — AdGuard Home can't bind it until that's freed."
  if ask_yn "Disable systemd-resolved and point /etc/resolv.conf at 1.1.1.1 so AdGuard can use :53? (skip if you won't run AdGuard)" N; then
    sudo systemctl disable --now systemd-resolved
    sudo rm -f /etc/resolv.conf
    echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf >/dev/null
    say "Port 53 freed; host DNS is 1.1.1.1 for now (switch the host to AdGuard once it's up)."
  else
    warn "Left systemd-resolved running — AdGuard won't start until you free :53 (see infrastructure/docker-compose.yml)."
  fi
fi

# ---- 4c. automatic OS security patches --------------------------------------
# Keep the host patched without anyone remembering to. Installs + enables
# unattended-upgrades (security-origin updates apply daily). Auto-reboot for
# kernel updates is OFF by default (a server reboot = brief downtime); offer it
# opt-in with a 04:00 window. `hs doctor` flags when a reboot is pending.
say "Enabling automatic security updates (unattended-upgrades)"
sudo apt-get install -y unattended-upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
if ask_yn "Auto-reboot at 04:00 when a security update needs it (e.g. a kernel update)? (brief downtime; default no)" N; then
  sudo tee /etc/apt/apt.conf.d/51homestack-reboot >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
  say "Auto-reboot enabled (04:00 when required)."
else
  say "Auto-reboot left off — reboot yourself when 'hs doctor' reports one pending."
fi

# ---- 5. docker group for this user ------------------------------------------
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  say "Adding $USER to the 'docker' group"
  sudo usermod -aG docker "$USER"
fi

# ---- 6. make sure we can talk to docker, then hand off ----------------------
if ! docker info >/dev/null 2>&1; then
  echo
  warn "Docker is installed, but your shell isn't in the 'docker' group yet."
  warn "Log out and back in (or run:  newgrp docker ), then re-run:"
  warn "    ./scripts/setup-fresh.sh"
  exit 0
fi

say "Host ready — running ./bootstrap.sh"
echo
exec ./bootstrap.sh
