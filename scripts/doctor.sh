#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# doctor.sh — read-only health check. Changes nothing; tells you what's wrong.
#
# Checks: docker daemon + compose, the `home` network, container health
# (restarting / unhealthy / stopped), .env present and in sync with
# .env.example, storage paths (exist, MEDIA_PATH actually mounted, CONFIG_PATH on
# local disk), per-stack .env symlinks, STACKS_PATH, every compose file
# validates, blank vars referenced by ACTIVE services, and the port-53 conflict.
#
# Exit: non-zero if any hard FAIL (handy as a pre-deploy gate). Flags: none.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR" || exit 1

FAILS=0; WARNS=0
ok()   { printf '  %s✓%s %s\n' "$c_green"  "$c_reset" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red"    "$c_reset" "$*"; FAILS=$((FAILS+1)); }
note() { printf '  %s!%s %s\n' "$c_yellow" "$c_reset" "$*"; WARNS=$((WARNS+1)); }
have_daemon=0

# Interactive = stdout is a TTY AND user didn't pass --quick.  When interactive,
# any failed check auto-escalates to the matching `hs diagnose <area>` block so
# the user gets the deep dive in one go.  When scripted (bootstrap, update,
# cron), stays terse and just reports.
QUICK=0; for a in "$@"; do [[ "$a" == "--quick" || "$a" == "-q" ]] && QUICK=1; done
is_interactive() { [[ -t 1 ]] && [[ "$QUICK" -ne 1 ]]; }
# Source diagnose.sh in library mode so we can call its diag_* functions.
# Suppress its dispatch by checking BASH_SOURCE != $0 inside diagnose.sh.
# shellcheck source=scripts/diagnose.sh disable=SC1091
[[ -f "$SCRIPT_DIR/diagnose.sh" ]] && source "$SCRIPT_DIR/diagnose.sh"
escalate() {
  # escalate FUNCNAME — call diag_<area> only when interactive.
  is_interactive && declare -F "$1" >/dev/null 2>&1 && "$1"
}

say "Docker"
if ! command -v docker >/dev/null; then bad "docker not installed"
else
  docker compose version >/dev/null 2>&1 && ok "docker compose v2 present" || bad "docker compose v2 missing"
  if docker info >/dev/null 2>&1; then have_daemon=1; ok "docker daemon reachable"
  else note "docker daemon not reachable (not in 'docker' group? network checks skipped)"; fi
fi

if [[ $have_daemon -eq 1 ]]; then
  say "Network"
  docker network inspect home >/dev/null 2>&1 && ok "'home' network exists" \
    || bad "'home' network missing — run 'hs network'"

  say "Containers"
  restarting="$(docker ps -a --filter status=restarting --format '{{.Names}}' 2>/dev/null)"
  unhealthy="$(docker ps    --filter health=unhealthy    --format '{{.Names}}' 2>/dev/null)"
  exited="$(docker ps -a    --filter status=exited       --format '{{.Names}}' 2>/dev/null)"
  if [[ -z "$restarting$unhealthy" ]]; then ok "none restarting or unhealthy"
  else
    for n in $restarting; do bad "$n is restarting (crash loop) — hs logs $n"; done
    for n in $unhealthy;  do bad "$n is unhealthy — hs logs $n"; done
  fi
  for n in $exited; do note "$n is stopped (Exited) — intentional? otherwise: hs logs $n"; done

  say "qBittorrent auth"
  # Whitelist of the docker home subnet lets *arr apps + decluttarr reach qBit's
  # API without password drift / IP-ban hazards. Set by scripts/patch-qbit-auth.sh.
  qbit_running="$(docker ps --filter name=^qbittorrent$ --format '{{.Names}}' 2>/dev/null)"
  if [[ -z "$qbit_running" ]]; then
    printf '  %s·%s qbittorrent not running — skipping whitelist check\n' "$c_dim" "$c_reset"
  else
    cfg_path="$(current_value CONFIG_PATH)"
    qbit_conf="${cfg_path:-/opt/docker/data}/qbittorrent/qBittorrent/qBittorrent.conf"
    if [[ ! -f "$qbit_conf" ]]; then
      note "qBittorrent.conf not found at $qbit_conf — fresh container? wait for it to write its config"
    else
      home_subnet="$(docker network inspect home --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
      wl_enabled="$(grep -F -m1 'WebUI\AuthSubnetWhitelistEnabled=' "$qbit_conf" 2>/dev/null | cut -d= -f2-)"
      wl_list="$(grep    -F -m1 'WebUI\AuthSubnetWhitelist='        "$qbit_conf" 2>/dev/null | cut -d= -f2-)"
      # whitelist is comma-separated; just check membership so multi-subnet setups pass.
      includes_home=0
      if [[ -n "$home_subnet" && -n "$wl_list" ]]; then
        IFS=',' read -r -a _wl_parts <<<"$wl_list"
        for _s in "${_wl_parts[@]}"; do [[ "${_s// /}" == "$home_subnet" ]] && includes_home=1; done
      fi
      if [[ "$wl_enabled" == "true" && $includes_home -eq 1 ]]; then
        ok "WebUI subnet whitelist includes $home_subnet"
      else
        note "qBit WebUI subnet whitelist missing $home_subnet (enabled='${wl_enabled:-unset}', list='${wl_list:-unset}') — run './scripts/patch-qbit-auth.sh'"
        escalate diag_qbit
      fi
    fi
  fi

  say "Recyclarr"
  # Watch for silent template/sync failures (e.g. the v7->v8 breakage that
  # silently bricked syncs for weeks).  Reads the most recent log file rather
  # than the live state so this works even between cron runs.
  cfg_path="$(current_value CONFIG_PATH)"
  recyc_log_dir="${cfg_path:-/opt/docker/data}/recyclarr/logs/cli"
  if [[ ! -d "$recyc_log_dir" ]]; then
    printf '  %s·%s recyclarr logs dir missing — has it ever run?\n' "$c_dim" "$c_reset"
  else
    latest_log="$(ls -t "$recyc_log_dir"/*.log 2>/dev/null | head -n1)"
    if [[ -z "$latest_log" ]]; then
      printf '  %s·%s no recyclarr log files yet\n' "$c_dim" "$c_reset"
    elif grep -q '^\[.*ERR\]' "$latest_log" 2>/dev/null; then
      err_line="$(grep -m1 '^\[.*ERR\]' "$latest_log" | sed 's/.*ERR\] //; s/^[[:space:]]*//' | head -c 130)"
      note "recyclarr last sync FAILED ($(basename "$latest_log")): $err_line"
      note "  fix:  docker exec recyclarr recyclarr sync  (then re-check)"
      escalate diag_recyclarr
    else
      ok "recyclarr last sync clean ($(basename "$latest_log"))"
    fi
  fi

  say "Decluttarr"
  # Each cycle (default 10min) starts with "*** Checking Instances ***" then logs
  # one "OK | <name>" or "ERROR | -- | <name>" per configured app/client.  We
  # grab the LAST such block within the past 30min and count OK vs ERROR.
  if ! docker ps --format '{{.Names}}' | grep -qx decluttarr; then
    printf '  %s·%s decluttarr not running\n' "$c_dim" "$c_reset"
  else
    # decluttarr only logs "Checking Instances" at startup (not every cycle), so
    # we look at the WHOLE log for the latest connection-check result, then also
    # verify the container is still actively logging (job runs in last 30min)
    # to catch a stuck-but-not-crashed state.
    last_check="$(docker logs decluttarr 2>&1 \
                  | awk '/\*\*\* Checking Instances \*\*\*/{out=""; capture=1; next}
                         capture && /^\s*INFO  +\| OK \| / {out = out $0 ORS; next}
                         capture && /^ERROR  +\| -- / {out = out $0 ORS; next}
                         capture && /\*\*\* Running jobs|Termination signal/ {capture=0}
                         END {printf "%s", out}')"
    recent_activity="$(docker logs --since 30m decluttarr 2>&1 | grep -c '^INFO ' || true)"
    if [[ -z "$last_check" ]]; then
      note "decluttarr never completed a connection check — has it ever cycled?"
      escalate diag_decluttarr
    elif [[ "$recent_activity" -eq 0 ]]; then
      note "decluttarr hasn't logged anything in 30min — may be stuck"
      escalate diag_decluttarr
    else
      err_count="$(printf '%s' "$last_check" | grep -cE '^ERROR  +\| --' || true)"
      ok_count="$( printf '%s' "$last_check" | grep -cE '^\s*INFO  +\| OK \|' || true)"
      if [[ "$err_count" -gt 0 ]]; then
        bad_line="$(printf '%s' "$last_check" | grep -m1 -E '^ERROR  +\| --' | head -c 120)"
        note "decluttarr last cycle had $err_count failed instance check(s): $bad_line"
        note "  inspect:  docker logs decluttarr --tail 60"
        escalate diag_decluttarr
      else
        ok "decluttarr last cycle: $ok_count instance(s) connected, no errors"
      fi
    fi
  fi
fi

say ".env"
if [[ -f "$ENV_FILE" ]]; then
  ok ".env present"
  missing="$(comm -13 \
    <(grep -oE '^[A-Z0-9_]+=' "$ENV_FILE"  | sed 's/=$//' | sort -u) \
    <(grep -oE '^[A-Z0-9_]+=' .env.example | sed 's/=$//' | sort -u))"
  if [[ -z "$missing" ]]; then ok "in sync with .env.example"
  else note "$(printf '%s' "$missing" | grep -c .) var(s) missing vs .env.example — run 'hs env sync'"; fi
else
  bad ".env missing — run 'hs env init'"
fi

say "Storage"
cfg="$(current_value CONFIG_PATH)"; med="$(current_value MEDIA_PATH)"
if [[ -z "$cfg" ]]; then note "CONFIG_PATH not set in .env"
elif [[ -d "$cfg" ]]; then
  ok "CONFIG_PATH ($cfg) exists"
  if command -v findmnt >/dev/null; then
    ft="$(findmnt -n -o FSTYPE --target "$cfg" 2>/dev/null || true)"
    case "$ft" in nfs*|cifs|smb*) bad "CONFIG_PATH is on a '$ft' mount — app DBs corrupt on network shares; move it to local disk" ;; esac
  fi
