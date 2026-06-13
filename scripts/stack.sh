#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# stack.sh — bulk operate on stacks (discovered, wave-ordered, multi-repo)
#
#   ./scripts/stack.sh up                 # start all stacks (wave order)
#   ./scripts/stack.sh down               # stop all stacks (reverse wave order)
#   ./scripts/stack.sh restart            # down then up
#   ./scripts/stack.sh pull               # pull latest images
#   ./scripts/stack.sh status             # docker compose ps for each
#   ./scripts/stack.sh up mediastack ...  # target specific stacks
#
# Stacks are DISCOVERED across STACK_ROOTS and ordered by their stack.conf WAVE —
# no hardcoded list. Uses the single root .env. Skips all-commented placeholders.
# A failure in one stack is reported but doesn't abort the rest.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/stacks.sh
source "$SCRIPT_DIR/lib/stacks.sh"
cd "$REPO_DIR"

usage() { echo "Usage: $0 {up|down|restart|pull|status} [stack ...]"; exit 1; }

# Bulk targets = the deploy profile (everything minus DENIED + manual), wave-ordered.
deploy_targets() {
  mapfile -t targets < <("$SCRIPT_DIR/stacks.sh" deploy-list 2>/dev/null)
  [[ ${#targets[@]} -gt 0 ]] || mapfile -t targets < <(deploy_list)
}

menu() {
  { echo "${c_bold}stack.sh — pick an action:${c_reset}"
    echo "  1) up   2) down   3) restart   4) pull   5) status   q) quit"; } >&2
  local choice; read -r -p "Choice [5]: " choice
  case "${choice:-5}" in
    1) echo up ;; 2) echo down ;; 3) echo restart ;; 4) echo pull ;; 5) echo status ;;
    q|Q) echo "" ;; *) echo "INVALID" ;;
  esac
}

for a in "$@"; do case "$a" in -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac; done
[[ -f "$ENV_FILE" ]] || { echo "No .env at $ENV_FILE — run 'hs setup' first." >&2; exit 1; }

if [[ $# -ge 1 ]]; then
  cmd="$1"; shift
  if [[ $# -gt 0 ]]; then targets=("$@"); explicit=1; else deploy_targets; explicit=0; fi
  if [[ $explicit -eq 1 ]]; then
    for s in "${targets[@]}"; do
      [[ "$s" == -* ]] && continue
      stack_dir "$s" >/dev/null || die "No such stack: '$s' — pick from: $(discover_stacks | tr '\n' ' ')"
    done
  fi
else
  cmd="$(menu)"
  [[ -z "$cmd" ]] && { echo "Cancelled."; exit 0; }
  [[ "$cmd" == "INVALID" ]] && { echo "Invalid choice."; exit 1; }
  deploy_targets; explicit=0
fi

run_each() {
  local action="$1"; shift
  for s in "$@"; do
    stack_dir "$s" >/dev/null 2>&1 || { warn "skip $s (not found)"; continue; }
    stack_is_active "$s" || { say "skip $s (placeholder — no active services)"; continue; }
    say "$action: $s"
    case "$action" in
      up)     dc "$s" up -d ${STACK_UP_ARGS:-} || warn "$s failed" ;;
      down)   dc "$s" down  || warn "$s failed" ;;
      pull)   dc "$s" pull  || warn "$s failed" ;;
      status) dc "$s" ps    || true ;;
    esac
  done
}

case "$cmd" in
  up)     ensure_network; run_each up   "${targets[@]}" ;;
  pull)   run_each pull   "${targets[@]}" ;;
  status) run_each status "${targets[@]}" ;;
  down)
    if [[ $explicit -eq 0 ]]; then
      rev=(); for ((i=${#targets[@]}-1; i>=0; i--)); do rev+=("${targets[i]}"); done
      targets=("${rev[@]}")
    fi
    run_each down "${targets[@]}" ;;
  restart) "$0" down "${targets[@]}"; "$0" up "${targets[@]}" ;;
  *) usage ;;
esac
say "Done."
