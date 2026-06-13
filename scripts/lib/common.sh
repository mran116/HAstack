#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# scripts/lib/common.sh — shared helpers for the homeserver scripts.
#
# Source AFTER setting REPO_DIR, e.g. from a script in scripts/:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
#
# Provides: colours, say/warn/die, ask/ask_yn, update_env, current_value,
# load_env, require_cmd/require_docker, and a tiny plan/gate framework
# (--dry-run / --yes) so every standalone step previews before it acts.
# =============================================================================

# ---- colours ----------------------------------------------------------------
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'

say()  { printf '%s==>%s %s\n' "$c_bold$c_green" "$c_reset" "$*"; }
warn() { printf '%s!!%s %s\n'  "$c_bold$c_yellow" "$c_reset" "$*"; }
die()  { printf '%sxx%s %s\n'  "$c_bold$c_red"    "$c_reset" "$*" >&2; exit 1; }

# ---- prompts ----------------------------------------------------------------
ask() {
  # ask "Prompt" default_value var_name
  local prompt="$1" default="$2" __var="$3" answer
  read -r -p "$(printf '%s  [%s%s%s]: ' "$prompt" "$c_dim" "$default" "$c_reset")" answer || true
  printf -v "$__var" '%s' "${answer:-$default}"
}

ask_yn() {
  # ask_yn "Prompt" default(Y|n)
  local prompt="$1" default="${2:-Y}" answer
  read -r -p "$(printf '%s [%s]: ' "$prompt" "$default")" answer || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ---- .env helpers -----------------------------------------------------------
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

update_env() {
  # update_env KEY VALUE — set (or append) KEY=VALUE in $ENV_FILE, atomically
  # (write to a temp file in the same dir, preserve mode, then os.replace).
  python3 - "$1" "$2" "$ENV_FILE" <<'PY'
import sys, re, os, pathlib, tempfile, shutil
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text()
if re.search(rf"(?m)^{re.escape(key)}=", text):
    text = re.sub(rf"(?m)^{re.escape(key)}=.*$", f"{key}={value}", text, count=1)
else:
    text = text.rstrip() + f"\n{key}={value}\n"
d = os.path.dirname(os.path.abspath(path)) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".env.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    try: shutil.copymode(path, tmp)
    except OSError: pass
    os.replace(tmp, path)
except BaseException:
    try: os.unlink(tmp)
    except OSError: pass
    raise
PY
}

current_value() {
  # current_value KEY — echo the value of KEY in $ENV_FILE (empty if unset)
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^${1}=" "$ENV_FILE" | head -n1 | cut -d= -f2-
}

backup_env() {
  # backup_env — timestamped copy of $ENV_FILE (keeps history; .env.* is gitignored)
  local b; b="$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$ENV_FILE" "$b"
  say "Backed up current .env to $b"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "No .env at $ENV_FILE — run ./scripts/env-init.sh (or ./bootstrap.sh) first."
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# require_env: die (or, in --dry-run, soft-skip) when .env is absent. Returns 1
# on a soft-skip so the caller can `require_env || exit 0`.
require_env() {
  [[ -f "$ENV_FILE" ]] && return 0
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    say "(no .env yet — this step would run after env-init.sh)"
    return 1
  fi
  die "No .env at $ENV_FILE — run ./scripts/env-init.sh (or ./bootstrap.sh) first."
}

# ---- prereqs ----------------------------------------------------------------
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

require_docker() {
  command -v docker >/dev/null || die "docker not found. Install Docker first: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not found. Upgrade Docker to a recent version."
  docker info >/dev/null 2>&1 || die "Cannot talk to the docker daemon. Is your user in the 'docker' group? (sudo usermod -aG docker \$USER, then re-login.)"
}

require_writable() {
  # require_writable PATH — die with an actionable fix if PATH (or its nearest
  # existing ancestor, when PATH doesn't exist yet) isn't writable by you.
  # Catches the classic "a step was run with sudo, so root owns it" trap.
  local target="$1" node="$1"
  while [[ ! -e "$node" && "$node" != "/" && "$node" != "." ]]; do
    node="$(dirname "$node")"
  done
  [[ -w "$node" ]] && return 0
  local owner; owner="$(stat -c '%U' "$node" 2>/dev/null || echo '?')"
  warn "No write permission for: $target"
  warn "  blocked at $node (owned by '$owner'; you are '$(id -un)')"
  warn "  Likely a step was run with sudo, so root owns it. Fix it, then re-run WITHOUT sudo:"
  die  "    sudo chown -R $(id -un):$(id -gn) \"$node\""
}

# ---- plan / gate framework (--dry-run / --yes) ------------------------------
DRY_RUN=0
ASSUME_YES=0
PLAN=()

parse_common_flags() {
  # Consumes --dry-run/-n, --yes/-y, --help/-h. Other args are ignored here so
  # individual scripts can still read their own positional args if needed.
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) DRY_RUN=1 ;;
      --yes|-y)     ASSUME_YES=1 ;;
      --help|-h)    if [[ "$(type -t usage)" == function ]]; then usage; fi; exit 0 ;;
    esac
  done
}

plan() { PLAN+=("$*"); }

# show_plan — print queued actions. Returns 1 when there's nothing to do, so:
#   show_plan || exit 0
show_plan() {
  if [[ ${#PLAN[@]} -eq 0 ]]; then
    say "Nothing to do — already in the desired state."
    return 1
  fi
  say "Planned changes:"
  local p
  for p in "${PLAN[@]}"; do printf '   %s•%s %s\n' "$c_bold" "$c_reset" "$p"; done
  return 0
}

# gate — honour --dry-run / --yes, else ask. Defaults to NO: nothing happens
# unless you explicitly accept by typing 'y'. Returns 1 to abort, so:
#   gate || exit 0
gate() {
  if [[ $DRY_RUN -eq 1 ]]; then say "Dry run — no changes made."; return 1; fi
  if [[ $ASSUME_YES -eq 1 ]]; then return 0; fi
  ask_yn "Apply these changes?" N || { say "Aborted — no changes made."; return 1; }
  return 0
}