else bad "CONFIG_PATH ($cfg) does not exist"; fi
if [[ -z "$med" ]]; then note "MEDIA_PATH not set in .env"
elif [[ -d "$med" ]]; then
  ok "MEDIA_PATH ($med) exists"
  if command -v mountpoint >/dev/null && ! mountpoint -q "$med" 2>/dev/null && [[ -z "$(ls -A "$med" 2>/dev/null)" ]]; then
    note "MEDIA_PATH is empty and not a mountpoint — if it's a NAS share it isn't mounted (containers would see no media)"
  fi
else bad "MEDIA_PATH ($med) does not exist"; fi
inc="$(current_value SAB_INCOMPLETE_PATH)"
if [[ -n "$inc" ]]; then
  [[ -d "$inc" ]] && ok "SAB_INCOMPLETE_PATH ($inc) exists" || note "SAB_INCOMPLETE_PATH ($inc) missing — created on next 'hs update'"
  if command -v findmnt >/dev/null; then
    ftinc="$(findmnt -n -o FSTYPE --target "$inc" 2>/dev/null || true)"
    case "$ftinc" in nfs*|cifs|smb*) bad "SAB_INCOMPLETE_PATH on a '$ftinc' mount — SAB stalls on network scratch; use local disk" ;; esac
  fi
