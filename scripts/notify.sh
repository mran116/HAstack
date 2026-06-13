#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# notify.sh TOPIC TITLE MESSAGE — best-effort ntfy push.
# Reuses the SERVER_IP / NTFY_PORT from .env (same mechanism as sab-watchdog).
# No-op (exit 0) if ntfy isn't configured, so callers never fail because of it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
[[ -f "$ENV_FILE" ]] && load_env || true

topic="${1:?usage: notify.sh TOPIC TITLE MESSAGE}"
title="${2:-}"
msg="${3:-}"
[[ -n "${NTFY_PORT:-}" && -n "${SERVER_IP:-}" ]] || exit 0

python3 - "http://${SERVER_IP}:${NTFY_PORT}/${topic}" "$title" "$msg" <<'PY' 2>/dev/null || true
import sys, urllib.request
url, title, body = sys.argv[1], sys.argv[2], sys.argv[3]
req = urllib.request.Request(
    url, data=body.encode(), method='POST',
    headers={'Title': title, 'Priority': 'high', 'Tags': 'rotating_light'})
try:
    urllib.request.urlopen(req, timeout=10).read()
except Exception:
    pass
PY
