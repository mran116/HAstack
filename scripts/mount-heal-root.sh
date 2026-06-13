#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# mount-heal-root.sh — privileged recovery for a dropped storage disk.
#
# Does exactly two things, both needing root: re-scan the SCSI bus (re-attaches a
# disk whose SATA/SCSI link dropped — the fix for the recurring media-disk drop)
# and `mount -a` (mount whatever fstab says, e.g. /mnt/disk1 + the mergerfs pool).
#
# Deliberately tiny and root-only so a single sudoers rule can grant the
# mount-watchdog exactly this — no broader privilege. The watchdog calls it via
# `sudo -n` when it detects a previously-healthy mount has dropped.
# =============================================================================
set -uo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "mount-heal-root.sh must run as root" >&2; exit 1; }

# Re-scan every SCSI host so a disk that dropped its link re-enumerates.
for h in /sys/class/scsi_host/host*/scan; do
  [[ -w "$h" ]] && echo "- - -" > "$h" 2>/dev/null || true
done
sleep 2
# Mount everything in fstab that isn't already mounted (nofail entries included).
mount -a