fi

say "OS updates"
# The real gate is the APT::Periodic config, not whether the unit is "enabled"
# (the unit can be enabled while periodic runs are off, or static while the timer
# drives it). apt-config reflects the effective value.
if command -v apt-config >/dev/null 2>&1 && apt-config dump 2>/dev/null | grep -E '^APT::Periodic::Unattended-Upgrade "[1-9]' >/dev/null 2>&1; then
  ok "unattended-upgrades active — OS security patches auto-apply"
elif command -v dpkg >/dev/null 2>&1 && dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
  note "unattended-upgrades installed but periodic runs are off — enable APT::Periodic::Unattended-Upgrade \"1\" (run scripts/setup-fresh.sh)"
else
  note "unattended-upgrades not set up — OS won't auto-patch (run scripts/setup-fresh.sh)"
fi
[[ -f /var/run/reboot-required ]] && bad "reboot pending — a security update (often the kernel) needs a reboot to take effect: sudo reboot"

say "Stack wiring"
if [[ "$(current_value STACKS_PATH)" == "$REPO_DIR" ]]; then ok "STACKS_PATH = $REPO_DIR"
else note "STACKS_PATH != repo path — run 'hs update' (re-links it)"; fi
bad_links=0
for compose in */docker-compose.yml; do
  d="$(dirname "$compose")"
  [[ "$(readlink "$d/.env" 2>/dev/null)" == "../.env" ]] || { note "missing/incorrect symlink: $d/.env"; bad_links=1; }
done
[[ $bad_links -eq 0 ]] && ok "every stack has its .env symlink" || note "fix with 'hs update'"

say "Compose validity"
ENV_ARG=(); [[ -f "$ENV_FILE" ]] && ENV_ARG=(--env-file "$ENV_FILE") || ENV_ARG=(--env-file .env.example)
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  for compose in */docker-compose.yml; do
    if docker compose -f "$compose" "${ENV_ARG[@]}" config -q >/dev/null 2>&1; then
      ok "${compose%/*} compose valid"
    else
      # A stack whose services are all commented out (e.g. devops placeholder)
      # fails config with "no services" — that's intentional, not broken.
      active=$(awk '/^services:/{i=1;next} /^[^[:space:]#]/{i=0} i&&/^  [A-Za-z0-9_-]+:[[:space:]]*$/{n++} END{print n+0}' "$compose")
      if [[ "${active:-0}" -eq 0 ]]; then note "${compose%/*} placeholder (all services commented) — skipped"
      else bad "${compose%/*} compose INVALID — docker compose -f $compose config"; fi
    fi
  done
else
  note "docker compose unavailable — skipped compose validation"
fi

say "Env values referenced by active services"
if [[ -f "$ENV_FILE" ]]; then
  report="$(python3 - "$ENV_FILE" <<'PY'
