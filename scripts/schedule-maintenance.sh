#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# schedule-maintenance.sh — install the low-maintenance cron jobs:
#
#   - nightly *arr key auto-sync (harvest-keys.sh --sync) @ 04:00 — self-heals
#     if an *arr API key changes; no-op on a normal night.
#   - weekly `docker image prune -af` @ Sun 05:00 — reclaims unused images
#     (never containers, volumes, or your bind-mounted data).
#   - SABnzbd stall watchdog (sab-watchdog.sh) every 5 min — recovers a wedged
#     SAB (pause/resume, then container restart as a last resort).
#   - storage mount watchdog (mount-watchdog.sh) every 5 min — ntfy alert if a
#     media/photos/docs/sync mount drops offline (so a detached disk/NAS doesn't
#     fail apps silently).
#   - GitOps auto-deploy (update.sh --yes) @ 03:30 daily — pulls main, reconciles
#     .env/dirs, and redeploys, so a merge to main ships itself (Arcane optional).
#     Opt-in: only installed when GITOPS_AUTOUPDATE is on in .env (default on in
#     the template). update.sh validates every compose before redeploying and is
#     DB-safe, so a broken commit can't deploy.
#
# Idempotent (keyed off marker comments). Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
# Read .env (best-effort) so we can honor the GITOPS_AUTOUPDATE toggle below.
[[ -f "$ENV_FILE" ]] && load_env 2>/dev/null || true

if ! command -v crontab >/dev/null 2>&1; then
  warn "cron not found — skipping. To automate maintenance, schedule these yourself:"
  warn "  cd $REPO_DIR && ./scripts/harvest-keys.sh --sync   (nightly)"
  warn "  docker image prune -af                             (weekly)"
  exit 0
fi

ks_marker="# homestack-key-sync"
ks_line="0 4 * * * cd $REPO_DIR && ./scripts/harvest-keys.sh --sync >> $REPO_DIR/key-sync.log 2>&1 $ks_marker"
pr_marker="# homestack-image-prune"
pr_line="0 5 * * 0 docker image prune -af >> $REPO_DIR/image-prune.log 2>&1 $pr_marker"
sw_marker="# homestack-sab-watchdog"
sw_line="*/5 * * * * cd $REPO_DIR && ./scripts/sab-watchdog.sh >> $REPO_DIR/sab-watchdog.log 2>&1 $sw_marker"
mw_marker="# homestack-mount-watchdog"
mw_line="*/5 * * * * cd $REPO_DIR && ./scripts/mount-watchdog.sh >> $REPO_DIR/mount-watchdog.log 2>&1 $mw_marker"
# GitOps auto-deploy — opt-in via GITOPS_AUTOUPDATE (on|true|1|yes).
up_marker="# homestack-gitops-update"
up_line="30 3 * * * cd $REPO_DIR && ./scripts/update.sh --yes >> $REPO_DIR/update.log 2>&1 $up_marker"
gitops="$(printf '%s' "${GITOPS_AUTOUPDATE:-off}" | tr '[:upper:]' '[:lower:]')"
case "$gitops" in on|true|1|yes) GITOPS_ON=1 ;; *) GITOPS_ON=0 ;; esac

cron_now="$(crontab -l 2>/dev/null || true)"
# Reconcile each managed line to EXACTLY match the repo. The drift fix: re-apply
# a line when the existing one DIFFERS (repo changed), not only when its marker
# is missing — so an improved schedule/command actually reaches the box.
plan_line() {  # plan_line MARKER DESIRED_LINE DESCRIPTION
  local existing; existing="$(grep -F "$1" <<<"$cron_now" || true)"
  if   [[ -z "$existing"   ]]; then plan "add $3"
  elif [[ "$existing" != "$2" ]]; then plan "update $3 (repo changed)"
  fi
}
plan_line "$ks_marker" "$ks_line" "nightly *arr key-sync cron (04:00) → key-sync.log"
plan_line "$pr_marker" "$pr_line" "weekly image-prune cron (Sun 05:00) → image-prune.log"
plan_line "$sw_marker" "$sw_line" "SABnzbd stall watchdog cron (every 5 min) → sab-watchdog.log"
plan_line "$mw_marker" "$mw_line" "storage mount watchdog cron (every 5 min) → mount-watchdog.log"
# Auto-heal sudoers: let the (user-owned) mount-watchdog cron run ONLY the
# privileged recovery helper (rescan + mount) without a password, so a dropped
# disk self-recovers instead of just alerting.
heal_user="$(id -un)"
sudoers_file="/etc/sudoers.d/homestack-mount-heal"
sudoers_line="$heal_user ALL=(root) NOPASSWD: $REPO_DIR/scripts/mount-heal-root.sh"
sudoers_ok=0
grep -qxF "$sudoers_line" "$sudoers_file" 2>/dev/null && sudoers_ok=1
[[ $sudoers_ok -eq 0 ]] && plan "install mount auto-heal sudoers rule ($sudoers_file) — needs sudo once"
if [[ $GITOPS_ON -eq 1 ]]; then
  plan_line "$up_marker" "$up_line" "GitOps auto-deploy cron (daily 03:30, hs update) → update.log"
elif grep -qF "$up_marker" <<<"$cron_now"; then
  plan "remove GitOps auto-deploy cron (GITOPS_AUTOUPDATE not on)"
fi

show_plan || exit 0
gate || exit 0

new_cron="$( { printf '%s\n' "$cron_now" | grep -vF "$ks_marker" | grep -vF "$pr_marker" | grep -vF "$sw_marker" | grep -vF "$mw_marker" | grep -vF "$up_marker"; echo "$ks_line"; echo "$pr_line"; echo "$sw_line"; echo "$mw_line"; [[ $GITOPS_ON -eq 1 ]] && echo "$up_line"; } )"
if [[ $sudoers_ok -eq 0 ]]; then
  if printf '%s\n' "$sudoers_line" | sudo -n tee "$sudoers_file" >/dev/null 2>&1 \
     && sudo -n chmod 0440 "$sudoers_file" 2>/dev/null \
     && sudo -n visudo -cf "$sudoers_file" >/dev/null 2>&1; then
    say "Installed mount auto-heal sudoers rule ($sudoers_file)."
  else
    sudo -n rm -f "$sudoers_file" 2>/dev/null || true   # don't leave a half/invalid file
    warn "Couldn't install the auto-heal sudoers rule without a password. Run once:"
    warn "  echo '$sudoers_line' | sudo tee $sudoers_file && sudo chmod 0440 $sudoers_file"
    warn "(Until then, mount-watchdog ALERTS on a disk drop but won't auto-recover.)"
  fi
fi

if printf '%s\n' "$new_cron" | crontab -; then
  say "Cron installed. Remove later with 'crontab -e' (delete the homestack-* lines)."
else
  warn "Could not write crontab — add these yourself:"
  warn "  $ks_line"
  warn "  $pr_line"
  warn "  $sw_line"
  warn "  $mw_line"
  [[ $GITOPS_ON -eq 1 ]] && warn "  $up_line"
fi
