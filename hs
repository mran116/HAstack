#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# hs — the homestack command. One entrypoint for everything in THIS repo.
#
# Works from any directory (resolves its own location). `hs install` puts it on
# PATH. Generic: any scripts/<name>.sh becomes `hs <name>` automatically, so a
# repo with extra app scripts (e.g. media's prowlarr-watchdog) gets them for free.
# Flags forward to the script:  -n/--dry-run   -y/--yes   -h/--help.
# =============================================================================
set -euo pipefail
src="${BASH_SOURCE[0]}"
while [ -L "$src" ]; do dir="$(cd -P "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"; [[ "$src" != /* ]] && src="$dir/$src"; done
ROOT="$(cd -P "$(dirname "$src")" && pwd)"
S="$ROOT/scripts"

run() { local f="$1"; shift; exec "$S/$f" "$@"; }

help() {
  cat <<'EOF'
hs — homestack command. Run from anywhere.

EVERYDAY
  hs update [-n|-y|--images]   pull latest + redeploy (reconciles .env, dirs, hooks)
  hs doctor                    read-only health check
  hs up|down|restart [stack]   start / stop / restart stacks (or one)
  hs startup [--install]       wave-ordered bring-up (avoids boot I/O storm)
  hs status [stack]            docker compose ps
  hs pull [stack]              pull newer images
  hs logs <stack|container>    tail logs (-f to follow)
  hs stacks [enable|disable|reconcile]   choose which stacks deploy here
  hs mounts                    check storage mounts (auto-heal + ntfy alert)

SETUP
  hs setup [--fresh]           run bootstrap (first-run host setup)
  hs install                   symlink hs onto PATH (+ tab-completion)
  hs network                   (re)create the shared docker network

.ENV
  hs env init|sync|tidy        create / top-up / reformat .env
  hs secrets                   fill blank machine secrets (DB-safe)
  hs keys                      pull app API keys into .env

MAINTENANCE
  hs cron                      (re)install maintenance cron jobs
  hs hooks                     (re)install the git pre-push validation hook

Any scripts/<name>.sh in this repo is also runnable as `hs <name>`.
Flags everywhere:  -n/--dry-run   -y/--yes   -h/--help
EOF
}

install() {
  local link=""
  if ln -sf "$ROOT/hs" /usr/local/bin/hs 2>/dev/null \
     || { command -v sudo >/dev/null && sudo ln -sf "$ROOT/hs" /usr/local/bin/hs 2>/dev/null; }; then
    link=/usr/local/bin/hs
  else
    local target="$HOME/.local/bin"; mkdir -p "$target"; ln -sf "$ROOT/hs" "$target/hs"; link="$target/hs"
    case ":$PATH:" in *":$target:"*) ;; *)
      local rc="$HOME/.bashrc"; [[ "${SHELL:-}" == *zsh* ]] && rc="$HOME/.zshrc"
      local line="export PATH=\"$target:\$PATH\""
      grep -qsF "$line" "$rc" 2>/dev/null || printf '%s\n' "$line" >> "$rc"
      echo "Added $target to PATH in $rc — open a new shell or: source $rc" ;;
    esac
  fi
  echo "Linked: $link -> $ROOT/hs   (run: hs help)"
  local comp="$HOME/.local/share/bash-completion/completions"; mkdir -p "$comp"
  [[ -f "$S/hs-completion.bash" ]] && ln -sf "$S/hs-completion.bash" "$comp/hs"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  update)                run update.sh "$@" ;;
  doctor)                run doctor.sh "$@" ;;
  up|down|restart|pull|status) exec "$S/stack.sh" "$cmd" "$@" ;;
  startup)               run staggered-up.sh "$@" ;;
  enable|disable)        [[ -x "$S/enable.sh" ]] && exec "$S/enable.sh" "$cmd" "$@" || exec "$S/stacks.sh" "$cmd" "$@" ;;
  logs)
    name="${1:-}"; shift 2>/dev/null || true
    [[ -z "$name" ]] && { echo "usage: hs logs <stack|container> [-f]" >&2; exit 1; }
    if [[ -f "$ROOT/$name/docker-compose.yml" ]]; then exec docker compose -f "$ROOT/$name/docker-compose.yml" --env-file "$ROOT/.env" logs --tail=200 "$@"
    else exec docker logs --tail=200 "$@" "$name"; fi ;;
  secrets)               run gen-secrets.sh "$@" ;;
  keys)                  run harvest-keys.sh "$@" ;;
  stacks)                run stacks.sh "$@" ;;
  network)               run create-network.sh "$@" ;;
  cron)                  run schedule-maintenance.sh "$@" ;;
  mounts)                run mount-watchdog.sh "$@" ;;
  hooks)                 run install-hooks.sh "$@" ;;
  setup)
    [[ "${1:-}" == "--fresh" && -x "$S/setup-fresh.sh" ]] && { shift; exec "$S/setup-fresh.sh" "$@"; }
    exec "$ROOT/bootstrap.sh" "$@" ;;
  env)
    sub="${1:-}"; shift 2>/dev/null || true
    case "$sub" in init) run env-init.sh "$@" ;; sync) run env-sync.sh "$@" ;; tidy) run env-rebuild.sh "$@" ;; *) echo "hs env {init|sync|tidy}" >&2; exit 1 ;; esac ;;
  install)               install ;;
  help|-h|--help|"")     help ;;
  *)  # generic: any scripts/<cmd>.sh (or .py) becomes a command
    if [[ -x "$S/$cmd.sh" ]]; then run "$cmd.sh" "$@"
    elif [[ -x "$S/$cmd.py" ]]; then exec "$S/$cmd.py" "$@"
    else echo "hs: unknown command '$cmd' — try 'hs help'" >&2; exit 1; fi ;;
esac
