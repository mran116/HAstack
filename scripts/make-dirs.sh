#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# make-dirs.sh — create the directory layout and sync the Homepage config.
#
# Creates CONFIG_PATH (+ homepage), per-app config, and scratch dirs. YOUR data
# dirs (MEDIA/PHOTOS/DOCS/SYNC) are NOT auto-created — a missing one warns (NAS
# not mounted?) and is offered for creation. MIRRORS dashboard/homepage/*.yaml
# into CONFIG_PATH/homepage (the repo is
# the source of truth — edit configs in the repo, not on the box). Only copies
# when something changed; Homepage hot-reloads and its runtime logs/ are left
# untouched. Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
require_env || exit 0
load_env

# Stack-managed LOCAL dirs — safe to auto-create (they're meant to be made fresh).
stack_dirs=("$CONFIG_PATH" "$CONFIG_PATH/homepage")

# YOUR data / mount points (libraries, usually a NAS). NEVER auto-create these: if
# the NAS isn't mounted (or the path's a typo), making an empty local dir at the
# mountpoint hides your library AND sends app writes to local disk instead of the
# NAS. A missing one only WARNS (and, interactively, offers to create).
# Only the mount vars THIS repo actually defines — a media-only repo sets
# MEDIA_PATH but not PHOTOS/DOCS/SYNC, so skip any that are unset/blank (the
# repo's .env is the source of truth for which libraries it has).
external_dirs=()
for _mv in MEDIA_PATH PHOTOS_PATH DOCS_PATH SYNC_PATH; do
  [[ -n "${!_mv:-}" ]] && external_dirs+=("${!_mv}")
done

# Local fast-scratch dirs (SAB usenet incomplete, Tdarr cache). Handled best-effort
# below so a root-owned parent (e.g. /mnt) only warns — it never aborts make-dirs.
scratch_dirs=("${SAB_INCOMPLETE_PATH:-/opt/docker/incomplete}" "${TDARR_CACHE:-/opt/docker/tdarr-cache}")

# Per-app config dirs. Docker auto-creates a missing bind-mount source as
# root:root mid-`up`, which then locks out any app that runs as PUID. Derive the
# exact ${CONFIG_PATH}/* mount paths from the ACTIVE compose services (commented
# services start with '#' and are skipped) and pre-create them here — owned by
# whoever runs this, normally PUID — so that never happens. DB containers
# re-chown their own data dir on init, so this is safe for them too.
app_dirs=()
while IFS= read -r sub; do
  [[ -n "$sub" ]] && app_dirs+=("$CONFIG_PATH/$sub")
done < <(grep -rhE '^[[:space:]]*-[[:space:]]*\$\{CONFIG_PATH\}/' */docker-compose.yml \
         | grep -oE '\$\{CONFIG_PATH\}/[A-Za-z0-9._/-]+' \
         | sed 's#\${CONFIG_PATH}/##' | sort -u)

