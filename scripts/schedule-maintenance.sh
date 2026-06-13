#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# schedule-maintenance.sh — install the low-maintenance cron jobs for THIS repo:
#
#   - nightly *arr key auto-sync (harvest-keys.sh --sync) @ 04:00 — self-heals
#     if an *arr API key changes; no-op on a normal night.
#   - SABnzbd stall watchdog (sab-watchdog.sh) every 5 min — recovers a wedged
#     SAB.  (only if this repo ships sab-watchdog.sh)
#   - Prowlarr watchdog (prowlarr-watchdog.sh) every 5 min.  (if present)
#   - storage mount watchdog (mount-watchdog.sh) every 5 min — ntfy alert / auto-
#     heal if a media/photos/docs/sync mount drops.
#   - GitOps auto-deploy (update.sh --yes) @ 03:30 daily — pulls main, reconciles
#     .env/dirs, redeploys. Opt-in via GITOPS_AUTOUPDATE in .env.
#
# MULTI-REPO SAFE: cron markers are namespaced per repo (# homestack-<ns>-<job>,
# ns = repo dir minus a trailing "stack" — mediastack→media, homestack→home), so
# several stacks on one host never clobber each other's crons. Each job installs
# ONLY if its script exists here. `docker image prune` is intentionally NOT here —
# it's host-global, run once outside the per-repo reconcile.
#
# Idempotent (keyed off marker comments). Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
# Read .env (best-effort) so we can honor the GITOPS_AUTOUPDATE toggle below.
[[ -f "$ENV_FILE" ]] && load_env 2>/dev/null || true

if ! command -v crontab >/dev/null 2>&1; then
  warn "cron not found — skipping. To automate maintenance, schedule these yourself:"
  warn "  cd $REPO_DIR && ./scripts/harvest-keys.sh --sync   (nightly)"
  exit 0
fi

# Per-repo namespace: mediastack→media, homestack→home, aistack→ai, …
ns="$(basename "$REPO_DIR")"; ns="${ns%stack}"

gitops="$(printf '%s' "${GITOPS_AUTOUPDATE:-off}" | tr '[:upper:]' '[:lower:]')"
case "$gitops" in on|true|1|yes) GITOPS_ON=1 ;; *) GITOPS_ON=0 ;; esac

# Jobs for THIS repo, namespaced + guarded on the script existing.
# Each entry: "MARKER<TAB>SCHEDULE<TAB>COMMAND"
jobs=()
add_job() { jobs+=("# homestack-${ns}-$1"$'\t'"$2"$'\t'"$3"); }
[[ -x scripts/harvest-keys.sh ]]      && add_job key-sync          "0 4 * * *"   "cd $REPO_DIR && ./scripts/harvest-keys.sh --sync >> $REPO_DIR/key-sync.log 2>&1"
[[ -x scripts/sab-watchdog.sh ]]      && add_job sab-watchdog      "*/5 * * * *" "cd $REPO_DIR && ./scripts/sab-watchdog.sh >> $REPO_DIR/sab-watchdog.log 2>&1"
[[ -x scripts/prowlarr-watchdog.sh ]] && add_job prowlarr-watchdog "*/5 * * * *" "cd $REPO_DIR && ./scripts/prowlarr-watchdog.sh >> $REPO_DIR/prowlarr-watchdog.log 2>&1"
[[ -x scripts/mount-watchdog.sh ]]    && add_job mount-watchdog    "*/5 * * * *" "cd $REPO_DIR && ./scripts/mount-watchdog.sh >> $REPO_DIR/mount-watchdog.log 2>&1"
[[ $GITOPS_ON -eq 1 && -x scripts/update.sh ]] && add_job gitops-update "30 3 * * *" "cd $REPO_DIR && ./scripts/update.sh --yes >> $REPO_DIR/update.log 2>&1"

# Every marker this repo could own (so we can cleanly strip + re-add, and remove
# a job whose script/opt-in went away).
strip_markers=(key-sync sab-watchdog prowlarr-watchdog mount-watchdog gitops-update)

cron_now="$(crontab -l 2>/dev/null || true)"

# --- build desired lines + plan ---------------------------------------------
desired=()
for j in "${jobs[@]}"; do
  IFS=$'\t' read -r mk sched cmd <<<"$j"
  line="$sched $cmd $mk"
  desired+=("$line")
  existing="$(grep -F "$mk" <<<"$cron_now" || true)"
  if   [[ -z "$existing"    ]]; then plan "add cron: ${mk#\# }"
  elif [[ "$existing" != "$line" ]]; then plan "update cron: ${mk#\# } (changed)"
  fi
done
if [[ $GITOPS_ON -eq 0 ]] && grep -qF "# homestack-${ns}-gitops-update" <<<"$cron_now"; then
  plan "remove GitOps cron (GITOPS_AUTOUPDATE not on)"
fi

# Auto-heal sudoers: let the (user-owned) mount-watchdog cron run ONLY the
# privileged recovery helper without a password (rescan + mount), so a dropped
# disk self-recovers instead of just alerting.
sudoers_ok=1
if [[ -x scripts/mount-heal-root.sh && -x scripts/mount-watchdog.sh ]]; then
  heal_user="$(id -un)"
  sudoers_file="/etc/sudoers.d/homestack-mount-heal"
  sudoers_line="$heal_user ALL=(root) NOPASSWD: $REPO_DIR/scripts/mount-heal-root.sh"
  grep -qxF "$sudoers_line" "$sudoers_file" 2>/dev/null || sudoers_ok=0
  [[ $sudoers_ok -eq 0 ]] && plan "install mount auto-heal sudoers rule ($sudoers_file) — needs sudo once"
fi

show_plan || exit 0
gate || exit 0

# --- apply ------------------------------------------------------------------
# strip all of THIS repo's markers, then re-add the desired set.
new_cron="$cron_now"
for s in "${strip_markers[@]}"; do
  new_cron="$(printf '%s\n' "$new_cron" | grep -vF "# homestack-${ns}-$s" || true)"
done
for line in "${desired[@]}"; do new_cron="$new_cron"$'\n'"$line"; done

if [[ "${sudoers_ok:-1}" -eq 0 ]]; then
  if printf '%s\n' "$sudoers_line" | sudo -n tee "$sudoers_file" >/dev/null 2>&1 \
     && sudo -n chmod 0440 "$sudoers_file" 2>/dev/null \
     && sudo -n visudo -cf "$sudoers_file" >/dev/null 2>&1; then
    say "Installed mount auto-heal sudoers rule ($sudoers_file)."
  else
    sudo -n rm -f "$sudoers_file" 2>/dev/null || true
    warn "Couldn't install the auto-heal sudoers rule without a password. Run once:"
    warn "  echo '$sudoers_line' | sudo tee $sudoers_file && sudo chmod 0440 $sudoers_file"
  fi
fi

if printf '%s\n' "$new_cron" | grep -v '^$' | crontab -; then
  say "Cron installed (namespace: $ns). Remove later with 'crontab -e' (delete the # homestack-$ns-* lines)."
else
  warn "Could not write crontab — add these yourself:"
  for line in "${desired[@]}"; do warn "  $line"; done
fi
