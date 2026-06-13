#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# scripts/lib/stacks.sh — repo-agnostic stack discovery + declarative metadata.
#
# Source AFTER common.sh (needs REPO_DIR + ENV_FILE):
#   source "$SCRIPT_DIR/lib/common.sh"
#   source "$SCRIPT_DIR/lib/stacks.sh"
#
# The whole point: NO script hardcodes the list of stacks or their ordering.
# Each stack DISCOVERS itself (it's a dir with a docker-compose.yml) and DECLARES
# its own properties in an optional `<stack>/stack.conf`:
#
#   # <stack>/stack.conf  — all keys optional, sane defaults if the file is absent
#   WAVE=1            # boot order, 1 (first) .. 5 (last). default 3.
#   MOUNTS="MEDIA"    # storage deps (MEDIA/PHOTOS/DOCS/SYNC) — mount-watchdog
#                     #   restarts this stack when one of these mounts re-heals.
#                     #   space-separated. default: none.
#   DEPLOY=auto       # auto (default) | manual — manual stacks are skipped by
#                     #   bulk `up`, still deployable by name.
#
# Because this is per-stack and self-describing, it travels: move a stack to
# another repo or a friend's machine and its boot wave / mount deps come with it,
# with no central list to edit. A repo with stacks you've never seen Just Works.
#
# MULTI-REPO: set STACK_ROOTS to a space-separated list of repo dirs to operate
# across sibling repos (e.g. the homestacks parent). Defaults to just REPO_DIR,
# so a single-repo checkout (a friend's box) needs no configuration at all.
# =============================================================================

# Roots to scan. One repo by default (portable); many for a homestacks host.
STACK_ROOTS="${STACK_ROOTS:-$REPO_DIR}"

# stack_dir STACK — absolute path of a stack's dir across all roots (first hit).
stack_dir() {
  local s="$1" root
  for root in $STACK_ROOTS; do
    [[ -f "$root/$s/docker-compose.yml" ]] && { echo "$root/$s"; return 0; }
  done
  return 1
}

# stack_is_active STACK — true if it has at least one UNCOMMENTED service
# (skips all-commented placeholder stacks that `docker compose` rejects).
stack_is_active() {
  local d; d="$(stack_dir "$1")" || return 1
  local n; n=$(awk '/^services:/{i=1;next} /^[^[:space:]#]/{i=0} i&&/^  [A-Za-z0-9_-]+:[[:space:]]*$/{c++} END{print c+0}' "$d/docker-compose.yml")
  [[ "${n:-0}" -gt 0 ]]
}

# discover_stacks — every active stack across STACK_ROOTS, deduped, one per line.
discover_stacks() {
  local root d s seen=" "
  for root in $STACK_ROOTS; do
    for d in "$root"/*/docker-compose.yml; do
      [[ -e "$d" ]] || continue
      s="$(basename "$(dirname "$d")")"
      case "$seen" in *" $s "*) continue ;; esac
      stack_is_active "$s" && { echo "$s"; seen+="$s "; }
    done
  done
}

# stack_conf STACK KEY DEFAULT — read KEY from <stack>/stack.conf, else DEFAULT.
stack_conf() {
  local d v=""; d="$(stack_dir "$1" 2>/dev/null)" || { echo "$3"; return 0; }
  [[ -f "$d/stack.conf" ]] && v="$(grep -E "^${2}=" "$d/stack.conf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\''')"
  echo "${v:-$3}"
}

stack_wave()   { stack_conf "$1" WAVE 3; }
stack_mounts() { stack_conf "$1" MOUNTS ""; }
stack_auto()   { [[ "$(stack_conf "$1" DEPLOY auto)" != "manual" ]]; }

# deploy_list — active, auto-deploy stacks (skips DEPLOY=manual), ordered by wave.
deploy_list() {
  local s; for s in $(discover_stacks); do stack_auto "$s" && echo "$s"; done \
    | while read -r s; do printf '%s %s\n' "$(stack_wave "$s")" "$s"; done \
    | sort -k1,1n -k2,2 | awk '{print $2}'
}

# stacks_for_mount MOUNT — stacks declaring this storage dep (mount-watchdog).
stacks_for_mount() {
  local want="$1" s m
  for s in $(discover_stacks); do
    for m in $(stack_mounts "$s"); do [[ "$m" == "$want" ]] && echo "$s"; done
  done
}

# dc STACK ARGS... — docker compose for a stack, auto-including its override
# (compose drops the auto-override once -f is passed, so we re-add it).
dc() {
  local s="$1"; shift
  local d; d="$(stack_dir "$s")" || { warn "no such stack: $s"; return 1; }
  local f=(-f "$d/docker-compose.yml")
  [[ -f "$d/docker-compose.override.yml" ]] && f+=(-f "$d/docker-compose.override.yml")
  docker compose "${f[@]}" --env-file "$ENV_FILE" "$@"
}

# ensure_network — idempotently create the shared bridge network (default: home).
# Called on deploy so ANY repo brought up first creates it; harmless when it
# already exists. This is why every stack can safely use `external: true`.
ensure_network() {
  local net="${HOME_NETWORK:-home}"
  docker network inspect "$net" >/dev/null 2>&1 && return 0
  say "creating docker network: $net"
  docker network create "$net" >/dev/null 2>&1 || warn "could not create network: $net"
}
