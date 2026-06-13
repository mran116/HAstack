#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# harvest-keys.sh
#
# Walk through every external API key / credential the stack uses and prompt
# for each one, with a direct link to the page where you find it. Writes
# values straight into .env so you never edit it by hand, then offers to
# recreate the homepage container so its widgets pick the new values up.
#
# Re-run any time. Existing values are shown and kept by default; press Enter
# to skip, type a new value to replace, or "-" to clear.
#
# Pass --force to re-prompt for keys that already have a value.
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/stacks.sh" 2>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib/stacks.sh"
source "$REPO_DIR/scripts/lib/common.sh"
source "$REPO_DIR/scripts/lib/stacks.sh" 2>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/lib/stacks.sh"

[[ -f .env ]] || { echo "No .env found. Run ./bootstrap.sh first." >&2; exit 1; }

FORCE=0; SYNC=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --sync)  SYNC=1 ;;   # non-interactive: detect *arr keys, redeploy consumers on change
  esac
done

# Keep the cron log bounded. The scheduled job redirects to key-sync.log; cap it
# at ~1 MB by truncating IN PLACE (same inode) so cron's open append-fd keeps
# working — safe, unlike a tail-to-temp+mv which would orphan that fd. Truncate
# before producing any output so this run's lines are preserved.
LOG="$REPO_DIR/key-sync.log"
if [[ $SYNC -eq 1 && -f "$LOG" && "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]]; then
  : > "$LOG"
fi

# shellcheck disable=SC1091
set -a; source .env; set +a
: "${SERVER_IP:?SERVER_IP missing from .env}"

c_b="$c_bold"; c_d="$c_dim"; c_g="$c_green"; c_y="$c_yellow"; c_r="$c_reset"

# -----------------------------------------------------------------------------
# Keys we harvest, in the order a user would naturally hit them.
# Format (pipe-separated, # for comments):
#   ENV_VAR | service URL on this server | UI path to find the value
# The URLs are display-only hints, so relax `set -u` while expanding them — a
# missing port just yields a blank URL rather than aborting (matters for --sync,
# which doesn't need ports at all).
# -----------------------------------------------------------------------------
set +u
KEYS=$(cat <<EOF
# ---- *arr stack (Settings → General → Security → API Key) ----
SONARR_API_KEY           | http://${SERVER_IP}:${SONARR_PORT}     | Settings → General → Security
RADARR_API_KEY           | http://${SERVER_IP}:${RADARR_PORT}     | Settings → General → Security
LIDARR_API_KEY           | http://${SERVER_IP}:${LIDARR_PORT}     | Settings → General → Security
WHISPARR_API_KEY         | http://${SERVER_IP}:${WHISPARR_PORT}   | Settings → General → Security
PROWLARR_API_KEY         | http://${SERVER_IP}:${PROWLARR_PORT}   | Settings → General → Security
BAZARR_API_KEY           | http://${SERVER_IP}:${BAZARR_PORT}     | Settings → General → Security
SABNZBD_API_KEY          | http://${SERVER_IP}:${SABNZBD_PORT}    | Config → General → Security

# ---- Media servers ----
JELLYFIN_API_KEY         | http://${SERVER_IP}:${JELLYFIN_PORT}   | Dashboard → API Keys → "+" (any name)
SEERR_API_KEY            | http://${SERVER_IP}:${SEERR_PORT}      | Settings → General → API Key
AUDIOBOOKSHELF_TOKEN     | http://${SERVER_IP}:${AUDIOBOOKSHELF_PORT} | Settings → Users → your user → API Token

# ---- Navidrome (token = md5(password+salt); the prompt above can compute it for you) ----
NAVIDROME_USER           | http://${SERVER_IP}:${NAVIDROME_PORT}  | Your Navidrome username
NAVIDROME_TOKEN          | http://${SERVER_IP}:${NAVIDROME_PORT}  | md5(password + salt)  — see Homepage docs
NAVIDROME_SALT           | http://${SERVER_IP}:${NAVIDROME_PORT}  | Random salt you pick (any string)

# ---- Downloader credentials ----
APP_USERNAME             | http://${SERVER_IP}:${BITTORRENT_PORT} | qBittorrent username (default: admin)
APP_PASSWORD             | http://${SERVER_IP}:${BITTORRENT_PORT} | qBittorrent password (default: adminadmin — change in WebUI)

# ---- Household ----
MEALIE_API_KEY           | http://${SERVER_IP}:${MEALIE_PORT}     | User profile (top-right) → API Tokens → Generate

# ---- Records (admin user/pass are set at install; press Enter to keep) ----
PAPERLESS_ADMIN_USER     | http://${SERVER_IP}:${PAPERLESS_PORT}  | Set in .env at install time (default: admin)
PAPERLESS_ADMIN_PASSWORD | http://${SERVER_IP}:${PAPERLESS_PORT}  | Set in .env at install time

# ---- Cloud ----
IMMICH_API_KEY           | http://${SERVER_IP}:${IMMICH_PORT}     | Account Settings → API Keys → New API Key

# ---- Notifications / external ----
TS_AUTHKEY                           | https://login.tailscale.com/admin/settings/keys | Generate a reusable auth key
CLOUDFLARE_TUNNEL_TOKEN              | https://one.dash.cloudflare.com           | Zero Trust → Networks → Tunnels → your tunnel → token
EOF
)
set -u

# -----------------------------------------------------------------------------
# update_env / current_value come from scripts/lib/common.sh — they target
# $ENV_FILE (= $REPO_DIR/.env, the same file this script operates on).

# -----------------------------------------------------------------------------
# Auto-detect *arr API keys from the config.xml each app generates on first
# boot. We only READ the file — never write app config — so this can't corrupt
# an app. config.xml is identical across Sonarr/Radarr/Lidarr/Whisparr/Prowlarr.
# Detected keys are written to .env, so the manual loop below then shows them as
# already set.
detect_arr() {
  local dir="$1" envvar="$2"
  local cfg="${CONFIG_PATH:-/opt/docker/data}/$dir/config.xml"
  [[ -f "$cfg" ]] || { printf '  %s·%s %-18s no config.xml yet (start the app first)\n' "$c_d" "$c_r" "$dir"; return 0; }
  local key
  key="$(grep -oE '<ApiKey>[^<]+</ApiKey>' "$cfg" | sed -E 's#</?ApiKey>##g' | head -n1)"
  [[ -n "$key" ]] || { printf '  %s·%s %-18s config.xml has no ApiKey yet\n' "$c_d" "$c_r" "$dir"; return 0; }
  if [[ "$(current_value "$envvar")" == "$key" ]]; then
    [[ $SYNC -eq 0 ]] && printf '  %s✓%s %-18s already in .env\n' "$c_g" "$c_r" "$envvar"
  else
    update_env "$envvar" "$key"
    CHANGED=1
    printf '  %s+%s %-18s detected from %s/config.xml\n' "$c_g" "$c_r" "$envvar" "$dir"
  fi
}

# Navidrome: its Homepage widget needs token = md5(password + salt). Navidrome
# shows no token in its UI, so the "manual" path is hand-computing an md5 — the
# #1 source of a broken Navidrome widget. Compute it here instead. The password
# is read ONCE and never stored; only username, computed token, and salt land in
# .env. Interactive only; press n to fall through to manual entry below.
navidrome_compute() {
  if [[ -n "$(current_value NAVIDROME_TOKEN)" && $FORCE -eq 0 ]]; then
    printf '  %s✓%s %-40s %s(set)%s\n' "$c_g" "$c_r" "NAVIDROME_TOKEN" "$c_d" "$c_r"
    return 0
  fi
  printf '\n%sNavidrome%s — compute the Subsonic token from your password (md5(password+salt)).\n' "$c_b" "$c_r"
  ask_yn "Compute the Navidrome token now? (password used once, never stored)" Y || return 0
  local user pass salt token
  ask "Navidrome username" "$(current_value NAVIDROME_USER)" user
  read -r -s -p "  Navidrome password (hidden): " pass || true; echo
  [[ -z "$pass" ]] && { warn "no password entered — leaving Navidrome for manual entry below"; return 0; }
  salt="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  token="$(printf '%s' "${pass}${salt}" | python3 -c 'import sys, hashlib; print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())')"
  unset pass
  update_env NAVIDROME_USER  "$user"
  update_env NAVIDROME_TOKEN "$token"
  update_env NAVIDROME_SALT  "$salt"
  CHANGED=1
  printf '  %s+%s NAVIDROME_USER / NAVIDROME_TOKEN / NAVIDROME_SALT written (token computed, password discarded)\n' "$c_g" "$c_r"
}

CHANGED=0
printf '%s\n' "${c_b}Auto-detecting *arr API keys from config.xml${c_r}"
detect_arr sonarr   SONARR_API_KEY
detect_arr radarr   RADARR_API_KEY
detect_arr lidarr   LIDARR_API_KEY
detect_arr whisparr WHISPARR_API_KEY
detect_arr prowlarr PROWLARR_API_KEY
echo

# --sync: non-interactive. If a key changed, recreate only the consumer services
# so they pick up the new value, then exit. Used by cron / a scheduler.
if [[ $SYNC -eq 1 ]]; then
  if [[ $CHANGED -eq 1 ]]; then
    printf '%s==>%s Key(s) changed — recreating consumers (unpackerr, recyclarr, homepage)\n' "$c_b$c_g" "$c_r"
    dc mediastack up -d unpackerr recyclarr 2>/dev/null || true
    dc dashboard up -d homepage 2>/dev/null           || true
  else
    printf '%s==>%s No key changes.\n' "$c_b$c_g" "$c_r"
  fi
  exit 0
fi

printf '%s\n' "${c_b}Homestack key harvester${c_r}"
printf '%s\n\n' "${c_d}Press Enter to keep current value, type new value to replace, '-' to clear.${c_r}"

navidrome_compute

# Feed the loop from fd 3, NOT stdin, so the `read` prompt below keeps reading
# from the TERMINAL. Otherwise that inner read consumes the next KEYS line as the
# user's answer — pasting hint rows into values and corrupting .env.
while IFS= read -r -u 3 line; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  IFS='|' read -r key url where <<<"$line"
  key="$(echo "$key" | xargs)"
  url="$(echo "$url" | xargs)"
  where="$(echo "$where" | xargs)"

  cur="$(current_value "$key" || true)"

  if [[ -n "$cur" && $FORCE -eq 0 ]]; then
    printf '  %s✓%s %-40s %s(set)%s\n' "$c_g" "$c_r" "$key" "$c_d" "$c_r"
    continue
  fi

  printf '\n%s%s%s\n' "$c_b" "$key" "$c_r"
  printf '  %sOpen:%s   %s\n'   "$c_y" "$c_r" "$url"
  printf '  %sLook:%s   %s\n'   "$c_y" "$c_r" "$where"
  if [[ -n "$cur" ]]; then
    printf '  %sCurrent:%s %s\n' "$c_d" "$c_r" "$cur"
  fi
  read -r -p "  > " new || true

  case "$new" in
    "")  ;;                                       # keep
    "-") update_env "$key" "";    CHANGED=1 ;;    # clear
    *)   update_env "$key" "$new"; CHANGED=1 ;;   # replace
  esac
done 3<<<"$KEYS"

# Homepage only reads HOMEPAGE_VAR_* at container creation, so newly-written keys
# don't reach its widgets until it's recreated. Offer to do it now.
if [[ $CHANGED -eq 1 ]]; then
  echo
  if ask_yn "Keys changed — recreate the homepage container now so its widgets pick them up?" Y; then
    if dc dashboard up -d homepage 2>/dev/null; then
      say "Homepage recreated — widgets will reload with the new keys."
    else
      warn "Couldn't recreate homepage — do it manually: cd dashboard && docker compose up -d homepage"
    fi
  else
    say "Skipped. Apply later with:  cd dashboard && docker compose up -d homepage   (or ./scripts/update.sh)"
  fi
fi

echo
printf '%sDone.%s Re-run with %s--force%s to revisit keys that already have a value.\n' \
  "$c_g" "$c_r" "$c_b" "$c_r"
