#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# env-init.sh — create .env from .env.example (interactive system values).
#
# No-op if .env already exists (use env-sync.sh to add new vars, gen-secrets.sh
# to fill blank secrets). Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
require_cmd python3

if [[ -f "$ENV_FILE" ]]; then
  say "Existing .env found — keeping it as-is."
  say "(env-sync.sh adds new vars; gen-secrets.sh fills blank secrets.)"
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  say "Would create .env from .env.example and prompt for SERVER_IP / TZ / PUID / PGID / storage + SAB scratch paths."
  exit 0
fi

require_writable "$ENV_FILE"
say "Configuring .env (press Enter to accept each default)"
echo
default_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; default_ip="${default_ip:-192.168.1.100}"
default_tz="$(cat /etc/timezone 2>/dev/null || echo America/Chicago)"
default_puid="$(id -u)"; default_pgid="$(id -g)"

ask "Server LAN IP"            "$default_ip"       SERVER_IP
say "Common US timezones: America/New_York  America/Chicago  America/Denver"
say "  America/Phoenix (no DST)  America/Los_Angeles  America/Anchorage  Pacific/Honolulu"
say "  (any IANA name works — full list: timedatectl list-timezones)"
ask "Timezone (TZ format)"     "$default_tz"       TZ
ask "PUID (user id)"           "$default_puid"     PUID
ask "PGID (group id)"          "$default_pgid"     PGID
echo
say "Storage paths (created later by make-dirs.sh)"
say "  CONFIG_PATH holds app config + databases — MUST be LOCAL disk (DBs corrupt on a NAS)."
ask "Config / bind-mount root" "/opt/docker/data"  CONFIG_PATH
ask "Media library root"       "/mnt/media"        MEDIA_PATH
ask "Photos library root"      "/mnt/photos"       PHOTOS_PATH
ask "Documents library root"   "/mnt/documents"    DOCS_PATH
echo
say "SABnzbd scratch — incomplete downloads + par2 verify/repair + unpack. Keep on"
say "a FAST LOCAL disk (SSD/NVMe), NOT the NAS — that work stalls over a network"
say "mount. RECOMMENDED: /opt/docker/incomplete (local SSD); or under the data dir,"
say "e.g. $CONFIG_PATH/incomplete. (Torrents stay on the NAS — this is usenet-only.)"
ask "SABnzbd incomplete/scratch path (recommended: local SSD)"  "/opt/docker/incomplete"  SAB_INCOMPLETE_PATH

# Guard: CONFIG + scratch must live on LOCAL disk. findmnt resolves the nearest
# existing ancestor, so this catches a NAS path even before the dir is created.
guard_local() {
  command -v findmnt >/dev/null || return 0
  local ft; ft="$(findmnt -n -o FSTYPE --target "$1" 2>/dev/null || true)"
  case "$ft" in nfs*|cifs|smb*)
    warn "$2 ($1) is on a '$ft' mount — use LOCAL disk; DBs/scratch corrupt or stall on a network share" ;;
  esac
}
guard_local "$CONFIG_PATH"     "CONFIG_PATH"
guard_local "$SAB_INCOMPLETE_PATH" "SAB_INCOMPLETE_PATH"

echo
plan "create .env from .env.example"
plan "SERVER_IP=$SERVER_IP  TZ=$TZ  PUID=$PUID  PGID=$PGID"
plan "CONFIG_PATH=$CONFIG_PATH  MEDIA_PATH=$MEDIA_PATH  PHOTOS_PATH=$PHOTOS_PATH  DOCS_PATH=$DOCS_PATH"
plan "SAB_INCOMPLETE_PATH=$SAB_INCOMPLETE_PATH"
show_plan || exit 0
gate || exit 0

cp .env.example "$ENV_FILE"
python3 - "$SERVER_IP" "$TZ" "$PUID" "$PGID" "$CONFIG_PATH" "$MEDIA_PATH" "$PHOTOS_PATH" "$DOCS_PATH" "$SAB_INCOMPLETE_PATH" "$ENV_FILE" <<'PY'
import sys, re, pathlib
ip, tz, puid, pgid, cfg, media, photos, docs, incomplete, path = sys.argv[1:]
p = pathlib.Path(path)
text = p.read_text()
subs = {"SERVER_IP": ip, "TZ": tz, "PUID": puid, "PGID": pgid,
        "CONFIG_PATH": cfg, "MEDIA_PATH": media, "PHOTOS_PATH": photos, "DOCS_PATH": docs,
        "SAB_INCOMPLETE_PATH": incomplete}
for k, v in subs.items():
    text = re.sub(rf"(?m)^{k}=.*$", f"{k}={v}", text, count=1)
p.write_text(text)
PY
say "Wrote $ENV_FILE"
