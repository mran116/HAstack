#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# env-rebuild.sh — rewrite .env to match .env.example's structure.
#
# Regenerates .env following .env.example's sections, order and comments, while
# carrying over ALL your existing values. Vars you set that aren't in the
# template are preserved in a trailing "LOCAL EXTRAS" block (never dropped). An
# optional var you activated (e.g. uncommented GITEA_HTTP_PORT) keeps its place
# in the template, uncommented. Shows a diff, backs up, then applies.
# Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
require_cmd python3
require_env || exit 0
require_writable "$ENV_FILE"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

python3 - "$ENV_FILE" .env.example > "$tmp" <<'PY'
import sys, re, pathlib
env_path, ex_path = sys.argv[1], sys.argv[2]
env_lines = pathlib.Path(env_path).read_text().splitlines()
ex_lines  = pathlib.Path(ex_path).read_text().splitlines()

key_re    = re.compile(r'^([A-Z0-9_]+)=(.*?)(\s+#.*)?$')   # active KEY=value [# comment]
comkey_re = re.compile(r'^#\s*([A-Z0-9_]+)=')              # commented optional KEY=

# Existing values from the live .env.
user = {}
for ln in env_lines:
    m = key_re.match(ln)
    if m:
        user[m.group(1)] = m.group(2)

out, consumed = [], set()
for ln in ex_lines:
    m = key_re.match(ln)
    if m:
        k, comment = m.group(1), (m.group(3) or '')
        if k in user:
            out.append(f"{k}={user[k]}{comment}"); consumed.add(k)
        else:
            out.append(ln)                      # template default line, untouched
        continue
    cm = comkey_re.match(ln)
    if cm and cm.group(1) in user:
        k = cm.group(1)
        out.append(f"{k}={user[k]}"); consumed.add(k)   # you activated this optional var
        continue
    out.append(ln)                              # comment / blank / section header — verbatim

extras = [k for k in user if k not in consumed]
if extras:
    bar = "# " + "=" * 77
    out += ["", bar, "# LOCAL EXTRAS — not in .env.example (preserved by env-rebuild)", bar]
    seen = set()
    for ln in env_lines:                        # keep their original lines + order
        m = key_re.match(ln)
        if m and m.group(1) in extras and m.group(1) not in seen:
            out.append(ln); seen.add(m.group(1))

print("\n".join(out))
PY

if diff -q "$ENV_FILE" "$tmp" >/dev/null 2>&1; then
  say "Already structured — .env matches the .env.example layout."
  exit 0
fi

say "Planned .env changes (diff — '<' current, '>' rebuilt):"
diff "$ENV_FILE" "$tmp" || true
echo
gate || exit 0

backup_env
cp "$tmp" "$ENV_FILE"
say "Rebuilt .env in template structure. Review it, then redeploy affected stacks."
