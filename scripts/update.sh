#!/usr/bin/env bash
# ⚠ VENDORED FROM core — DO NOT EDIT HERE. Change it in the core repo, then run sync-tooling.
# =============================================================================
# update.sh — pull the latest repo, reconcile, redeploy. (generic / multi-repo)
#
#   1. fetch; pull if there are new commits (autostash — survives Arcane edits)
#   2. reconcile: env-sync + gen-secrets + link-env + make-dirs
#   3. ask about any NEW stacks (deploy or exclude); decided ones aren't re-asked
#   4. re-apply cron + git hooks IF already set up (fixes drift; never imposes)
#   5. validate every discovered stack's compose (aborts redeploy if one is broken)
#   6. redeploy enabled stacks with --remove-orphans
#   7. run each deployed stack's post-deploy.sh hook (app-specific: profile syncs,
#      auth patches, …) — so that logic lives WITH the stack, not in here
#   8. doctor — surface anything still needing you
#
# Discovery-driven: no stack is named here. App-specific post-deploy steps belong
# in <stack>/post-deploy.sh (or <stack>/scripts/post-deploy.sh). Generic for any
# repo on any machine. Flags: --dry-run, --yes (cron), --images.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/stacks.sh
source "$SCRIPT_DIR/lib/stacks.sh"
cd "$REPO_DIR"

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"
PULL_IMAGES=0; for a in "$@"; do [[ "$a" == "--images" ]] && PULL_IMAGES=1; done
require_cmd git; require_docker
git rev-parse --git-dir >/dev/null 2>&1 || die "Not a git repository: $REPO_DIR"

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "HEAD" ]] && die "Detached HEAD — check out a branch first."

say "Fetching origin/$branch"
for i in 1 2 3 4; do git fetch origin "$branch" 2>/dev/null && break || { warn "fetch failed (try $i)"; sleep $((i*2)); }; done
incoming="$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"
[[ "$incoming" -eq 0 ]] && say "No new commits — will still reconcile + redeploy."

[[ "$incoming" -gt 0 ]] && plan "git pull origin $branch ($incoming new commit(s))"
plan "reconcile: env-sync + gen-secrets + link-env + make-dirs + new-stack check + cron/hooks"
[[ $PULL_IMAGES -eq 1 ]] && plan "docker compose pull (newer images)"
plan "redeploy enabled stacks (--remove-orphans) + run per-stack post-deploy hooks"
plan "run doctor (report)"
show_plan || exit 0
gate || exit 0

# --- pull -------------------------------------------------------------------
if [[ "$incoming" -gt 0 ]]; then
  say "Pulling origin/$branch"
  if [[ -n "$(git status --porcelain)" ]]; then
    git pull --autostash origin "$branch" || die "git pull hit a conflict — resolve it, then re-run."
  else
    git pull origin "$branch" || die "git pull failed."
  fi
fi

# --- reconcile --------------------------------------------------------------
before_vars="$(grep -oE '^[A-Z0-9_]+=' "$ENV_FILE" 2>/dev/null | sort -u || true)"
"$SCRIPT_DIR/env-sync.sh" --yes
"$SCRIPT_DIR/gen-secrets.sh" --yes
"$SCRIPT_DIR/link-env.sh" --yes
[[ -x "$SCRIPT_DIR/make-dirs.sh" ]] && "$SCRIPT_DIR/make-dirs.sh" --yes || true
if [[ $ASSUME_YES -eq 1 ]]; then "$SCRIPT_DIR/stacks.sh" reconcile --yes; else "$SCRIPT_DIR/stacks.sh" reconcile; fi
crontab -l 2>/dev/null | grep -q '# homestack-' && [[ -x "$SCRIPT_DIR/schedule-maintenance.sh" ]] && "$SCRIPT_DIR/schedule-maintenance.sh" --yes
grep -q 'install-hooks.sh' .git/hooks/pre-push 2>/dev/null && [[ -x "$SCRIPT_DIR/install-hooks.sh" ]] && "$SCRIPT_DIR/install-hooks.sh" --yes
after_vars="$(grep -oE '^[A-Z0-9_]+=' "$ENV_FILE" 2>/dev/null | sort -u || true)"
new_vars="$(comm -13 <(printf '%s\n' "$before_vars") <(printf '%s\n' "$after_vars") | grep -v '^$' || true)"
if [[ -n "$new_vars" && $ASSUME_YES -eq 0 ]]; then
  say "New var(s) added to .env:"; printf '   %s\n' $new_vars
  ask_yn "Reformat .env to match the template now?" && [[ -x "$SCRIPT_DIR/env-rebuild.sh" ]] && "$SCRIPT_DIR/env-rebuild.sh" --yes
fi

# --- validate ---------------------------------------------------------------
say "Validating compose files"
bad=0
for s in $(discover_stacks); do
  d="$(stack_dir "$s")"
  docker compose -f "$d/docker-compose.yml" --env-file "$ENV_FILE" config -q >/dev/null 2>&1 || { warn "INVALID compose: $s"; bad=1; }
done
[[ $bad -eq 1 ]] && die "Aborting redeploy — fix the invalid compose above first. (Repo is pulled; nothing redeployed.)"

# --- redeploy ---------------------------------------------------------------
[[ $PULL_IMAGES -eq 1 ]] && { say "Pulling newer images"; "$SCRIPT_DIR/stack.sh" pull || true; }
say "Redeploying stacks (--remove-orphans)"
STACK_UP_ARGS="--remove-orphans" "$SCRIPT_DIR/stack.sh" up

# --- per-stack post-deploy hooks (app-specific logic lives with the stack) ---
for s in $(deploy_list); do
  d="$(stack_dir "$s")"
  for hook in "$d/post-deploy.sh" "$d/scripts/post-deploy.sh"; do
    [[ -x "$hook" ]] || continue
    say "post-deploy: $s"
    ( cd "$d" && ENV_FILE="$ENV_FILE" "$hook" --yes ) || warn "$s post-deploy hook failed"
    break
  done
done

# --- report -----------------------------------------------------------------
echo; say "Post-update health check:"
[[ -x "$SCRIPT_DIR/doctor.sh" ]] && "$SCRIPT_DIR/doctor.sh" || true
say "Update complete."
