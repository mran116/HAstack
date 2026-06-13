#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# diagnose.sh — deep root-cause analysis for the mediastack ecosystem.
#
# Where doctor.sh is fast triage ("is anything red?"), diagnose goes deep on
# ONE subsystem at a time, hits APIs, scans logs in detail, and prints the
# specific commands to fix what it finds.
#
# Run this when doctor or your gut says something's off.  Subcommands are
# read-only; nothing is changed automatically.
#
# Usage:
#   ./scripts/diagnose.sh                    # list available subcommands
#   ./scripts/diagnose.sh decluttarr         # connections, queue health, recent activity
#   ./scripts/diagnose.sh sonarr             # CF integrity, profile drift, queue patterns
#   ./scripts/diagnose.sh radarr             # same but movies
#   ./scripts/diagnose.sh recyclarr          # sync log + drift between yaml and live
#   ./scripts/diagnose.sh qbit               # IP ban list, whitelist drift
#   ./scripts/diagnose.sh all                # run every subcommand
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR" || exit 1
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Local rendering helpers (lighter than say/warn/die — diagnose is meant to
# print a lot).  We bump the noise floor since this script is verbose by design.
hdr()      { printf '\n%s== %s ==%s\n' "$c_bold" "$*" "$c_reset"; }
sub()      { printf '\n%s-- %s --%s\n' "$c_dim" "$*" "$c_reset"; }
ok_line()  { printf '  %s✓%s %s\n' "$c_green"  "$c_reset" "$*"; }
bad_line() { printf '  %s✗%s %s\n' "$c_red"    "$c_reset" "$*"; }
note_line(){ printf '  %s!%s %s\n' "$c_yellow" "$c_reset" "$*"; }
fix()      { printf '    %sfix:%s %s\n' "$c_bold$c_green" "$c_reset" "$*"; }
kv()       { printf '    %s%-18s%s %s\n' "$c_dim" "$1:" "$c_reset" "$2"; }

# Load .env so API keys + URLs are available.
if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$REPO_DIR/.env"; set +a
fi

usage() {
  cat <<'EOF'
Usage: diagnose.sh <subcommand>

Subcommands:
  decluttarr    instance connections, queue patterns, removals/skips
  sonarr        CF score integrity, profile assignments, language filter, importBlocked breakdown
  radarr        same as sonarr but movies
  recyclarr     last sync result + drift between recyclarr.yml and Sonarr/Radarr
  qbit          IP ban status, whitelist current vs expected
  all           run every subcommand
  -h, --help    this help
EOF
}

# -----------------------------------------------------------------------------
# Tiny *arr API helper (uses host-mapped ports so we don't depend on the docker
# network).  Run from inside a python heredoc; called as `arr_api SERVICE PATH`.
# -----------------------------------------------------------------------------
arr_python() {
  # Args: SERVICE_NAME (sonarr/radarr/lidarr/whisparr) - then python script on stdin
  local svc="$1"; shift
  local var="${svc^^}_API_KEY"; local port="${svc^^}_PORT"
  local key="${!var:-}"; local p="${!port:-}"
  if [[ -z "$key" || -z "$p" || -z "${SERVER_IP:-}" ]]; then
    note_line "missing env: SERVER_IP=$SERVER_IP / ${svc^^}_PORT=$p / ${svc^^}_API_KEY=$([ -n "$key" ] && echo set || echo MISSING)"
    return 1
  fi
  BASE_URL="http://${SERVER_IP}:${p}/api/v3" API_KEY="$key" python3 -
}

# -----------------------------------------------------------------------------
# decluttarr
# -----------------------------------------------------------------------------
diag_decluttarr() {
  hdr "decluttarr"
  if ! docker ps --format '{{.Names}}' | grep -qx decluttarr; then
    bad_line "container not running"
    fix "cd mediastack && docker compose up -d decluttarr"
    return
  fi
  ok_line "container is up"

  sub "Last 'Checking Instances' result (within 30min)"
  local last_check
  last_check="$(docker logs --since 30m decluttarr 2>&1 \
                | awk '/\*\*\* Checking Instances \*\*\*/{out=""; capture=1; next}
                       capture && /^\s*INFO  +\| OK \| / {out = out $0 ORS; next}
                       capture && /^ERROR  +\| -- / {out = out $0 ORS; next}
                       # Only end the capture when a NEW cycle starts (Running jobs / Termination).
                       # Other INFO lines (tips, "Enabling X", separators) are skipped, not terminators.
                       capture && /\*\*\* Running jobs|Termination signal/ {capture=0}
                       END {printf "%s", out}')"
  if [[ -z "$last_check" ]]; then
    # Fallback: pull a larger window from logs (decluttarr may have last cycled
    # before the 30-min docker-logs window if it just restarted).
    last_check="$(docker logs decluttarr 2>&1 \
                  | awk '/\*\*\* Checking Instances \*\*\*/{out=""; capture=1; next}
                         capture && /^\s*INFO  +\| OK \| / {out = out $0 ORS; next}
                         capture && /^ERROR  +\| -- / {out = out $0 ORS; next}
                         capture && /\*\*\* Running jobs|Termination signal/ {capture=0}
                         END {printf "%s", out}')"
  fi
  if [[ -z "$last_check" ]]; then
    note_line "no Checking Instances block found — has decluttarr cycled at all?"
    local timer_val
    timer_val="$(awk '/^  timer:/{gsub(/#.*/, ""); gsub(/[^0-9]/, ""); print; exit}' mediastack/decluttarr/config.yaml)"
    kv "timer (cycle)" "${timer_val:-?}m"
    fix "docker logs decluttarr --tail 200"
  else
    printf '%s\n' "$last_check" | sed 's/^/    /'
    local err ok
    err=$(printf '%s\n' "$last_check" | grep -cE '^ERROR  +\| --' || true)
    ok=$( printf '%s\n' "$last_check" | grep -cE '^\s*INFO  +\| OK \|' || true)
    [[ "$err" -gt 0 ]] && bad_line "$err instance(s) failed connection ($ok OK)" \
                       || ok_line "$ok instance(s) connected"
  fi

  sub "Most recent 'triggered removal' events (in test_run logging)"
  local removals
  removals="$(docker logs --since 24h decluttarr 2>&1 | grep -E "triggered removal:" | tail -10)"
  if [[ -z "$removals" ]]; then
    ok_line "no removals in last 24h"
  else
    printf '%s\n' "$removals" | sed 's/^/    /'
    kv "test_run" "$(awk '/^  test_run:/{print $2; exit}' mediastack/decluttarr/config.yaml | tr -d ' ')"
  fi

  sub "Recent errors (last 24h)"
  local errs
  errs="$(docker logs --since 24h decluttarr 2>&1 | grep -E "^ERROR" | sort -u | head -10)"
  if [[ -z "$errs" ]]; then
    ok_line "no errors"
  else
    printf '%s\n' "$errs" | sed 's/^/    /'
  fi
}

# -----------------------------------------------------------------------------
# sonarr / radarr — shared logic
# -----------------------------------------------------------------------------
diag_arr() {
  # CF_ID / CF_NAME / CF_EXPECTED_SCORE reach the embedded Python via env vars
  # the callers set inline (see diag_sonarr/diag_radarr), so they aren't params.
  local svc="$1" expected_profile="$2" items_endpoint="$3"
  hdr "$svc"
  if ! docker ps --format '{{.Names}}' | grep -qx "$svc"; then
    bad_line "container not running"; return
  fi
  ok_line "container is up"

  sub "Quality profile integrity"
  arr_python "$svc" <<'PY' || return
import os, json, urllib.request, sys
base, key = os.environ['BASE_URL'], os.environ['API_KEY']
import urllib.parse
def api(p): return json.load(urllib.request.urlopen(urllib.request.Request(f'{base}{p}', headers={'X-Api-Key': key}), timeout=15))

# (Outer bash passes these via env when called; we just report)
expected_profile = os.environ.get('EXPECTED_PROFILE')
cf_id   = os.environ.get('CF_ID')
cf_name = os.environ.get('CF_NAME')
cf_score = int(os.environ.get('CF_EXPECTED_SCORE', '0'))

qps = api('/qualityprofile')
p = next((q for q in qps if q['name'] == expected_profile), None)
if not p:
    print(f'    ✗ expected profile "{expected_profile}" NOT FOUND in {len(qps)} profiles')
    print(f'      available: {[q["name"] for q in qps]}')
    print(f'      fix:  docker exec recyclarr recyclarr sync')
    sys.exit(0)

if cf_id:
    formats = p.get('formatItems') or []
    hit = next((f for f in formats if f.get('name') == cf_name), None)
    if not hit:
        print(f'    ! CF "{cf_name}" not found on profile')
    else:
        score = hit.get('score', 0)
        if score == cf_score:
            print(f'    ✓ CF "{cf_name}" score = {score} (expected)')
        else:
            print(f'    ✗ CF "{cf_name}" score = {score} (expected {cf_score})')
            print(f'      fix:  docker exec recyclarr recyclarr sync   (or check recyclarr.yml)')
else:
    print('    (no language CF expected — profile.language handles it for this service)')

# Show language setting on profile
lang = (p.get('language') or {}).get('name')
print(f'    profile language: {lang or "(not set — Sonarr v4 uses CFs instead)"}')
print(f'    min_format_score: {p.get("minFormatScore")} (anything below this is rejected)')
PY

  sub "Items on the recyclarr-managed profile"
  EXPECTED_PROFILE="$expected_profile" ITEMS_ENDPOINT="$items_endpoint" arr_python "$svc" <<'PY' || return
import os, json, urllib.request
base, key = os.environ['BASE_URL'], os.environ['API_KEY']
def api(p): return json.load(urllib.request.urlopen(urllib.request.Request(f'{base}{p}', headers={'X-Api-Key': key}), timeout=20))

qps = api('/qualityprofile')
p = next((q for q in qps if q['name'] == os.environ['EXPECTED_PROFILE']), None)
if not p:
    print('    ! profile not found — skipping')
    raise SystemExit
target_id = p['id']

items = api(os.environ['ITEMS_ENDPOINT'])
on  = [i for i in items if i.get('qualityProfileId') == target_id]
off = [i for i in items if i.get('qualityProfileId') != target_id]
print(f'    on {os.environ["EXPECTED_PROFILE"]}: {len(on)} / {len(items)}')
if off:
    print(f'    ✗ {len(off)} item(s) NOT on the right profile (sample):')
    for it in off[:5]:
        print(f'        [{it.get("qualityProfileId")}] {it.get("title", it.get("name", "?"))[:60]}')
    print(f'      fix:  ./scripts/seed-arr-quality.sh --yes')
PY

  sub "Queue health (importBlocked / failed)"
  arr_python "$svc" <<'PY' || return
import os, json, urllib.request, collections
base, key = os.environ['BASE_URL'], os.environ['API_KEY']
def api(p): return json.load(urllib.request.urlopen(urllib.request.Request(f'{base}{p}', headers={'X-Api-Key': key}), timeout=20))

q = api('/queue?pageSize=200')
records = q.get('records', [])
print(f'    queue items: {len(records)}')

blocked = [r for r in records if r.get('trackedDownloadState') == 'importBlocked']
failed  = [r for r in records if r.get('status') == 'failed']
print(f'    importBlocked: {len(blocked)}')
print(f'    failed:        {len(failed)}')

if blocked:
    # Cluster by error message
    msgs = collections.Counter()
    for r in blocked:
        for sm in (r.get('statusMessages') or []):
            for m in (sm.get('messages') or []):
                msgs[m[:80]] += 1
    print('    blocked reason breakdown:')
    for m, c in msgs.most_common(5):
        print(f'      {c:>3} × {m}')
    print(f'    fix:  sample: ./scripts/sonarr-clear-queue.sh  (or use Sonarr UI manual import)')
PY
}

diag_sonarr() {
  EXPECTED_PROFILE="WEB-1080p"  CF_ID="69aa1e159f97d860440b04cd6d590c4f"  CF_NAME="Language: Not English"  CF_EXPECTED_SCORE="-10000" \
    diag_arr sonarr "WEB-1080p" "/series"
}
diag_radarr() {
  EXPECTED_PROFILE="WEB-Only"  CF_ID=""  CF_NAME=""  CF_EXPECTED_SCORE="0" \
    diag_arr radarr "WEB-Only" "/movie"
}

# -----------------------------------------------------------------------------
# recyclarr
# -----------------------------------------------------------------------------
diag_recyclarr() {
  hdr "recyclarr"
  if ! docker ps --format '{{.Names}}' | grep -qx recyclarr; then
    bad_line "container not running"; return
  fi
  ok_line "container is up"

  local cfg_path="${CONFIG_PATH:-/opt/docker/data}"
  local logdir="$cfg_path/recyclarr/logs/cli"

  sub "Last 3 sync results"
  if [[ ! -d "$logdir" ]]; then
    note_line "log dir missing — has it ever run?"; return
  fi
  for f in $(ls -t "$logdir"/*.log 2>/dev/null | head -3); do
    if grep -q '^\[.*ERR\]' "$f" 2>/dev/null; then
      bad_line "$(basename "$f"): FAILED"
      local errln
      errln="$(grep -m1 '^\[.*ERR\]' "$f" | sed 's/.*ERR\] //; s/^[[:space:]]*//' | head -c 160)"
      echo "      $errln"
    else
      ok_line "$(basename "$f"): clean"
    fi
  done

  sub "Live config preview (would recyclarr.yml apply cleanly right now?)"
  docker exec recyclarr recyclarr sync --preview 2>&1 \
    | grep -vE "^\[INF\] Initializing provider|^\[INF\] Loading|^\s*$" \
    | head -30 | sed 's/^/    /'
}

# -----------------------------------------------------------------------------
# qbit
# -----------------------------------------------------------------------------
diag_qbit() {
  hdr "qbittorrent"
  if ! docker ps --format '{{.Names}}' | grep -qx qbittorrent; then
    bad_line "container not running"; return
  fi
  ok_line "container is up"

  local cfg="${CONFIG_PATH:-/opt/docker/data}/qbittorrent/qBittorrent/qBittorrent.conf"
  if [[ ! -f "$cfg" ]]; then
    bad_line "config file missing: $cfg"; return
  fi

  sub "Auth whitelist (vs docker 'home' subnet)"
  local home_subnet wl_enabled wl_list
  home_subnet="$(docker network inspect home --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  wl_enabled="$(grep -F -m1 'WebUI\AuthSubnetWhitelistEnabled=' "$cfg" 2>/dev/null | cut -d= -f2-)"
  wl_list="$(grep    -F -m1 'WebUI\AuthSubnetWhitelist='        "$cfg" 2>/dev/null | cut -d= -f2-)"
  kv "home subnet"     "$home_subnet"
  kv "whitelist on"    "${wl_enabled:-unset}"
  kv "whitelist list"  "${wl_list:-unset}"
  if [[ "$wl_enabled" == "true" && "$wl_list" == *"$home_subnet"* ]]; then
    ok_line "whitelist includes home subnet"
  else
    bad_line "whitelist drift"
    fix "./scripts/patch-qbit-auth.sh --yes"
  fi

  sub "Recent 403 events in qBit log (last 30min)"
  local sab_403
  sab_403="$(docker logs --since 30m qbittorrent 2>&1 | grep -iE "403|forbidden|banned" | tail -10)"
  if [[ -z "$sab_403" ]]; then
    ok_line "no 403/ban events"
  else
    printf '%s\n' "$sab_403" | sed 's/^/    /'
    note_line "see above — may indicate a client with wrong credentials retrying"
  fi
}

# -----------------------------------------------------------------------------
# dispatch — only runs when this file is the entry point.  When doctor.sh
# `source`s us for auto-escalation, the dispatch is skipped (library mode).
# -----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_common_flags "$@"
  SUB="${1:-}"
  case "$SUB" in
    decluttarr) diag_decluttarr ;;
    sonarr)     diag_sonarr ;;
    radarr)     diag_radarr ;;
    recyclarr)  diag_recyclarr ;;
    qbit|qbittorrent) diag_qbit ;;
    all)
      diag_recyclarr
      diag_decluttarr
      diag_sonarr
      diag_radarr
      diag_qbit
      ;;
    -h|--help|"") usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
fi