dirs=("${stack_dirs[@]}" "${app_dirs[@]}")
# Only the stack roots need a writability probe; app dirs live under CONFIG_PATH.
for d in "${stack_dirs[@]}"; do [[ -d "$d" ]] || require_writable "$d"; done
for d in "${stack_dirs[@]}"; do [[ -d "$d" ]] || plan "create dir $d"; done
for d in "${scratch_dirs[@]}"; do [[ -d "$d" ]] || plan "create scratch dir $d (PUID-owned, best-effort)"; done
# Missing data/mount dirs are NOT auto-created — warn (NAS not mounted?) + ask.
missing_external=(); for d in "${external_dirs[@]}"; do [[ -d "$d" ]] || missing_external+=("$d"); done
[[ ${#missing_external[@]} -gt 0 ]] && plan "WARN (not auto-create) missing data dir(s) — NAS not mounted?: ${missing_external[*]}"
# Only the dirs that DON'T exist yet — so a pre-existing dir (e.g. a live DB data
# dir) is never re-created or re-chowned below.
new_app_dirs=(); for d in "${app_dirs[@]}"; do [[ -d "$d" ]] || new_app_dirs+=("$d"); done
[[ ${#new_app_dirs[@]} -gt 0 ]] && plan "create ${#new_app_dirs[@]} per-app config dir(s) under $CONFIG_PATH"

# Homepage config: repo is the source of truth. Mirror ./homepage/*.{yaml,css,js}
# into CONFIG_PATH/homepage whenever anything differs (Homepage hot-reloads — incl.
# custom.css/custom.js). Its runtime logs/ live alongside and are never touched.
shopt -s nullglob
hp_all=(dashboard/homepage/*.yaml dashboard/homepage/*.css dashboard/homepage/*.js)
shopt -u nullglob
# PRIVATE, gitignored overlays (personal config kept out of the public repo).
# Neither is mirrored verbatim:
#   - bookmarks.local.yaml : its lines are APPENDED onto live bookmarks.yaml
#     (bookmarks.yaml is a top-level list, so append = add more groups).
#   - settings.local.yaml  : DEEP-MERGED onto live settings.yaml (settings is a
#     map, so a merge — not append — adds e.g. a private tab in `layout:`).
# Both survive every sync yet never enter git. Drop them from the mirror list.
hp_overlay="dashboard/homepage/bookmarks.local.yaml"
hp_set_overlay="dashboard/homepage/settings.local.yaml"
# Deep-merge helper: prints base settings with the overlay merged on top (overlay
# wins for scalars; dicts merge recursively — e.g. extra `layout` keys for a tab).
hp_merge_settings() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
base = yaml.safe_load(open(sys.argv[1])) or {}
over = yaml.safe_load(open(sys.argv[2])) or {}
def deep(a, b):
    for k, v in b.items():
        a[k] = deep(a[k], v) if isinstance(v, dict) and isinstance(a.get(k), dict) else v
    return a
yaml.safe_dump(deep(base, over), sys.stdout, sort_keys=False, allow_unicode=True)
PY
}
hp_files=()
for f in "${hp_all[@]}"; do
  case "$f" in "$hp_overlay"|"$hp_set_overlay") ;; *) hp_files+=("$f") ;; esac
done
sync_homepage=0
for f in "${hp_files[@]}"; do
  base="$(basename "$f")"
  if [[ "$base" == bookmarks.yaml && -s "$hp_overlay" ]]; then
    # live bookmarks should equal repo bookmarks + the private overlay
    cmp -s <(cat "$f" "$hp_overlay") "$CONFIG_PATH/homepage/$base" 2>/dev/null || sync_homepage=1
  elif [[ "$base" == settings.yaml && -s "$hp_set_overlay" ]]; then
    # live settings should equal repo settings deep-merged with the private overlay
    cmp -s <(hp_merge_settings "$f" "$hp_set_overlay") "$CONFIG_PATH/homepage/$base" 2>/dev/null || sync_homepage=1
  else
    cmp -s "$f" "$CONFIG_PATH/homepage/$base" 2>/dev/null || sync_homepage=1
  fi
done
[[ $sync_homepage -eq 1 ]] && plan "sync Homepage config → $CONFIG_PATH/homepage (repo is source of truth)"

show_plan || exit 0
gate || exit 0

mkdir -p "${dirs[@]}"
# chown ONLY the dirs we just created — a pre-existing dir (e.g. an existing
# database's data dir) is left exactly as its container set it, so this can never
# disturb live data. No-op when already PUID-owned; needs root otherwise, so
# best-effort. Never recursive.
if [[ -n "${PUID:-}" && -n "${PGID:-}" && ${#new_app_dirs[@]} -gt 0 ]]; then
  chown "$PUID:$PGID" "${new_app_dirs[@]}" 2>/dev/null || true
fi
# Scratch dirs (SAB usenet, Tdarr) — best-effort, NEVER abort. A root-owned parent
# (e.g. /mnt) just warns with a one-time sudo hint; the /opt/docker default works.
for d in "${scratch_dirs[@]}"; do
  [[ -d "$d" ]] && continue
  if mkdir -p "$d" 2>/dev/null; then
    [[ -n "${PUID:-}" && -n "${PGID:-}" ]] && chown "$PUID:$PGID" "$d" 2>/dev/null || true
    chmod 775 "$d" 2>/dev/null || true
  else
    warn "scratch dir not created: $d (parent not writable). Once: sudo mkdir -p '$d' && sudo chown ${PUID:-1000}:${PGID:-1000} '$d'"
  fi
done
# YOUR data dirs: never silently create. A missing one usually means a NAS isn't
# mounted — auto-creating would mask your library and send writes to local disk.
for d in "${missing_external[@]}"; do
  warn "data dir does not exist: $d"
  warn "  if it's a NAS/mount, it may not be mounted — fix that BEFORE deploying,"
  warn "  or apps write to an empty LOCAL dir instead of your library."
  if [[ $ASSUME_YES -eq 1 ]]; then
    warn "  (--yes) not creating it — create it yourself only if it's genuinely new + local."
  elif ask_yn "  Create $d anyway? (No if it's an unmounted NAS)" "n"; then
    mkdir -p "$d" && say "created $d"
    [[ -n "${PUID:-}" && -n "${PGID:-}" ]] && chown "$PUID:$PGID" "$d" 2>/dev/null || true
  else
    warn "  left uncreated."
  fi
done
if [[ $sync_homepage -eq 1 ]]; then
  cp "${hp_files[@]}" "$CONFIG_PATH/homepage/"
  # Apply the PRIVATE overlays (gitignored) so personal config persists across
  # every sync without ever entering the public repo:
  #   bookmarks.local.yaml -> APPENDED onto live bookmarks.yaml (a list)
  #   settings.local.yaml  -> DEEP-MERGED into live settings.yaml (a map; e.g. a private tab)
  [[ -s "$hp_overlay" ]] && cat "$hp_overlay" >> "$CONFIG_PATH/homepage/bookmarks.yaml"
  if [[ -s "$hp_set_overlay" ]]; then
    hp_merge_settings dashboard/homepage/settings.yaml "$hp_set_overlay" \
      > "$CONFIG_PATH/homepage/settings.yaml"
  fi
fi
say "Directory layout ready."