import glob, re, pathlib, sys
env = {}
for ln in pathlib.Path(sys.argv[1]).read_text().splitlines():
    m = re.match(r'^([A-Z0-9_]+)=(.*)$', ln)
    if m: env[m.group(1)] = re.split(r'\s+#', m.group(2), 1)[0].strip()
REQUIRED = set("WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES "
               "IMMICH_DB_PASSWORD PAPERLESS_DB_PASSWORD PAPERLESS_SECRET_KEY DONETICK_JWT_SECRET "
               "VAULTWARDEN_ADMIN_TOKEN ARCANE_ENCRYPTION_KEY ARCANE_JWT_SECRET".split())
refs = {}
for f in sorted(glob.glob('*/docker-compose.yml')):
    for ln in pathlib.Path(f).read_text().splitlines():
        if ln.lstrip().startswith('#'):      # skip commented (inactive) services
            continue
        for m in re.finditer(r'\$\{([A-Z0-9_]+)(:-[^}]*|:\?[^}]*)?\}', ln):
            if m.group(2) and m.group(2).startswith(':-'):   # has a default -> fine
                continue
            refs.setdefault(m.group(1), set()).add(pathlib.Path(f).parent.name)
for var in sorted(refs):
    val = env.get(var)
    if val is None or val == '':
        tag = "REQ" if var in REQUIRED else "OPT"
        print(f"{tag} {var} {','.join(sorted(refs[var]))}")
PY
)"
  if [[ -z "$report" ]]; then ok "all active-service vars have values"
  else
    while read -r tag var stacks; do
      [[ -z "$tag" ]] && continue
      if [[ "$tag" == REQ ]]; then bad "$var is blank but required ($stacks) — run 'hs secrets' (or 'hs keys' for app keys)"
      else note "$var blank — fine for optional widgets, set if you use it ($stacks)"; fi
    done <<<"$report"
  fi
else
  note "no .env — skipped value check"
fi

say "AdGuard port 53"
if command -v systemctl >/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  note "systemd-resolved is active and holds :53 — AdGuard won't start until it's freed (see infrastructure/docker-compose.yml)"
elif command -v ss >/dev/null && ss -lntu 2>/dev/null | grep -qE '[:.]53\b'; then
  note "something is listening on :53 — verify it's AdGuard, not a conflict"
else
  ok "no obvious :53 conflict"
fi

say "Stack profile"
if [[ -f .stacks.local ]]; then
  denied="$("$SCRIPT_DIR/stacks.sh" denied-list 2>/dev/null | tr '\n' ' ' | sed 's/  *$//')"
  pending="$("$SCRIPT_DIR/stacks.sh" pending-list 2>/dev/null | tr '\n' ' ' | sed 's/  *$//')"
  if [[ -z "$denied" ]]; then ok "no stacks excluded"
  else printf '  %s·%s excluded from bulk deploy: %s  (hs stacks enable <name>)\n' "$c_dim" "$c_reset" "$denied"; fi
  [[ -n "$pending" ]] && note "new/undecided stack(s): $pending  (run 'hs stacks reconcile')"
  # Flag (don't remove) .env vars now unused because their only stack is disabled.
  if [[ -n "$denied" && -f "$ENV_FILE" ]]; then
    while read -r var stk; do
      [[ -n "$var" ]] && printf '  %s·%s %s is set but unused (%s disabled)\n' "$c_dim" "$c_reset" "$var" "$stk"
    done < <(python3 - "$ENV_FILE" "$denied" <<'PY'
import sys, re, glob, pathlib
env_path, denied = sys.argv[1], set(sys.argv[2].split())
env = {}
for ln in pathlib.Path(env_path).read_text().splitlines():
    m = re.match(r'^([A-Z0-9_]+)=(.*)$', ln)
    if m: env[m.group(1)] = re.split(r'\s+#', m.group(2), 1)[0].strip()
refs = {}
for f in glob.glob('*/docker-compose.yml'):
    stack = pathlib.Path(f).parent.name
    for ln in pathlib.Path(f).read_text().splitlines():
        if ln.lstrip().startswith('#'):
            continue
        for m in re.finditer(r'\$\{([A-Z0-9_]+)', ln):
            refs.setdefault(m.group(1), set()).add(stack)
for var in sorted(refs):
    st = refs[var]
    if st and st <= denied and env.get(var):   # referenced ONLY by denied stacks, and set
        print(f"{var} {','.join(sorted(st))}")
PY
)
  fi
else
  ok "all stacks deploy (no profile yet)"
fi

echo
if [[ $FAILS -gt 0 ]]; then die "$FAILS problem(s), $WARNS warning(s). Fix the ✗ items above."; fi
[[ $WARNS -gt 0 ]] && say "Healthy with $WARNS warning(s)." || say "All checks passed."
