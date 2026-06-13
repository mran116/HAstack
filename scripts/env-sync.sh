#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# env-sync.sh — additively top up .env with vars added to .env.example.
#
# Appends any uncommented KEY=default present in .env.example but missing from
# .env (e.g. new ports/services in a newer version). Never modifies, reorders,
# or touches existing values or commented lines. Backs up first.
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
require_cmd python3
require_env || exit 0
require_writable "$ENV_FILE"

missing="$(comm -13 \
  <(grep -oE '^[A-Z0-9_]+=' "$ENV_FILE"  | sed 's/=$//' | sort -u) \
  <(grep -oE '^[A-Z0-9_]+=' .env.example | sed 's/=$//' | sort -u))"

[[ -z "$missing" ]] && { say "No missing variables — .env is in sync with .env.example."; exit 0; }

while IFS= read -r k; do [[ -n "$k" ]] && plan "append $k (with .env.example default)"; done <<<"$missing"
show_plan || exit 0
gate || exit 0

backup_env
{
  echo ""
  echo "# --- added by env-sync on $(date '+%Y-%m-%d') (new since your .env) ---"
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    grep -E "^${key}=" .env.example | head -n1
  done <<<"$missing"
} >> "$ENV_FILE"
say "Appended $(printf '%s\n' "$missing" | grep -c .) variable(s). Review them at the bottom of .env."
