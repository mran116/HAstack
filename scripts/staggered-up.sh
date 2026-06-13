#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# staggered-up.sh — bring stacks up in ordered WAVES, not all at once.
#
# WHY: on a host reboot the Docker daemon auto-restarts every `restart:`-policy
# container CONCURRENTLY (compose `depends_on` is a `compose up` construct the
# daemon ignores on boot). On a big host that's an I/O storm that can wedge the
# disk/NFS. This serialises bring-up into waves with a gap between them.
#
# Fully DISCOVERY-DRIVEN — no hardcoded stack list. Each stack declares its wave
# in `<stack>/stack.conf` (`WAVE=1`..`5`, default 3); we discover every active
# stack and bring them up wave by wave. Intra-stack order is the stack's own
# `depends_on` (honoured here, since this IS a `compose up`). So a friend's box
# with different stacks works unchanged, and stacks moved to other repos carry
# their wave with them.
#
# MULTI-REPO: set STACK_ROOTS="/path/a /path/b" (e.g. the homestacks repos) to
# wave across all of them globally. Defaults to this one repo.
#
#   ./scripts/staggered-up.sh           bring everything up in waves
#   ./scripts/staggered-up.sh --stop    stop all (reverse wave order)
#   ./scripts/staggered-up.sh --install install the systemd boot units
#
# Wave gap: STARTUP_WAVE_GAP=<seconds> (default 20). Flags: -n, -y, -h.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/stacks.sh
source "$SCRIPT_DIR/lib/stacks.sh"
cd "$REPO_DIR"

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"

GAP="${STARTUP_WAVE_GAP:-20}"
MAXWAVE="${STARTUP_MAX_WAVE:-5}"

gap() { [[ "${GAP}" -gt 0 && $DRY_RUN -eq 0 ]] && { say "  …settle ${GAP}s…"; sleep "$GAP"; }; return 0; }

do_up() {
  require_docker
  say "Staggered bring-up (gap ${GAP}s between waves)${DRY_RUN:+ [dry-run]}"
  mapfile -t STACKS < <(deploy_list)
  [[ ${#STACKS[@]} -gt 0 ]] || { warn "no active stacks discovered under: $STACK_ROOTS"; return 0; }

  local w s any
  for ((w=1; w<=MAXWAVE; w++)); do
    local in_wave=()
    for s in "${STACKS[@]}"; do [[ "$(stack_wave "$s")" == "$w" ]] && in_wave+=("$s"); done
    [[ ${#in_wave[@]} -eq 0 ]] && continue
    say "Wave $w/$MAXWAVE — ${in_wave[*]}"
    if [[ $DRY_RUN -eq 0 ]]; then
      for s in "${in_wave[@]}"; do dc "$s" up -d ${STACK_UP_ARGS:-} || warn "$s failed"; done
    fi
    any=1
    [[ $w -lt $MAXWAVE ]] && gap
  done

  # Catch-all: any wave value outside 1..MAXWAVE (a stack.conf typo or a custom
  # high wave) — bring them up last so nothing is silently left down.
  local extra=()
  for s in "${STACKS[@]}"; do
    local wv; wv="$(stack_wave "$s")"
    { [[ "$wv" =~ ^[0-9]+$ ]] && [[ "$wv" -ge 1 && "$wv" -le "$MAXWAVE" ]]; } || extra+=("$s")
  done
  if [[ ${#extra[@]} -gt 0 ]]; then
    [[ -n "${any:-}" ]] && gap
    say "Catch-all (wave outside 1..$MAXWAVE) — ${extra[*]}"
    [[ $DRY_RUN -eq 0 ]] && for s in "${extra[@]}"; do dc "$s" up -d ${STACK_UP_ARGS:-} || warn "$s failed"; done
  fi
  say "Done — stacks up in waves."
}

# Stop all (reverse wave order) so the daemon won't auto-restart on next boot.
do_stop() {
  require_docker
  say "Stopping all stacks in reverse wave order${DRY_RUN:+ [dry-run]}"
  mapfile -t STACKS < <(deploy_list)
  local w s
  for ((w=MAXWAVE; w>=1; w--)); do
    for s in "${STACKS[@]}"; do
      [[ "$(stack_wave "$s")" == "$w" ]] || continue
      say "  stop: $s"
      [[ $DRY_RUN -eq 1 ]] && continue
      dc "$s" stop || warn "$s stop failed"
    done
  done
  say "Done — all stacks stopped."
}

do_install() {
  command -v systemctl >/dev/null || die "systemctl not found — this host isn't systemd."
  local SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
  local unit_src="$REPO_DIR/infrastructure/systemd/homestack-startup.service"
  local drop_src="$REPO_DIR/infrastructure/systemd/docker.service.d/startup-delay.conf"
  [[ -f "$unit_src" ]] || die "missing $unit_src"
  [[ -f "$drop_src" ]] || die "missing $drop_src"
  plan "install /etc/systemd/system/homestack-startup.service (ExecStart from $REPO_DIR)"
  plan "install /etc/systemd/system/docker.service.d/startup-delay.conf (boot delay)"
  plan "systemctl daemon-reload && enable --now homestack-startup.service"
  show_plan || return 0
  gate || return 0
  $SUDO install -m 644 /dev/stdin /etc/systemd/system/homestack-startup.service \
    < <(sed "s#__REPO_DIR__#$REPO_DIR#g; s#/opt/docker/stacks#$REPO_DIR#g" "$unit_src")
  $SUDO install -d /etc/systemd/system/docker.service.d
  $SUDO install -m 644 "$drop_src" /etc/systemd/system/docker.service.d/startup-delay.conf
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now homestack-startup.service
  say "Installed. Apply the docker boot-delay with: $SUDO systemctl restart docker (when convenient)."
}

case "${1:-up}" in
  --stop|stop)       do_stop ;;
  --install|install) do_install ;;
  *)                 do_up ;;
esac
