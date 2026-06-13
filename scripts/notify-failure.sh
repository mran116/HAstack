#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# notify-failure.sh UNIT — ntfy alert when a systemd unit fails.
# Wired via `OnFailure=homestack-notify-failure@%n.service`, so a backup that
# can't even start (script missing, OOM, mount gone) still alerts — unlike an
# in-script trap. Includes the unit's last log lines for context.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit="${1:-unknown}"
log_tail="$(journalctl -u "$unit" -n 12 --no-pager -o cat 2>/dev/null || true)"
exec "$SCRIPT_DIR/notify.sh" homestack "FAILED: $unit" \
  "$unit failed on $(hostname) at $(date '+%F %T')

--- last log lines ---
$log_tail"
