#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# gen-secrets.sh — fill ONLY blank machine secrets with random values.
#
# Safe on a partial or existing setup: anything already set is left untouched.
# A DB-password key is SKIPPED if that database's data dir already exists (a
# live Postgres/MariaDB only honours its password on first init), so we can't
# orphan an existing DB — you paste the original password yourself.
# Also generates Arcane's ENCRYPTION_KEY / JWT_SECRET (base64) if blank.
# Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
require_cmd python3
require_env || exit 0
require_writable "$ENV_FILE"

# User-facing / external credentials (VPN keys, third-party tokens, admin
# passwords) are deliberately NOT here — they need a human or external account.
SECRET_KEYS='VAULTWARDEN_ADMIN_TOKEN PAPERLESS_DB_PASSWORD PAPERLESS_SECRET_KEY PAPERLESS_ADMIN_PASSWORD IMMICH_DB_PASSWORD GITEA_DB_PASSWORD DONETICK_JWT_SECRET WGER_DB_PASSWORD WGER_SECRET_KEY WGER_SIGNING_KEY CROWDSEC_BOUNCER_KEY KARAKEEP_NEXTAUTH_SECRET KARAKEEP_MEILI_KEY'

# secrets_pass MODE(plan|apply) — emits "FILL <key>" / "GUARD <key>" lines; only
# writes the file when MODE=apply. Single source of truth for both passes.
secrets_pass() {
  python3 - "$1" "$SECRET_KEYS" "$ENV_FILE" <<'PY'
import sys, os, re, pathlib, secrets, string
mode, keys_str, path = sys.argv[1], sys.argv[2], sys.argv[3]
keys = set(keys_str.split())
DB_DIRS = {
    "IMMICH_DB_PASSWORD":   "immich/db",
    "PAPERLESS_DB_PASSWORD":"paperless/db",
    "GITEA_DB_PASSWORD":    "gitea/db",
    "WGER_DB_PASSWORD":     "wger/db",
}
text = pathlib.Path(path).read_text()
m = re.search(r"(?m)^CONFIG_PATH=(.*)$", text)
config_path = (m.group(1).strip() if m else "") or "/opt/docker/data"

def db_exists(sub):
    d = os.path.join(config_path, sub)
    if not os.path.isdir(d):
        return False
    try:
        return any(os.scandir(d))
    except PermissionError:
        # An unreadable dir is almost certainly a live, container-owned DB data
        # dir (e.g. Postgres, mode 700). Guard it rather than crash the script.
        return True

gen = lambda n=36: "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))
out, filled, guarded = [], [], []
for line in text.splitlines():
    mm = re.match(r"^([A-Z0-9_]+)=\s*(#.*)?$", line)
    if mm and mm.group(1) in keys:
        k = mm.group(1)
        if k in DB_DIRS and db_exists(DB_DIRS[k]):
            out.append(line); guarded.append(k)
        else:
            out.append(f"{k}={gen()}" if mode == "apply" else line); filled.append(k)
    else:
        out.append(line)
if mode == "apply":
    pathlib.Path(path).write_text("\n".join(out) + "\n")
for k in filled:  print(f"FILL {k}")
for k in guarded: print(f"GUARD {k}")
PY
}

report="$(secrets_pass plan)"
if [[ -n "$report" ]]; then
  while read -r tag key; do
    case "$tag" in
      FILL)  plan "generate secret: $key" ;;
      GUARD) plan "SKIP $key — existing database found; paste its original password yourself" ;;
    esac
  done <<<"$report"
fi

# Arcane keys want a proper base64 32-byte value. Prefer openssl; fall back to
# python3 (already required above) so a box WITHOUT openssl still gets real keys
# instead of silently-blank ones — Arcane won't start with empty crypto keys.
gen_b64_32() {
  if command -v openssl >/dev/null; then openssl rand -base64 32
  else python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())'; fi
}
arcane_keys=()
for k in ARCANE_ENCRYPTION_KEY ARCANE_JWT_SECRET; do
  if [[ -z "$(current_value "$k")" ]]; then arcane_keys+=("$k"); plan "generate $k (base64 32)"; fi
done

show_plan || exit 0
gate || exit 0

secrets_pass apply >/dev/null
if [[ ${#arcane_keys[@]} -gt 0 ]]; then
  for k in "${arcane_keys[@]}"; do update_env "$k" "$(gen_b64_32)"; done
fi

# Report guarded keys prominently — the user must act on these.
while read -r tag key; do
  [[ "$tag" == GUARD ]] || continue
  warn "$key left blank — existing DB detected. Paste the password it was created with, or the app won't connect."
done <<<"$report"
say "Secrets filled. Store the final values in Vaultwarden."
