#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# bootstrap.sh — FIRST-RUN host setup for a homestack repo (generic).
#
# Run ONCE when first setting up THIS repo on a host. Each step previews what it
# will do, then asks before applying. Idempotent (safe to re-run). Discovery-
# driven: no stack is named here — it sets up the .env, dirs, network, and `hs`,
# optionally enables the edge module (caddy/tailscale), then brings every
# discovered stack up in wave order and runs each stack's post-deploy hook.
#
# After the first run, the routine commands are:
#   hs update    pull latest + redeploy           hs doctor   health check
#   hs help      list every command
#
# Flags:
#   --dry-run    preview every step, change nothing
#   --yes        apply every step without prompting (non-interactive)
#   --no-deploy  set up the host but don't bring stacks up (deploy later)
# =============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"
# shellcheck source=scripts/lib/common.sh
source "$REPO_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/stacks.sh
source "$REPO_DIR/scripts/lib/stacks.sh"

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
NO_DEPLOY=0; for a in "$@"; do [[ "$a" == "--no-deploy" ]] && NO_DEPLOY=1; done

PASS=()
[[ $DRY_RUN -eq 1 ]]    && PASS+=(--dry-run)
[[ $ASSUME_YES -eq 1 ]] && PASS+=(--yes)

say "Checking prerequisites"
require_docker

run() { echo; say "── ${1%.sh}"; "$REPO_DIR/scripts/$1" "${PASS[@]}"; }

# --- host setup (generic, no stack names) -----------------------------------
run env-init.sh
run env-sync.sh
run gen-secrets.sh
[[ -x "$REPO_DIR/scripts/make-dirs.sh" ]] && run make-dirs.sh
run link-env.sh
run create-network.sh
run schedule-maintenance.sh

# Put `hs` on PATH (+ tab-completion) so it runs from anywhere.
if [[ $DRY_RUN -eq 0 ]]; then echo; say "── hs install"; "$REPO_DIR/hs" install || true; fi

# --- optional: edge module (caddy / tailscale) ------------------------------
# Per-machine reverse-proxy + mesh. Enabled via COMPOSE_PROFILES in .env, so we
# just point at it here; the stacks themselves opt in by being on the home net.
if [[ -d "$REPO_DIR/edge" && $DRY_RUN -eq 0 ]]; then
  echo
  if [[ $ASSUME_YES -eq 0 ]] && ask_yn "Enable the edge module (caddy reverse-proxy / tailscale mesh) on this host?" N; then
    say "Edge profiles are set in .env via COMPOSE_PROFILES (e.g. 'caddy', 'tailscale')."
    say "Set them, then: docker compose -f edge/docker-compose.yml --env-file .env up -d"
  fi
fi

# --- deploy + per-stack post-deploy hooks -----------------------------------
if [[ $NO_DEPLOY -eq 1 ]]; then
  echo; say "--no-deploy: host is set up; bring stacks up later with 'hs startup' or 'hs up'."
elif [[ $DRY_RUN -eq 1 ]]; then
  echo; say "Would bring up discovered stacks in wave order (skipped in --dry-run):"
  for s in $(deploy_list); do echo "   wave $(stack_wave "$s")  $s"; done
else
  echo
  if [[ $ASSUME_YES -eq 1 ]] || ask_yn "Bring all stacks up now (wave-ordered)?" Y; then
    "$REPO_DIR/scripts/staggered-up.sh" "${PASS[@]}"
    for s in $(deploy_list); do
      d="$(stack_dir "$s")"
      for hook in "$d/post-deploy.sh" "$d/scripts/post-deploy.sh"; do
        [[ -x "$hook" ]] || continue
        say "post-deploy: $s"; ( cd "$d" && ENV_FILE="$ENV_FILE" "$hook" --yes ) || warn "$s post-deploy hook failed"; break
      done
    done
  fi
fi

echo
say "Bootstrap complete."
[[ $DRY_RUN -eq 1 ]] && exit 0
load_env 2>/dev/null || true
cat <<EOF

Next steps:
  • Third-party tokens (VPN keys, Diun/Tailscale/Cloudflare, widget API keys)
    still need filling — run:  hs keys   (after the apps are up)
  • Health check anytime:      hs doctor
  • Routine updates:           hs update
EOF
