#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# create-network.sh — create the shared external docker network `home`.
#
# Every stack attaches to this one network so containers can reach each other
# by name across stacks. No-op if it already exists. Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
require_docker

if docker network inspect home >/dev/null 2>&1; then
  say "Docker network 'home' already exists."
  exit 0
fi

plan "create docker network 'home'"
show_plan || exit 0
gate || exit 0

docker network create home >/dev/null
say "Created docker network 'home'."
