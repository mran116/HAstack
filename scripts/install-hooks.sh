#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# install-hooks.sh — install this repo's git hooks (idempotent, re-run safe):
#
#   pre-push   : runs `docker compose config` on every stack so a broken YAML /
#                interpolation error is caught locally BEFORE it reaches GitHub
#                (same check CI runs, just earlier). Bypass: git push --no-verify
#   pre-commit : leak-guard — scans the staged diff against a LOCAL denylist of
#                PII patterns and blocks the commit on a match. The hook is
#                generic + safe to commit; the denylist is local/gitignored:
#                $HOMESTACK_LEAK_DENYLIST or ~/.config/homestack/leak-denylist.txt
#                (one regex per line). No denylist on the box => the hook is a
#                no-op, so a fresh clone on a friend's machine is unaffected.
#                Bypass: git commit --no-verify
#
# Flags: --dry-run, --yes.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
cd "$REPO_DIR"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
[[ -d "$REPO_DIR/.git" ]] || die "Not a git repository (no .git dir): $REPO_DIR"

pp_hook="$REPO_DIR/.git/hooks/pre-push"
pc_hook="$REPO_DIR/.git/hooks/pre-commit"
pp_tmp="$(mktemp)"; pc_tmp="$(mktemp)"; trap 'rm -f "$pp_tmp" "$pc_tmp"' EXIT

cat > "$pp_tmp" <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/install-hooks.sh — validates compose before pushing.
# Bypass once with:  git push --no-verify
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
env="$([[ -f .env ]] && echo .env || echo .env.example)"
[[ -f "$env" ]] || exit 0                # no env file -> can't resolve vars, skip
command -v docker >/dev/null || exit 0   # no docker -> skip (CI still checks)
fail=0
for f in */docker-compose.yml; do
  docker compose -f "$f" --env-file "$env" config -q 2>/dev/null && continue
  active=$(awk '/^services:/{i=1;next} /^[^[:space:]#]/{i=0} i&&/^  [A-Za-z0-9_-]+:[[:space:]]*$/{n++} END{print n+0}' "$f")
  [[ "${active:-0}" -eq 0 ]] && continue   # all-commented placeholder
  echo "pre-push: INVALID compose: $f  (fix it, or 'git push --no-verify' to bypass)" >&2
  fail=1
done
exit $fail
HOOK

cat > "$pc_tmp" <<'HOOK'
#!/usr/bin/env bash
# Installed by scripts/install-hooks.sh — leak-guard. Scans the staged diff
# against a LOCAL denylist of PII patterns and blocks the commit on a match.
# Denylist (local/gitignored, one regex per line):
#   $HOMESTACK_LEAK_DENYLIST  or  ~/.config/homestack/leak-denylist.txt
# No denylist => no-op (safe on a fresh clone). Bypass: git commit --no-verify
set -euo pipefail
deny="${HOMESTACK_LEAK_DENYLIST:-$HOME/.config/homestack/leak-denylist.txt}"
[[ -f "$deny" ]] || exit 0
staged="$(git diff --cached -U0 2>/dev/null || true)"
[[ -n "$staged" ]] || exit 0
hit=0
while IFS= read -r pat; do
  [[ -z "$pat" || "$pat" == \#* ]] && continue
  if grep -nEi -- "$pat" <<<"$staged" >/dev/null 2>&1; then
    echo "leak-guard: staged change matches blocked pattern: $pat" >&2; hit=1
  fi
done < "$deny"
[[ $hit -eq 0 ]] || { echo "leak-guard: commit blocked — use a placeholder, or 'git commit --no-verify'." >&2; exit 2; }
exit 0
HOOK

# Plan only what's missing or has drifted — a quiet no-op when in sync, so
# `hs update` can re-apply on every run without churn.
if   [[ ! -f "$pp_hook" ]];                          then plan "install git pre-push hook → $pp_hook"
elif ! diff -q "$pp_hook" "$pp_tmp" >/dev/null 2>&1; then plan "update git pre-push hook → $pp_hook (repo changed)"
fi
if   [[ ! -f "$pc_hook" ]];                          then plan "install git pre-commit leak-guard → $pc_hook"
elif ! diff -q "$pc_hook" "$pc_tmp" >/dev/null 2>&1; then plan "update git pre-commit leak-guard → $pc_hook (repo changed)"
fi
show_plan || exit 0
gate || exit 0
install -m 0755 "$pp_tmp" "$pp_hook"
install -m 0755 "$pc_tmp" "$pc_hook"
say "git hooks in sync: pre-push (compose validation) + pre-commit (leak-guard)."
[[ -f "${HOMESTACK_LEAK_DENYLIST:-$HOME/.config/homestack/leak-denylist.txt}" ]] \
  || warn "leak-guard idle: no denylist yet at ~/.config/homestack/leak-denylist.txt (one PII regex per line)."
