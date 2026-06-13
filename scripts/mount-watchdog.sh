#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# mount-watchdog.sh — detect, AUTO-HEAL, and alert when a storage mount drops.
#
# A storage disk/NAS can detach (a passthrough disk dropping its link, an NFS
# share going away). Because mounts use `nofail`, the box boots fine but the
# mount point sits EMPTY — and apps fail SILENTLY (*arr "root folder doesn't
# exist", Jellyfin playback hangs). This catches that, tries to recover (SCSI
# rescan + `mount -a`), restarts the stacks that bind the path so they re-bind
# the now-populated mount, and pushes a phone alert either way.
#
# Watches every storage path from .env (MEDIA/PHOTOS/DOCS/SYNC). On recovery it
# restarts the stacks that DECLARE that mount in their `<stack>/stack.conf`
# (`MOUNTS="MEDIA"`) — discovered, not hardcoded. So it adapts to any layout and
# finds dependent stacks across repos (STACK_ROOTS) with zero config.
#
#   hs mounts        (or sudo ./scripts/mount-watchdog.sh  to allow auto-heal)
# Flags: --dry-run (report only). --no-heal (alert, don't repair).
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/stacks.sh
source "$SCRIPT_DIR/lib/stacks.sh"
cd "$REPO_DIR" || exit 1
parse_common_flags "$@"
require_env || exit 0
load_env

TOPIC="${NTFY_TOPIC:-diun-updates}"
STATE_DIR="${CONFIG_PATH:-/opt/docker/data}/.mount-watchdog"
mkdir -p "$STATE_DIR" 2>/dev/null || { STATE_DIR="/tmp/.mount-watchdog"; mkdir -p "$STATE_DIR"; }

HEAL=1
for a in "$@"; do [[ "$a" == "--no-heal" ]] && HEAL=0; done
[[ "${DRY_RUN:-0}" -eq 1 ]] && HEAL=0

is_present() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$path" 2>/dev/null && return 0
  [[ -n "$(ls -A "$path" 2>/dev/null)" ]] && return 0
  return 1
}

healed_this_run=0
attempt_remount() {
  [[ $healed_this_run -eq 1 ]] && return 0
  healed_this_run=1
  say "auto-heal: SCSI rescan + mount -a (via mount-heal-root.sh)"
  if [[ "$(id -u)" -eq 0 ]]; then
    "$SCRIPT_DIR/mount-heal-root.sh" || true
  elif command -v sudo >/dev/null 2>&1 && sudo -n "$SCRIPT_DIR/mount-heal-root.sh" 2>/dev/null; then
    :
  else
    warn "auto-heal needs root: install the sudoers rule (run 'sudo hs cron' once). Falling back to alert-only."
  fi
}

# Restart every stack that DECLARES this mount (MOUNTS= in its stack.conf), across
# all roots. Returns the space-separated list it restarted (for the alert text).
restart_dependents() {
  local mount="$1" s did=""
  command -v docker >/dev/null 2>&1 || { echo ""; return 0; }
  for s in $(stacks_for_mount "$mount"); do
    say "auto-heal: restarting $s so it re-binds the remounted volume"
    dc "$s" restart >/dev/null 2>&1 || true
    did+="$s "
  done
  echo "${did% }"
}

notify() { [[ "${DRY_RUN:-0}" -eq 1 ]] && return 0; "$SCRIPT_DIR/notify.sh" "$@" >/dev/null 2>&1 || true; }

alerts=0
check() {  # check NAME PATH
  local name="$1" path="$2" flag seen restarted
  [[ -z "$path" ]] && return 0
  flag="$STATE_DIR/${name}.down"; seen="$STATE_DIR/${name}.seen"

  if is_present "$path"; then
    : > "$seen"
    if [[ -f "$flag" ]]; then
      say "$name recovered: $path"
      notify "$TOPIC" "✅ Storage recovered: $name" "$path is back."
      rm -f "$flag"
    fi
    return 0
  fi
  [[ -f "$seen" ]] || return 0

  if [[ $HEAL -eq 1 ]]; then
    attempt_remount
    if is_present "$path"; then
      : > "$seen"
      restarted="$(restart_dependents "$name")"
      say "$name AUTO-RECOVERED: $path"
      notify "$TOPIC" "🔧 Storage auto-recovered: $name" \
        "$path had dropped (likely a disk link reset); a SCSI rescan + remount brought it back and restarted: ${restarted:-<no dependent stacks declared>}. If this recurs, fix the disk power-management on the host."
      rm -f "$flag"
      return 0
    fi
  fi

  if [[ ! -f "$flag" ]]; then
    warn "$name OFFLINE: $path — was populated before, now empty/not mounted"
    if [[ $HEAL -eq 1 ]]; then
      notify "$TOPIC" "⚠️ Storage offline: $name" \
        "$path dropped and AUTO-RECOVERY did NOT bring it back — likely detached at the host/Proxmox level. Apps using it will fail. Manual fix needed."
    else
      notify "$TOPIC" "⚠️ Storage offline: $name" \
        "$path was populated before and is now empty / not mounted. Apps will fail (*arr 'root folder doesn't exist'). Run 'sudo hs mounts' to auto-recover."
    fi
    : > "$flag"; alerts=$((alerts + 1))
  fi
}

check MEDIA  "${MEDIA_PATH:-}"
check PHOTOS "${PHOTOS_PATH:-}"
check DOCS   "${DOCS_PATH:-}"
check SYNC   "${SYNC_PATH:-}"

[[ $alerts -eq 0 ]] && say "all storage mounts present"
exit 0
