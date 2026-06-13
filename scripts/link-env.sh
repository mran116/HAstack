#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# link-env.sh — wire every stack to the single root .env.
#
# Sets STACKS_PATH to this repo (Arcane's projects dir) and symlinks the root
# .env into each stack folder (<stack>/.env -> ../.env) so Arcane and plain
# `docker compose` both find it with no --env-file flag. Idempotent.
# Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
require_env || exit 0
require_writable "$ENV_FILE"
require_writable "$REPO_DIR"

set_stacks_path=0
if [[ "$(current_value STACKS_PATH)" != "$REPO_DIR" ]]; then
  plan "set STACKS_PATH=$REPO_DIR"
  set_stacks_path=1
fi

links=()
for compose in */docker-compose.yml; do
  d="$(dirname "$compose")"
  link="$d/.env"
  if [[ ! -L "$link" || "$(readlink "$link" 2>/dev/null)" != "../.env" ]]; then
    plan "symlink $link -> ../.env"
    links+=("$d")
  fi
done

show_plan || exit 0
gate || exit 0

[[ $set_stacks_path -eq 1 ]] && update_env STACKS_PATH "$REPO_DIR"
if [[ ${#links[@]} -gt 0 ]]; then
  for d in "${links[@]}"; do ln -sf ../.env "$d/.env"; done
fi
say "Stacks wired to the root .env."
